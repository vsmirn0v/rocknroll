import ConferenceCore
import Foundation

/// Shared resolution and persistence for one-tap room creation preferences across iOS and macOS.
public enum InstantRoomPreferences {
    public static let lastOriginKey = "siteAuth.lastCreateRoomOrigin"

    private static func isSupportedCreationOrigin(_ url: URL) -> URL? {
        guard let canonical = SiteOrigin.canonicalOrigin(for: url),
              canonical.host?.lowercased() != "rock.glowsoft.ru" else {
            return nil
        }
        return canonical
    }

    public static func loadLastOrigin(defaults: UserDefaults = .standard) -> URL? {
        guard let raw = defaults.string(forKey: lastOriginKey),
              let normalized = SiteOrigin.normalize(raw) else {
            return nil
        }
        return isSupportedCreationOrigin(normalized)
    }

    public static func saveLastOrigin(_ origin: URL, defaults: UserDefaults = .standard) {
        guard let canonical = isSupportedCreationOrigin(origin) else { return }
        defaults.set(canonical.absoluteString, forKey: lastOriginKey)
    }

    /// Ordered deduplicated list of candidate room-creation origins:
    /// 1. Remembered last origin
    /// 2. Signed-in non-community accounts (active sessions first)
    /// 3. Remaining non-community accounts
    /// 4. Suggested origins from history/calendar/fallback
    public static func availableOrigins(
        accounts: [SiteAccountRecord],
        suggestedOrigins: [URL],
        lastOrigin: URL? = nil
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ rawURL: URL?) {
            guard let rawURL,
                  let canonical = isSupportedCreationOrigin(rawURL) else {
                return
            }
            if seen.insert(canonical.absoluteString).inserted {
                result.append(canonical)
            }
        }

        append(lastOrigin)
        for account in accounts where account.engine != .community && !account.needsReauthentication {
            append(account.originURL)
        }
        for account in accounts where account.engine != .community && account.needsReauthentication {
            append(account.originURL)
        }
        for origin in suggestedOrigins {
            append(origin)
        }
        return result
    }

    public static func preferredOrigin(
        accounts: [SiteAccountRecord],
        suggestedOrigins: [URL],
        lastOrigin: URL? = nil
    ) -> URL? {
        availableOrigins(accounts: accounts, suggestedOrigins: suggestedOrigins, lastOrigin: lastOrigin).first
    }

    public static func defaultRoomTitle(displayName: String) -> String {
        let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? L("New meeting") : L("%@’s meeting", clean)
    }
}
