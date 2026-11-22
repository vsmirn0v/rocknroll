import Foundation

/// Canonical site identity for multi-site logins, cookies, and mTLS preferences.
/// One login is stored per normalized HTTPS origin (`https://host[:non-default-port]`).
public enum SiteOrigin {
    public static let telemostCanonicalOrigin = URL(string: "https://telemost.yandex.ru")!

    /// Normalizes user-entered text or a URL into its canonical HTTPS origin.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4_096 else { return nil }
        if !text.contains("://") {
            text = "https://\(text)"
        }
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              let rawHost = parts.host, !rawHost.isEmpty,
              parts.user == nil, parts.password == nil else {
            return nil
        }
        let host = rawHost.lowercased()
        if TelemostTarget.hosts.contains(host), parts.port == nil || parts.port == 443 {
            return telemostCanonicalOrigin
        }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = host
        if let port = parts.port, port != 443 {
            canonical.port = port
        }
        return canonical.url
    }

    /// Extracts canonical HTTPS origin from any URL (including `https://...` or `wss://...`).
    public static func canonicalOrigin(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "wss",
              let rawHost = parts.host, !rawHost.isEmpty,
              parts.user == nil, parts.password == nil else {
            return nil
        }
        let host = rawHost.lowercased()
        if TelemostTarget.hosts.contains(host), parts.port == nil || parts.port == 443 {
            return telemostCanonicalOrigin
        }
        parts.scheme = "https"
        parts.host = host
        if parts.port == 443 { parts.port = nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    public static func canonicalKey(for url: URL) -> String? {
        canonicalOrigin(for: url)?.absoluteString
    }

    public static func canonicalKey(normalizing raw: String) -> String? {
        normalize(raw)?.absoluteString
    }

    /// Returns the last two DNS labels (e.g. `corp.ru` for `api.jazz.corp.ru`) for
    /// subdomain mTLS inheritance when a site discovers a separate API or SSO subdomain.
    public static func registrableSuffix(of host: String) -> String {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = lower.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return lower }
        return labels.suffix(2).joined(separator: ".")
    }

    /// True if `candidateHost` is equal to or shares the same registrable domain suffix as `siteHost`,
    /// or is a Telemost alias when `siteHost` is Telemost.
    public static func hostMatches(_ candidateHost: String, siteHost: String) -> Bool {
        let lhs = candidateHost.lowercased()
        let rhs = siteHost.lowercased()
        if lhs == rhs { return true }
        if TelemostTarget.hosts.contains(lhs) && TelemostTarget.hosts.contains(rhs) {
            return true
        }
        if lhs.hasSuffix("." + rhs) || rhs.hasSuffix("." + lhs) {
            return true
        }
        let suffix = registrableSuffix(of: rhs)
        return suffix.contains(".") && registrableSuffix(of: lhs) == suffix
    }
}

/// Lightweight, signature-agnostic JWT payload inspector for display name, subject, and expiry.
public struct JWTClaims: Equatable, Sendable {
    public var subject: String?
    public var displayName: String?
    public var email: String?
    public var expiresAt: Date?

    public init(subject: String? = nil, displayName: String? = nil, email: String? = nil, expiresAt: Date? = nil) {
        self.subject = subject
        self.displayName = displayName
        self.email = email
        self.expiresAt = expiresAt
    }

    public static func inspect(_ token: String) -> JWTClaims? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let expDate: Date?
        if let exp = json["exp"] as? TimeInterval {
            expDate = Date(timeIntervalSince1970: exp)
        } else if let exp = json["exp"] as? Int {
            expDate = Date(timeIntervalSince1970: TimeInterval(exp))
        } else {
            expDate = nil
        }
        let subject = (json["sub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = (json["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let displayName = [
            json["name"] as? String,
            json["preferred_username"] as? String,
            json["given_name"] as? String,
            email,
            subject
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return JWTClaims(subject: subject, displayName: displayName, email: email, expiresAt: expDate)
    }
}
