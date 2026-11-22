import ConferenceCore
import Foundation

/// Thread-safe, nonisolated registry of saved site accounts and mTLS client identities
/// used synchronously by `URLSession` TLS delegates and `MeetingEngineDetector` probes.
public final class SiteClientIdentityRegistry: SiteClientIdentityLookup, @unchecked Sendable {
    public static let shared = SiteClientIdentityRegistry()

    static let accountsDefaultsKey = "siteAuth.accounts.v1"
    static let certificatesDefaultsKey = "siteAuth.certificates.v1"

    public let secretStore: any SiteSecretStoring
    private let lock = NSLock()
    private var snapshotAccounts: [SiteAccountRecord] = []
    private var unlockedPKCS12: [UUID: UnlockedClientIdentity] = [:]
    private var unlockedSystem: [String: UnlockedClientIdentity] = [:]
    private var challengedHosts: [String: Bool] = [:]

    public init(
        preferences: UserDefaults = .standard,
        secretStore: any SiteSecretStoring = KeychainSiteSecretStore()
    ) {
        self.secretStore = secretStore
        if let data = preferences.data(forKey: Self.accountsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SiteAccountRecord].self, from: data) {
            snapshotAccounts = decoded
        }
    }

    public func replaceAccounts(_ accounts: [SiteAccountRecord]) {
        lock.lock()
        snapshotAccounts = accounts
        lock.unlock()
    }

    public func cachePKCS12Identity(_ unlocked: UnlockedClientIdentity, for id: UUID) {
        lock.lock()
        unlockedPKCS12[id] = unlocked
        lock.unlock()
    }

    public func removePKCS12Identity(for id: UUID) {
        lock.lock()
        unlockedPKCS12.removeValue(forKey: id)
        lock.unlock()
    }

    public func replaceSystemIdentities(_ map: [String: UnlockedClientIdentity]) {
        lock.lock()
        unlockedSystem = map
        lock.unlock()
    }

    public func hasActiveSession(for url: URL) -> Bool {
        guard let key = SiteOrigin.canonicalKey(for: url) else { return false }
        lock.lock()
        let match = snapshotAccounts.first(where: { $0.originKey == key })
        lock.unlock()
        guard let match else { return false }
        return match.isSignedIn || match.hasClientCertificate
    }

    public func wasChallengedForClientCertificate(host: String) -> (challenged: Bool, rejected: Bool) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        let entry = challengedHosts[clean]
        lock.unlock()
        guard let entry else { return (false, false) }
        return (true, entry)
    }

    public func clearClientCertificateChallenge(host: String) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        challengedHosts.removeValue(forKey: clean)
        lock.unlock()
    }

    public func noteClientCertificateChallenge(host: String, port: Int?, rejected: Bool) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        lock.lock()
        challengedHosts[clean] = rejected
        lock.unlock()
    }

    public func clientIdentity(
        for host: String,
        port: Int?,
        distinguishedNames: [Data]?,
        preferredOrigin: URL?
    ) -> UnlockedClientIdentity? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty else { return nil }
        let preferredKey = preferredOrigin.flatMap { SiteOrigin.canonicalKey(for: $0) }

        var requestComponents = URLComponents()
        requestComponents.scheme = "https"
        requestComponents.host = cleanHost
        if let port, port > 0, port != 443 { requestComponents.port = port }
        let exactKey = requestComponents.url.flatMap { SiteOrigin.canonicalKey(for: $0) }

        lock.lock()
        let currentAccounts = snapshotAccounts
        lock.unlock()

        var candidates: [SiteAccountRecord] = []
        if let exactKey, let exact = currentAccounts.first(where: { $0.originKey == exactKey && $0.hasClientCertificate }) {
            candidates.append(exact)
        }
        if let preferredKey,
           let preferred = currentAccounts.first(where: { $0.originKey == preferredKey && $0.hasClientCertificate }),
           !candidates.contains(where: { $0.originKey == preferred.originKey }) {
            candidates.append(preferred)
        }
        for account in currentAccounts where account.hasClientCertificate {
            guard !candidates.contains(where: { $0.originKey == account.originKey }),
                  let siteHost = account.originURL?.host else { continue }
            if SiteOrigin.hostMatches(cleanHost, siteHost: siteHost) {
                candidates.append(account)
            }
        }

        let resolved: [UnlockedClientIdentity] = candidates.compactMap { unlockIdentity(for: $0) }
        guard !resolved.isEmpty else { return nil }

        if let dns = distinguishedNames, !dns.isEmpty,
           let dnMatch = resolved.first(where: { $0.matches(distinguishedNames: dns) }) {
            return dnMatch
        }
        return resolved.first
    }

    private func unlockIdentity(for account: SiteAccountRecord) -> UnlockedClientIdentity? {
        if let id = account.clientCertificateID {
            lock.lock()
            let cached = unlockedPKCS12[id]
            lock.unlock()
            if let cached { return cached }
            guard let blob = secretStore.readCertificateBlob(id: id),
                  let unlocked = try? ClientCertificateLoader.importPKCS12(
                    data: blob.data,
                    passphrase: blob.passphrase,
                    id: id
                  ) else {
                return nil
            }
            lock.lock()
            unlockedPKCS12[id] = unlocked
            lock.unlock()
            return unlocked
        }
        if let fingerprint = account.systemCertificateFingerprint, !fingerprint.isEmpty {
            lock.lock()
            let cached = unlockedSystem[fingerprint]
            lock.unlock()
            if let cached { return cached }
            #if os(macOS)
            let discovered = ClientCertificateLoader.availableSystemIdentities()
            var map: [String: UnlockedClientIdentity] = [:]
            for item in discovered { map[item.record.sha256Fingerprint] = item }
            lock.lock()
            unlockedSystem = map
            let match = map[fingerprint]
            lock.unlock()
            return match
            #endif
        }
        return nil
    }
}
