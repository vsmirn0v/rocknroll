import ConferenceCore
import CryptoKit
import Foundation
#if canImport(WebKit) && (os(iOS) || os(macOS))
import WebKit
#endif

/// Derives deterministic per-origin `WKWebsiteDataStore` identifiers so web SSO sessions
/// persist cookies and avoid private-browsing AutoFill restrictions per site origin.
public enum SiteWebDataStore {
    public static func identifier(for origin: URL) -> UUID? {
        guard let canonicalKey = SiteOrigin.canonicalKey(for: origin) else { return nil }
        return uuidV5(forCanonicalKey: canonicalKey)
    }

    public static func identifier(forOriginKey rawKey: String) -> UUID? {
        guard let canonicalKey = SiteOrigin.canonicalKey(normalizing: rawKey) else { return nil }
        return uuidV5(forCanonicalKey: canonicalKey)
    }

    private static func uuidV5(forCanonicalKey canonicalKey: String) -> UUID {
        let digest = SHA256.hash(data: Data("dev.vsmirn0v.conferenceguest.siteauth.webstore.v1:\(canonicalKey)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    #if canImport(WebKit) && (os(iOS) || os(macOS))
    @MainActor
    public static func dataStore(for origin: URL) -> WKWebsiteDataStore {
        if #available(iOS 17.0, macOS 14.0, *), let id = identifier(for: origin) {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        return .nonPersistent()
    }

    @MainActor
    public static func removeDataStore(forOriginKey originKey: String) async {
        guard #available(iOS 17.0, macOS 14.0, *),
              let id = identifier(forOriginKey: originKey) else {
            return
        }
        if let host = SiteOrigin.normalize(originKey)?.host, SiteOrigin.isReservedTestHost(host) {
            return
        }
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: id)
        } catch {
            let store = WKWebsiteDataStore(forIdentifier: id)
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    @MainActor
    public static func scheduleRemoval(forOriginKey originKey: String) {
        Task { @MainActor in
            await removeDataStore(forOriginKey: originKey)
        }
    }
    #endif
}
