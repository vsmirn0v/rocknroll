import ConferenceCore
import LiveKit
import XCTest
@testable import MeetingEngine

@MainActor
final class UniversalMeetingEngineTests: XCTestCase {
    func testConfigurationParsesProviderFilter() {
        let all = UniversalMeetingEngine.Configuration.current(environment: [:])
        XCTAssertEqual(all.enabledProviders, [.guest, .community, .telemost, .trueconf])

        let subset = UniversalMeetingEngine.Configuration.current(environment: [
            "ROCK_UNIVERSAL_PROVIDERS": "guest, trueconf",
        ])
        XCTAssertEqual(subset.enabledProviders, [.guest, .trueconf])
    }

    func testCreatesSessionsForAllFourProviders() throws {
        let engine = UniversalMeetingEngine(sharedAudio: nil)
        let urls = [
            "https://jazz.example.com/room-guest?psw=secret123",
            "https://rock.glowsoft.ru/jams/rock-room",
            "https://telemost.yandex.ru/j/1234567890",
            "https://trueconf.example.com/c/1234567890",
        ]
        let expectedKinds: [MeetingEngineKind] = [.guest, .community, .telemost, .trueconf]
        let kinds = [MeetingEngineKind.guest, .community, .telemost, .trueconf]

        var retained: [MeetingSession] = []
        for ((raw, kind), expected) in zip(zip(urls, kinds), expectedKinds) {
            let destination = try JoinDestination.verified(URL(string: raw)!, engine: kind)
            let session = engine.makeSession(destination: destination)
            XCTAssertEqual(session.kind, expected)
            retained.append(session)
        }
        XCTAssertEqual(engine.activeSessionCount, 4)

        retained.removeAll()
        XCTAssertEqual(engine.activeSessionCount, 0)
    }

    func testLobbySnapshotDefaultsAndPhase() {
        let lobby = GuestLobbyState(inLobby: true, title: "Weekly Sync", moderatorPresent: true)
        XCTAssertTrue(lobby.inLobby)
        XCTAssertEqual(lobby.title, "Weekly Sync")
        XCTAssertEqual(lobby.moderatorPresent, true)

        let snapshot = GuestSessionSnapshot(
            state: .lobby,
            desiredIntent: nil,
            appliedIntent: nil,
            permissions: .init(canShareMicrophone: true, canShareCamera: true),
            recoveryAttempts: 0,
            failure: nil,
            microphoneActivated: false,
            desiredPlayoutEnabled: nil,
            appliedPlayoutEnabled: nil,
            lobbyTitle: lobby.title,
            lobbyModeratorPresent: lobby.moderatorPresent
        )
        XCTAssertEqual(snapshot.state, .lobby)
        XCTAssertEqual(snapshot.lobbyTitle, "Weekly Sync")
        XCTAssertEqual(snapshot.lobbyModeratorPresent, true)

        var external = NativeDesktopExternalSnapshot(phase: .lobby, lobbyModeratorPresent: false)
        XCTAssertEqual(external.phase, .lobby)
        XCTAssertEqual(external.lobbyModeratorPresent, false)
        external.phase = .connected
        XCTAssertEqual(external.phase, .connected)
    }

    func testRockReconnectSubscriptionLifecycle() async throws {
        XCTAssertTrue(RockAdapter.appliesSubscriptions(when: .connected))
        XCTAssertFalse(RockAdapter.appliesSubscriptions(when: .connecting))
        XCTAssertFalse(RockAdapter.appliesSubscriptions(when: .reconnecting))
        XCTAssertFalse(RockAdapter.appliesSubscriptions(when: .disconnecting))
        XCTAssertFalse(RockAdapter.appliesSubscriptions(when: .disconnected))

        let lock = NSLock()
        var capturedEvents: [[String: Any]] = []
        setProbeLogSink { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.lock()
            capturedEvents.append(object)
            lock.unlock()
        }
        let adapter = RockAdapter(sharedAudio: nil)
        let room = Room()
        adapter.installRoomForTesting(room)
        defer {
            setProbeLogSink(nil)
            adapter.installRoomForTesting(nil)
        }
        func events(named name: String) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return capturedEvents.filter { ($0["event"] as? String) == name }
        }

        let dummyKey = ObjectIdentifier(room)
        let dummyDemand = NativeRockTrackDemand(subscribed: true, ready: false, primary: false)
        let sampleError = NSError(domain: "RockReconnectTest", code: 1)
        adapter.primeSubscriptionStateForTesting(failure: sampleError, cachedDemandKey: dummyKey, demand: dummyDemand)

        adapter.handleConnectionStateChange(.reconnecting, from: .connected, in: room)
        XCTAssertEqual(adapter.snapshot.phase, .reconnecting)
        XCTAssertFalse(adapter.chat.canSend)
        XCTAssertNotNil(adapter.reconnectStartedAt)
        XCTAssertFalse(adapter.hasCachedDemandsForTesting)
        XCTAssertNil(adapter.subscriptionFailureForTesting)
        XCTAssertEqual(events(named: "rock-reconnect-start").count, 1)

        try await adapter.setVideoDemand(.init(visibleParticipantIDs: ["person-1"], focusedParticipantID: "person-1", receivesCameras: false))
        XCTAssertFalse(adapter.hasCachedDemandsForTesting)
        XCTAssertNil(adapter.subscriptionFailureForTesting)

        adapter.primeSubscriptionStateForTesting(failure: sampleError, cachedDemandKey: dummyKey, demand: dummyDemand)
        adapter.handleConnectionStateChange(.connecting, from: .reconnecting, in: room)
        XCTAssertEqual(adapter.snapshot.phase, .connecting)
        XCTAssertNotNil(adapter.reconnectStartedAt)

        adapter.handleConnectionStateChange(.connected, from: .connecting, in: room)
        XCTAssertNil(adapter.reconnectStartedAt)
        XCTAssertEqual(adapter.snapshot.phase, .connected)
        XCTAssertTrue(adapter.chat.canSend)
        XCTAssertFalse(adapter.hasCachedDemandsForTesting)
        XCTAssertNil(adapter.subscriptionFailureForTesting)
        let completed = events(named: "rock-reconnect-complete")
        XCTAssertEqual(completed.count, 1)
        XCTAssertNotNil(completed.last?["elapsedMs"] as? Int)

        adapter.handleConnectionStateChange(.reconnecting, from: .connected, in: room)
        adapter.handleConnectionStateChange(.disconnected, from: .reconnecting, in: room)
        XCTAssertNil(adapter.reconnectStartedAt)
        XCTAssertEqual(adapter.snapshot.phase, .failed)
        let failed = events(named: "rock-reconnect-failed")
        XCTAssertEqual(failed.count, 1)
        XCTAssertNotNil(failed.last?["elapsedMs"] as? Int)

        adapter.handleConnectionStateChange(.reconnecting, from: .connected, in: room)
        XCTAssertNotNil(adapter.reconnectStartedAt)
        let failedBeforeLeave = events(named: "rock-reconnect-failed").count
        let completeBeforeLeave = events(named: "rock-reconnect-complete").count
        _ = await adapter.leave()
        XCTAssertNil(adapter.reconnectStartedAt)
        XCTAssertFalse(adapter.hasCachedDemandsForTesting)
        XCTAssertNil(adapter.subscriptionFailureForTesting)
        XCTAssertEqual(events(named: "rock-reconnect-failed").count, failedBeforeLeave)
        XCTAssertEqual(events(named: "rock-reconnect-complete").count, completeBeforeLeave)
    }
}
