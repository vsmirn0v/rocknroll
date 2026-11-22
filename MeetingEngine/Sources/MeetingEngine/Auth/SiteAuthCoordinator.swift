import ConferenceCore
import Foundation
#if canImport(WebKit) && (os(iOS) || os(macOS))
import WebKit
#endif

public struct ResolvedSiteCredentials: Equatable, Sendable {
    public let account: SiteAccountRecord
    public let accessToken: String?
    public let cookieHeader: String?
    public let cookies: [SerializedHTTPCookie]

    public init(
        account: SiteAccountRecord,
        accessToken: String? = nil,
        cookieHeader: String? = nil,
        cookies: [SerializedHTTPCookie] = []
    ) {
        self.account = account
        self.accessToken = accessToken
        self.cookieHeader = cookieHeader
        self.cookies = cookies
    }

    public func httpHeaders(for url: URL, engine: MeetingEngineKind) -> [String: String] {
        var headers: [String: String] = [:]
        if let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            switch engine {
            case .guest:
                headers["X-Jazz-Token"] = token
                if token.split(separator: ".").count == 3 {
                    headers["Authorization"] = "Bearer \(token)"
                }
            case .trueconf, .community:
                headers["Authorization"] = "Bearer \(token)"
            case .telemost:
                headers["Authorization"] = "OAuth \(token)"
            }
        }
        if let header = SerializedHTTPCookie.cookieHeader(from: cookies, for: url) ?? cookieHeader,
           !header.isEmpty {
            headers["Cookie"] = header
        }
        return headers
    }
}

public enum SiteAuthError: LocalizedError, Equatable {
    case invalidSiteURL
    case clientCertificateRequired(host: String)
    case clientCertificateRejected(host: String)
    case invalidCredentials(String?)
    case unsupportedEngine
    case verificationFailed(String?)
    case signInRequired(origin: URL, engine: MeetingEngineKind)

    public var errorDescription: String? {
        switch self {
        case .invalidSiteURL:
            return L("Enter a valid HTTPS website address.")
        case .clientCertificateRequired(let host):
            return L("%@ requires a client certificate (mTLS). Import or choose a certificate and try again.", host)
        case .clientCertificateRejected(let host):
            return L("%@ rejected the selected client certificate.", host)
        case .invalidCredentials(let detail):
            return detail ?? L("The username, password, or token was rejected.")
        case .unsupportedEngine:
            return L("This website does not support login or room creation.")
        case .verificationFailed(let detail):
            return detail ?? L("Could not verify your sign-in session on this website.")
        case .signInRequired(let origin, _):
            return L("Sign in to %@ to continue.", origin.host ?? origin.absoluteString)
        }
    }

    /// Returns a canonical origin when an error indicates authentication or a client certificate is needed.
    @MainActor
    public static func challengeOrigin(
        from error: Error,
        attemptedURL: URL?,
        store: SiteAccountStore? = nil
    ) -> URL? {
        let resolvedStore = store ?? .shared
        switch error {
        case let auth as SiteAuthError:
            switch auth {
            case .clientCertificateRequired(let host), .clientCertificateRejected(let host):
                return SiteOrigin.normalize(host) ?? attemptedURL.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            case .signInRequired(let origin, _):
                return SiteOrigin.canonicalOrigin(for: origin) ?? origin
            case .invalidCredentials, .verificationFailed:
                return attemptedURL.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            default:
                return nil
            }
        case let creation as RoomCreationError:
            if case .signInRequired(let origin, _) = creation {
                return SiteOrigin.canonicalOrigin(for: origin) ?? origin
            }
            return nil
        case let telemost as TelemostError:
            if case .admissionRequired = telemost { return SiteOrigin.telemostCanonicalOrigin }
            if case .requestFailed(let code) = telemost, code == 401 || code == 403 {
                return SiteOrigin.telemostCanonicalOrigin
            }
            return nil
        case let trueconf as TrueConfError:
            if trueconf == .unavailable || trueconf == .rejected {
                return attemptedURL.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            }
            return nil
        case let guest as GuestBootstrapError:
            if case .httpStatus(let code) = guest, code == 401 || code == 403 {
                return attemptedURL.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            }
            return nil
        case let guestEngine as GuestEngineError:
            if case .admissionDenied = guestEngine {
                return attemptedURL.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            }
            return nil
        case let urlError as URLError:
            if urlError.code == .clientCertificateRequired || urlError.code == .clientCertificateRejected {
                return attemptedURL.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
            }
            return nil
        default:
            if let attemptedURL, let host = attemptedURL.host,
               resolvedStore.wasChallengedForClientCertificate(host: host).challenged {
                return SiteOrigin.canonicalOrigin(for: attemptedURL)
            }
            return nil
        }
    }
}

@MainActor
public final class SiteAuthCoordinator: ObservableObject {
    public static let shared = SiteAuthCoordinator(store: .shared)

    public let store: SiteAccountStore
    private let makeSession: @Sendable (URL) -> URLSession
    private let verifyTrueConfWebSocketLogin: (@Sendable (URL, String, String, URLSession) async throws -> String?)?
    private let renewWebSession: (@MainActor (URL, [SerializedHTTPCookie], SiteAccountStore) async -> (token: String?, cookies: [HTTPCookie])?)?
    private var refreshTasks: [String: Task<ResolvedSiteCredentials?, Never>] = [:]

    public init(
        store: SiteAccountStore? = nil,
        makeSession: (@Sendable (URL) -> URLSession)? = nil,
        verifyTrueConfWebSocketLogin: (@Sendable (URL, String, String, URLSession) async throws -> String?)? = nil,
        renewWebSession: (@MainActor (URL, [SerializedHTTPCookie], SiteAccountStore) async -> (token: String?, cookies: [HTTPCookie])?)? = nil
    ) {
        let resolvedStore = store ?? .shared
        self.store = resolvedStore
        let registry = resolvedStore.registry
        self.makeSession = makeSession ?? { origin in
            SiteTLSDelegate.makeEphemeralSession(preferredOrigin: origin, lookup: registry, timeout: 15, allowsCookies: false)
        }
        self.verifyTrueConfWebSocketLogin = verifyTrueConfWebSocketLogin
        self.renewWebSession = renewWebSession
    }

    // MARK: - Engine Detection

    public func detectEngine(for rawOrigin: URL) async throws -> (engine: MeetingEngineKind, serverURL: URL?) {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin),
              let host = origin.host?.lowercased() else {
            throw SiteAuthError.invalidSiteURL
        }
        if TelemostTarget.hosts.contains(host) {
            return (.telemost, nil)
        }
        store.clearClientCertificateChallenge(host: host)
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        // 1. Guest (.well-known/jazz-services.json or .well-known/s2b-services.json)
        do {
            let serverURL = try await GuestBootstrap(session: session, useBoundedHTTP: true).discoverServer(origin: origin)
            return (.guest, serverURL)
        } catch let error as URLError {
            throw mapTransportError(error, host: host)
        } catch {
            if let certError = checkClientCertificateChallenge(host: host) {
                throw certError
            }
        }

        // 2. TrueConf Server REST API probes
        for path in ["/api/v4/conferences", "/api/v3.8/conferences", "/api/v4/software/clients"] {
            var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
            components.path = path
            var req = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await BoundedHTTP.load(req, session: session, maximumBytes: 131_072)
                if Self.looksLikeTrueConfResponse(statusCode: response.statusCode, data: data) {
                    return (.trueconf, nil)
                }
            } catch let error as URLError {
                throw mapTransportError(error, host: host)
            } catch {
                if let certError = checkClientCertificateChallenge(host: host) {
                    throw certError
                }
            }
        }

        // 3. Rock / community check
        var jamComponents = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        jamComponents.path = "/api/jams/test"
        var jamRequest = URLRequest(url: jamComponents.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        jamRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await BoundedHTTP.load(jamRequest, session: session, maximumBytes: 32_768),
           response.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["join_protocol"] as? String == "rocknroll-v1" {
            return (.community, nil)
        }

        if let certError = checkClientCertificateChallenge(host: host) {
            throw certError
        }
        throw SiteAuthError.verificationFailed(L("Could not detect a supported meeting service at %@.", host))
    }

    private static func looksLikeTrueConfResponse(statusCode: Int, data: Data) -> Bool {
        guard [200, 400, 401, 403].contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if json["conferences"] != nil || json["conference"] != nil || json["clients"] != nil || json["cnt"] != nil {
            return true
        }
        if let err = json["error"] as? [String: Any], err["message"] != nil || err["code"] != nil {
            return true
        }
        return json["error_description"] != nil
    }

    // MARK: - Sign-In Flows

    @discardableResult
    public func signInWithCredentials(
        origin rawOrigin: URL,
        engine: MeetingEngineKind,
        username rawUsername: String,
        password: String,
        oauthClientID: String? = nil,
        oauthClientSecret: String? = nil
    ) async throws -> SiteAccountRecord {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin),
              let originKey = SiteOrigin.canonicalKey(for: origin) else {
            throw SiteAuthError.invalidSiteURL
        }
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            throw SiteAuthError.invalidCredentials(L("Enter both username and password."))
        }
        let host = origin.host ?? originKey
        store.clearClientCertificateChallenge(host: host)
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        let existing = store.account(forOriginKey: originKey)
        switch engine {
        case .trueconf:
            return try await signInTrueConfCredentials(
                origin: origin,
                originKey: originKey,
                username: username,
                password: password,
                oauthClientID: oauthClientID?.trimmingCharacters(in: .whitespacesAndNewlines),
                oauthClientSecret: oauthClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                existing: existing,
                session: session
            )
        case .guest:
            return try await signInGuestCredentials(
                origin: origin,
                originKey: originKey,
                username: username,
                password: password,
                existing: existing,
                session: session
            )
        case .telemost, .community:
            throw SiteAuthError.invalidCredentials(L("Use SSO / Web Sign-In or an OAuth token for this service."))
        }
    }

    @discardableResult
    public func signInWithToken(
        origin rawOrigin: URL,
        engine: MeetingEngineKind,
        token rawToken: String
    ) async throws -> SiteAccountRecord {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin),
              let originKey = SiteOrigin.canonicalKey(for: origin) else {
            throw SiteAuthError.invalidSiteURL
        }
        let token = Self.cleanToken(rawToken)
        guard !token.isEmpty else {
            throw SiteAuthError.invalidCredentials(L("Enter an access token."))
        }
        let host = origin.host ?? originKey
        store.clearClientCertificateChallenge(host: host)
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        let existing = store.account(forOriginKey: originKey)
        let claims = JWTClaims.inspect(token)
        if let exp = claims?.expiresAt, exp <= Date() {
            throw SiteAuthError.invalidCredentials(L("This token is already expired."))
        }

        var discoveredServerURL: String? = existing?.discoveredServerURL
        var displayName = claims?.displayName
        var username = claims?.email ?? claims?.subject

        switch engine {
        case .guest:
            let server = try await resolveGuestServerURL(origin: origin, existing: existing, session: session)
            discoveredServerURL = server.absoluteString
            if let profile = try await verifyGuestSession(serverURL: server, origin: origin, token: token, cookies: [], session: session) {
                displayName = displayName ?? profile.displayName
                username = username ?? profile.username
            }
        case .trueconf:
            let verified = try await verifyTrueConfSession(origin: origin, token: token, cookies: [], session: session)
            guard verified else {
                throw SiteAuthError.invalidCredentials(L("TrueConf Server rejected this token."))
            }
        case .telemost:
            let info = try await verifyTelemostOAuth(token: token, session: session)
            displayName = info.displayName ?? displayName
            username = info.username ?? username
        case .community:
            break
        }

        let record = SiteAccountRecord(
            originKey: originKey,
            engine: engine,
            authMethod: .token,
            username: username,
            userDisplayName: displayName,
            clientCertificateID: existing?.clientCertificateID,
            systemCertificateFingerprint: existing?.systemCertificateFingerprint,
            tokenEndpoint: existing?.tokenEndpoint,
            discoveredServerURL: discoveredServerURL,
            tokenExpiresAt: claims?.expiresAt,
            lastAuthenticatedAt: Date(),
            needsReauthentication: false
        )
        let secret = SiteSecretPayload(accessToken: token)
        return store.upsertAccount(record, secret: secret, preservingCertificate: true)
    }

    @discardableResult
    public func completeWebSignIn(
        origin rawOrigin: URL,
        engine: MeetingEngineKind,
        capturedAccessToken: String?,
        capturedRefreshToken: String? = nil,
        tokenEndpoint: String? = nil,
        cookies rawCookies: [HTTPCookie],
        fallbackDisplayName: String? = nil,
        requireVerifiedProof: Bool = true
    ) async throws -> SiteAccountRecord {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin),
              let originKey = SiteOrigin.canonicalKey(for: origin) else {
            throw SiteAuthError.invalidSiteURL
        }
        let host = origin.host ?? originKey
        let existing = store.account(forOriginKey: originKey)
        let previousSecret = store.readSecret(for: originKey)
        let cleanToken = capturedAccessToken.map(Self.cleanToken).flatMap { $0.isEmpty ? nil : $0 }
        let serializedCookies = rawCookies.compactMap(SerializedHTTPCookie.init)
            .filter { $0.expiresAt == nil || ($0.expiresAt ?? .distantFuture) > Date() }

        if cleanToken == nil && serializedCookies.isEmpty {
            throw SiteAuthError.verificationFailed(L("Complete sign-in in the web page before verifying your session."))
        }

        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        let claims = cleanToken.flatMap(JWTClaims.inspect)
        var displayName = claims?.displayName ?? fallbackDisplayName
        var username = claims?.email ?? claims?.subject
        var discoveredServerURL = existing?.discoveredServerURL

        switch engine {
        case .guest:
            let server = try await resolveGuestServerURL(origin: origin, existing: existing, session: session)
            discoveredServerURL = server.absoluteString
            if let profile = try await verifyGuestSession(
                serverURL: server,
                origin: origin,
                token: cleanToken,
                cookies: serializedCookies,
                session: session
            ) {
                displayName = displayName ?? profile.displayName
                username = username ?? profile.username
            } else if cleanToken == nil {
                // Cookie-only guest session: background auto-verify requires server proof;
                // manual verification accepts an auth-like session cookie when profile endpoints are disabled.
                guard !requireVerifiedProof, Self.containsAuthLikeCookie(serializedCookies) else {
                    throw SiteAuthError.verificationFailed(L("No authenticated session or token was found on %@.", host))
                }
            }
        case .trueconf:
            let ok = try await verifyTrueConfSession(origin: origin, token: cleanToken, cookies: serializedCookies, session: session)
            guard ok else {
                throw SiteAuthError.verificationFailed(L("Complete sign-in on %@ before continuing.", host))
            }
        case .telemost:
            let hasYandexSession = serializedCookies.contains {
                ["Session_id", "sessionid2", "yandex_login"].contains($0.name)
            }
            if let cleanToken {
                let info = try await verifyTelemostOAuth(token: cleanToken, session: session)
                displayName = info.displayName ?? displayName
                username = info.username ?? username
            } else {
                guard hasYandexSession else {
                    throw SiteAuthError.verificationFailed(L("Sign in to your Yandex account in the web page first."))
                }
                if let loginCookie = serializedCookies.first(where: { $0.name == "yandex_login" })?.value,
                   !loginCookie.isEmpty {
                    username = loginCookie
                    displayName = displayName ?? loginCookie
                }
            }
        case .community:
            break
        }

        let record = SiteAccountRecord(
            originKey: originKey,
            engine: engine,
            authMethod: .webSSO,
            username: username ?? existing?.username,
            userDisplayName: displayName ?? existing?.userDisplayName,
            clientCertificateID: existing?.clientCertificateID,
            systemCertificateFingerprint: existing?.systemCertificateFingerprint,
            tokenEndpoint: tokenEndpoint ?? existing?.tokenEndpoint,
            discoveredServerURL: discoveredServerURL,
            tokenExpiresAt: claims?.expiresAt,
            lastAuthenticatedAt: Date(),
            needsReauthentication: false
        )
        let secret = SiteSecretPayload(
            accessToken: cleanToken,
            refreshToken: capturedRefreshToken ?? previousSecret?.refreshToken,
            savedPassword: previousSecret?.savedPassword,
            oauthClientID: previousSecret?.oauthClientID,
            oauthClientSecret: previousSecret?.oauthClientSecret,
            cookies: serializedCookies
        )
        return store.upsertAccount(record, secret: secret, preservingCertificate: true)
    }

    @discardableResult
    public func saveMTLSOnlySite(origin rawOrigin: URL, engine: MeetingEngineKind) async throws -> SiteAccountRecord {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin),
              let originKey = SiteOrigin.canonicalKey(for: origin),
              let host = origin.host else {
            throw SiteAuthError.invalidSiteURL
        }
        guard let existing = store.account(forOriginKey: originKey), existing.hasClientCertificate else {
            throw SiteAuthError.clientCertificateRequired(host: host)
        }
        store.clearClientCertificateChallenge(host: host)
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        do {
            _ = try await BoundedHTTP.load(request, session: session, maximumBytes: 16_384)
        } catch let error as URLError {
            throw mapTransportError(error, host: host)
        } catch {
            if let certError = checkClientCertificateChallenge(host: host) {
                throw certError
            }
        }
        if let certError = checkClientCertificateChallenge(host: host) {
            throw certError
        }
        let updated = SiteAccountRecord(
            originKey: originKey,
            engine: engine,
            authMethod: .mtlsOnly,
            username: existing.username,
            userDisplayName: existing.userDisplayName,
            clientCertificateID: existing.clientCertificateID,
            systemCertificateFingerprint: existing.systemCertificateFingerprint,
            tokenEndpoint: existing.tokenEndpoint,
            discoveredServerURL: existing.discoveredServerURL,
            tokenExpiresAt: nil,
            lastAuthenticatedAt: Date(),
            needsReauthentication: false
        )
        return store.upsertAccount(updated, preservingCertificate: true)
    }

    // MARK: - Silent Token Renewal & Credential Resolution

    public func validCredentials(
        for rawOrigin: URL,
        engine: MeetingEngineKind,
        forceRefresh: Bool = false
    ) async -> ResolvedSiteCredentials? {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin),
              let originKey = SiteOrigin.canonicalKey(for: origin),
              let account = store.account(forOriginKey: originKey) else {
            return nil
        }

        let secret = store.readSecret(for: originKey) ?? SiteSecretPayload()
        let now = Date()
        let activeCookies = secret.cookies.filter { $0.expiresAt == nil || ($0.expiresAt ?? .distantFuture) > now }

        let jwtExpiry = secret.accessToken.flatMap(JWTClaims.inspect)?.expiresAt
        let effectiveExpiry = account.tokenExpiresAt ?? jwtExpiry
        let isExpiring = effectiveExpiry.map { $0 <= now.addingTimeInterval(60) } ?? false

        if !forceRefresh && !account.needsReauthentication && !isExpiring {
            if account.authMethod == .mtlsOnly {
                return ResolvedSiteCredentials(account: account, accessToken: secret.accessToken, cookies: activeCookies)
            }
            if let token = secret.accessToken, !token.isEmpty {
                return ResolvedSiteCredentials(account: account, accessToken: token, cookies: activeCookies)
            }
            if !activeCookies.isEmpty {
                return ResolvedSiteCredentials(account: account, accessToken: nil, cookies: activeCookies)
            }
        }

        if let running = refreshTasks[originKey] {
            return await running.value
        }

        let task = Task<ResolvedSiteCredentials?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.refreshTasks.removeValue(forKey: originKey) }
            return await self.performSilentRenewal(origin: origin, originKey: originKey, engine: engine, account: account, secret: secret)
        }
        refreshTasks[originKey] = task
        return await task.value
    }

    private func performSilentRenewal(
        origin: URL,
        originKey: String,
        engine: MeetingEngineKind,
        account: SiteAccountRecord,
        secret: SiteSecretPayload
    ) async -> ResolvedSiteCredentials? {
        // 1. Try OAuth / REST refresh_token exchange
        if let refreshToken = secret.refreshToken, !refreshToken.isEmpty {
            if let renewed = await attemptRefreshTokenExchange(
                origin: origin,
                originKey: originKey,
                engine: engine,
                account: account,
                secret: secret,
                refreshToken: refreshToken
            ) {
                return renewed
            }
        }

        // 2. Try silent relogin with saved username & password
        if let username = account.username, !username.isEmpty,
           let password = secret.savedPassword, !password.isEmpty {
            if let updatedAccount = try? await signInWithCredentials(
                origin: origin,
                engine: engine,
                username: username,
                password: password,
                oauthClientID: secret.oauthClientID,
                oauthClientSecret: secret.oauthClientSecret
            ) {
                let freshSecret = store.readSecret(for: originKey) ?? SiteSecretPayload()
                return ResolvedSiteCredentials(
                    account: updatedAccount,
                    accessToken: freshSecret.accessToken,
                    cookies: freshSecret.cookies
                )
            }
        }

        // 3. Try silent offscreen WebView renewal using saved SSO cookies + mTLS identity
        if account.authMethod == .webSSO && (!secret.cookies.isEmpty || account.hasClientCertificate) {
            if let webResult = await runSilentWebRenewal(origin: origin, cookies: secret.cookies) {
                if let updated = try? await completeWebSignIn(
                    origin: origin,
                    engine: engine,
                    capturedAccessToken: webResult.token,
                    capturedRefreshToken: secret.refreshToken,
                    tokenEndpoint: account.tokenEndpoint,
                    cookies: webResult.cookies,
                    fallbackDisplayName: account.userDisplayName
                ) {
                    let freshSecret = store.readSecret(for: originKey) ?? SiteSecretPayload()
                    return ResolvedSiteCredentials(
                        account: updated,
                        accessToken: freshSecret.accessToken,
                        cookies: freshSecret.cookies
                    )
                }
            }
        }

        // If mTLS-only, cert itself remains usable even without a refreshable token
        if account.authMethod == .mtlsOnly && account.hasClientCertificate {
            return ResolvedSiteCredentials(account: account, accessToken: nil, cookies: secret.cookies)
        }

        store.markNeedsReauthentication(true, for: originKey)
        return nil
    }

    private func attemptRefreshTokenExchange(
        origin: URL,
        originKey: String,
        engine: MeetingEngineKind,
        account: SiteAccountRecord,
        secret: SiteSecretPayload,
        refreshToken: String
    ) async -> ResolvedSiteCredentials? {
        let endpointURL: URL?
        if let explicit = account.tokenEndpoint, let parsed = URL(string: explicit) {
            endpointURL = parsed
        } else if engine == .trueconf {
            var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
            comps?.path = "/oauth2/v1/token"
            endpointURL = comps?.url
        } else if engine == .guest, let serverString = account.discoveredServerURL, let server = URL(string: serverString) {
            endpointURL = server.appendingPathComponent("v1/auth/refresh")
        } else {
            endpointURL = nil
        }
        guard let endpointURL else { return nil }

        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: endpointURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if engine == .trueconf {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var pairs = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken)
            ]
            if let cid = secret.oauthClientID, !cid.isEmpty { pairs.append(.init(name: "client_id", value: cid)) }
            if let csec = secret.oauthClientSecret, !csec.isEmpty { pairs.append(.init(name: "client_secret", value: csec)) }
            var bodyComps = URLComponents()
            bodyComps.queryItems = pairs
            request.httpBody = Data((bodyComps.percentEncodedQuery ?? "").utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken, "refresh_token": refreshToken])
        }

        guard let (data, response) = try? await BoundedHTTP.load(request, session: session, maximumBytes: 131_072),
              (200..<300).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = Self.extractAccessToken(from: json) else {
            return nil
        }

        let newRefresh = (json["refresh_token"] as? String) ?? (json["refreshToken"] as? String) ?? refreshToken
        let expiresAt = Self.extractExpiry(from: json, token: newToken)
        let claims = JWTClaims.inspect(newToken)
        var updatedAccount = account
        updatedAccount.tokenExpiresAt = expiresAt
        updatedAccount.lastAuthenticatedAt = Date()
        updatedAccount.needsReauthentication = false
        if let name = claims?.displayName { updatedAccount.userDisplayName = name }

        var updatedSecret = secret
        updatedSecret.accessToken = newToken
        updatedSecret.refreshToken = newRefresh
        let saved = store.upsertAccount(updatedAccount, secret: updatedSecret, preservingCertificate: true)
        return ResolvedSiteCredentials(account: saved, accessToken: newToken, cookies: updatedSecret.cookies)
    }

    private func runSilentWebRenewal(origin: URL, cookies: [SerializedHTTPCookie]) async -> (token: String?, cookies: [HTTPCookie])? {
        if let renewWebSession {
            return await renewWebSession(origin, cookies, store)
        }
        #if canImport(WebKit) && (os(iOS) || os(macOS))
        return await SilentWebSessionRenewer.renew(origin: origin, cookies: cookies, store: store)
        #else
        return nil
        #endif
    }

    // MARK: - Provider Helpers

    private func signInTrueConfCredentials(
        origin: URL,
        originKey: String,
        username: String,
        password: String,
        oauthClientID: String?,
        oauthClientSecret: String?,
        existing: SiteAccountRecord?,
        session: URLSession
    ) async throws -> SiteAccountRecord {
        // Path 1: OAuth2 password grant if client_id/secret supplied (or server accepts public client)
        if let oauthClientID, !oauthClientID.isEmpty, let oauthClientSecret, !oauthClientSecret.isEmpty {
            var tokenURL = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
            tokenURL.path = "/oauth2/v1/token"
            var req = URLRequest(url: tokenURL.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            var body = URLComponents()
            body.queryItems = [
                .init(name: "grant_type", value: "password"),
                .init(name: "client_id", value: oauthClientID),
                .init(name: "client_secret", value: oauthClientSecret),
                .init(name: "username", value: username),
                .init(name: "password", value: password)
            ]
            req.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
            do {
                let (data, response) = try await BoundedHTTP.load(req, session: session, maximumBytes: 131_072)
                if (200..<300).contains(response.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = Self.extractAccessToken(from: json) {
                    let refresh = (json["refresh_token"] as? String) ?? (json["refreshToken"] as? String)
                    let expiry = Self.extractExpiry(from: json, token: token)
                    let record = SiteAccountRecord(
                        originKey: originKey,
                        engine: .trueconf,
                        authMethod: .credentials,
                        username: username,
                        userDisplayName: JWTClaims.inspect(token)?.displayName ?? username,
                        clientCertificateID: existing?.clientCertificateID,
                        systemCertificateFingerprint: existing?.systemCertificateFingerprint,
                        tokenEndpoint: tokenURL.url!.absoluteString,
                        discoveredServerURL: nil,
                        tokenExpiresAt: expiry,
                        lastAuthenticatedAt: Date(),
                        needsReauthentication: false
                    )
                    let secret = SiteSecretPayload(
                        accessToken: token,
                        refreshToken: refresh,
                        savedPassword: password,
                        oauthClientID: oauthClientID,
                        oauthClientSecret: oauthClientSecret
                    )
                    return store.upsertAccount(record, secret: secret, preservingCertificate: true)
                } else if response.statusCode == 400 || response.statusCode == 401 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let desc = json["error_description"] as? String {
                        throw SiteAuthError.invalidCredentials(desc)
                    }
                    throw SiteAuthError.invalidCredentials(nil)
                }
            } catch let error as URLError {
                throw mapTransportError(error, host: origin.host ?? originKey)
            }
        }

        // Path 2: REST auth login (/api/v4/auth/login or /api/v3.8/auth/login)
        for path in ["/api/v4/auth/login", "/api/v3.8/auth/login"] {
            var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
            comps.path = path
            var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["login": username, "password": password])
            if let (data, response) = try? await BoundedHTTP.load(req, session: session, maximumBytes: 131_072) {
                if (200..<300).contains(response.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = Self.extractAccessToken(from: json) {
                    let refresh = (json["refresh_token"] as? String) ?? (json["refreshToken"] as? String)
                    let expiry = Self.extractExpiry(from: json, token: token)
                    let record = SiteAccountRecord(
                        originKey: originKey,
                        engine: .trueconf,
                        authMethod: .credentials,
                        username: username,
                        userDisplayName: (json["display_name"] as? String) ?? username,
                        clientCertificateID: existing?.clientCertificateID,
                        systemCertificateFingerprint: existing?.systemCertificateFingerprint,
                        tokenEndpoint: comps.url!.absoluteString,
                        tokenExpiresAt: expiry,
                        lastAuthenticatedAt: Date(),
                        needsReauthentication: false
                    )
                    let secret = SiteSecretPayload(
                        accessToken: token,
                        refreshToken: refresh,
                        savedPassword: password,
                        oauthClientID: oauthClientID,
                        oauthClientSecret: oauthClientSecret
                    )
                    return store.upsertAccount(record, secret: secret, preservingCertificate: true)
                } else if response.statusCode == 401 || response.statusCode == 403 {
                    throw SiteAuthError.invalidCredentials(nil)
                }
            }
        }

        // Path 3: Direct TrueConf WebSocket `loginUser` credential verification (`credentialsType: 1`)
        let verifiedID: String?
        if let verifier = verifyTrueConfWebSocketLogin {
            verifiedID = try await verifier(origin, username, password, session)
        } else {
            verifiedID = try await performTrueConfWebSocketLogin(origin: origin, username: username, password: password, session: session)
        }

        let record = SiteAccountRecord(
            originKey: originKey,
            engine: .trueconf,
            authMethod: .credentials,
            username: username,
            userDisplayName: verifiedID ?? username,
            clientCertificateID: existing?.clientCertificateID,
            systemCertificateFingerprint: existing?.systemCertificateFingerprint,
            lastAuthenticatedAt: Date(),
            needsReauthentication: false
        )
        let secret = SiteSecretPayload(
            savedPassword: password,
            oauthClientID: oauthClientID,
            oauthClientSecret: oauthClientSecret
        )
        return store.upsertAccount(record, secret: secret, preservingCertificate: true)
    }

    private func performTrueConfWebSocketLogin(
        origin: URL,
        username: String,
        password: String,
        session: URLSession
    ) async throws -> String? {
        var ws = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        ws.scheme = "wss"
        ws.path = "/websocket/"
        let task = session.webSocketTask(with: ws.url!)
        task.maximumMessageSize = 1_048_576
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        do {
            let loginPayload: [String: Any] = [
                "method": "loginUser",
                "AppID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                "login": username,
                "credentials": password,
                "credentialsType": 1,
                "chatV2Enabled": false,
                "browser": "RockNRoll Native",
                "appLang": "en",
                "appVersion": "5.1.0",
                "appName": "RockNRoll Native"
            ]
            let data = try JSONSerialization.data(withJSONObject: loginPayload)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))

            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let msg = try await task.receive()
                        let raw: Data
                        switch msg {
                        case .data(let value): raw = value
                        case .string(let value): raw = Data(value.utf8)
                        @unknown default: continue
                        }
                        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                              let method = obj["method"] as? String else { continue }
                        if method == "loginResponse" {
                            if obj["result"] as? Int == 0 {
                                return obj["trueconfId"] as? String
                            }
                            throw SiteAuthError.invalidCredentials(nil)
                        }
                    }
                    throw SiteAuthError.verificationFailed(nil)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw SiteAuthError.verificationFailed(L("Timed out waiting for TrueConf login."))
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch let error as SiteAuthError {
            throw error
        } catch let error as URLError {
            throw mapTransportError(error, host: origin.host ?? origin.absoluteString)
        } catch {
            if let cert = checkClientCertificateChallenge(host: origin.host ?? "") { throw cert }
            throw SiteAuthError.invalidCredentials(nil)
        }
    }

    private func signInGuestCredentials(
        origin: URL,
        originKey: String,
        username: String,
        password: String,
        existing: SiteAccountRecord?,
        session: URLSession
    ) async throws -> SiteAccountRecord {
        let serverURL = try await resolveGuestServerURL(origin: origin, existing: existing, session: session)
        let candidateURLs = [
            serverURL.appendingPathComponent("v1/auth/login"),
            origin.appendingPathComponent("api/v1/auth/login")
        ]
        var lastStatus: Int?
        for url in candidateURLs {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "username": username,
                "login": username,
                "password": password
            ])
            do {
                let (data, response) = try await BoundedHTTP.load(req, session: session, maximumBytes: 131_072)
                lastStatus = response.statusCode
                if (200..<300).contains(response.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = Self.extractAccessToken(from: json) {
                    let refresh = (json["refresh_token"] as? String) ?? (json["refreshToken"] as? String)
                    let expiry = Self.extractExpiry(from: json, token: token)
                    let claims = JWTClaims.inspect(token)
                    let record = SiteAccountRecord(
                        originKey: originKey,
                        engine: .guest,
                        authMethod: .credentials,
                        username: username,
                        userDisplayName: claims?.displayName ?? (json["name"] as? String) ?? username,
                        clientCertificateID: existing?.clientCertificateID,
                        systemCertificateFingerprint: existing?.systemCertificateFingerprint,
                        tokenEndpoint: url.absoluteString,
                        discoveredServerURL: serverURL.absoluteString,
                        tokenExpiresAt: expiry,
                        lastAuthenticatedAt: Date(),
                        needsReauthentication: false
                    )
                    let secret = SiteSecretPayload(
                        accessToken: token,
                        refreshToken: refresh,
                        savedPassword: password
                    )
                    return store.upsertAccount(record, secret: secret, preservingCertificate: true)
                } else if response.statusCode == 401 || response.statusCode == 403 {
                    throw SiteAuthError.invalidCredentials(nil)
                }
            } catch let error as SiteAuthError {
                throw error
            } catch let error as URLError {
                throw mapTransportError(error, host: origin.host ?? originKey)
            } catch {
                continue
            }
        }
        if let cert = checkClientCertificateChallenge(host: origin.host ?? "") {
            throw cert
        }
        if lastStatus == 404 {
            throw SiteAuthError.invalidCredentials(L("This server requires SSO / Web Sign-In or an access token."))
        }
        throw SiteAuthError.invalidCredentials(nil)
    }

    private func resolveGuestServerURL(origin: URL, existing: SiteAccountRecord?, session: URLSession) async throws -> URL {
        if let cached = existing?.discoveredServerURL, let url = URL(string: cached) {
            return url
        }
        do {
            return try await GuestBootstrap(session: session, useBoundedHTTP: true).discoverServer(origin: origin)
        } catch let error as URLError {
            throw mapTransportError(error, host: origin.host ?? origin.absoluteString)
        } catch {
            if let cert = checkClientCertificateChallenge(host: origin.host ?? "") {
                throw cert
            }
            throw error
        }
    }

    private func verifyGuestSession(
        serverURL: URL,
        origin: URL,
        token: String?,
        cookies: [SerializedHTTPCookie],
        session: URLSession
    ) async throws -> (username: String?, displayName: String?)? {
        for candidate in [serverURL.appendingPathComponent("user/current"), serverURL.appendingPathComponent("v1/user/info")] {
            var req = URLRequest(url: candidate, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token {
                req.setValue(token, forHTTPHeaderField: "X-Jazz-Token")
                if token.split(separator: ".").count == 3 {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            }
            if let cookieHeader = SerializedHTTPCookie.cookieHeader(from: cookies, for: candidate) {
                req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            guard let (data, response) = try? await BoundedHTTP.load(req, session: session, maximumBytes: 65_536) else {
                continue
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SiteAuthError.invalidCredentials(L("The session or token was rejected by %@.", origin.host ?? ""))
            }
            if (200..<300).contains(response.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = (json["name"] as? String) ?? (json["displayName"] as? String)
                let user = (json["email"] as? String) ?? (json["username"] as? String) ?? (json["login"] as? String)
                return (user, name)
            }
        }
        return nil
    }

    private func verifyTrueConfSession(
        origin: URL,
        token: String?,
        cookies: [SerializedHTTPCookie],
        session: URLSession
    ) async throws -> Bool {
        for path in ["/api/v3.8/conferences", "/api/v4/conferences"] {
            var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
            comps.path = path
            var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let cookieHeader = SerializedHTTPCookie.cookieHeader(from: cookies, for: comps.url!) {
                req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            if let (_, response) = try? await BoundedHTTP.load(req, session: session, maximumBytes: 65_536) {
                if (200..<300).contains(response.statusCode) { return true }
                if response.statusCode == 401, let token, path == "/api/v3.8/conferences" {
                    // Legacy TrueConf API v3 also accepts ?access_token=
                    comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
                    var alt = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                    alt.setValue("application/json", forHTTPHeaderField: "Accept")
                    if let (_, altResponse) = try? await BoundedHTTP.load(alt, session: session, maximumBytes: 65_536),
                       (200..<300).contains(altResponse.statusCode) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func verifyTelemostOAuth(token: String, session: URLSession) async throws -> (username: String?, displayName: String?) {
        let infoURL = URL(string: "https://login.yandex.ru/info?format=json")!
        var req = URLRequest(url: infoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await BoundedHTTP.load(req, session: session, maximumBytes: 65_536)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SiteAuthError.invalidCredentials(L("Yandex rejected this OAuth token."))
            }
            if (200..<300).contains(response.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let display = (json["real_name"] as? String) ?? (json["display_name"] as? String)
                let login = (json["login"] as? String) ?? (json["default_email"] as? String)
                return (login, display)
            }
            return (nil, nil)
        } catch let error as SiteAuthError {
            throw error
        } catch {
            return (nil, nil)
        }
    }

    private func mapTransportError(_ error: URLError, host: String) -> SiteAuthError {
        let challenge = store.wasChallengedForClientCertificate(host: host)
        if error.code == .clientCertificateRejected || challenge.rejected {
            return .clientCertificateRejected(host: host)
        }
        if error.code == .clientCertificateRequired || challenge.challenged {
            return .clientCertificateRequired(host: host)
        }
        return .verificationFailed(error.localizedDescription)
    }

    private func checkClientCertificateChallenge(host: String) -> SiteAuthError? {
        let state = store.wasChallengedForClientCertificate(host: host)
        guard state.challenged else { return nil }
        return state.rejected ? .clientCertificateRejected(host: host) : .clientCertificateRequired(host: host)
    }

    private static func containsAuthLikeCookie(_ cookies: [SerializedHTTPCookie]) -> Bool {
        let markers = ["session", "auth", "token", "jwt", "sid", "sso", "openid", "kc_", "jazz", "sber", "refresh"]
        return cookies.contains { cookie in
            let lower = cookie.name.lowercased()
            return markers.contains { lower.contains($0) }
        }
    }

    static func cleanToken(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Bearer ", "bearer ", "OAuth ", "oauth "] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return value
    }

    static func extractAccessToken(from json: [String: Any]) -> String? {
        for key in ["access_token", "accessToken", "jazzToken", "token"] {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func extractExpiry(from json: [String: Any], token: String) -> Date? {
        if let seconds = json["expires_in"] as? TimeInterval, seconds > 0 {
            return Date().addingTimeInterval(seconds)
        }
        if let seconds = json["expires_in"] as? Int, seconds > 0 {
            return Date().addingTimeInterval(TimeInterval(seconds))
        }
        return JWTClaims.inspect(token)?.expiresAt
    }
}

#if canImport(WebKit) && (os(iOS) || os(macOS))
/// Bounded (8s) offscreen WKWebView session refresher using saved cookies + mTLS `SiteTLSDelegate`.
/// Aborts immediately if an interactive challenge or login prompt is needed.
@MainActor
private enum SilentWebSessionRenewer {
    static func renew(
        origin: URL,
        cookies: [SerializedHTTPCookie],
        store: SiteAccountStore
    ) async -> (token: String?, cookies: [HTTPCookie])? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let cookieStore = config.websiteDataStore.httpCookieStore
        for item in cookies {
            if let httpCookie = item.makeHTTPCookie() {
                await cookieStore.setCookie(httpCookie)
            }
        }

        final class Collector: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            let tlsDelegate: SiteTLSDelegate
            var capturedToken: String?
            var onFinish: (() -> Void)?

            init(origin: URL, store: SiteAccountStore) {
                self.tlsDelegate = SiteTLSDelegate(preferredOrigin: origin, lookup: store.registry)
            }

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let dict = message.body as? [String: Any],
                      let token = dict["token"] as? String, !token.isEmpty else { return }
                capturedToken = token
            }

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                onFinish?()
            }

            func webView(
                _ webView: WKWebView,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                tlsDelegate.handleChallenge(challenge, completionHandler: completionHandler)
            }
        }

        let collector = Collector(origin: origin, store: store)
        let script = WKUserScript(source: SiteAuthWebScript.captureSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(collector, name: "siteAuthBridge")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.navigationDelegate = collector
        defer {
            config.userContentController.removeScriptMessageHandler(forName: "siteAuthBridge")
            webView.stopLoading()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            @MainActor func finish() {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            collector.onFinish = {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    finish()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                finish()
            }
            webView.load(URLRequest(url: origin))
        }

        let refreshedCookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { list in
                continuation.resume(returning: list)
            }
        }
        guard collector.capturedToken != nil || !refreshedCookies.isEmpty else {
            return nil
        }
        return (collector.capturedToken, refreshedCookies)
    }
}

enum SiteAuthWebScript {
    /// Captures auth tokens sent by the site's web client in headers (`X-Jazz-Token`, `Authorization`)
    /// or returned by JSON auth responses (`access_token`, `accessToken`, `jazzToken`), and reads
    /// localStorage token keys used by Jazz / OIDC web apps.
    static let captureSource = #"""
    (function() {
        function post(token, refreshToken, tokenEndpoint) {
            if (!token || typeof token !== 'string' || token.length < 8) return;
            if (/^basic\s+/i.test(token)) return;
            try {
                window.webkit.messageHandlers.siteAuthBridge.postMessage({
                    token: token,
                    refreshToken: refreshToken || "",
                    tokenEndpoint: tokenEndpoint || ""
                });
            } catch (e) {}
        }
        function inspectHeaders(headers) {
            if (!headers) return;
            try {
                if (typeof headers.get === 'function') {
                    post(headers.get('X-Jazz-Token') || headers.get('x-jazz-token'));
                    post(headers.get('Authorization') || headers.get('authorization'));
                } else if (typeof headers === 'object') {
                    for (var k in headers) {
                        var lk = String(k).toLowerCase();
                        if (lk === 'x-jazz-token' || lk === 'authorization') post(headers[k]);
                    }
                }
            } catch (e) {}
        }
        var origFetch = window.fetch;
        if (origFetch) {
            window.fetch = function(input, init) {
                if (init && init.headers) inspectHeaders(init.headers);
                var reqUrl = (typeof input === 'string') ? input : (input && input.url ? input.url : "");
                var lowerUrl = String(reqUrl || '').toLowerCase();
                return origFetch.apply(this, arguments).then(function(resp) {
                    try {
                        var ct = resp.headers && resp.headers.get('content-type') || '';
                        if (ct.indexOf('json') >= 0 && (lowerUrl.indexOf('auth') >= 0 || lowerUrl.indexOf('token') >= 0 || lowerUrl.indexOf('login') >= 0)) {
                            resp.clone().json().then(function(data) {
                                if (data && typeof data === 'object') {
                                    var tok = data.access_token || data.accessToken || data.jazzToken || data.token;
                                    var ref = data.refresh_token || data.refreshToken || "";
                                    if (tok) post(tok, ref, reqUrl);
                                }
                            }).catch(function(){});
                        }
                    } catch (e) {}
                    return resp;
                });
            };
        }
        var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            var ln = String(name || '').toLowerCase();
            if (ln === 'x-jazz-token' || ln === 'authorization') post(value);
            return origSetHeader.apply(this, arguments);
        };
        function scanStorage() {
            try {
                for (var i = 0; i < window.localStorage.length; i++) {
                    var key = window.localStorage.key(i) || '';
                    var lk = key.toLowerCase();
                    if (lk.indexOf('jazz') >= 0 && lk.indexOf('token') >= 0) {
                        var val = window.localStorage.getItem(key);
                        if (val && val.length >= 12 && val[0] !== '{') post(val);
                    }
                }
            } catch (e) {}
        }
        window.addEventListener('load', function() { setTimeout(scanStorage, 300); });
    })();
    """#
}
#endif
