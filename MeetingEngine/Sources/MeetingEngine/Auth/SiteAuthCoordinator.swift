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
        let initialClaims = JWTClaims.inspect(token)
        if engine == .guest, initialClaims?.isLicenseToken == true {
            throw SiteAuthError.invalidCredentials(L("The session or token was rejected by %@.", host))
        }
        if let exp = initialClaims?.expiresAt, exp <= Date() {
            throw SiteAuthError.invalidCredentials(L("This token is already expired."))
        }

        var claims = initialClaims
        var effectiveToken = token
        var discoveredServerURL: String? = existing?.discoveredServerURL
        var displayName = initialClaims?.displayName
        var username = initialClaims?.email ?? initialClaims?.subject

        switch engine {
        case .guest:
            let server = try await resolveGuestServerURL(origin: origin, existing: existing, session: session)
            discoveredServerURL = server.absoluteString
            let outcome = try await verifyGuestSessionWithB2BFallback(
                serverURL: server,
                origin: origin,
                initialToken: effectiveToken,
                initialClaims: initialClaims,
                cookies: [],
                session: session
            )
            effectiveToken = outcome.effectiveToken ?? effectiveToken
            claims = outcome.claims ?? claims
            switch outcome.verification {
            case .authenticated(let profileUser, let profileName):
                displayName = Self.preferredDisplayName(
                    outcomeClaims: outcome.claims,
                    initialClaims: initialClaims,
                    profileName: profileName,
                    fallback: displayName
                )
                username = outcome.claims?.email ?? initialClaims?.email ?? profileUser ?? outcome.claims?.subject ?? initialClaims?.subject ?? username
            case .rejected, .anonymous:
                throw SiteAuthError.invalidCredentials(L("The session or token was rejected by %@.", host))
            case .unavailable:
                break
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
            tokenExpiresAt: claims?.expiresAt ?? initialClaims?.expiresAt,
            lastAuthenticatedAt: Date(),
            needsReauthentication: false
        )
        let secret = SiteSecretPayload(accessToken: effectiveToken)
        return store.upsertAccount(record, secret: secret, preservingCertificate: true)
    }

    @discardableResult
    public func completeWebSignIn(
        origin rawOrigin: URL,
        engine: MeetingEngineKind,
        capturedAccessToken: String?,
        capturedRefreshToken: String? = nil,
        tokenEndpoint: String? = nil,
        capturedClientID: String? = nil,
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
        var effectiveToken = capturedAccessToken.map(Self.cleanToken).flatMap { $0.isEmpty ? nil : $0 }
        if engine == .guest, let tok = effectiveToken, JWTClaims.inspect(tok)?.isLicenseToken == true {
            effectiveToken = nil
        }
        let serializedCookies = rawCookies.compactMap(SerializedHTTPCookie.init)
            .filter { $0.expiresAt == nil || ($0.expiresAt ?? .distantFuture) > Date() }

        if effectiveToken == nil && serializedCookies.isEmpty {
            throw SiteAuthError.verificationFailed(L("Complete sign-in in the web page before verifying your session."))
        }

        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        let initialClaims = effectiveToken.flatMap(JWTClaims.inspect)
        var claims = initialClaims
        var displayName = claims?.displayName ?? fallbackDisplayName
        var username = claims?.email ?? claims?.subject
        var discoveredServerURL = existing?.discoveredServerURL

        switch engine {
        case .guest:
            let server = try await resolveGuestServerURL(origin: origin, existing: existing, session: session)
            discoveredServerURL = server.absoluteString
            if effectiveToken == nil, !serializedCookies.isEmpty,
               let exchanged = await exchangeGuestCookieToToken(serverURL: server, cookies: serializedCookies, session: session) {
                let cleaned = Self.cleanToken(exchanged)
                if !cleaned.isEmpty, JWTClaims.inspect(cleaned)?.isLicenseToken != true {
                    effectiveToken = cleaned
                    claims = JWTClaims.inspect(cleaned)
                    displayName = claims?.displayName ?? displayName
                    username = claims?.email ?? claims?.subject ?? username
                }
            }
            let outcome = try await verifyGuestSessionWithB2BFallback(
                serverURL: server,
                origin: origin,
                initialToken: effectiveToken,
                initialClaims: claims,
                cookies: serializedCookies,
                session: session
            )
            effectiveToken = outcome.effectiveToken ?? effectiveToken
            claims = outcome.claims ?? claims
            let verificationName: String = switch outcome.verification {
            case .authenticated: "authenticated"
            case .rejected: "rejected"
            case .anonymous: "anonymous"
            case .unavailable: "unavailable"
            }
            probeLog("site-auth-web", [
                "engine": engine.rawValue,
                "hasToken": effectiveToken != nil,
                "isJWT": claims != nil,
                "initialIsJWT": initialClaims != nil,
                "cookieCount": serializedCookies.count,
                "b2bExchanged": outcome.exchangedViaB2B,
                "verification": verificationName
            ])
            switch outcome.verification {
            case .authenticated(let profileUser, let profileName):
                displayName = Self.preferredDisplayName(
                    outcomeClaims: outcome.claims,
                    initialClaims: initialClaims,
                    profileName: profileName,
                    fallback: fallbackDisplayName ?? displayName
                )
                username = outcome.claims?.email ?? initialClaims?.email ?? profileUser ?? outcome.claims?.subject ?? initialClaims?.subject ?? username
            case .rejected:
                throw SiteAuthError.invalidCredentials(L("The session or token was rejected by %@.", host))
            case .anonymous:
                throw SiteAuthError.verificationFailed(L("No authenticated session or token was found on %@.", host))
            case .unavailable:
                guard effectiveToken != nil || (!requireVerifiedProof && Self.containsAuthLikeCookie(serializedCookies)) else {
                    throw SiteAuthError.verificationFailed(L("No authenticated session or token was found on %@.", host))
                }
            }
        case .trueconf:
            let ok = try await verifyTrueConfSession(origin: origin, token: effectiveToken, cookies: serializedCookies, session: session)
            guard ok else {
                throw SiteAuthError.verificationFailed(L("Complete sign-in on %@ before continuing.", host))
            }
        case .telemost:
            let hasYandexSession = serializedCookies.contains {
                ["Session_id", "sessionid2", "yandex_login"].contains($0.name)
            }
            if let effectiveToken {
                let info = try await verifyTelemostOAuth(token: effectiveToken, session: session)
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

        let cleanedRefresh = capturedRefreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? previousSecret?.refreshToken
        let explicitTokenEndpoint = tokenEndpoint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .flatMap { Self.isRefreshableTokenEndpoint($0) ? $0 : nil }
        let derivedOIDCEndpoint: String? = (engine == .guest && explicitTokenEndpoint == nil && cleanedRefresh != nil)
            ? (Self.derivedOIDCTokenEndpoint(issuer: claims?.issuer, siteOrigin: origin)
                ?? Self.derivedOIDCTokenEndpoint(issuer: initialClaims?.issuer, siteOrigin: origin))
            : nil
        let existingTokenEndpoint = existing?.tokenEndpoint.flatMap {
            Self.isRefreshableTokenEndpoint($0) ? $0 : nil
        }
        let resolvedTokenEndpoint = explicitTokenEndpoint ?? derivedOIDCEndpoint ?? existingTokenEndpoint
        let resolvedClientID = capturedClientID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? claims?.authorizedParty ?? initialClaims?.authorizedParty ?? previousSecret?.oauthClientID

        let record = SiteAccountRecord(
            originKey: originKey,
            engine: engine,
            authMethod: .webSSO,
            username: username ?? existing?.username,
            userDisplayName: displayName ?? existing?.userDisplayName,
            clientCertificateID: existing?.clientCertificateID,
            systemCertificateFingerprint: existing?.systemCertificateFingerprint,
            tokenEndpoint: resolvedTokenEndpoint,
            discoveredServerURL: discoveredServerURL,
            tokenExpiresAt: claims?.expiresAt ?? initialClaims?.expiresAt,
            lastAuthenticatedAt: Date(),
            needsReauthentication: false
        )
        let secret = SiteSecretPayload(
            accessToken: effectiveToken,
            refreshToken: cleanedRefresh,
            savedPassword: previousSecret?.savedPassword,
            oauthClientID: resolvedClientID,
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
        let isExpired = effectiveExpiry.map { $0 <= now } ?? false
        let isExpiring = effectiveExpiry.map { $0 <= now.addingTimeInterval(60) } ?? false
        let canFallbackToUnexpired = !forceRefresh && !account.needsReauthentication && !isExpired

        func fallbackUnexpiredCredentials() -> ResolvedSiteCredentials? {
            if account.authMethod == .mtlsOnly {
                return ResolvedSiteCredentials(account: account, accessToken: secret.accessToken, cookies: activeCookies)
            }
            if let token = secret.accessToken, !token.isEmpty {
                return ResolvedSiteCredentials(account: account, accessToken: token, cookies: activeCookies)
            }
            if !activeCookies.isEmpty {
                return ResolvedSiteCredentials(account: account, accessToken: nil, cookies: activeCookies)
            }
            return nil
        }

        if !forceRefresh && !account.needsReauthentication && !isExpiring,
           let cached = fallbackUnexpiredCredentials() {
            return cached
        }

        if let running = refreshTasks[originKey] {
            return await running.value ?? (canFallbackToUnexpired ? fallbackUnexpiredCredentials() : nil)
        }

        let task = Task<ResolvedSiteCredentials?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.refreshTasks.removeValue(forKey: originKey) }
            return await self.performSilentRenewal(
                origin: origin,
                originKey: originKey,
                engine: engine,
                account: account,
                secret: secret,
                markExpiredOnFailure: !canFallbackToUnexpired
            )
        }
        refreshTasks[originKey] = task
        return await task.value ?? (canFallbackToUnexpired ? fallbackUnexpiredCredentials() : nil)
    }

    private func performSilentRenewal(
        origin: URL,
        originKey: String,
        engine: MeetingEngineKind,
        account: SiteAccountRecord,
        secret: SiteSecretPayload,
        markExpiredOnFailure: Bool
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
            if let renewWebSession {
                if let webResult = await renewWebSession(origin, secret.cookies, store),
                   let updated = try? await completeWebSignIn(
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
            } else {
                #if canImport(WebKit) && (os(iOS) || os(macOS))
                if let webResult = await SilentWebSessionRenewer.renew(origin: origin, cookies: secret.cookies, store: store),
                   let updated = try? await completeWebSignIn(
                       origin: origin,
                       engine: engine,
                       capturedAccessToken: webResult.token,
                       capturedRefreshToken: webResult.refreshToken ?? secret.refreshToken,
                       tokenEndpoint: webResult.tokenEndpoint ?? account.tokenEndpoint,
                       capturedClientID: webResult.clientID,
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
                #endif
            }
        }

        // If mTLS-only, cert itself remains usable even without a refreshable token
        if account.authMethod == .mtlsOnly && account.hasClientCertificate {
            return ResolvedSiteCredentials(account: account, accessToken: nil, cookies: secret.cookies)
        }

        if markExpiredOnFailure {
            store.markNeedsReauthentication(true, for: originKey)
        }
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
        let tokenClaims = JWTClaims.inspect(secret.accessToken ?? "")
        let refreshClaims = JWTClaims.inspect(refreshToken)
        let endpointURL: URL?
        if let explicit = account.tokenEndpoint,
           Self.isRefreshableTokenEndpoint(explicit),
           let parsed = URL(string: explicit) {
            endpointURL = parsed
        } else if engine == .trueconf {
            var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
            comps?.path = "/oauth2/v1/token"
            endpointURL = comps?.url
        } else if engine == .guest,
                  let oidcEndpoint = Self.derivedOIDCTokenEndpoint(issuer: tokenClaims?.issuer ?? refreshClaims?.issuer, siteOrigin: origin),
                  let parsedOIDC = URL(string: oidcEndpoint) {
            endpointURL = parsedOIDC
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
        let lowerPath = endpointURL.path.lowercased()
        let isFormOAuth = (engine == .trueconf) || lowerPath.contains("openid-connect/token") || lowerPath.contains("/oauth")
        if isFormOAuth {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var pairs = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken)
            ]
            let clientID = secret.oauthClientID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? tokenClaims?.authorizedParty
                ?? refreshClaims?.authorizedParty
            if let clientID { pairs.append(.init(name: "client_id", value: clientID)) }
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

        let cleanedNewToken = Self.cleanToken(newToken)
        var finalAccessToken = cleanedNewToken.isEmpty ? newToken : cleanedNewToken
        var resolvedServerURL = account.discoveredServerURL.flatMap(URL.init(string:))
        if engine == .guest && isFormOAuth {
            if resolvedServerURL == nil {
                resolvedServerURL = try? await resolveGuestServerURL(origin: origin, existing: account, session: session)
            }
            if let serverURL = resolvedServerURL,
               let exchanged = await exchangeGuestKeycloakB2BToken(
                   serverURL: serverURL,
                   keycloakToken: finalAccessToken,
                   cookies: secret.cookies,
                   session: session
               ),
               !exchanged.isEmpty {
                finalAccessToken = exchanged
            }
        }

        let newRefresh = (json["refresh_token"] as? String) ?? (json["refreshToken"] as? String) ?? refreshToken
        let oauthClaims = JWTClaims.inspect(newToken)
        let finalClaims = JWTClaims.inspect(finalAccessToken)
        let expiresAt = finalClaims?.expiresAt ?? Self.extractExpiry(from: json, token: newToken)
        var updatedAccount = account
        updatedAccount.tokenEndpoint = endpointURL.absoluteString
        if let resolvedServerURL {
            updatedAccount.discoveredServerURL = resolvedServerURL.absoluteString
        }
        updatedAccount.tokenExpiresAt = expiresAt
        updatedAccount.lastAuthenticatedAt = Date()
        updatedAccount.needsReauthentication = false
        if let name = Self.preferredDisplayName(
            outcomeClaims: finalClaims,
            initialClaims: oauthClaims,
            fallback: account.userDisplayName
        ) {
            updatedAccount.userDisplayName = name
        }
        if let email = finalClaims?.email ?? oauthClaims?.email { updatedAccount.username = email }

        var updatedSecret = secret
        updatedSecret.accessToken = finalAccessToken
        updatedSecret.refreshToken = newRefresh
        if let cid = oauthClaims?.authorizedParty ?? finalClaims?.authorizedParty,
           (updatedSecret.oauthClientID ?? "").isEmpty {
            updatedSecret.oauthClientID = cid
        }
        let saved = store.upsertAccount(updatedAccount, secret: updatedSecret, preservingCertificate: true)
        return ResolvedSiteCredentials(account: saved, accessToken: finalAccessToken, cookies: updatedSecret.cookies)
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

    private enum GuestSessionVerification {
        case authenticated(username: String?, displayName: String?)
        case anonymous
        case rejected
        case unavailable
    }

    private func guestAuthRequest(
        url: URL,
        token: String?,
        cookies: [SerializedHTTPCookie],
        timeout: TimeInterval = 10
    ) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            req.setValue(token, forHTTPHeaderField: "X-Jazz-Token")
            if token.split(separator: ".").count == 3 {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        if let cookieHeader = SerializedHTTPCookie.cookieHeader(from: cookies, for: url) {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return req
    }

    private func decodeGuestUserProfile(from json: [String: Any]) -> (username: String?, displayName: String?) {
        let name = ((json["name"] as? String) ?? (json["displayName"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let user = ((json["email"] as? String)
            ?? (json["username"] as? String)
            ?? (json["login"] as? String)
            ?? (json["preferred_username"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return (user, name)
    }

    private struct GuestVerificationOutcome {
        var verification: GuestSessionVerification
        var effectiveToken: String?
        var claims: JWTClaims?
        var exchangedViaB2B: Bool
    }

    private static func preferredDisplayName(
        outcomeClaims: JWTClaims?,
        initialClaims: JWTClaims? = nil,
        profileName: String? = nil,
        fallback: String? = nil
    ) -> String? {
        let explicitOutcomeName: String? = {
            guard let name = outcomeClaims?.displayName else { return nil }
            return name != outcomeClaims?.subject ? name : nil
        }()
        let explicitInitialName: String? = {
            guard let name = initialClaims?.displayName else { return nil }
            return name != initialClaims?.subject ? name : nil
        }()
        return explicitOutcomeName
            ?? profileName
            ?? explicitInitialName
            ?? fallback
            ?? outcomeClaims?.displayName
            ?? initialClaims?.displayName
    }

    private func verifyGuestSessionWithB2BFallback(
        serverURL: URL,
        origin: URL,
        initialToken: String?,
        initialClaims: JWTClaims?,
        cookies: [SerializedHTTPCookie],
        session: URLSession
    ) async throws -> GuestVerificationOutcome {
        var token = initialToken
        var claims = initialClaims
        var verification = try await verifyGuestSession(
            serverURL: serverURL,
            origin: origin,
            token: token,
            cookies: cookies,
            session: session
        )
        var exchangedViaB2B = false
        switch verification {
        case .rejected, .anonymous:
            if let keycloakToken = token,
               let exchanged = await exchangeGuestKeycloakB2BToken(
                   serverURL: serverURL,
                   keycloakToken: keycloakToken,
                   cookies: cookies,
                   session: session
               ),
               exchanged != keycloakToken {
                token = exchanged
                claims = JWTClaims.inspect(exchanged)
                exchangedViaB2B = true
                verification = try await verifyGuestSession(
                    serverURL: serverURL,
                    origin: origin,
                    token: exchanged,
                    cookies: cookies,
                    session: session
                )
            }
        case .authenticated, .unavailable:
            break
        }
        return GuestVerificationOutcome(
            verification: verification,
            effectiveToken: token,
            claims: claims,
            exchangedViaB2B: exchangedViaB2B
        )
    }

    private func exchangeGuestKeycloakB2BToken(
        serverURL: URL,
        keycloakToken: String,
        cookies: [SerializedHTTPCookie],
        session: URLSession
    ) async -> String? {
        let cleaned = Self.cleanToken(keycloakToken)
        guard !cleaned.isEmpty, JWTClaims.inspect(cleaned)?.isLicenseToken != true else {
            return nil
        }
        let endpoint = serverURL.appendingPathComponent("auth/login/b2b")
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(cleaned)", forHTTPHeaderField: "Authorization")
        if let cookieHeader = SerializedHTTPCookie.cookieHeader(from: cookies, for: endpoint) {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await BoundedHTTP.load(req, session: session, maximumBytes: 65_536),
              (200..<300).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exchanged = Self.extractAccessToken(from: json) else {
            return nil
        }
        let cleanedExchanged = Self.cleanToken(exchanged)
        return cleanedExchanged.isEmpty ? nil : cleanedExchanged
    }

    private func exchangeGuestCookieToToken(
        serverURL: URL,
        cookies: [SerializedHTTPCookie],
        session: URLSession
    ) async -> String? {
        let endpoint = serverURL.appendingPathComponent("auth/cookie-to-token")
        guard let cookieHeader = SerializedHTTPCookie.cookieHeader(from: cookies, for: endpoint) else {
            return nil
        }
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await BoundedHTTP.load(req, session: session, maximumBytes: 65_536),
              (200..<300).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.extractAccessToken(from: json)
    }

    private func verifyGuestSession(
        serverURL: URL,
        origin: URL,
        token: String?,
        cookies: [SerializedHTTPCookie],
        session: URLSession
    ) async throws -> GuestSessionVerification {
        // 1. Standard SaluteJazz / SberJazz user info endpoint (`/user/info`).
        let userInfoURL = serverURL.appendingPathComponent("user/info")
        if let (data, response) = try? await BoundedHTTP.load(
            guestAuthRequest(url: userInfoURL, token: token, cookies: cookies),
            session: session,
            maximumBytes: 65_536
        ) {
            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if (200..<300).contains(response.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let authType = (json["authType"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                let authErr = (json["authErr"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                if let authErr, ["TOKEN_INVALID", "TOKEN_EXPIRED", "AUTH_TYPE_MISMATCH", "TOKEN_PARSE_FAILED"].contains(authErr) {
                    return .rejected
                }
                if authType == "ANONYMOUS" || authErr == "TOKEN_MISSING" {
                    return .anonymous
                }
                let profile = decodeGuestUserProfile(from: json)
                if authType != nil || authErr == "OK" || profile.username != nil || profile.displayName != nil {
                    return .authenticated(username: profile.username, displayName: profile.displayName)
                }
            } else if response.statusCode == 401, contentType.contains("json") {
                return token != nil ? .rejected : .anonymous
            }
        }

        // 2. Token validation endpoint (`/auth/validate`) for servers without `/user/info`.
        let validateURL = serverURL.appendingPathComponent("auth/validate")
        if let (data, response) = try? await BoundedHTTP.load(
            guestAuthRequest(url: validateURL, token: token, cookies: cookies),
            session: session,
            maximumBytes: 65_536
        ) {
            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if (200..<300).contains(response.statusCode) {
                return .authenticated(username: nil, displayName: nil)
            }
            if response.statusCode == 401, contentType.contains("json") {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let code = (json?["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return code == "TOKEN_MISSING" ? .anonymous : .rejected
            }
        }

        // 3. Legacy fallback (`/user/current`) when neither `/user/info` nor `/auth/validate` is exposed.
        let legacyURL = serverURL.appendingPathComponent("user/current")
        if let (data, response) = try? await BoundedHTTP.load(
            guestAuthRequest(url: legacyURL, token: token, cookies: cookies),
            session: session,
            maximumBytes: 65_536
        ) {
            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if (200..<300).contains(response.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let profile = decodeGuestUserProfile(from: json)
                return .authenticated(username: profile.username, displayName: profile.displayName)
            }
            if response.statusCode == 401 || (response.statusCode == 403 && contentType.contains("json")) {
                return token != nil ? .rejected : .anonymous
            }
        }

        return .unavailable
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

    static func isRefreshableTokenEndpoint(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsed = URL(string: trimmed),
              parsed.scheme?.lowercased() == "https" else {
            return false
        }
        let path = parsed.path.lowercased()
        if path.contains("plat-license-manager") || path.contains("/licenses/") || path.contains("/license/") {
            return false
        }
        return path.contains("openid-connect/token")
            || path.contains("/oauth")
            || path.contains("/refresh")
            || path.hasSuffix("/token")
    }

    static func derivedOIDCTokenEndpoint(issuer: String?, siteOrigin: URL) -> String? {
        guard let rawIssuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawIssuer.isEmpty,
              let parsed = URL(string: rawIssuer),
              parsed.scheme?.lowercased() == "https",
              let issuerHost = parsed.host,
              let siteHost = siteOrigin.host,
              SiteOrigin.hostMatches(issuerHost, siteHost: siteHost) else {
            return nil
        }
        var trimmed = parsed.absoluteString
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed + "/protocol/openid-connect/token"
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if canImport(WebKit) && (os(iOS) || os(macOS))
/// Bounded (8s) offscreen WKWebView session refresher using saved cookies + mTLS `SiteTLSDelegate`.
/// Aborts immediately if an interactive challenge or login prompt is needed.
@MainActor
private enum SilentWebSessionRenewer {
    struct RenewalResult {
        let token: String?
        let refreshToken: String?
        let tokenEndpoint: String?
        let clientID: String?
        let cookies: [HTTPCookie]
    }

    static func renew(
        origin: URL,
        cookies: [SerializedHTTPCookie],
        store: SiteAccountStore
    ) async -> RenewalResult? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let cookieStore = config.websiteDataStore.httpCookieStore
        for item in cookies {
            if let httpCookie = item.makeHTTPCookie() {
                await cookieStore.setCookie(httpCookie)
            }
        }

        final class Collector: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            let origin: URL
            let tlsDelegate: SiteTLSDelegate
            var capturedToken: String?
            var capturedRefreshToken: String?
            var capturedTokenEndpoint: String?
            var capturedClientID: String?
            var onFinish: (() -> Void)?
            var onTokenCaptured: (() -> Void)?

            init(origin: URL, store: SiteAccountStore) {
                self.origin = origin
                self.tlsDelegate = SiteTLSDelegate(preferredOrigin: origin, lookup: store.registry)
            }

            func acceptPayload(_ dict: [String: Any]) {
                if let pageHost = (dict["pageHost"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !pageHost.isEmpty,
                   let siteHost = origin.host,
                   !SiteOrigin.hostMatches(pageHost, siteHost: siteHost) {
                    return
                }
                guard let rawToken = dict["token"] as? String else { return }
                let cleaned = SiteAuthCoordinator.cleanToken(rawToken)
                guard cleaned.count >= 12 else { return }
                let newClaims = JWTClaims.inspect(cleaned)
                if newClaims?.isLicenseToken == true {
                    return
                }
                if let existing = capturedToken,
                   JWTClaims.inspect(existing) != nil,
                   newClaims == nil {
                    return
                }
                capturedToken = cleaned
                if let ref = (dict["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
                    capturedRefreshToken = ref
                }
                if let endpoint = (dict["tokenEndpoint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty {
                    capturedTokenEndpoint = endpoint
                }
                if let cid = (dict["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cid.isEmpty {
                    capturedClientID = cid
                }
                onTokenCaptured?()
            }

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let dict = message.body as? [String: Any] else { return }
                acceptPayload(dict)
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
        let script = WKUserScript(source: SiteAuthWebScript.captureSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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
            var finishTask: Task<Void, Never>?
            var tokenFinishScheduled = false
            @MainActor func finish() {
                guard !resumed else { return }
                resumed = true
                finishTask?.cancel()
                continuation.resume()
            }
            collector.onTokenCaptured = {
                guard !tokenFinishScheduled else { return }
                tokenFinishScheduled = true
                finishTask?.cancel()
                finishTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    finish()
                }
            }
            collector.onFinish = {
                finishTask?.cancel()
                let delay: Duration = collector.capturedToken != nil ? .milliseconds(250) : .milliseconds(2500)
                finishTask = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    finish()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                finish()
            }
            webView.load(URLRequest(url: origin))
        }

        if let snapshot = (try? await webView.evaluateJavaScript(SiteAuthWebScript.snapshotExpression)) as? [String: Any] {
            collector.acceptPayload(snapshot)
        }

        let refreshedCookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { list in
                continuation.resume(returning: list)
            }
        }
        guard collector.capturedToken != nil || !refreshedCookies.isEmpty else {
            return nil
        }
        return RenewalResult(
            token: collector.capturedToken,
            refreshToken: collector.capturedRefreshToken,
            tokenEndpoint: collector.capturedTokenEndpoint,
            clientID: collector.capturedClientID,
            cookies: refreshedCookies
        )
    }
}

enum SiteAuthWebScript {
    static let snapshotExpression = "window.__rockSiteAuthSnapshot ? window.__rockSiteAuthSnapshot() : null"

    /// Captures auth tokens exchanged via XHR/fetch OIDC token endpoints, BroadcastChannel
    /// updates, request headers (`X-Jazz-Token`, `Authorization: Bearer|OAuth|JWT`), and
    /// storage keys used by Jazz / OIDC web apps while filtering unrelated telemetry headers.
    static let captureSource = #"""
    (function() {
        var BEST_KEY = '__rockSiteAuthCaptured';
        function isIgnoredUrl(url) {
            var s = String(url || '').toLowerCase();
            return s.indexOf('unleash') >= 0 ||
                s.indexOf('amplitude') >= 0 ||
                s.indexOf('clickbeat') >= 0 ||
                s.indexOf('mc.yandex') >= 0 ||
                s.indexOf('firebase') >= 0 ||
                s.indexOf('google-analytics') >= 0 ||
                s.indexOf('googleapis.com') >= 0 ||
                s.indexOf('sentry') >= 0 ||
                s.indexOf('plat-license-manager') >= 0 ||
                s.indexOf('/licenses/') >= 0 ||
                s.indexOf('/license/') >= 0 ||
                s.indexOf('/xr/token') >= 0 ||
                s.indexOf('media-stream-token') >= 0;
        }
        function isJwt(tok) {
            return typeof tok === 'string' && /^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(tok);
        }
        function decodeBase64Url(segment) {
            var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            var clean = String(segment || '').replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, '');
            var bytes = [];
            for (var i = 0; i < clean.length; i += 4) {
                var c1 = clean.charAt(i);
                var c2 = clean.charAt(i + 1);
                var c3 = clean.charAt(i + 2);
                var c4 = clean.charAt(i + 3);
                var e1 = c1 ? chars.indexOf(c1) : -1;
                var e2 = c2 ? chars.indexOf(c2) : -1;
                var e3 = c3 ? chars.indexOf(c3) : -1;
                var e4 = c4 ? chars.indexOf(c4) : -1;
                if (e1 < 0 || e2 < 0) break;
                bytes.push((e1 << 2) | (e2 >> 4));
                if (e3 >= 0) bytes.push(((e2 & 15) << 4) | (e3 >> 2));
                if (e4 >= 0) bytes.push(((e3 & 3) << 6) | e4);
            }
            var hex = '';
            for (var j = 0; j < bytes.length; j++) {
                hex += '%' + ('0' + bytes[j].toString(16)).slice(-2);
            }
            return decodeURIComponent(hex);
        }
        function decodeJwtPayload(tok) {
            if (!isJwt(tok)) return null;
            try {
                var parts = tok.split('.');
                if (parts.length !== 3) return null;
                return JSON.parse(decodeBase64Url(parts[1]));
            } catch (e) {
                return null;
            }
        }
        function isLicenseJwt(tok) {
            var p = decodeJwtPayload(tok);
            if (!p || typeof p !== 'object') return false;
            var hasLicenseClaim = (p.graceExp !== undefined && p.graceExp !== null) ||
                (p.jazz_premium_user !== undefined && p.jazz_premium_user !== null) ||
                (p.license_type !== undefined && p.license_type !== null);
            var sub = (typeof p.sub === 'string') ? p.sub.trim() : '';
            var email = (typeof p.email === 'string') ? p.email.trim() : '';
            var pref = (typeof p.preferred_username === 'string') ? p.preferred_username.trim() : '';
            return hasLicenseClaim && !sub && !email && !pref;
        }
        function cleanAndValidateToken(raw, fromAuthHeader) {
            if (typeof raw !== 'string') return '';
            var trimmed = raw.trim();
            if (!trimmed || /^basic\s+/i.test(trimmed)) return '';
            var hasExplicitPrefix = /^(?:bearer|oauth)\s+/i.test(trimmed);
            var stripped = trimmed.replace(/^(?:bearer|oauth)\s+/i, '').trim();
            if (stripped.length < 12) return '';
            if (fromAuthHeader && !hasExplicitPrefix && !isJwt(stripped)) return '';
            return stripped;
        }
        function extractClientId(body) {
            if (!body) return '';
            try {
                if (typeof URLSearchParams === 'function' && body instanceof URLSearchParams) {
                    return body.get('client_id') || body.get('clientId') || '';
                }
                if (typeof body === 'string') {
                    var trimmed = body.trim();
                    if (trimmed[0] === '{') {
                        var parsed = JSON.parse(trimmed);
                        return (parsed && (parsed.client_id || parsed.clientId)) || '';
                    }
                    var match = trimmed.match(/(?:^|&)client_id=([^&]+)/i);
                    if (match && match[1]) {
                        return decodeURIComponent(match[1].replace(/\+/g, ' '));
                    }
                }
            } catch (e) {}
            return '';
        }
        function resolveUrl(rawUrl) {
            if (!rawUrl || typeof rawUrl !== 'string') return '';
            try {
                return new URL(rawUrl, window.location.href).href;
            } catch (e) {
                return rawUrl;
            }
        }
        function looksLikeAuthUrl(rawUrl) {
            var l = String(rawUrl || '').toLowerCase();
            return l.indexOf('auth') >= 0 ||
                l.indexOf('token') >= 0 ||
                l.indexOf('openid') >= 0 ||
                l.indexOf('oauth') >= 0 ||
                l.indexOf('login') >= 0 ||
                l.indexOf('session') >= 0 ||
                l.indexOf('cookie-to-token') >= 0;
        }
        function isOAuthTokenEndpoint(url) {
            var l = String(url || '').toLowerCase().split('?')[0].split('#')[0];
            if (!l || isIgnoredUrl(l)) return false;
            return l.indexOf('openid-connect/token') >= 0 ||
                l.indexOf('/oauth') >= 0 ||
                l.indexOf('/refresh') >= 0 ||
                /\/token$/.test(l);
        }
        function isJazzBackendSource(url, source) {
            if (source === 'x-jazz-token') return true;
            if (source !== 'fetch-response' && source !== 'xhr-response') return false;
            var l = String(url || '').toLowerCase().split('?')[0].split('#')[0];
            return l.indexOf('/auth/login/b2b') >= 0 || l.indexOf('/auth/cookie-to-token') >= 0;
        }
        function post(rawToken, refreshToken, tokenEndpoint, clientId, fromAuthHeader, source, endpointUrl) {
            var token = cleanAndValidateToken(rawToken, Boolean(fromAuthHeader));
            if (!token || isLicenseJwt(token)) return;
            var prev = window[BEST_KEY];
            if (prev && isJwt(prev.token) && !isJwt(token)) return;
            var incomingIsJazz = isJazzBackendSource(endpointUrl, source);
            var safeEndpoint = isOAuthTokenEndpoint(tokenEndpoint) ? String(tokenEndpoint).trim() : '';
            var nextRefresh = (typeof refreshToken === 'string' && refreshToken.trim()) ? refreshToken.trim() : ((prev && prev.refreshToken) || '');
            var nextEndpoint = safeEndpoint || ((prev && prev.tokenEndpoint) || '');
            var nextClient = (typeof clientId === 'string' && clientId.trim()) ? clientId.trim() : ((prev && prev.clientId) || '');
            if (prev && prev.isJazzBackend && !incomingIsJazz) {
                if (prev.refreshToken === nextRefresh && prev.tokenEndpoint === nextEndpoint && prev.clientId === nextClient) {
                    return;
                }
                token = prev.token;
                incomingIsJazz = true;
            }
            var effectiveSource = source || (prev && prev.source) || '';
            if (prev && prev.token === token && prev.refreshToken === nextRefresh && prev.tokenEndpoint === nextEndpoint && prev.clientId === nextClient && Boolean(prev.isJazzBackend) === incomingIsJazz) {
                return;
            }
            var payload = {
                token: token,
                refreshToken: nextRefresh,
                tokenEndpoint: nextEndpoint,
                clientId: nextClient,
                pageHost: (window.location && window.location.hostname) || '',
                source: effectiveSource,
                isJazzBackend: incomingIsJazz
            };
            window[BEST_KEY] = payload;
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.siteAuthBridge) {
                    window.webkit.messageHandlers.siteAuthBridge.postMessage(payload);
                }
            } catch (e) {}
        }
        function inspectJsonPayload(data, endpointUrl, clientId, source) {
            if (!data || typeof data !== 'object') return;
            var tok = data.access_token || data.accessToken || data.jazzToken || data.token;
            var ref = data.refresh_token || data.refreshToken || '';
            var cid = clientId || data.client_id || data.clientId || '';
            if (tok && typeof tok === 'string') {
                post(tok, ref, endpointUrl, cid, false, source, endpointUrl);
            }
        }
        function handleAuthHeader(name, value, source, endpointUrl) {
            if (!value) return;
            var ln = String(name || '').toLowerCase();
            if (ln === 'x-jazz-token') post(value, '', '', '', false, 'x-jazz-token', endpointUrl || '');
            else if (ln === 'x-auth-token') post(value, '', '', '', false, source, endpointUrl || '');
            else if (ln === 'authorization') post(value, '', '', '', true, source, endpointUrl || '');
        }
        function inspectHeaders(headers, endpointUrl) {
            if (!headers) return;
            try {
                if (typeof headers.get === 'function') {
                    handleAuthHeader('x-jazz-token', headers.get('X-Jazz-Token') || headers.get('x-jazz-token'), 'fetch-header', endpointUrl);
                    handleAuthHeader('x-auth-token', headers.get('X-Auth-Token') || headers.get('x-auth-token'), 'fetch-header', endpointUrl);
                    handleAuthHeader('authorization', headers.get('Authorization') || headers.get('authorization'), 'fetch-header', endpointUrl);
                } else if (Array.isArray(headers)) {
                    for (var i = 0; i < headers.length; i++) {
                        var pair = headers[i];
                        if (!Array.isArray(pair) || pair.length < 2) continue;
                        handleAuthHeader(pair[0], pair[1], 'fetch-header', endpointUrl);
                    }
                } else if (typeof headers === 'object') {
                    for (var k in headers) {
                        handleAuthHeader(k, headers[k], 'fetch-header', endpointUrl);
                    }
                }
            } catch (e) {}
        }
        var origFetch = window.fetch;
        if (origFetch) {
            window.fetch = function(input, init) {
                var rawUrl = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
                var resolvedUrl = resolveUrl(rawUrl);
                var ignored = isIgnoredUrl(resolvedUrl);
                var reqClientId = '';
                if (!ignored) {
                    if (input && typeof input === 'object' && input.headers) inspectHeaders(input.headers, resolvedUrl);
                    if (init && init.headers) inspectHeaders(init.headers, resolvedUrl);
                    reqClientId = extractClientId(init && init.body);
                }
                return origFetch.apply(this, arguments).then(function(resp) {
                    try {
                        var finalUrl = resolveUrl((resp && resp.url) || resolvedUrl);
                        var ct = ((resp && resp.headers && resp.headers.get('content-type')) || '').toLowerCase();
                        if (!ignored && !isIgnoredUrl(finalUrl) && resp && resp.ok && ct.indexOf('json') >= 0 && looksLikeAuthUrl(finalUrl)) {
                            resp.clone().json().then(function(data) {
                                inspectJsonPayload(data, finalUrl, reqClientId, 'fetch-response');
                            }).catch(function() {});
                        }
                    } catch (e) {}
                    return resp;
                });
            };
        }
        if (typeof XMLHttpRequest === 'function' && XMLHttpRequest.prototype) {
            var origOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__rockUrl = resolveUrl(url);
                this.__rockClientId = '';
                return origOpen.apply(this, arguments);
            };
            var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
                if (!isIgnoredUrl(this.__rockUrl)) {
                    handleAuthHeader(name, value, 'xhr-header', this.__rockUrl);
                }
                return origSetHeader.apply(this, arguments);
            };
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.send = function(body) {
                if (body) {
                    var cid = extractClientId(body);
                    if (cid) this.__rockClientId = cid;
                }
                if (!this.__rockHooked && typeof this.addEventListener === 'function') {
                    this.__rockHooked = true;
                    var xhr = this;
                    this.addEventListener('load', function() {
                        try {
                            var status = xhr.status || 0;
                            if (status < 200 || status >= 300) return;
                            var finalUrl = resolveUrl(xhr.responseURL || xhr.__rockUrl || '');
                            if (isIgnoredUrl(finalUrl)) return;
                            var cid = xhr.__rockClientId || '';
                            if (xhr.responseType === 'json') {
                                if (looksLikeAuthUrl(finalUrl) || (xhr.response && (xhr.response.access_token || xhr.response.accessToken || xhr.response.jazzToken))) {
                                    inspectJsonPayload(xhr.response, finalUrl, cid, 'xhr-response');
                                }
                                return;
                            }
                            if (xhr.responseType && xhr.responseType !== 'text') return;
                            var text = xhr.responseText || '';
                            var trimmed = text.trim();
                            if (!trimmed || (trimmed[0] !== '{' && trimmed[0] !== '[')) return;
                            if (looksLikeAuthUrl(finalUrl) || text.indexOf('access_token') >= 0 || text.indexOf('accessToken') >= 0 || text.indexOf('jazzToken') >= 0) {
                                inspectJsonPayload(JSON.parse(trimmed), finalUrl, cid, 'xhr-response');
                            }
                        } catch (e) {}
                    });
                }
                return origSend.apply(this, arguments);
            };
        }
        try {
            if (typeof BroadcastChannel === 'function' && BroadcastChannel.prototype && typeof BroadcastChannel.prototype.postMessage === 'function') {
                var origBcPost = BroadcastChannel.prototype.postMessage;
                BroadcastChannel.prototype.postMessage = function(msg) {
                    try {
                        if (msg && typeof msg === 'object') {
                            var bcTok = msg.access_token || msg.accessToken || msg.jazzToken || msg.token;
                            if (typeof bcTok === 'string') {
                                var ref = msg.refreshToken || msg.refresh_token || '';
                                var cid = msg.clientId || msg.client_id || '';
                                post(bcTok, ref, '', cid, false, 'broadcast', '');
                            }
                        }
                    } catch (e) {}
                    return origBcPost.apply(this, arguments);
                };
            }
        } catch (e) {}
        function scanHash() {
            try {
                var hash = (window.location && window.location.hash) || '';
                if (hash.indexOf('access_token=') >= 0) {
                    var params = new URLSearchParams(hash.replace(/^#/, ''));
                    var tok = params.get('access_token');
                    var ref = params.get('refresh_token') || '';
                    if (tok) post(tok, ref, '', '', false, 'hash', '');
                }
            } catch (e) {}
        }
        function scanStoreArea(storage) {
            if (!storage) return;
            for (var i = 0; i < storage.length; i++) {
                var key = storage.key(i) || '';
                var lk = key.toLowerCase();
                if (lk.indexOf('license') >= 0 ||
                    lk.indexOf('unleash') >= 0 ||
                    lk.indexOf('analytics') >= 0 ||
                    lk.indexOf('amplitude') >= 0 ||
                    lk.indexOf('telemetry') >= 0 ||
                    lk.indexOf('firebase') >= 0) {
                    continue;
                }
                if (lk.indexOf('auth') >= 0 || lk.indexOf('token') >= 0 || lk.indexOf('jazz') >= 0 || lk.indexOf('oidc') >= 0 || lk.indexOf('keycloak') >= 0) {
                    var val = storage.getItem(key);
                    if (!val || val.length < 12) continue;
                    var trimmed = val.trim();
                    if (trimmed[0] === '{') {
                        try { inspectJsonPayload(JSON.parse(trimmed), '', '', 'storage'); } catch (e) {}
                    } else if ((lk.indexOf('jazz') >= 0 && lk.indexOf('token') >= 0) || isJwt(trimmed)) {
                        post(trimmed, '', '', '', false, 'storage', '');
                    }
                }
            }
        }
        function scanStorage() {
            try {
                scanStoreArea(window.localStorage);
                scanStoreArea(window.sessionStorage);
            } catch (e) {}
        }
        window.__rockSiteAuthSnapshot = function() {
            scanHash();
            scanStorage();
            return window[BEST_KEY] || null;
        };
        window.addEventListener('load', function() {
            setTimeout(function() {
                scanHash();
                scanStorage();
            }, 300);
        });
    })();
    """#
}
#endif
