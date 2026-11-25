import ConferenceCore
import Foundation
import XCTest
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
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

    private func makeJWT(
        exp: TimeInterval,
        name: String = "Test User",
        email: String? = nil,
        azp: String? = nil,
        iss: String? = nil
    ) -> String {
        var payload: [String: Any] = ["sub": "u1", "name": name, "exp": Int(exp)]
        if let email { payload["email"] = email }
        if let azp { payload["azp"] = azp }
        if let iss { payload["iss"] = iss }
        return makeRawJWT(payload)
    }

    private func makeRawJWT(_ payload: [String: Any]) -> String {
        func b64(_ obj: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "HS256", "typ": "JWT"])).\(b64(payload)).sig"
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

        // Token expiring in +30s (inside 60s proactive refresh window) falls back to the unexpired token
        // and keeps needsReauthentication == false when silent refresh fails and no password is saved.
        store.upsertAccount(
            SiteAccountRecord(
                originKey: origin.absoluteString,
                engine: .trueconf,
                authMethod: .token,
                username: "ada",
                tokenEndpoint: "https://tc.example.test/oauth2/v1/token",
                tokenExpiresAt: Date().addingTimeInterval(30)
            ),
            secret: SiteSecretPayload(accessToken: reloginJWT, refreshToken: "ref-3")
        )
        MockURLProtocol.reset { _ in .init(status: 404, body: Data()) }
        let unexpiredFallback = await coordinator.validCredentials(for: origin, engine: .trueconf)
        XCTAssertEqual(unexpiredFallback?.accessToken, reloginJWT)
        XCTAssertEqual(store.account(for: origin)?.needsReauthentication, false)
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

    func testSaluteJazzUserInfoVerificationAndKeycloakRefresh() async throws {
        let (store, prefs, suite) = makeIsolatedStore()
        defer { prefs.removePersistentDomain(forName: suite) }

        let origin = URL(string: "https://jazz.example.test")!
        let issuer = "https://jazz.example.test/realms/s2b"
        let expiredJWT = makeJWT(
            exp: Date().addingTimeInterval(-120).timeIntervalSince1970,
            name: "Ivan Petrov",
            email: "ivan@example.ru",
            azp: "s2b",
            iss: issuer
        )
        let refreshedJWT = makeJWT(
            exp: Date().addingTimeInterval(3600).timeIntervalSince1970,
            name: "Ivan Petrov",
            email: "ivan@example.ru",
            azp: "s2b",
            iss: issuer
        )
        let coordinator = SiteAuthCoordinator(store: store, makeSession: { _ in self.makeMockSession() })
        let trackingCookie = HTTPCookie(properties: [
            .domain: "jazz.example.test",
            .path: "/",
            .name: "session_hint",
            .value: "abc123"
        ])!

        // 1. 200 ANONYMOUS + TOKEN_MISSING on /user/info must NOT be treated as signed in.
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://bk.jazz.example.test\"}}".utf8))
            case "/user/info":
                return .init(body: Data("{\"authType\":\"ANONYMOUS\",\"authErr\":\"TOKEN_MISSING\"}".utf8))
            case "/v1/user/info":
                return .init(status: 403, mime: "text/html", body: Data("<html>403 Forbidden</html>".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        do {
            _ = try await coordinator.completeWebSignIn(
                origin: origin,
                engine: .guest,
                capturedAccessToken: nil,
                cookies: [trackingCookie],
                requireVerifiedProof: false
            )
            XCTFail("Expected verificationFailed when /user/info returns ANONYMOUS")
        } catch let error as SiteAuthError {
            if case .verificationFailed = error {} else {
                XCTFail("Expected verificationFailed, got \(error)")
            }
        }

        // 2. 200 ANONYMOUS + TOKEN_INVALID must throw invalidCredentials.
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://bk.jazz.example.test\"}}".utf8))
            case "/user/info":
                return .init(body: Data("{\"authType\":\"ANONYMOUS\",\"authErr\":\"TOKEN_INVALID\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        do {
            _ = try await coordinator.completeWebSignIn(
                origin: origin,
                engine: .guest,
                capturedAccessToken: expiredJWT,
                cookies: [trackingCookie]
            )
            XCTFail("Expected invalidCredentials for TOKEN_INVALID")
        } catch let error as SiteAuthError {
            if case .invalidCredentials = error {} else {
                XCTFail("Expected invalidCredentials, got \(error)")
            }
        }

        // 3. Valid /user/info (S2B) succeeds even though /user/current=404 and /v1/user/info=403 nginx HTML.
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://bk.jazz.example.test\"}}".utf8))
            case "/v1/user/info":
                return .init(status: 403, mime: "text/html", body: Data("<html>403 Forbidden</html>".utf8))
            case "/user/info":
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Jazz-Token"), expiredJWT)
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(expiredJWT)")
                return .init(body: Data("{\"authType\":\"S2B\",\"authErr\":\"OK\",\"name\":\"Ivan Petrov\",\"email\":\"ivan@example.ru\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        let saved = try await coordinator.completeWebSignIn(
            origin: origin,
            engine: .guest,
            capturedAccessToken: expiredJWT,
            capturedRefreshToken: "kc-ref-1",
            cookies: []
        )
        XCTAssertEqual(saved.userDisplayName, "Ivan Petrov")
        XCTAssertEqual(saved.username, "ivan@example.ru")
        XCTAssertEqual(saved.tokenEndpoint, "\(issuer)/protocol/openid-connect/token")
        XCTAssertEqual(store.readSecret(for: origin.absoluteString)?.oauthClientID, "s2b")

        // 4. Keycloak refresh uses application/x-www-form-urlencoded with client_id=s2b.
        MockURLProtocol.reset { req in
            if req.url?.absoluteString == "\(issuer)/protocol/openid-connect/token" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                let bodyText = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                XCTAssertTrue(bodyText.contains("grant_type=refresh_token"))
                XCTAssertTrue(bodyText.contains("refresh_token=kc-ref-1"))
                XCTAssertTrue(bodyText.contains("client_id=s2b"))
                let json = try! JSONSerialization.data(withJSONObject: [
                    "access_token": refreshedJWT,
                    "refresh_token": "kc-ref-2",
                    "expires_in": 3600
                ])
                return .init(body: json)
            }
            return .init(status: 404, body: Data())
        }
        let creds = await coordinator.validCredentials(for: origin, engine: .guest)
        XCTAssertEqual(creds?.accessToken, refreshedJWT)
        XCTAssertEqual(store.readSecret(for: origin.absoluteString)?.refreshToken, "kc-ref-2")

        // 5. License JWTs must be ignored/rejected rather than treated as authenticated tokens.
        let licenseJWT = makeRawJWT([
            "jazz_premium_user": true,
            "graceExp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        ])
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://bk.jazz.example.test\"}}".utf8))
            case "/user/info":
                return .init(body: Data("{\"authType\":\"ANONYMOUS\",\"authErr\":\"TOKEN_MISSING\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        do {
            _ = try await coordinator.completeWebSignIn(
                origin: origin,
                engine: .guest,
                capturedAccessToken: licenseJWT,
                cookies: []
            )
            XCTFail("Expected verificationFailed when only a license JWT is supplied")
        } catch let error as SiteAuthError {
            if case .verificationFailed = error {} else {
                XCTFail("Expected verificationFailed, got \(error)")
            }
        }
        do {
            _ = try await coordinator.signInWithToken(
                origin: origin,
                engine: .guest,
                token: licenseJWT
            )
            XCTFail("Expected invalidCredentials when signing in with a license JWT")
        } catch let error as SiteAuthError {
            if case .invalidCredentials = error {} else {
                XCTFail("Expected invalidCredentials, got \(error)")
            }
        }

        // 6. Keycloak JWT accepted via GET /auth/login/b2b -> Jazz backend JWT (for both completeWebSignIn & refresh).
        let (b2bStore, b2bPrefs, b2bSuite) = makeIsolatedStore()
        defer { b2bPrefs.removePersistentDomain(forName: b2bSuite) }
        let b2bCoordinator = SiteAuthCoordinator(store: b2bStore, makeSession: { _ in self.makeMockSession() })
        let expiredJazzB2B = makeRawJWT(["sub": "b2b-user", "exp": Int(Date().addingTimeInterval(-60).timeIntervalSince1970)])
        let refreshedJazzB2B = makeRawJWT(["sub": "b2b-user", "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)])

        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://bk.jazz.example.test\"}}".utf8))
            case "/user/info":
                let jazzHeader = req.value(forHTTPHeaderField: "X-Jazz-Token")
                if jazzHeader == expiredJWT {
                    return .init(body: Data("{\"authType\":\"ANONYMOUS\",\"authErr\":\"TOKEN_INVALID\"}".utf8))
                }
                if jazzHeader == expiredJazzB2B {
                    return .init(body: Data("{\"authType\":\"S2B\",\"authErr\":\"OK\",\"name\":\"Ivan Petrov\",\"email\":\"ivan@example.ru\"}".utf8))
                }
                return .init(body: Data("{\"authType\":\"ANONYMOUS\",\"authErr\":\"TOKEN_MISSING\"}".utf8))
            case "/auth/login/b2b":
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(expiredJWT)")
                return .init(body: Data("{\"token\":\"\(expiredJazzB2B)\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        let savedB2B = try await b2bCoordinator.completeWebSignIn(
            origin: origin,
            engine: .guest,
            capturedAccessToken: expiredJWT,
            capturedRefreshToken: "kc-ref-b2b-1",
            tokenEndpoint: "https://bk.jazz.example.test/auth/login/b2b",
            cookies: []
        )
        XCTAssertEqual(savedB2B.userDisplayName, "Ivan Petrov")
        XCTAssertEqual(savedB2B.username, "ivan@example.ru")
        XCTAssertEqual(savedB2B.tokenEndpoint, "\(issuer)/protocol/openid-connect/token")
        XCTAssertEqual(b2bStore.readSecret(for: origin.absoluteString)?.accessToken, expiredJazzB2B)
        XCTAssertEqual(b2bStore.readSecret(for: origin.absoluteString)?.oauthClientID, "s2b")

        // Expired Jazz B2B token refreshes via Keycloak OIDC and re-exchanges via /auth/login/b2b.
        MockURLProtocol.reset { req in
            if req.url?.absoluteString == "\(issuer)/protocol/openid-connect/token" {
                let json = try! JSONSerialization.data(withJSONObject: [
                    "access_token": refreshedJWT,
                    "refresh_token": "kc-ref-b2b-2",
                    "expires_in": 300
                ])
                return .init(body: json)
            }
            if req.url?.path == "/auth/login/b2b" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(refreshedJWT)")
                return .init(body: Data("{\"token\":\"\(refreshedJazzB2B)\"}".utf8))
            }
            return .init(status: 404, body: Data())
        }
        let renewedB2B = await b2bCoordinator.validCredentials(for: origin, engine: .guest)
        XCTAssertEqual(renewedB2B?.accessToken, refreshedJazzB2B)
        XCTAssertEqual(b2bStore.readSecret(for: origin.absoluteString)?.refreshToken, "kc-ref-b2b-2")

        // signInWithToken also exchanges a raw Keycloak token via /auth/login/b2b when /user/info rejects it.
        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://bk.jazz.example.test\"}}".utf8))
            case "/user/info":
                let jazzHeader = req.value(forHTTPHeaderField: "X-Jazz-Token")
                if jazzHeader == refreshedJazzB2B {
                    return .init(body: Data("{\"authType\":\"S2B\",\"authErr\":\"OK\",\"name\":\"Ivan Petrov\",\"email\":\"ivan@example.ru\"}".utf8))
                }
                return .init(body: Data("{\"authType\":\"ANONYMOUS\",\"authErr\":\"TOKEN_INVALID\"}".utf8))
            case "/auth/login/b2b":
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(refreshedJWT)")
                return .init(body: Data("{\"token\":\"\(refreshedJazzB2B)\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        let tokenAccount = try await b2bCoordinator.signInWithToken(origin: origin, engine: .guest, token: refreshedJWT)
        XCTAssertEqual(tokenAccount.username, "ivan@example.ru")
        XCTAssertEqual(b2bStore.readSecret(for: origin.absoluteString)?.accessToken, refreshedJazzB2B)
    }

    #if canImport(JavaScriptCore) && (os(iOS) || os(macOS))
    func testSiteAuthWebScriptCapturesKeycloakXHRAndIgnoresProxyClientKey() throws {
        let context = try XCTUnwrap(JSContext())
        var jsException: String?
        context.exceptionHandler = { _, exc in
            jsException = exc?.toString()
        }

        let jwt1 = makeJWT(exp: Date().addingTimeInterval(3600).timeIntervalSince1970, name: "Jazz User", azp: "s2b")
        let jwt2 = makeJWT(exp: Date().addingTimeInterval(7200).timeIntervalSince1970, name: "Jazz User 2", azp: "s2b")
        let jwt3 = makeJWT(exp: Date().addingTimeInterval(9000).timeIntervalSince1970, name: "Jazz User 3", azp: "s2b")
        let jazzJwt = makeRawJWT(["sub": "jazz-backend-1", "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)])
        let licenseJwt = makeRawJWT(["jazz_premium_user": true, "graceExp": 1_900_000_000])

        let harness = """
        var window = this;
        window.location = { href: 'https://jazz.example.test/?state=1&code=abc', hostname: 'jazz.example.test', hash: '' };
        window.__messages = [];
        window.webkit = { messageHandlers: { siteAuthBridge: { postMessage: function(m) { window.__messages.push(m); } } } };
        window.addEventListener = function() {};
        window.__lsData = {};
        window.localStorage = {
            get length() { return Object.keys(window.__lsData).length; },
            key: function(i) { return Object.keys(window.__lsData)[i] || null; },
            getItem: function(k) { return Object.prototype.hasOwnProperty.call(window.__lsData, k) ? window.__lsData[k] : null; }
        };
        window.sessionStorage = { length: 0, key: function() { return null; }, getItem: function() { return null; } };
        function URL(u) { this.href = u; }
        function XMLHttpRequest() { this._headers = {}; this._listeners = []; }
        XMLHttpRequest.prototype.open = function(m, u) {};
        XMLHttpRequest.prototype.setRequestHeader = function(n, v) { this._headers[n] = v; };
        XMLHttpRequest.prototype.addEventListener = function(ev, fn) { if (ev === 'load') this._listeners.push(fn); };
        XMLHttpRequest.prototype.send = function(body) { this._sentBody = body; };
        function BroadcastChannel(name) { this.name = name; }
        BroadcastChannel.prototype.postMessage = function(msg) {};
        window.__fetchRoutes = {};
        window.fetch = function(input, init) {
            var u = (typeof input === 'string') ? input : (input && input.url) || '';
            var route = window.__fetchRoutes[u];
            if (!route) {
                return { then: function() { return this; }, catch: function() { return this; } };
            }
            var resp = {
                ok: true,
                url: u,
                headers: { get: function(h) { return String(h).toLowerCase() === 'content-type' ? 'application/json' : ''; } },
                clone: function() {
                    return {
                        json: function() {
                            return { then: function(cb) { cb(route); return { catch: function() {} }; } };
                        }
                    };
                }
            };
            return { then: function(cb) { cb(resp); return { catch: function() {} }; } };
        };
        """
        context.evaluateScript(harness)
        XCTAssertNil(jsException)

        context.evaluateScript(SiteAuthWebScript.captureSource)
        XCTAssertNil(jsException)

        // 1. Unleash / bare non-JWT Authorization header "proxy-client-key" must be ignored.
        context.evaluateScript("""
        window.fetch('https://jazz.example.test/api/unleash/client/features', { headers: { Authorization: 'proxy-client-key' } });
        window.fetch('https://jazz.example.test/api/other', { headers: { Authorization: 'proxy-client-key' } });
        """)
        XCTAssertNil(jsException)
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 0)

        // 2. Keycloak XHR /protocol/openid-connect/token exchange captures access_token, refresh_token, endpoint, clientId.
        context.evaluateScript("""
        var x = new XMLHttpRequest();
        x.open('POST', 'https://jazz.example.test/realms/s2b/protocol/openid-connect/token', true);
        x.setRequestHeader('Content-type', 'application/x-www-form-urlencoded');
        x.send('code=abc&grant_type=authorization_code&client_id=s2b');
        x.status = 200;
        x.responseType = '';
        x.responseText = JSON.stringify({ access_token: '\(jwt1)', refresh_token: 'ref-xhr-1', expires_in: 300 });
        for (var i = 0; i < x._listeners.length; i++) { x._listeners[i](); }
        """)
        XCTAssertNil(jsException)
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("window.__messages[0].token")?.toString(), jwt1)
        XCTAssertEqual(context.evaluateScript("window.__messages[0].refreshToken")?.toString(), "ref-xhr-1")
        XCTAssertEqual(context.evaluateScript("window.__messages[0].tokenEndpoint")?.toString(), "https://jazz.example.test/realms/s2b/protocol/openid-connect/token")
        XCTAssertEqual(context.evaluateScript("window.__messages[0].clientId")?.toString(), "s2b")

        // 3. Bare non-JWT X-Jazz-Token cannot downgrade an already captured JWT, while BroadcastChannel JWT updates it.
        context.evaluateScript("""
        var x2 = new XMLHttpRequest();
        x2.open('GET', 'https://bk.jazz.example.test/user/info', true);
        x2.setRequestHeader('X-Jazz-Token', 'opaque-not-a-jwt-token');
        new BroadcastChannel('s2b-keycloak').postMessage({ token: '\(jwt2)', refreshToken: 'ref-bc-2' });
        """)
        XCTAssertNil(jsException)
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().token")?.toString(), jwt2)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().refreshToken")?.toString(), "ref-bc-2")

        // 4. License fetch endpoints and localStorage["s2b.license.token"] must be ignored.
        context.evaluateScript("""
        window.__fetchRoutes['https://jazz.example.test/api/plat/plat-license-manager/licenses/me/proj-1/token'] = { token: '\(licenseJwt)' };
        window.fetch('https://jazz.example.test/api/plat/plat-license-manager/licenses/me/proj-1/token');
        window.__lsData['s2b.license.token'] = '\(licenseJwt)';
        """)
        XCTAssertNil(jsException)
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().token")?.toString(), jwt2)

        // 5. /auth/login/b2b response upgrades captured token to Jazz backend JWT and preserves Keycloak metadata.
        context.evaluateScript("""
        window.__fetchRoutes['https://bk.jazz.example.test/auth/login/b2b'] = { token: '\(jazzJwt)' };
        window.fetch('https://bk.jazz.example.test/auth/login/b2b', { headers: { Authorization: 'Bearer \(jwt2)' } });
        """)
        XCTAssertNil(jsException)
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 3)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().token")?.toString(), jazzJwt)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().refreshToken")?.toString(), "ref-bc-2")
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().tokenEndpoint")?.toString(), "https://jazz.example.test/realms/s2b/protocol/openid-connect/token")
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().clientId")?.toString(), "s2b")

        // 6. BroadcastChannel & storage Keycloak JWTs must NOT overwrite the Jazz backend token, while still merging new refreshToken.
        context.evaluateScript("""
        new BroadcastChannel('s2b-keycloak').postMessage({ token: '\(jwt3)', refreshToken: 'ref-bc-3' });
        window.__lsData['oidc.user:https://jazz.example.test/realms/s2b:s2b'] = JSON.stringify({ access_token: '\(jwt3)' });
        """)
        XCTAssertNil(jsException)
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 4)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().token")?.toString(), jazzJwt)
        XCTAssertEqual(context.evaluateScript("window.__rockSiteAuthSnapshot().refreshToken")?.toString(), "ref-bc-3")
        XCTAssertEqual(context.evaluateScript("window.__messages.length")?.toInt32(), 4)
    }
    #endif

    func testInstantRoomPreferencesOriginResolutionPersistenceAndDefaultTitle() {
        let suiteName = "InstantRoomPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(InstantRoomPreferences.loadLastOrigin(defaults: defaults))

        let corpOrigin = URL(string: "https://MEET.CORP.RU/some/path?x=1")!
        InstantRoomPreferences.saveLastOrigin(corpOrigin, defaults: defaults)
        let saved = InstantRoomPreferences.loadLastOrigin(defaults: defaults)
        XCTAssertEqual(saved, URL(string: "https://meet.corp.ru")!)

        // Community host rock.glowsoft.ru is never persisted as a room-creation origin.
        InstantRoomPreferences.saveLastOrigin(URL(string: "https://rock.glowsoft.ru/jams/test")!, defaults: defaults)
        XCTAssertEqual(InstantRoomPreferences.loadLastOrigin(defaults: defaults), URL(string: "https://meet.corp.ru")!)

        let activeAccount = SiteAccountRecord(
            originKey: "https://jazz.active.test",
            engine: .guest,
            authMethod: .webSSO,
            needsReauthentication: false
        )
        let expiredAccount = SiteAccountRecord(
            originKey: "https://jazz.expired.test",
            engine: .guest,
            authMethod: .webSSO,
            needsReauthentication: true
        )
        let communityAccount = SiteAccountRecord(
            originKey: "https://rock.glowsoft.ru",
            engine: .community,
            authMethod: .token,
            needsReauthentication: false
        )

        let origins = InstantRoomPreferences.availableOrigins(
            accounts: [expiredAccount, communityAccount, activeAccount],
            suggestedOrigins: [
                URL(string: "https://rock.glowsoft.ru")!,
                URL(string: "https://telemost.yandex.ru")!,
                URL(string: "https://jazz.active.test/ignored")!
            ],
            lastOrigin: saved
        )

        XCTAssertEqual(origins, [
            URL(string: "https://meet.corp.ru")!,
            URL(string: "https://jazz.active.test")!,
            URL(string: "https://jazz.expired.test")!,
            URL(string: "https://telemost.yandex.ru")!
        ])
        XCTAssertEqual(
            InstantRoomPreferences.preferredOrigin(
                accounts: [expiredAccount, activeAccount],
                suggestedOrigins: [URL(string: "https://telemost.yandex.ru")!],
                lastOrigin: nil
            ),
            URL(string: "https://jazz.active.test")!
        )

        XCTAssertEqual(InstantRoomPreferences.defaultRoomTitle(displayName: "   "), L("New meeting"))
        XCTAssertEqual(InstantRoomPreferences.defaultRoomTitle(displayName: "  Alex  "), L("%@’s meeting", "Alex"))
    }
}
