import ConferenceCore
import Foundation
import XCTest
@testable import MeetingEngine

@MainActor
final class RoomPoolAndFallbackTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
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

    nonisolated private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeIsolatedStores() throws -> (SiteAccountStore, RoomPoolStore, UserDefaults, String) {
        let suite = "RoomPoolTests.\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let secrets = InMemorySiteSecretStore()
        let registry = SiteClientIdentityRegistry(preferences: prefs, secretStore: secrets)
        let accountStore = SiteAccountStore(preferences: prefs, secretStore: secrets, registry: registry, loadSystemIdentities: false)
        let poolStore = RoomPoolStore(preferences: prefs, secretStore: secrets)
        return (accountStore, poolStore, prefs, suite)
    }

    func testAnonymousRejectionWithoutPoolThrowsSignInRequiredAndMarksOrigin() async throws {
        let (accountStore, poolStore, prefs, suite) = try makeIsolatedStores()
        defer { prefs.removePersistentDomain(forName: suite) }

        let origin = URL(string: "https://jazz.corp.test")!
        let auth = SiteAuthCoordinator(store: accountStore, makeSession: { _ in self.makeMockSession() })
        let creator = MeetingRoomCreator(auth: auth, poolStore: poolStore, makeSession: { _ in self.makeMockSession() })

        MockURLProtocol.reset { req in
            switch req.url?.path {
            case "/.well-known/jazz-services.json":
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.test\"}}".utf8))
            case "/room/create-meeting":
                return .init(status: 403, body: Data("{\"error\":\"anonymous_disabled\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }

        do {
            _ = try await creator.createRoom(on: origin, engine: .guest, options: .init(title: "Sync"))
            XCTFail("Expected signInRequired")
        } catch let error as RoomCreationError {
            XCTAssertEqual(error, .signInRequired(origin: origin, engine: .guest))
            XCTAssertTrue(RoomCreationError.allowsPoolFallback(error, engine: .guest))
            XCTAssertTrue(poolStore.isAnonymousCreationDisabled(for: origin))
        }
    }

    func testAnonymousRejectionFallsBackToPoolAndSkipsCreateOnNextCall() async throws {
        let (accountStore, poolStore, prefs, suite) = try makeIsolatedStores()
        defer { prefs.removePersistentDomain(forName: suite) }

        let poolLink = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636&auth=dhdbdhBvVv75b")
        poolStore.upsertPool(poolLink, status: RoomPoolStatus(poolID: "363636", label: "Team", availableCount: 3, usedCount: 0, origins: [:]))

        let origin = URL(string: "https://jazz.corp.test")!
        let auth = SiteAuthCoordinator(store: accountStore, makeSession: { _ in self.makeMockSession() })
        let creator = MeetingRoomCreator(auth: auth, poolStore: poolStore, makeSession: { _ in self.makeMockSession() })

        var claimCount = 0
        var createRoomRequests = 0
        MockURLProtocol.reset { req in
            switch (req.url?.host, req.url?.path) {
            case ("jazz.corp.test", "/.well-known/jazz-services.json"),
                 ("other.jazz.test", "/.well-known/jazz-services.json"):
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.test\"}}".utf8))
            case ("api.jazz.corp.test", "/room/create-meeting"):
                createRoomRequests += 1
                return .init(status: 403, body: Data("{\"error\":\"anonymous_disabled\"}".utf8))
            case ("rock.glowsoft.ru", "/api/pools/363636/claim"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer dhdbdhBvVv75b")
                claimCount += 1
                let roomURL = claimCount == 1
                    ? "https://other.jazz.test/calls/dead-room?psw=MQo"
                    : "https://other.jazz.test/calls/live-room?psw=MQo"
                let body = try! JSONSerialization.data(withJSONObject: [
                    "poolId": "363636",
                    "roomUrl": roomURL,
                    "origin": "https://other.jazz.test",
                    "remainingCount": 3 - claimCount
                ])
                return .init(body: body)
            case ("api.jazz.corp.test", "/room/dead-room/preconnect"):
                return .init(status: 404, body: Data())
            case ("api.jazz.corp.test", "/room/live-room/preconnect"):
                return .init(body: Data("{\"connectorUrl\":\"wss://rtc.jazz.corp.test/ws\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }

        // First call tries ANONYMOUS -> 403 -> claims dead-room -> 404 preconnect -> claims live-room -> 200
        let first = try await creator.createRoom(on: origin, engine: .guest, options: .init(title: "Standup"))
        XCTAssertEqual(createRoomRequests, 1)
        XCTAssertEqual(claimCount, 2)
        XCTAssertEqual(first.origin.absoluteString, "https://other.jazz.test")
        XCTAssertEqual(first.roomID, "live-room")
        XCTAssertEqual(first.title, "Standup")
        XCTAssertEqual(poolStore.activePool?.lastKnownAvailable, 1)

        // Second call sees anonymousDisabledOrigins cache -> skips ANONYMOUS /room/create-meeting!
        MockURLProtocol.reset { req in
            switch (req.url?.host, req.url?.path) {
            case ("other.jazz.test", "/.well-known/jazz-services.json"):
                return .init(body: Data("{\"jazz\":{\"serverUrl\":\"https://api.jazz.corp.test\"}}".utf8))
            case ("api.jazz.corp.test", "/room/create-meeting"):
                createRoomRequests += 1
                return .init(status: 403, body: Data())
            case ("rock.glowsoft.ru", "/api/pools/363636/claim"):
                let body = try! JSONSerialization.data(withJSONObject: [
                    "poolId": "363636",
                    "roomUrl": "https://other.jazz.test/calls/third-room?psw=MQo",
                    "origin": "https://other.jazz.test",
                    "remainingCount": 0
                ])
                return .init(body: body)
            case ("api.jazz.corp.test", "/room/third-room/preconnect"):
                return .init(body: Data("{\"connectorUrl\":\"wss://rtc.jazz.corp.test/ws\"}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }
        let second = try await creator.createRoom(on: origin, engine: .guest, options: .init(title: "Follow-up"))
        XCTAssertEqual(createRoomRequests, 1)
        XCTAssertEqual(second.roomID, "third-room")
        XCTAssertEqual(poolStore.activePool?.lastKnownAvailable, 0)
    }

    func testPoolExhaustedMapsToPoolExhaustedError() async throws {
        let (accountStore, poolStore, prefs, suite) = try makeIsolatedStores()
        defer { prefs.removePersistentDomain(forName: suite) }

        let poolLink = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636#auth=dhdbdhBvVv75b")
        poolStore.upsertPool(poolLink)
        let origin = URL(string: "https://jazz.corp.test")!
        poolStore.markAnonymousCreationDisabled(for: origin)

        let auth = SiteAuthCoordinator(store: accountStore, makeSession: { _ in self.makeMockSession() })
        let creator = MeetingRoomCreator(auth: auth, poolStore: poolStore, makeSession: { _ in self.makeMockSession() })

        MockURLProtocol.reset { _ in
            .init(status: 409, body: Data("{\"error\":\"pool_empty\",\"message\":\"No unused rooms left.\"}".utf8))
        }

        do {
            _ = try await creator.createRoom(on: origin, engine: .guest, options: .init(title: "Empty"))
            XCTFail("Expected poolExhausted")
        } catch let error as RoomCreationError {
            XCTAssertEqual(error, .poolExhausted(origin: origin, poolID: "363636"))
            XCTAssertTrue(RoomCreationError.allowsPoolFallback(error, engine: .guest))
        }
    }

    func testPoolClientSendsWriteTokenForManagementEndpoints() async throws {
        let client = RoomPoolClient(makeSession: { _ in self.makeMockSession() })
        let link = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636#auth=AuthSecret1234")

        MockURLProtocol.reset { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/pools"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Pool-Write-Token"), "write-pass-123")
                return .init(status: 201, body: Data("{\"poolId\":\"newpool\",\"auth\":\"AuthToken9999\"}".utf8))
            case ("POST", "/api/pools/363636/links"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AuthSecret1234")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Pool-Write-Token"), "write-pass-123")
                return .init(body: Data("{\"added\":1,\"skippedDuplicates\":0,\"invalid\":0,\"availableCount\":1}".utf8))
            case ("GET", "/api/pools/363636/links"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AuthSecret1234")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Pool-Write-Token"), "write-pass-123")
                return .init(body: Data("{\"links\":[{\"id\":7,\"url\":\"https://jazz.sber.ru/calls/1\",\"origin\":\"https://jazz.sber.ru\",\"addedAt\":1700000000}]}".utf8))
            case ("POST", "/api/pools/363636/links/remove"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AuthSecret1234")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Pool-Write-Token"), "write-pass-123")
                return .init(body: Data("{\"removed\":1,\"availableCount\":0}".utf8))
            default:
                return .init(status: 404, body: Data())
            }
        }

        let created = try await client.createPool(poolID: "newpool", label: "Test", writeToken: "write-pass-123")
        XCTAssertEqual(created.poolID, "newpool")

        let added = try await client.addLinks(link: link, urls: [URL(string: "https://jazz.sber.ru/calls/1")!], writeToken: "write-pass-123")
        XCTAssertEqual(added.added, 1)

        let listed = try await client.listLinks(link: link, writeToken: "write-pass-123")
        XCTAssertEqual(listed.map(\.id), [7])

        let removed = try await client.removeLinks(link: link, ids: [7], writeToken: "write-pass-123")
        XCTAssertEqual(removed.removed, 1)
    }

    func testPoolClientFallsBackToGetActionOn405AndCachesPreference() async throws {
        let client = RoomPoolClient(makeSession: { _ in self.makeMockSession() })
        let link = try RoomPoolLink.parse("https://rock.glowsoft.ru/pools/363636#auth=AuthSecret1234")
        var methodsSeen: [String] = []

        MockURLProtocol.reset { req in
            methodsSeen.append("\(req.httpMethod ?? ""):\(req.url?.path ?? "")")
            if req.httpMethod == "POST" {
                return .init(status: 405, mime: "text/html", body: Data("405".utf8))
            }
            if req.httpMethod == "GET", req.url?.path == "/api/pools/363636/claim" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Pool-Action"), "claim")
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AuthSecret1234")
                let payloadHeader = req.value(forHTTPHeaderField: "X-Pool-Payload") ?? ""
                XCTAssertFalse(payloadHeader.isEmpty)
                let body = try! JSONSerialization.data(withJSONObject: [
                    "poolId": "363636",
                    "roomUrl": "https://jazz.sber.ru/calls/cdn-room?psw=MQo",
                    "origin": "https://jazz.sber.ru",
                    "remainingCount": 4
                ])
                return .init(body: body)
            }
            return .init(status: 404, body: Data())
        }

        let first = try await client.claimRoom(link: link, requestID: "req-cdn-1")
        XCTAssertEqual(first.roomURL.absoluteString, "https://jazz.sber.ru/calls/cdn-room?psw=MQo")
        XCTAssertEqual(methodsSeen, ["POST:/api/pools/363636/claim", "GET:/api/pools/363636/claim"])

        methodsSeen.removeAll()
        let second = try await client.claimRoom(link: link, requestID: "req-cdn-2")
        XCTAssertEqual(second.remainingCount, 4)
        // Cached preference skips POST on subsequent calls
        XCTAssertEqual(methodsSeen, ["GET:/api/pools/363636/claim"])
    }
}
