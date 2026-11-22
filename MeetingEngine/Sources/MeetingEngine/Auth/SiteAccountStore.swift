import ConferenceCore
import Foundation

@MainActor
public final class SiteAccountStore: ObservableObject {
    public static let shared = SiteAccountStore()

    @Published public private(set) var accounts: [SiteAccountRecord] = []
    @Published public private(set) var certificates: [ClientCertificateRecord] = []
    #if os(macOS)
    @Published public private(set) var systemCertificates: [ClientCertificateRecord] = []
    #endif

    public let registry: SiteClientIdentityRegistry
    public var secretStore: any SiteSecretStoring { registry.secretStore }
    private let preferences: UserDefaults

    public init(
        preferences: UserDefaults = .standard,
        secretStore: (any SiteSecretStoring)? = nil,
        registry: SiteClientIdentityRegistry? = nil,
        loadSystemIdentities: Bool = true
    ) {
        self.preferences = preferences
        if let registry {
            self.registry = registry
        } else if let secretStore {
            self.registry = SiteClientIdentityRegistry(preferences: preferences, secretStore: secretStore)
        } else {
            self.registry = .shared
        }
        loadFromStorage()
        #if os(macOS)
        if loadSystemIdentities {
            refreshSystemIdentities()
        }
        #endif
    }

    public func account(for url: URL) -> SiteAccountRecord? {
        guard let key = SiteOrigin.canonicalKey(for: url) else { return nil }
        return accounts.first(where: { $0.originKey == key })
    }

    public func account(forOriginKey key: String) -> SiteAccountRecord? {
        let normalized = SiteOrigin.canonicalKey(normalizing: key) ?? key.lowercased()
        return accounts.first(where: { $0.originKey == normalized })
    }

    public nonisolated func hasActiveSession(for url: URL) -> Bool {
        false // Use registry.hasActiveSession(for:) for nonisolated checks
    }

    public func hasActiveSessionOnMain(for url: URL) -> Bool {
        registry.hasActiveSession(for: url)
    }

    public func wasChallengedForClientCertificate(host: String) -> (challenged: Bool, rejected: Bool) {
        registry.wasChallengedForClientCertificate(host: host)
    }

    public func clearClientCertificateChallenge(host: String) {
        registry.clearClientCertificateChallenge(host: host)
    }

    public func readSecret(for originKey: String) -> SiteSecretPayload? {
        let key = SiteOrigin.canonicalKey(normalizing: originKey) ?? originKey.lowercased()
        return secretStore.readSiteSecret(originKey: key)
    }

    @discardableResult
    public func upsertAccount(
        _ incoming: SiteAccountRecord,
        secret: SiteSecretPayload? = nil,
        preservingCertificate: Bool = true
    ) -> SiteAccountRecord {
        var record = incoming
        record.originKey = SiteOrigin.canonicalKey(normalizing: incoming.originKey) ?? incoming.originKey.lowercased()
        if let existing = accounts.first(where: { $0.originKey == record.originKey }), preservingCertificate {
            if record.clientCertificateID == nil && record.systemCertificateFingerprint == nil {
                record.clientCertificateID = existing.clientCertificateID
                record.systemCertificateFingerprint = existing.systemCertificateFingerprint
            }
        }
        if let secret {
            _ = secretStore.writeSiteSecret(secret, originKey: record.originKey)
        }
        if let index = accounts.firstIndex(where: { $0.originKey == record.originKey }) {
            accounts[index] = record
        } else {
            accounts.append(record)
        }
        accounts.sort { $0.hostDisplayName.localizedCaseInsensitiveCompare($1.hostDisplayName) == .orderedAscending }
        persistAccounts()
        if let host = URL(string: record.originKey)?.host {
            clearClientCertificateChallenge(host: host)
        }
        return record
    }

    public func updateSecret(_ secret: SiteSecretPayload?, for originKey: String) {
        let key = SiteOrigin.canonicalKey(normalizing: originKey) ?? originKey.lowercased()
        _ = secretStore.writeSiteSecret(secret, originKey: key)
    }

    public func setClientCertificate(
        importedID: UUID? = nil,
        systemFingerprint: String? = nil,
        forOrigin origin: URL,
        defaultEngine: MeetingEngineKind = .guest
    ) {
        guard let key = SiteOrigin.canonicalKey(for: origin) else { return }
        if var existing = accounts.first(where: { $0.originKey == key }) {
            existing.clientCertificateID = importedID
            existing.systemCertificateFingerprint = systemFingerprint
            _ = upsertAccount(existing, preservingCertificate: false)
        } else if importedID != nil || systemFingerprint != nil {
            let record = SiteAccountRecord(
                originKey: key,
                engine: defaultEngine,
                authMethod: .mtlsOnly,
                clientCertificateID: importedID,
                systemCertificateFingerprint: systemFingerprint,
                lastAuthenticatedAt: Date(),
                needsReauthentication: false
            )
            _ = upsertAccount(record, preservingCertificate: false)
        }
        clearClientCertificateChallenge(host: origin.host ?? "")
    }

    public func clearClientCertificate(forOriginKey originKey: String) {
        let key = SiteOrigin.canonicalKey(normalizing: originKey) ?? originKey.lowercased()
        guard var existing = accounts.first(where: { $0.originKey == key }) else { return }
        if let host = existing.originURL?.host {
            clearClientCertificateChallenge(host: host)
        }
        if existing.authMethod == .mtlsOnly {
            removeSite(originKey: key)
            return
        }
        existing.clientCertificateID = nil
        existing.systemCertificateFingerprint = nil
        _ = upsertAccount(existing, preservingCertificate: false)
    }

    public func markNeedsReauthentication(_ needs: Bool, for originKey: String) {
        let key = SiteOrigin.canonicalKey(normalizing: originKey) ?? originKey.lowercased()
        guard var existing = accounts.first(where: { $0.originKey == key }) else { return }
        existing.needsReauthentication = needs
        _ = upsertAccount(existing, preservingCertificate: false)
    }

    public func signOut(originKey: String, keepCertificate: Bool = true) {
        let key = SiteOrigin.canonicalKey(normalizing: originKey) ?? originKey.lowercased()
        _ = secretStore.writeSiteSecret(nil, originKey: key)
        guard var existing = accounts.first(where: { $0.originKey == key }) else { return }
        if keepCertificate && existing.hasClientCertificate {
            existing.authMethod = .mtlsOnly
            existing.username = nil
            existing.userDisplayName = nil
            existing.tokenExpiresAt = nil
            existing.needsReauthentication = false
            _ = upsertAccount(existing, preservingCertificate: false)
        } else {
            removeSite(originKey: key)
        }
    }

    public func removeSite(originKey: String) {
        let key = SiteOrigin.canonicalKey(normalizing: originKey) ?? originKey.lowercased()
        if let host = (accounts.first(where: { $0.originKey == key })?.originURL ?? URL(string: key))?.host {
            clearClientCertificateChallenge(host: host)
        }
        _ = secretStore.writeSiteSecret(nil, originKey: key)
        accounts.removeAll { $0.originKey == key }
        persistAccounts()
    }

    @discardableResult
    public func importCertificate(data: Data, passphrase: String, label: String? = nil) throws -> ClientCertificateRecord {
        let unlocked = try ClientCertificateLoader.importPKCS12(data: data, passphrase: passphrase, customLabel: label)
        // Replace existing record with identical fingerprint to avoid duplicates.
        if let existing = certificates.first(where: { $0.sha256Fingerprint == unlocked.record.sha256Fingerprint }) {
            let updatedRecord = ClientCertificateRecord(
                id: existing.id,
                label: label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? label! : unlocked.record.label,
                subjectSummary: unlocked.record.subjectSummary,
                commonName: unlocked.record.commonName,
                issuerSummary: unlocked.record.issuerSummary,
                issuerDERBase64: unlocked.record.issuerDERBase64,
                sha256Fingerprint: unlocked.record.sha256Fingerprint,
                expiresAt: unlocked.record.expiresAt,
                source: .importedPKCS12(id: existing.id),
                createdAt: existing.createdAt
            )
            let updatedUnlocked = UnlockedClientIdentity(
                record: updatedRecord,
                identity: unlocked.identity,
                certificateChain: unlocked.certificateChain,
                issuerDER: unlocked.issuerDER
            )
            _ = secretStore.writeCertificateBlob(StoredPKCS12Blob(data: data, passphrase: passphrase), id: existing.id)
            registry.cachePKCS12Identity(updatedUnlocked, for: existing.id)
            if let index = certificates.firstIndex(where: { $0.id == existing.id }) {
                certificates[index] = updatedRecord
            }
            persistCertificates()
            return updatedRecord
        }

        _ = secretStore.writeCertificateBlob(StoredPKCS12Blob(data: data, passphrase: passphrase), id: unlocked.record.id)
        registry.cachePKCS12Identity(unlocked, for: unlocked.record.id)
        certificates.append(unlocked.record)
        certificates.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        persistCertificates()
        return unlocked.record
    }

    public func deleteCertificate(id: UUID) {
        _ = secretStore.writeCertificateBlob(nil, id: id)
        registry.removePKCS12Identity(for: id)
        certificates.removeAll { $0.id == id }
        persistCertificates()

        var changed = false
        for idx in accounts.indices.reversed() where accounts[idx].clientCertificateID == id {
            if let host = accounts[idx].originURL?.host {
                clearClientCertificateChallenge(host: host)
            }
            accounts[idx].clientCertificateID = nil
            if accounts[idx].authMethod == .mtlsOnly && !accounts[idx].hasClientCertificate {
                _ = secretStore.writeSiteSecret(nil, originKey: accounts[idx].originKey)
                accounts.remove(at: idx)
            }
            changed = true
        }
        if changed {
            persistAccounts()
        }
    }

    public func certificate(for id: UUID?) -> ClientCertificateRecord? {
        guard let id else { return nil }
        return certificates.first(where: { $0.id == id })
    }

    #if os(macOS)
    public func refreshSystemIdentities() {
        let identities = ClientCertificateLoader.availableSystemIdentities()
        var map: [String: UnlockedClientIdentity] = [:]
        for entry in identities {
            map[entry.record.sha256Fingerprint] = entry
        }
        registry.replaceSystemIdentities(map)
        systemCertificates = identities.map(\.record)
    }

    public func systemCertificate(fingerprint: String?) -> ClientCertificateRecord? {
        guard let fingerprint, !fingerprint.isEmpty else { return nil }
        return systemCertificates.first(where: { $0.sha256Fingerprint == fingerprint })
    }
    #endif

    public func certificateSummary(for account: SiteAccountRecord) -> String? {
        if let id = account.clientCertificateID {
            return certificate(for: id)?.label ?? L("Client certificate")
        }
        #if os(macOS)
        if let fp = account.systemCertificateFingerprint {
            return systemCertificate(fingerprint: fp)?.label ?? L("Keychain certificate")
        }
        #endif
        return nil
    }

    private func loadFromStorage() {
        if let data = preferences.data(forKey: SiteClientIdentityRegistry.accountsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SiteAccountRecord].self, from: data) {
            accounts = decoded
        }
        if let data = preferences.data(forKey: SiteClientIdentityRegistry.certificatesDefaultsKey),
           let decoded = try? JSONDecoder().decode([ClientCertificateRecord].self, from: data) {
            certificates = decoded
        }
        syncSnapshot()
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            preferences.set(data, forKey: SiteClientIdentityRegistry.accountsDefaultsKey)
        }
        syncSnapshot()
    }

    private func persistCertificates() {
        if let data = try? JSONEncoder().encode(certificates) {
            preferences.set(data, forKey: SiteClientIdentityRegistry.certificatesDefaultsKey)
        }
    }

    private func syncSnapshot() {
        registry.replaceAccounts(accounts)
    }
}
