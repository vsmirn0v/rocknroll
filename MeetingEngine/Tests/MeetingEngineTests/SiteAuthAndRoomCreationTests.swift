import ConferenceCore
import Foundation
import XCTest
@testable import MeetingEngine

@MainActor
final class SiteAuthAndRoomCreationTests: XCTestCase {
    // Disposable self-signed EC P-256 fixture (/O=ExampleCorp/CN=Fixture Client Cert, pass: "testpass")
    private static let fixtureP12Base64 =
        "MIIERAIBAzCCA/IGCSqGSIb3DQEHAaCCA+MEggPfMIID2zCCAooGCSqGSIb3DQEHBqCCAnswggJ3" +
        "AgEAMIICcAYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBA5KJEJRi+6" +
        "WvUO6OX1a9IFAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQYfdfCOw7dxxl0YzXfbMp" +
        "poCCAgDsJEhukl0gUyeMAbyUL3vCPLKyhgP+9rKr7DI7f7ssufObrcJe6Pxf5gH9axlyAEQXvZmG" +
        "bFB2Z5p13Vp6hfn5YEnKly/vDk69JS17bJgXiMO9iiDpZK9rp1LqFO2IVlR66vdSbvsFy3FmYd3i" +
        "yNA86q4eC0YywLRSLHy1I2Aj7ryvzp2naCp4Mb9Uiy8ip5FFYMEaSbq6IUHi853dydu6Nm2E8D6e" +
        "W0SdjGwps5DcrMLtyNJ1M63RCM6SoBi/3ucIx7RqLIjnHuuPuKR4cRDW7TvNvzB72Qf+D1sWSBHW" +
        "pAlb++kaRMBLjPvK5SI3uHECUGdJVQehJSUB87aXq9mVru1jdZxbIQVsRTTngWtgCnkmY5uyJ1qe" +
        "KD41OsRtgSLSIhmxAtAovgR+Ll7kJJ2Po6d4KxiZD9JAQpc87MVQthN8fNBkAznXLrVeuTCivPnc" +
        "nrM7UVq8bRQbGEbNfGQNgSXoSNbi8gRq2PVrkoFheAP0yTmLWNf3pIGqT+fGEavxCyyhxnyRxCpF" +
        "F1smj0iuBr2VJDjq54JjhQnBiDLp8FrADudU3N8U6ds2yFBqz8aruwVL+JEfOI2OldGimbpFYnos" +
        "adZ3T1ldhJOWT36uz7m2mTRxmZiqTx8RF7J5+RJX//Xu61eErp4gbdVw4LO4W3c8RAOqJbYe6Or9" +
        "SHMDwTCCAUkGCSqGSIb3DQEHAaCCAToEggE2MIIBMjCCAS4GCyqGSIb3DQEMCgECoIH3MIH0MF8G" +
        "CSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBDjpB7CcchpizqFdKGCvLofAgIIADAMBggqhkiG" +
        "9w0CCQUAMB0GCWCGSAFlAwQBKgQQoYPMIzBiTS//qJaYElVa6QSBkISFUhEdAIbtUSyfZwvOu6Eq" +
        "kL+YV+eYVyp4HQmFuH4HFbjeGTn9AJiEeRFu71EQHZg0jZoBngV2QDdTF/qsNi4cvuePlOEuJrBj" +
        "7pDAlBvWeFs0sCSJFbEgHYVcfltqCfiGvT2AtKNJDuccdws3Xlpagh6kb6G7LNt9OLeEb9RRa9Fc" +
        "KgNIvIE7KeH5rGPzAzElMCMGCSqGSIb3DQEJFTEWBBTAvCcF9SSsuSsuwlDSeGpZpPnrRzBJMDEw" +
        "DQYJYIZIAWUDBAIBBQAEIFn+kDtGZjOpHcvf2DwQSwYTB0o8nAWTWaBaEI2ZbNjPBBBonPSTPl7O" +
        "NFFY9Mrr8idFAgIIAA=="

    final class MockURLProtocol: URLProtocol {
        struct Reply {
            var status = 200
            var mime = "application/json"
            var body: Data
        }
        private static let lock = NSLock()
        private static var requests: [URLRequest] = []
        private static var handler: (URLRequest) -> Reply = { _ in Reply(status: 404, body: Data()) }

        static func reset(_ handler: @escaping (URLRequest) -> Reply) {
            lock.lock()
            requests = []
            self.handler = handler
            lock.unlock()
        }

        static var capturedRequests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read > 0 { data.append(buffer, count: read) } else { break }
                }
                stream.close()
                captured.httpBody = data
            }
            Self.lock.lock()
            Self.requests.append(captured)
            let reply = Self.handler(captured)
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.mime]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class DummyChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func makeIsolatedStore() -> (store: SiteAccountStore, prefs: UserDefaults, suite: String) {
        let suite = "site-auth-test-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        let secretStore = InMemorySiteSecretStore()
        let registry = SiteClientIdentityRegistry(preferences: prefs, secretStore: secretStore)
        let store = SiteAccountStore(preferences: prefs, secretStore: secretStore, registry: registry, loadSystemIdentities: false)
        return (store, prefs, suite)
    }

    nonisolated private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeJWT(exp: TimeInterval, name: String = "Test User") -> String {
        func b64(_ obj: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "HS256", "typ": "JWT"])).\(b64(["sub": "u1", "name": name, "exp": Int(exp)])).sig"
    }

    // MARK: - SiteTLSDelegate Tests

    func testSiteTLSDelegateClientCertResponseSubdomainInheritanceAndRejectionLoopGuard() throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        let p12 = try XCTUnwrap(Data(base64Encoded: Self.fixtureP12Base64))
        let cert = try store.importCertificate(data: p12, passphrase: "testpass")
        let jazzOrigin = URL(string: "https://jazz.corp.ru")!
        store.setClientCertificate(importedID: cert.id, forOrigin: jazzOrigin, defaultEngine: .guest)

        let delegate = SiteTLSDelegate(preferredOrigin: nil, lookup: store.registry)
        let sender = DummyChallengeSender()

        // Subdomain `api.jazz.corp.ru` inherits client cert from `https://jazz.corp.ru`
        let subSpace = URLProtectionSpace(
            host: "api.jazz.corp.ru",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        let firstChallenge = URLAuthenticationChallenge(
            protectionSpace: subSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        var firstDisp: URLSession.AuthChallengeDisposition?
        var firstCred: URLCredential?
        delegate.handleChallenge(firstChallenge) { disp, cred in
            firstDisp = disp
            firstCred = cred
        }
        XCTAssertEqual(firstDisp, .useCredential)
        XCTAssertNotNil(firstCred?.identity)

        // When previousFailureCount > 0, cancel instead of looping and record rejected = true
        let retryChallenge = URLAuthenticationChallenge(
            protectionSpace: subSpace,
            proposedCredential: nil,
            previousFailureCount: 1,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        var retryDisp: URLSession.AuthChallengeDisposition?
        var retryCred: URLCredential?
        delegate.handleChallenge(retryChallenge) { disp, cred in
            retryDisp = disp
            retryCred = cred
        }
        XCTAssertEqual(retryDisp, .cancelAuthenticationChallenge)
        XCTAssertNil(retryCred)
        let challengeState = store.wasChallengedForClientCertificate(host: "api.jazz.corp.ru")
        XCTAssertTrue(challengeState.challenged)
        XCTAssertTrue(challengeState.rejected)

        // Unrelated host receives .performDefaultHandling (no cert leaked)
        let otherSpace = URLProtectionSpace(
            host: "unrelated.example.net",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        let otherChallenge = URLAuthenticationChallenge(
            protectionSpace: otherSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        var otherDisp: URLSession.AuthChallengeDisposition?
        delegate.handleChallenge(otherChallenge) { disp, _ in otherDisp = disp }
        XCTAssertEqual(otherDisp, .performDefaultHandling)
        XCTAssertTrue(store.wasChallengedForClientCertificate(host: "unrelated.example.net").challenged)
    }

    // MARK: - SiteAccountStore 1-Login-Per-Site Tests

    func testOneLoginPerSiteAndTelemostCanonicalizationPreservingCertificate() throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        let p12 = try XCTUnwrap(Data(base64Encoded: Self.fixtureP12Base64))
        let cert = try store.importCertificate(data: p12, passphrase: "testpass")

        let first = SiteAccountRecord(
            originKey: "https://Jazz.Corp.RU:443/calls/123",
            engine: .guest,
            authMethod: .webSSO,
            username: "alice",
            clientCertificateID: cert.id
        )
        store.upsertAccount(first, secret: SiteSecretPayload(accessToken: "tok-1"))

        let replacement = SiteAccountRecord(
            originKey: "https://jazz.corp.ru",
            engine: .guest,
            authMethod: .token,
            username: "bob"
        )
        store.upsertAccount(replacement, secret: SiteSecretPayload(accessToken: "tok-2"))

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.username, "bob")
        XCTAssertEqual(store.accounts.first?.clientCertificateID, cert.id)
        XCTAssertEqual(store.readSecret(for: "https://jazz.corp.ru")?.accessToken, "tok-2")

        // Telemost 360 and regular Telemost map to one canonical account
        store.upsertAccount(
            SiteAccountRecord(originKey: "https://telemost.360.yandex.ru/j/abc", engine: .telemost, authMethod: .token, username: "ya"),
            secret: SiteSecretPayload(accessToken: "oauth-ya")
        )
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertNotNil(store.account(for: URL(string: "https://telemost.yandex.ru/j/xyz")!))
        XCTAssertNotNil(store.account(for: URL(string: "https://telemost.360.yandex.ru/j/xyz")!))
    }

    // MARK: - Silent Token Refresh & Relogin Tests

    func testSilentRefreshTokenDeduplicatesConcurrentCallsAndSavedPasswordReloginFallback() async throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        let origin = URL(string: "https://tc.example.test")!
        let expiredJWT = makeJWT(exp: Date().addingTimeInterval(-300).timeIntervalSince1970)
        let freshJWT = makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970, name: "Refreshed Ada")

        store.upsertAccount(
            SiteAccountRecord(
                originKey: origin.absoluteString,
                engine: .trueconf,
                authMethod: .credentials,
                username: "ada",
                tokenEndpoint: "https://tc.example.test/oauth2/v1/token",
                tokenExpiresAt: Date().addingTimeInterval(-300)
            ),
            secret: SiteSecretPayload(
                accessToken: expiredJWT,
                refreshToken: "ref-1",
                savedPassword: "pw!",
                oauthClientID: "cid",
                oauthClientSecret: "csec"
            )
        )

        MockURLProtocol.reset { req in
            if req.url?.path == "/oauth2/v1/token" {
                let body = try! JSONSerialization.data(withJSONObject: [
                    "access_token": freshJWT,
                    "refresh_token": "ref-2",
                    "expires_in": 3600
                ])
                return .init(body: body)
            }
            return .init(status: 404, body: Data())
        }

        let coordinator = SiteAuthCoordinator(store: store, makeSession: { _ in self.makeMockSession() })

        // Fire two concurrent validCredentials calls; refresh endpoint should only be hit once.
        async let c1 = coordinator.validCredentials(for: origin, engine: .trueconf)
        async let c2 = coordinator.validCredentials(for: origin, engine: .trueconf)
        let (r1, r2) = await (c1, c2)
        XCTAssertEqual(r1?.accessToken, freshJWT)
        XCTAssertEqual(r2?.accessToken, freshJWT)
        XCTAssertEqual(MockURLProtocol.capturedRequests.filter { $0.url?.path == "/oauth2/v1/token" }.count, 1)
        XCTAssertEqual(store.readSecret(for: origin.absoluteString)?.refreshToken, "ref-2")

        // Now expire token and make refresh_token fail (400) -> silent saved-password relogin takes over
        let reloginJWT = makeJWT(exp: Date().addingTimeInterval(7200).timeIntervalSince1970, name: "Relogin Ada")
        store.upsertAccount(
            SiteAccountRecord(
                originKey: origin.absoluteString,
                engine: .trueconf,
                authMethod: .credentials,
                username: "ada",
                tokenEndpoint: "https://tc.example.test/oauth2/v1/token",
                tokenExpiresAt: Date().addingTimeInterval(-60)
            ),
            secret: SiteSecretPayload(
                accessToken: freshJWT,
                refreshToken: "ref-2",
                savedPassword: "pw!",
                oauthClientID: "cid",
                oauthClientSecret: "csec"
            )
        )

        MockURLProtocol.reset { req in
            let bodyText = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if req.url?.path == "/oauth2/v1/token" && bodyText.contains("grant_type=refresh_token") {
                return .init(status: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8))
            }
            if req.url?.path == "/oauth2/v1/token" && bodyText.contains("grant_type=password") {
                let body = try! JSONSerialization.data(withJSONObject: [
                    "access_token": reloginJWT,
                    "refresh_token": "ref-3",
                    "expires_in": 7200
                ])
                return .init(body: body)
            }
            return .init(status: 404, body: Data())
        }

        let relogged = await coordinator.validCredentials(for: origin, engine: .trueconf)
        XCTAssertEqual(relogged?.accessToken, reloginJWT)
        XCTAssertEqual(store.readSecret(for: origin.absoluteString)?.refreshToken, "ref-3")
    }

    // MARK: - MeetingRoomCreator Across All 3 Engines

    func testMeetingRoomCreatorGuestTrueConfAndTelemost() async throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        let coordinator = SiteAuthCoordinator(store: store, makeSession: { _ in self.makeMockSession() })
        let creator = MeetingRoomCreator(auth: coordinator, makeSession: { _ in self.makeMockSession() })

        // 1. Guest with 401 -> refresh -> retry -> MEETING room created
        let jazzOrigin = URL(string: "https://jazz.corp.ru")!
        let oldJazzJWT = makeJWT(exp: Date().addingTimeInterval(600).timeIntervalSince1970)
        let newJazzJWT = makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
        store.upsertAccount(
            SiteAccountRecord(
                originKey: jazzOrigin.absoluteString,
                engine: .guest,
                authMethod: .credentials,
                tokenEndpoint: "https://api.jazz.corp.ru/v1/auth/refresh",
                discoveredServerURL: "https://api.jazz.corp.ru",
                tokenExpiresAt: Date().addingTimeInterval(600)
            ),
            secret: SiteSecretPayload(accessToken: oldJazzJWT, refreshToken: "jazz-ref")
        )

        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.ru\"}}".utf8))
            case "/v1/auth/refresh":
                return .init(body: try! JSONSerialization.data(withJSONObject: ["accessToken": newJazzJWT, "expires_in": 3600]))
            case "/room/create-meeting":
                if req.value(forHTTPHeaderField: "X-Jazz-Token") == oldJazzJWT {
                    return .init(status: 401, body: Data("{\"error\":\"expired\"}".utf8))
                }
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Jazz-Token"), newJazzJWT)
                let body = try! JSONSerialization.data(withJSONObject: [
                    "url": "https://jazz.corp.ru/calls/jazzRoom1?psw=MXY",
                    "roomId": "jazzRoom1",
                    "password": "y"
                ])
                return .init(body: body)
            default:
                return .init(status: 404, body: Data())
            }
        }
        // Encode password "y" in sberdevices-prefix format: len=1 ('1' = 49), 'y'(121) ^ 's'(115) = 10 -> [49, 10] -> base64 "MQo="
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.ru\"}}".utf8))
            case "/v1/auth/refresh":
                return .init(body: try! JSONSerialization.data(withJSONObject: ["accessToken": newJazzJWT, "expires_in": 3600]))
            case "/room/create-meeting":
                if req.value(forHTTPHeaderField: "X-Jazz-Token") == oldJazzJWT {
                    return .init(status: 401, body: Data("{\"error\":\"expired\"}".utf8))
                }
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Jazz-Token"), newJazzJWT)
                let body = try! JSONSerialization.data(withJSONObject: [
                    "url": "https://jazz.corp.ru/calls/jazzRoom1?psw=MQo",
                    "roomId": "jazzRoom1",
                    "password": "y"
                ])
                return .init(body: body)
            default:
                return .init(status: 404, body: Data())
            }
        }
        let jazzRoom = try await creator.createRoom(
            on: jazzOrigin,
            engine: .guest,
            options: .init(title: "Design Sync", allowGuests: true, enableLobby: true)
        )
        XCTAssertEqual(jazzRoom.engine, .guest)
        XCTAssertEqual(jazzRoom.roomID, "jazzRoom1")
        XCTAssertEqual(jazzRoom.invitationURL.absoluteString, "https://jazz.corp.ru/calls/jazzRoom1?psw=MQo")

        // 2. TrueConf (/api/v3.8/conferences -> 404 -> /api/v4/conferences)
        let tcOrigin = URL(string: "https://tc.corp.ru")!
        store.upsertAccount(
            SiteAccountRecord(originKey: tcOrigin.absoluteString, engine: .trueconf, authMethod: .token, username: "alice"),
            secret: SiteSecretPayload(accessToken: "tc-bearer")
        )
        MockURLProtocol.reset { req in
            if req.url?.path == "/api/v3.8/conferences" {
                return .init(status: 404, body: Data())
            }
            if req.url?.path == "/api/v4/conferences" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tc-bearer")
                let body = try! JSONSerialization.data(withJSONObject: [
                    "conference": ["id": "0560438410", "topic": "TrueConf Standup"]
                ])
                return .init(body: body)
            }
            return .init(status: 404, body: Data())
        }
        let tcRoom = try await creator.createRoom(on: tcOrigin, engine: .trueconf, options: .init(title: "TrueConf Standup"))
        XCTAssertEqual(tcRoom.engine, .trueconf)
        XCTAssertEqual(tcRoom.roomID, "0560438410")
        XCTAssertEqual(tcRoom.invitationURL.absoluteString, "https://tc.corp.ru/c/0560438410")

        // 3. Telemost (OAuth token -> v1/telemost-api/conferences, then Cookie -> telemost_front/v2)
        let tmOrigin = URL(string: "https://telemost.360.yandex.ru")!
        store.upsertAccount(
            SiteAccountRecord(originKey: tmOrigin.absoluteString, engine: .telemost, authMethod: .token),
            secret: SiteSecretPayload(accessToken: "ya-oauth-tok")
        )
        MockURLProtocol.reset { req in
            XCTAssertEqual(req.url?.absoluteString, "https://cloud-api.yandex.net/v1/telemost-api/conferences")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "OAuth ya-oauth-tok")
            return .init(body: Data("{\"join_url\":\"https://telemost.yandex.ru/j/9988776655\"}".utf8))
        }
        let tmRoom = try await creator.createRoom(on: tmOrigin, engine: .telemost, options: .init(title: "Yandex Sync", allowGuests: true))
        XCTAssertEqual(tmRoom.engine, .telemost)
        XCTAssertEqual(tmRoom.roomID, "9988776655")
        XCTAssertEqual(tmRoom.invitationURL.absoluteString, "https://telemost.yandex.ru/j/9988776655")

        let cookie = SerializedHTTPCookie(name: "Session_id", value: "s1", domain: ".yandex.ru", path: "/", isSecure: true)
        store.upsertAccount(
            SiteAccountRecord(originKey: tmOrigin.absoluteString, engine: .telemost, authMethod: .webSSO),
            secret: SiteSecretPayload(cookies: [cookie])
        )
        MockURLProtocol.reset { req in
            XCTAssertEqual(req.url?.absoluteString, "https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "Session_id=s1")
            return .init(body: Data("{\"join_url\":\"https://telemost.yandex.ru/j/1122334455\"}".utf8))
        }
        let tmCookieRoom = try await creator.createRoom(on: tmOrigin, engine: .telemost, options: .init(title: "Cookie Sync"))
        XCTAssertEqual(tmCookieRoom.roomID, "1122334455")
    }

    // MARK: - Authenticated Bootstrap Tests

    func testAuthenticatedBootstrapsSendHeadersAndFallbackCleanly() async throws {
        let session = makeMockSession()

        // GuestBootstrap with authHeaders + jazzToken
        let guestInvite = try GuestInvitation.parse("https://jazz.corp.ru/calls/r1")
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.ru\"}}".utf8))
            case "/room/r1/preconnect":
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Jazz-Token"), "j-tok")
                return .init(body: Data("{\"connectorUrl\":\"wss://rtc.jazz.corp.ru/ws\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        let prepared = try await GuestBootstrap(session: session).prepare(
            guestInvite,
            participantName: "Alice",
            jazzToken: "j-tok",
            authHeaders: ["X-Jazz-Token": "j-tok"]
        )
        XCTAssertEqual(prepared.joinPayload["jazzToken"] as? String, "j-tok")

        // TrueConfBootstrap with authenticated Bearer + fallback to saved password when allow_guests is false
        let tcTarget = try TrueConfTarget.parse("https://tc.corp.ru/c/private1")
        let tcAccount = SiteAccountRecord(originKey: "https://tc.corp.ru", engine: .trueconf, authMethod: .credentials, username: "alice")
        let tcCreds = ResolvedSiteCredentials(account: tcAccount, accessToken: "tc-tok")

        MockURLProtocol.reset { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tc-tok")
            return .init(status: 403, body: Data())
        }
        let tcFallback = try await TrueConfBootstrap.load(
            tcTarget,
            name: "Alice",
            session: session,
            credentials: tcCreds,
            savedPassword: "alice-password"
        )
        XCTAssertEqual(tcFallback.login, "alice")
        XCTAssertEqual(tcFallback.credential, "alice-password")
        XCTAssertEqual(tcFallback.credentialsType, 1)

        // TelemostBootstrap with OAuth header
        let tmTarget = try TelemostTarget.parse("https://telemost.yandex.ru/j/12345")
        let tmAccount = SiteAccountRecord(originKey: "https://telemost.yandex.ru", engine: .telemost, authMethod: .token)
        let tmCreds = ResolvedSiteCredentials(account: tmAccount, accessToken: "ya-tok")
        MockURLProtocol.reset { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "OAuth ya-tok")
            let body = try! JSONSerialization.data(withJSONObject: [
                "connection_type": "CONFERENCE",
                "media_platform": "GOLOOM",
                "room_id": "12345",
                "peer_id": "p1",
                "credentials": "c1",
                "client_configuration": [
                    "media_server_url": "wss://rtc.yandex.net/ws",
                    "service_name": "telemost"
                ]
            ])
            return .init(body: body)
        }
        let tmBoot = try await TelemostBootstrap.load(tmTarget, name: "Alice", session: session, credentials: tmCreds)
        XCTAssertEqual(tmBoot.roomID, "12345")
    }

    func testCompleteWebSignInRejectsUnverifiedAnonymousCookies() async throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        MockURLProtocol.reset { req in
            if req.url?.path == "/.well-known/jazz-services.json" {
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.ru\"}}".utf8))
            }
            return .init(status: 404, body: Data())
        }

        let coordinator = SiteAuthCoordinator(store: store, makeSession: { _ in self.makeMockSession() })
        let trackingCookie = HTTPCookie(properties: [
            .domain: "jazz.corp.ru",
            .path: "/",
            .name: "_ga",
            .value: "GA1.2.12345"
        ])!

        do {
            _ = try await coordinator.completeWebSignIn(
                origin: URL(string: "https://jazz.corp.ru")!,
                engine: .guest,
                capturedAccessToken: nil,
                cookies: [trackingCookie],
                requireVerifiedProof: true
            )
            XCTFail("Expected verificationFailed for unauthenticated cookies")
        } catch let error as SiteAuthError {
            if case .verificationFailed = error {
                // expected
            } else {
                XCTFail("Unexpected SiteAuthError: \(error)")
            }
        }

        do {
            _ = try await coordinator.completeWebSignIn(
                origin: URL(string: "https://tc.corp.ru")!,
                engine: .trueconf,
                capturedAccessToken: nil,
                cookies: [trackingCookie],
                requireVerifiedProof: false
            )
            XCTFail("Expected verificationFailed for unverified TrueConf web session")
        } catch let error as SiteAuthError {
            if case .verificationFailed = error {
                // expected
            } else {
                XCTFail("Unexpected SiteAuthError: \(error)")
            }
        }
    }

    func testClearingOrDeletingCertificateRemovesOrphanMTLSAccountAndChallengeState() throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        let p12 = try XCTUnwrap(Data(base64Encoded: Self.fixtureP12Base64))
        let cert = try store.importCertificate(data: p12, passphrase: "testpass")
        let origin = URL(string: "https://mtls.example.org")!
        store.setClientCertificate(importedID: cert.id, forOrigin: origin, defaultEngine: .guest)
        store.registry.noteClientCertificateChallenge(host: "mtls.example.org", port: 443, rejected: true)
        XCTAssertTrue(store.wasChallengedForClientCertificate(host: "mtls.example.org").rejected)

        store.clearClientCertificate(forOriginKey: "https://mtls.example.org")
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(store.wasChallengedForClientCertificate(host: "mtls.example.org").challenged)

        store.setClientCertificate(importedID: cert.id, forOrigin: origin, defaultEngine: .guest)
        store.registry.noteClientCertificateChallenge(host: "mtls.example.org", port: 443, rejected: false)
        store.deleteCertificate(id: cert.id)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(store.wasChallengedForClientCertificate(host: "mtls.example.org").challenged)
    }
}
