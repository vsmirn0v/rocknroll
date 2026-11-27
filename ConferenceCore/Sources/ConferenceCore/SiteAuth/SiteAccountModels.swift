import Foundation

public enum SiteAuthMethod: String, Codable, CaseIterable, Sendable {
    case webSSO = "web_sso"
    case credentials = "credentials"
    case token = "token"
    case mtlsOnly = "mtls_only"

    public var localizedTitle: String {
        switch self {
        case .webSSO: return L("SSO / Web")
        case .credentials: return L("Password")
        case .token: return L("Token")
        case .mtlsOnly: return L("Client Certificate")
        }
    }
}

public struct SerializedHTTPCookie: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresAt: Date? = nil,
        isSecure: Bool = true,
        isHTTPOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    public init?(_ cookie: HTTPCookie) {
        guard !cookie.name.isEmpty else { return nil }
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.expiresAt = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
    }

    public func makeHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path
        ]
        if let expiresAt {
            properties[.expires] = expiresAt
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    public func matches(url: URL, now: Date = Date()) -> Bool {
        if let expiresAt, expiresAt <= now { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if isSecure && url.scheme?.lowercased() != "https" && url.scheme?.lowercased() != "wss" {
            return false
        }
        let cleanDomain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !cleanDomain.isEmpty else { return false }
        let hostMatches = if domain.hasPrefix(".") {
            host == cleanDomain || host.hasSuffix("." + cleanDomain)
        } else {
            host == cleanDomain || host.hasSuffix("." + cleanDomain)
        }
        guard hostMatches else { return false }
        let cookiePath = path.isEmpty ? "/" : path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if cookiePath == "/" { return true }
        return requestPath == cookiePath || requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
    }

    public static func cookieHeader(from cookies: [SerializedHTTPCookie], for url: URL, now: Date = Date()) -> String? {
        let matching = cookies.filter { $0.matches(url: url, now: now) }
        guard !matching.isEmpty else { return nil }
        // Keep last value per cookie name if duplicates exist across paths/domains.
        var orderedNames: [String] = []
        var values: [String: String] = [:]
        for cookie in matching {
            if values[cookie.name] == nil { orderedNames.append(cookie.name) }
            values[cookie.name] = cookie.value
        }
        return orderedNames.compactMap { name in
            values[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }
}

public struct SiteAccountRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { originKey }
    public var originKey: String
    public var engine: MeetingEngineKind
    public var authMethod: SiteAuthMethod
    public var username: String?
    public var userDisplayName: String?
    public var clientCertificateID: UUID?
    public var systemCertificateFingerprint: String?
    public var tokenEndpoint: String?
    public var discoveredServerURL: String?
    public var tokenExpiresAt: Date?
    public var lastAuthenticatedAt: Date?
    public var needsReauthentication: Bool

    public init(
        originKey: String,
        engine: MeetingEngineKind,
        authMethod: SiteAuthMethod,
        username: String? = nil,
        userDisplayName: String? = nil,
        clientCertificateID: UUID? = nil,
        systemCertificateFingerprint: String? = nil,
        tokenEndpoint: String? = nil,
        discoveredServerURL: String? = nil,
        tokenExpiresAt: Date? = nil,
        lastAuthenticatedAt: Date? = Date(),
        needsReauthentication: Bool = false
    ) {
        self.originKey = originKey
        self.engine = engine
        self.authMethod = authMethod
        self.username = username
        self.userDisplayName = userDisplayName
        self.clientCertificateID = clientCertificateID
        self.systemCertificateFingerprint = systemCertificateFingerprint
        self.tokenEndpoint = tokenEndpoint
        self.discoveredServerURL = discoveredServerURL
        self.tokenExpiresAt = tokenExpiresAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
        self.needsReauthentication = needsReauthentication
    }

    public var originURL: URL? { URL(string: originKey) }

    public var hostDisplayName: String {
        originURL?.host ?? originKey
    }

    public var hasClientCertificate: Bool {
        clientCertificateID != nil || systemCertificateFingerprint?.isEmpty == false
    }

    public var isSignedIn: Bool {
        !needsReauthentication && lastAuthenticatedAt != nil
    }

    public var displayAccountSummary: String {
        let candidates = [userDisplayName, username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = candidates.first { return first }
        if authMethod == .mtlsOnly { return L("Client certificate") }
        return L("Signed in")
    }
}

public struct SiteSecretPayload: Codable, Equatable, Sendable {
    public var accessToken: String?
    public var refreshToken: String?
    public var savedPassword: String?
    public var oauthClientID: String?
    public var oauthClientSecret: String?
    public var cookies: [SerializedHTTPCookie]

    public init(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        savedPassword: String? = nil,
        oauthClientID: String? = nil,
        oauthClientSecret: String? = nil,
        cookies: [SerializedHTTPCookie] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.savedPassword = savedPassword
        self.oauthClientID = oauthClientID
        self.oauthClientSecret = oauthClientSecret
        self.cookies = cookies
    }

    public var isEmpty: Bool {
        (accessToken?.isEmpty ?? true) &&
        (refreshToken?.isEmpty ?? true) &&
        (savedPassword?.isEmpty ?? true) &&
        (oauthClientID?.isEmpty ?? true) &&
        (oauthClientSecret?.isEmpty ?? true) &&
        cookies.isEmpty
    }
}

public struct StoredPKCS12Blob: Codable, Equatable, Sendable {
    public var data: Data
    public var passphrase: String

    public init(data: Data, passphrase: String) {
        self.data = data
        self.passphrase = passphrase
    }
}

public struct StoredRoomPoolSecret: Codable, Equatable, Sendable {
    public var authToken: String
    public var writeToken: String?

    public init(authToken: String, writeToken: String? = nil) {
        self.authToken = authToken
        self.writeToken = writeToken
    }

    public var isEmpty: Bool {
        authToken.isEmpty && (writeToken?.isEmpty ?? true)
    }
}
