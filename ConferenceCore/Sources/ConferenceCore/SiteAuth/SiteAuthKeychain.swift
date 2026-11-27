import Foundation
import Security

public protocol SiteSecretStoring: Sendable {
    func readSiteSecret(originKey: String) -> SiteSecretPayload?
    @discardableResult func writeSiteSecret(_ payload: SiteSecretPayload?, originKey: String) -> Bool
    func readCertificateBlob(id: UUID) -> StoredPKCS12Blob?
    @discardableResult func writeCertificateBlob(_ blob: StoredPKCS12Blob?, id: UUID) -> Bool
    func readPoolSecret(poolKey: String) -> StoredRoomPoolSecret?
    @discardableResult func writePoolSecret(_ secret: StoredRoomPoolSecret?, poolKey: String) -> Bool
}

/// Data Protection Keychain store for per-site credentials/tokens and imported mTLS PKCS#12 blobs.
public struct KeychainSiteSecretStore: SiteSecretStoring {
    public let service: String

    public init(service: String = "dev.vsmirn0v.conferenceguest.siteauth") {
        self.service = service
    }

    public func readSiteSecret(originKey: String) -> SiteSecretPayload? {
        guard let data = readData(account: "site:\(originKey.lowercased())") else { return nil }
        return try? JSONDecoder().decode(SiteSecretPayload.self, from: data)
    }

    @discardableResult
    public func writeSiteSecret(_ payload: SiteSecretPayload?, originKey: String) -> Bool {
        let account = "site:\(originKey.lowercased())"
        guard let payload, !payload.isEmpty, let data = try? JSONEncoder().encode(payload) else {
            return deleteData(account: account)
        }
        return writeData(data, account: account)
    }

    public func readCertificateBlob(id: UUID) -> StoredPKCS12Blob? {
        guard let data = readData(account: "p12:\(id.uuidString.lowercased())") else { return nil }
        return try? JSONDecoder().decode(StoredPKCS12Blob.self, from: data)
    }

    @discardableResult
    public func writeCertificateBlob(_ blob: StoredPKCS12Blob?, id: UUID) -> Bool {
        let account = "p12:\(id.uuidString.lowercased())"
        guard let blob, !blob.data.isEmpty, let data = try? JSONEncoder().encode(blob) else {
            return deleteData(account: account)
        }
        return writeData(data, account: account)
    }

    public func readPoolSecret(poolKey: String) -> StoredRoomPoolSecret? {
        guard let data = readData(account: "pool:\(poolKey.lowercased())") else { return nil }
        return try? JSONDecoder().decode(StoredRoomPoolSecret.self, from: data)
    }

    @discardableResult
    public func writePoolSecret(_ secret: StoredRoomPoolSecret?, poolKey: String) -> Bool {
        let account = "pool:\(poolKey.lowercased())"
        guard let secret, !secret.isEmpty, let data = try? JSONEncoder().encode(secret) else {
            return deleteData(account: account)
        }
        return writeData(data, account: account)
    }

    private func baseQuery(account: String) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }

    private final class EphemeralKeychainFallback: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func read(service: String, account: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return storage["\(service)\0\(account)"]
        }

        func write(_ data: Data, service: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            storage["\(service)\0\(account)"] = data
        }

        func delete(service: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            storage.removeValue(forKey: "\(service)\0\(account)")
        }
    }

    private static let ephemeralFallback = EphemeralKeychainFallback()

    private func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return result as? Data
        }
        return Self.ephemeralFallback.read(service: service, account: account)
    }

    private func writeData(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess {
            Self.ephemeralFallback.delete(service: service, account: account)
            return true
        }
        if status == errSecMissingEntitlement {
            Self.ephemeralFallback.write(data, service: service, account: account)
            return true
        }
        return false
    }

    private func deleteData(account: String) -> Bool {
        Self.ephemeralFallback.delete(service: service, account: account)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
    }
}

public final class InMemorySiteSecretStore: SiteSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: SiteSecretPayload] = [:]
    private var certs: [UUID: StoredPKCS12Blob] = [:]
    private var poolSecrets: [String: StoredRoomPoolSecret] = [:]

    public init() {}

    public func readSiteSecret(originKey: String) -> SiteSecretPayload? {
        lock.lock(); defer { lock.unlock() }
        return secrets[originKey.lowercased()]
    }

    @discardableResult
    public func writeSiteSecret(_ payload: SiteSecretPayload?, originKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = originKey.lowercased()
        if let payload, !payload.isEmpty {
            secrets[key] = payload
        } else {
            secrets.removeValue(forKey: key)
        }
        return true
    }

    public func readCertificateBlob(id: UUID) -> StoredPKCS12Blob? {
        lock.lock(); defer { lock.unlock() }
        return certs[id]
    }

    @discardableResult
    public func writeCertificateBlob(_ blob: StoredPKCS12Blob?, id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let blob, !blob.data.isEmpty {
            certs[id] = blob
        } else {
            certs.removeValue(forKey: id)
        }
        return true
    }

    public func readPoolSecret(poolKey: String) -> StoredRoomPoolSecret? {
        lock.lock(); defer { lock.unlock() }
        return poolSecrets[poolKey.lowercased()]
    }

    @discardableResult
    public func writePoolSecret(_ secret: StoredRoomPoolSecret?, poolKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = poolKey.lowercased()
        if let secret, !secret.isEmpty {
            poolSecrets[key] = secret
        } else {
            poolSecrets.removeValue(forKey: key)
        }
        return true
    }
}
