import Foundation
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine

@MainActor
final class GuestPermissionsAndSignalingTests: XCTestCase {
    func testOwnerWithExplicitCanViewTranscriptionFalseCannotViewTranscript() {
        var features = GuestMeetingFeatures()
        features.receive([
            "event": "joined",
            "payload": [
                "roomId": "room-1",
                "participant": [
                    "participantId": "owner-1",
                    "name": "Vitalii",
                    "role": "OWNER",
                    "permissions": [
                        "canViewParticipants": true,
                        "canViewChat": true,
                        "canSendChatMessage": true,
                        "canSendReaction": true,
                        "canViewTranscription": false,
                        "canStartTranscription": false,
                        "canShareMicrophone": true
                    ]
                ],
                "participantGroup": [
                    "groupId": "group-1",
                    "name": "Creator Room",
                    "participants": []
                ]
            ]
        ])

        XCTAssertFalse(features.snapshot.permissions.canViewTranscript)
        XCTAssertFalse(features.snapshot.permissions.canManageTranscript)
        XCTAssertTrue(features.snapshot.permissions.canViewChat)

        // When the server omits canViewTranscription for an OWNER (unrestricted room), fallback grants it.
        var openRoomFeatures = GuestMeetingFeatures()
        openRoomFeatures.receive([
            "event": "joined",
            "payload": [
                "roomId": "room-2",
                "participant": [
                    "participantId": "owner-2",
                    "name": "Vitalii",
                    "role": "OWNER",
                    "permissions": [
                        "canViewParticipants": true,
                        "canViewChat": true
                    ]
                ],
                "participantGroup": [
                    "groupId": "group-2",
                    "name": "Open Room",
                    "participants": []
                ]
            ]
        ])
        XCTAssertTrue(openRoomFeatures.snapshot.permissions.canViewTranscript)
        XCTAssertTrue(openRoomFeatures.snapshot.permissions.canManageTranscript)
    }

    func testTransportPermissionDeniedServerErrorClassification() {
        XCTAssertTrue(GuestTransportError.server(code: "FORBIDDEN").isPermissionDeniedServerError)
        XCTAssertTrue(GuestTransportError.server(code: "permission_denied").isPermissionDeniedServerError)
        XCTAssertTrue(GuestTransportError.server(code: "TRANSCRIPTION_DISABLED").isPermissionDeniedServerError)
        XCTAssertFalse(GuestTransportError.server(code: "FIXTURE").isPermissionDeniedServerError)
        XCTAssertFalse(GuestTransportError.server(code: "INTERNAL_ERROR").isPermissionDeniedServerError)
        XCTAssertFalse(GuestTransportError.timedOut.isPermissionDeniedServerError)
    }

    func testAdapterSuppressesFeatureErrorOnForbiddenTranscriptHistoryWhileSurfacingRealErrors() async throws {
        // 1. FORBIDDEN on transcript history revokes canViewTranscript without firing onFeatureError.
        let adapter1 = GuestAdapter(microphoneAuthorized: { false })
        var reported1: [Error] = []
        adapter1.onFeatureError = { reported1.append($0) }

        let engine1 = NativeGuestEngine(label: "test-forbidden", verifyReceivedPixels: false)
        _ = try await engine1.prepareJoinForTesting()
        var forbiddenRequested = false
        engine1.featureRequestForTesting = { event, _, _ in
            if event == "get-transcription-messages" {
                forbiddenRequested = true
                throw GuestTransportError.server(code: "FORBIDDEN")
            }
            return ["payload": ["messages": [], "hasMore": false]]
        }
        adapter1.bindHistoryForTesting(engine1)
        try await engine1.processEventForTesting([
            "event": "joined",
            "payload": [
                "roomId": "room-forbidden",
                "participant": [
                    "participantId": "p-1",
                    "name": "Guest",
                    "role": "PARTICIPANT",
                    "permissions": [
                        "canViewParticipants": true,
                        "canViewChat": false,
                        "canViewTranscription": true
                    ]
                ],
                "participantGroup": [
                    "groupId": "group-forbidden",
                    "name": "Room",
                    "participants": []
                ]
            ]
        ])
        for _ in 0..<50 {
            await Task.yield()
            if forbiddenRequested && adapter1.transcriptHistoryIdleForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(forbiddenRequested)
        XCTAssertTrue(reported1.isEmpty, "FORBIDDEN transcript history should revoke capability silently without error banner")
        XCTAssertFalse(engine1.meetingSnapshot.permissions.canViewTranscript)
        adapter1.unbindHistoryForTesting()
        _ = await engine1.leave(sendLeave: false)

        // 2. Genuine server errors (e.g. FIXTURE) must still surface via onFeatureError.
        let adapter2 = GuestAdapter(microphoneAuthorized: { false })
        var reported2: [Error] = []
        adapter2.onFeatureError = { reported2.append($0) }

        let engine2 = NativeGuestEngine(label: "test-fixture-error", verifyReceivedPixels: false)
        _ = try await engine2.prepareJoinForTesting()
        var fixtureRequested = false
        engine2.featureRequestForTesting = { event, _, _ in
            if event == "get-transcription-messages" {
                fixtureRequested = true
                throw GuestTransportError.server(code: "FIXTURE")
            }
            return ["payload": ["messages": [], "hasMore": false]]
        }
        adapter2.bindHistoryForTesting(engine2)
        try await engine2.processEventForTesting([
            "event": "joined",
            "payload": [
                "roomId": "room-err",
                "participant": [
                    "participantId": "p-2",
                    "name": "Guest",
                    "role": "PARTICIPANT",
                    "permissions": [
                        "canViewParticipants": true,
                        "canViewChat": false,
                        "canViewTranscription": true
                    ]
                ],
                "participantGroup": [
                    "groupId": "group-err",
                    "name": "Room",
                    "participants": []
                ]
            ]
        ])
        for _ in 0..<50 {
            await Task.yield()
            if fixtureRequested && adapter2.transcriptHistoryIdleForTesting && !reported2.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(fixtureRequested)
        XCTAssertEqual(reported2.count, 1)
        adapter2.unbindHistoryForTesting()
        _ = await engine2.leave(sendLeave: false)
    }

    func testTransportSocketFailureLogsAllowlistedDiagnosticsAndGracefulCloseDoesNot() async throws {
        var events: [[String: Any]] = []
        setProbeLogSink { line in
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                events.append(obj)
            }
        }
        defer { setProbeLogSink(nil) }

        let url = URL(string: "wss://secret.example.test/ws?token=supersecret")!

        // 1. Unexpected WebSocket close logs allowlisted diagnostics without URLs or raw reason text.
        let unexpected = GuestTransport(url: url, roomID: "room-1")
        await unexpected.openWithoutSocketForTesting()
        await unexpected.simulateUnexpectedSocketEndForTesting(closeCode: 1006, reasonBytes: 24, error: nil)
        let failureEvents = events.filter { $0["event"] as? String == "guest-transport-failure" }
        XCTAssertEqual(failureEvents.count, 1)
        let first = try XCTUnwrap(failureEvents.first)
        XCTAssertEqual(first["source"] as? String, "ws-close")
        XCTAssertEqual(first["kind"] as? String, "networkFailure")
        XCTAssertEqual(first["closeCode"] as? Int, 1006)
        XCTAssertEqual(first["reasonBytes"] as? Int, 24)
        let serialized = try String(data: JSONSerialization.data(withJSONObject: first), encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("secret.example.test"))
        XCTAssertFalse(serialized.contains("supersecret"))

        // 2. Task error with underlying error logs sanitized domain/code.
        events.removeAll()
        let taskFailed = GuestTransport(url: url, roomID: "room-2")
        await taskFailed.openWithoutSocketForTesting()
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let outer = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSUnderlyingErrorKey: inner,
            NSURLErrorFailingURLStringErrorKey: "https://secret.example.test/leak"
        ])
        await taskFailed.simulateUnexpectedSocketEndForTesting(closeCode: nil, reasonBytes: nil, error: outer)
        let taskEvents = events.filter { $0["event"] as? String == "guest-transport-failure" }
        XCTAssertEqual(taskEvents.count, 1)
        let second = try XCTUnwrap(taskEvents.first)
        XCTAssertEqual(second["source"] as? String, "task-complete")
        XCTAssertEqual(second["errorDomain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(second["errorCode"] as? Int, NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(second["underlyingDomain"] as? String, NSPOSIXErrorDomain)
        XCTAssertEqual(second["underlyingCode"] as? Int, Int(ECONNRESET))
        let taskSerialized = try String(data: JSONSerialization.data(withJSONObject: second), encoding: .utf8) ?? ""
        XCTAssertFalse(taskSerialized.contains("secret.example.test"))

        // 3. Graceful close emits no failure event.
        events.removeAll()
        let graceful = GuestTransport(url: url, roomID: "room-3")
        await graceful.openWithoutSocketForTesting()
        let closing = Task { await graceful.close(graceTimeout: 1) }
        while await !graceful.isClosingForTesting { await Task.yield() }
        await graceful.finishCloseForTesting()
        await closing.value
        XCTAssertTrue(events.filter { $0["event"] as? String == "guest-transport-failure" }.isEmpty)
    }

    func testGuestAdapterPreservesParticipantsAcrossRecoveringAndClearsOnTerminalState() async throws {
        let invitation = try GuestInvitation.parse(URL(string: "https://guest.example.test/call/daily-room")!)
        let adapter = GuestAdapter(microphoneAuthorized: { false })
        var attemptCount = 0
        var engines: [NativeGuestEngine] = []
        var releaseSecondAttempt: CheckedContinuation<Void, Never>?

        let session = GuestSession(makeEngine: {
            attemptCount += 1
            let engine = NativeGuestEngine(label: "Guest", verifyReceivedPixels: false)
            if attemptCount == 1 {
                engine.joinForTesting = { _, _ in }
            } else {
                engine.joinForTesting = { _, _ in
                    await withCheckedContinuation { releaseSecondAttempt = $0 }
                    throw GuestTransportError.networkFailure
                }
            }
            engines.append(engine)
            return engine
        })
        adapter.attachSessionForTesting(session)

        try await session.connect(invitation, publish: false, codec: "h264", camera: false,
                                  initialAudioMuted: true, initialVideoMuted: true)
        XCTAssertEqual(session.state, .connected)
        let firstEngine = try XCTUnwrap(engines.first)
        try await firstEngine.processEventForTesting([
            "event": "joined",
            "payload": [
                "roomId": "room-daily",
                "participant": [
                    "participantId": "local-1",
                    "name": "Vitalii",
                    "role": "PARTICIPANT",
                    "permissions": ["canViewParticipants": true, "canViewChat": false, "canViewTranscription": false]
                ],
                "participantGroup": [
                    "groupId": "group-daily",
                    "name": "Daily Standup",
                    "participants": [
                        ["participantId": "local-1", "name": "Vitalii", "role": "PARTICIPANT"],
                        ["participantId": "remote-1", "name": "Alex", "role": "MODERATOR"]
                    ]
                ]
            ]
        ])
        XCTAssertEqual(adapter.snapshot.phase, .connected)
        XCTAssertEqual(adapter.snapshot.participants.count, 2)
        XCTAssertEqual(adapter.guestSnapshot.title, "Daily Standup")

        // Trigger a recoverable network failure; the old engine retires while recovery holds.
        firstEngine.simulateFailureForTesting(GuestTransportError.networkFailure)
        for _ in 0..<100 {
            if session.state == .recovering && attemptCount >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.state, .recovering)
        XCTAssertEqual(adapter.snapshot.phase, .reconnecting)
        XCTAssertEqual(adapter.snapshot.participants.count, 2, "Participants must remain visible during recovery")
        XCTAssertTrue(adapter.snapshot.participants.allSatisfy { $0.speaking != true && $0.sharing != true })
        XCTAssertEqual(adapter.guestSnapshot.title, "Daily Standup")
        XCTAssertFalse(adapter.guestSnapshot.connected)

        // Even if the replacement engine emits an unjoined empty snapshot before failing, preserve the roster.
        releaseSecondAttempt?.resume()
        releaseSecondAttempt = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(adapter.snapshot.phase, .reconnecting)
        XCTAssertEqual(adapter.snapshot.participants.count, 2)

        // Terminal leave clears the preserved roster cleanly.
        let left = await adapter.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(adapter.snapshot.phase, .left)
        XCTAssertTrue(adapter.snapshot.participants.isEmpty)
        XCTAssertEqual(adapter.guestSnapshot, GuestMeetingSnapshot())
    }

    func testAttemptHandoffRetainsAudioEngineWithoutReleaseAcrossPeerTeardown() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let audio = try await GuestSystemAudio.create(
            microphoneEnabled: false,
            playoutEnabled: true,
            concurrent: true,
            manualRendering: true,
            keepOutputAvailableWithInput: true
        )
        do {
            let activated = await audio.activateMicrophone()
            XCTAssertTrue(activated)
            let subscriber = try await GuestPeer(target: .subscriber, factory: audio.factory, physicalAudio: true)
            let publisher = try await GuestPeer(target: .publisher, factory: audio.factory, physicalAudio: true)
            let micTrack = try await publisher.prepareAudio(cid: "handoff-mic")
            try await publisher.attach(micTrack, codec: "opus")
            _ = try await publisher.makeOffer()

            let beforeSnapshot = audio.snapshot
            let createdBefore = beforeSnapshot["enginesCreated"] as? Int ?? 0
            let releasedBefore = beforeSnapshot["enginesReleased"] as? Int ?? 0
            XCTAssertEqual(createdBefore, 1)
            XCTAssertEqual(releasedBefore, 0)
            XCTAssertEqual(beforeSnapshot["recording"] as? Bool, true)

            let handoffPrepared = await audio.prepareAttemptHandoff()
            XCTAssertTrue(handoffPrepared)
            await subscriber.closeAndDrain(timeout: 1)
            await publisher.closeAndDrain(timeout: 1)
            let handoffCompleted = await audio.completeAttemptHandoff()
            XCTAssertTrue(handoffCompleted)
            let reactivated = await audio.activateMicrophone()
            XCTAssertTrue(reactivated)

            let afterSnapshot = audio.snapshot
            XCTAssertEqual(afterSnapshot["enginesCreated"] as? Int, 1, "Attempt handoff must retain the existing AVAudioEngine")
            XCTAssertEqual(afterSnapshot["enginesReleased"] as? Int ?? 0, 0, "Attempt handoff must not release the AVAudioEngine across peer teardown")
            XCTAssertEqual(afterSnapshot["recording"] as? Bool, true)
            XCTAssertEqual(afterSnapshot["microphoneMuted"] as? Bool, true)
            XCTAssertEqual(afterSnapshot["recordingAlwaysPrepared"] as? Bool, false)
        } catch {
            _ = await audio.shutdown()
            throw error
        }
        let stopped = await audio.shutdown()
        XCTAssertTrue(stopped)
    }

    func testPostSleepPOSIXENOMEMIsRecoverableAcrossGuestAndExternalPolicies() {
        let bridgedENOMEM = NSError(domain: NSURLErrorDomain, code: Int(POSIXErrorCode.ENOMEM.rawValue))
        XCTAssertTrue(GuestRecoveryPolicy.isRecoverable(bridgedENOMEM))
        XCTAssertTrue(NativeAdapterRecoveryPolicy.isRetryableTransportFailure(bridgedENOMEM))

        let directENOMEM = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOMEM.rawValue))
        XCTAssertTrue(GuestRecoveryPolicy.isRecoverable(directENOMEM))
        XCTAssertTrue(NativeAdapterRecoveryPolicy.isRetryableTransportFailure(directENOMEM))

        let einval = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EINVAL.rawValue))
        XCTAssertFalse(GuestRecoveryPolicy.isRecoverable(einval))
        XCTAssertFalse(NativeAdapterRecoveryPolicy.isRetryableTransportFailure(einval))
    }

    func testConnectedSessionStaysUpWhenLocalUnmuteAudioFails() async throws {
        @MainActor final class MockAudioRejectionEngine: GuestSessionEngine {
            var sessionID: String? = "sess-1"
            var onFailure: ((Error) -> Void)?
            var onForcedMute: ((Bool) -> Void)?
            var mediaPermissions = GuestMediaPermissions(canShareMicrophone: true, canShareCamera: true)
            var onPermissionsChange: ((GuestMediaPermissions) -> Void)?
            var lobbyState = GuestLobbyState()
            var onLobbyChange: ((GuestLobbyState) -> Void)?
            var leaves = 0
            var activateBeforeJoin = false
            var joined = false

            func activateMicrophone() async throws {
                if !joined { activateBeforeJoin = true }
            }
            func setPlayoutEnabled(_ enabled: Bool) async throws {}
            func waitForStartupAudio() async throws {}
            func waitForTransportRecovery() async throws {}
            func releaseStartupAudio() -> Bool { true }
            func join(_ invitation: GuestInvitation, sessionID: String?) async throws { joined = true }
            func publishPattern(codec: String, camera: Bool, audioMuted: Bool, videoMuted: Bool) async throws {}
            func mute(_ muted: Bool, video: Bool) async throws {
                if !video && !muted {
                    throw GuestSystemAudioError.microphoneActivationFailure(authorization: .authorized)
                }
            }
            func setLocalMuteIntent(_ muted: Bool, video: Bool) {}
            func suppressOutgoingMedia() {}
            func leave(sendLeave: Bool) async -> Bool { leaves += 1; return true }
            func interruptTransportForTesting() async {}
        }

        let invitation = try GuestInvitation.parse(URL(string: "https://guest.example.test/call/unmute-fail")!)
        var created: [MockAudioRejectionEngine] = []
        let session = GuestSession(makeAttempt: {
            let e = MockAudioRejectionEngine()
            created.append(e)
            return e
        })

        try await session.connect(invitation, publish: true, codec: "h264", camera: false,
                                  initialAudioMuted: true, initialVideoMuted: true,
                                  initialMicrophonePreparation: true)
        XCTAssertEqual(session.state, .connected)
        let first = try XCTUnwrap(created.first)
        XCTAssertFalse(first.activateBeforeJoin, "Microphone preparation must run after join completes")

        do {
            try await session.mute(false, video: false)
            XCTFail("Unmute audio failure must throw to caller")
        } catch let error as GuestSystemAudioError {
            if case .setupFailedOrTimedOut = error {} else { XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(session.state, .connected, "Local unmute rejection must keep the live session connected")
        XCTAssertEqual(session.snapshot.desiredIntent?.audioMuted, true, "Failed unmute must revert desired audioMuted back to muted")
        XCTAssertEqual(first.leaves, 0)
        XCTAssertEqual(created.count, 1)
        _ = await session.leave()
    }

    func testMediaEventDiagnosticsSuppressSpeakersChangedAndQuality() async throws {
        var events: [[String: Any]] = []
        setProbeLogSink { line in
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                events.append(obj)
            }
        }
        defer { setProbeLogSink(nil) }

        let engine = NativeGuestEngine(label: "LogFilter", verifyReceivedPixels: false)
        _ = try await engine.prepareJoinForTesting()
        try await engine.processEventForTesting([
            "event": "media-out",
            "payload": ["method": "rtc:speakers:changed", "speakersChanged": ["speakers": []]]
        ])
        try await engine.processEventForTesting([
            "event": "media-out",
            "payload": ["method": "rtc:quality", "updates": []]
        ])

        let mediaEvents = events.filter { $0["event"] as? String == "media-event" }
        XCTAssertTrue(mediaEvents.isEmpty, "High-frequency rtc:speakers:changed and rtc:quality should not flood event logs")
        _ = await engine.leave(sendLeave: false)
    }

    @MainActor
    func testMutedAttemptHandoffSuppressesSpontaneousStopAndTerminalLeaveAvoidsExtraEngine() async throws {
        let audio = try await GuestSystemAudio.create(
            microphoneEnabled: false,
            playoutEnabled: true,
            concurrent: true,
            manualRendering: true,
            keepOutputAvailableWithInput: true
        )
        var spontaneousStops = 0
        audio.onSpontaneousEngineChange = { change in
            if change == .stopped { spontaneousStops += 1 }
        }
        do {
            let sub = try await GuestPeer(target: .subscriber, factory: audio.factory, physicalAudio: true)
            let pub = try await GuestPeer(target: .publisher, factory: audio.factory, physicalAudio: true)
            let prepared = await audio.prepareAttemptHandoff()
            XCTAssertTrue(prepared)
            await sub.closeAndDrain(timeout: 1)
            await pub.closeAndDrain(timeout: 1)
            let completed = await audio.completeAttemptHandoff()
            XCTAssertTrue(completed)
            XCTAssertEqual(spontaneousStops, 0, "Planned attempt handoff must not report spontaneous hardware stops")

            let engine = NativeGuestEngine(label: "TerminalLeaveNoExtraEngine", systemAudio: audio, verifyReceivedPixels: false)
            engine.configureStartupPlayback(sound: true)
            _ = try await engine.prepareJoinForTesting()
            _ = try await engine.prepareSubscriberForTesting()
            let createdBeforeLeave = audio.snapshot["enginesCreated"] as? Int ?? 0
            let clean = await engine.leave(sendLeave: true)
            XCTAssertTrue(clean)
            let createdAfterLeave = audio.snapshot["enginesCreated"] as? Int ?? 0
            XCTAssertEqual(createdAfterLeave, createdBeforeLeave, "Terminal leave must not spin up a throwaway AVAudioEngine")
        } catch {
            _ = await audio.shutdown()
            throw error
        }
        _ = await audio.shutdown()
    }

    @MainActor
    func testAudioSenderKeepsEncodingActiveWhenMutedSoSFURegistersTrackAndSwapsSyntheticReply() async throws {
        let factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory()
        )
        let peer = try await GuestPeer(target: .publisher, factory: factory, physicalAudio: false, verifyReceivedPixels: false)
        defer { peer.close() }

        let mic = try await peer.prepareAudio(cid: "mic-cid")
        try await peer.attach(mic, codec: "h264")
        let initial = await peer.localAudioStateForTesting()
        XCTAssertEqual(initial["enabled"] as? Bool, false)
        XCTAssertEqual(initial["encodingActive"] as? [Bool], [true],
                       "Audio sender encoding must stay active while track is disabled so the Guest SFU receives initial silent RTP and advertises the track")

        try await peer.setMuted(false, video: false)
        let unmuted = await peer.localAudioStateForTesting()
        XCTAssertEqual(unmuted["enabled"] as? Bool, true)
        XCTAssertEqual(unmuted["encodingActive"] as? [Bool], [true])

        try await peer.setMuted(true, video: false)
        let muted = await peer.localAudioStateForTesting()
        XCTAssertEqual(muted["enabled"] as? Bool, false)
        XCTAssertEqual(muted["encodingActive"] as? [Bool], [true])

        let synth = try await peer.native.run("make-synth") {
            factory.audioTrack(with: factory.syntheticAudioSource(), trackId: "synth-cid")
        }
        let attachedSynth = await peer.setSyntheticAudioTrack(synth)
        XCTAssertTrue(attachedSynth)
        let duringSynth = await peer.localAudioStateForTesting()
        XCTAssertEqual(duringSynth["senderTrackID"] as? String, "synth-cid")
        XCTAssertEqual(duringSynth["encodingActive"] as? [Bool], [true])

        let restoredMuted = await peer.setSyntheticAudioTrack(nil, restoreAudioEnabled: false)
        XCTAssertTrue(restoredMuted)
        let afterSynth = await peer.localAudioStateForTesting()
        XCTAssertEqual(afterSynth["senderTrackID"] as? String, "mic-cid")
        XCTAssertEqual(afterSynth["enabled"] as? Bool, false)
        XCTAssertEqual(afterSynth["encodingActive"] as? [Bool], [true])
    }

    @MainActor
    func testSuppressOutgoingMediaDuringStartupDoesNotSpinSessionAndCancelsPendingUnmute() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let audio = try await GuestSystemAudio.create(
            microphoneEnabled: false,
            playoutEnabled: true,
            concurrent: true,
            manualRendering: true,
            keepOutputAvailableWithInput: true
        )
        let engine = NativeGuestEngine(label: "SuppressStartupNoSpin", systemAudio: audio, verifyReceivedPixels: false)
        engine.configureStartupPlayback(sound: true)
        engine.suppressOutgoingMedia()

        do {
            try await engine.waitForStartupAudio()
            XCTFail("waitForStartupAudio must throw CancellationError when outputSuppressed is true rather than returning prematurely")
        } catch is CancellationError {
            // Expected: breaks GuestSession.run out of startup loop instead of spinning on releaseStartupAudio() == false.
        }
        _ = await engine.leave(sendLeave: false)
        _ = await audio.shutdown()
    }

    @MainActor
    func testReleaseMutedTalkInputPreservesRecordingDemandForSubsequentUnmute() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let audio = try await GuestSystemAudio.create(
            microphoneEnabled: false,
            playoutEnabled: true,
            concurrent: true,
            manualRendering: true,
            keepOutputAvailableWithInput: true
        )
        let activated = await audio.activateMicrophone()
        XCTAssertTrue(activated)
        let unmutedInitially = await audio.setMicrophoneMuted(false)
        XCTAssertTrue(unmutedInitially)
        XCTAssertEqual(audio.snapshot["recording"] as? Bool, true)
        XCTAssertEqual(audio.snapshot["microphoneMuted"] as? Bool, false)

        let mutedAgain = await audio.setMicrophoneMuted(true)
        XCTAssertTrue(mutedAgain)
        let released = await audio.releaseMutedTalkInput()
        XCTAssertTrue(released)
        XCTAssertEqual(audio.snapshot["inputAvailable"] as? Bool, false)
        XCTAssertEqual(audio.snapshot["deferredActivation"] as? Bool, true)
        XCTAssertEqual(audio.snapshot["recording"] as? Bool, true,
                       "releaseMutedTalkInput must keep WebRTC recording demand so unmuting resumes capture")

        let unmutedAfterRelease = await audio.setMicrophoneMuted(false)
        XCTAssertTrue(unmutedAfterRelease)
        XCTAssertEqual(audio.snapshot["inputAvailable"] as? Bool, true)
        XCTAssertEqual(audio.snapshot["recording"] as? Bool, true)
        XCTAssertEqual(audio.snapshot["microphoneMuted"] as? Bool, false)
        _ = await audio.shutdown()
    }

    func testNativeVideoPixelBufferInterleavesUVPlanesAccuratelyAcrossWidths() throws {
        let width: Int32 = 22, height: Int32 = 14 // chromaWidth = 11 (tests 4-wide SWAR + 3-pixel scalar tail)
        let i420 = LKRTCMutableI420Buffer(width: width, height: height)
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                i420.mutableDataY[y * Int(i420.strideY) + x] = UInt8((y * 17 + x * 3) & 0xFF)
            }
        }
        for cy in 0..<Int((height + 1) / 2) {
            for cx in 0..<Int((width + 1) / 2) {
                i420.mutableDataU[cy * Int(i420.strideU) + cx] = UInt8((0x20 + cy * 7 + cx * 5) & 0xFF)
                i420.mutableDataV[cy * Int(i420.strideV) + cx] = UInt8((0x90 + cy * 11 + cx * 9) & 0xFF)
            }
        }
        let frame = LKRTCVideoFrame(buffer: i420, rotation: ._0, timeStampNs: 1_000)
        let converter = NativeVideoPixelBuffer()
        let out = try XCTUnwrap(converter.convert(frame))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(out, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }

        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 0)).assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                XCTAssertEqual(luma[y * yStride + x], UInt8((y * 17 + x * 3) & 0xFF))
            }
        }

        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 1)).assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        for cy in 0..<Int((height + 1) / 2) {
            for cx in 0..<Int((width + 1) / 2) {
                XCTAssertEqual(uv[cy * uvStride + cx * 2], UInt8((0x20 + cy * 7 + cx * 5) & 0xFF))
                XCTAssertEqual(uv[cy * uvStride + cx * 2 + 1], UInt8((0x90 + cy * 11 + cx * 9) & 0xFF))
            }
        }
    }

    func testSpeakerUpdatesPreserveSortedRosterAndUpdateInPlace() {
        var features = GuestMeetingFeatures()
        var memberPayloads: [[String: Any]] = [
            ["participantId": "local-id", "name": "Zoe Local", "role": "GUEST"]
        ]
        var rtcPayloads: [[String: Any]] = [
            ["sid": "sid-local", "identity": "local-id", "version": 1, "tracks": [["source": "MICROPHONE", "muted": true]]]
        ]
        for index in 1...52 {
            let id = "remote-\(index)"
            memberPayloads.append(["participantId": id, "name": "Participant \(index)", "role": "GUEST"])
            rtcPayloads.append(["sid": "sid-\(index)", "identity": id, "version": 1, "tracks": [["source": "MICROPHONE", "muted": index > 2]]])
        }
        features.receive([
            "event": "joined",
            "payload": [
                "roomId": "room-53",
                "participant": [
                    "participantId": "local-id",
                    "name": "Zoe Local",
                    "permissions": ["canViewParticipants": true]
                ],
                "participantGroup": [
                    "groupId": "group-1",
                    "name": "All Hands",
                    "participants": memberPayloads
                ]
            ]
        ])
        features.updateRTC(rtcPayloads)
        features.setLocalMute(true, video: false)
        let initialIDs = features.snapshot.participants.map(\.id)
        XCTAssertEqual(initialIDs.count, 53)
        XCTAssertEqual(initialIDs.first, "local-id")
        XCTAssertEqual(initialIDs[1], "remote-1")
        XCTAssertEqual(initialIDs[2], "remote-2")
        XCTAssertEqual(initialIDs[10], "remote-10", "localizedStandardCompare keeps natural numeric order")

        features.updateSpeakers([
            ["sid": "sid-local", "level": 0.9, "active": true],
            ["sid": "sid-10", "level": 0.65, "active": true]
        ])
        XCTAssertEqual(features.snapshot.participants.map(\.id), initialIDs)
        let local = features.snapshot.participants.first { $0.id == "local-id" }
        let remote10 = features.snapshot.participants.first { $0.id == "remote-10" }
        XCTAssertEqual(local?.isSpeaking, false, "Local mute suppresses server speaker echo")
        XCTAssertEqual(remote10?.isSpeaking, true)
        XCTAssertEqual(remote10?.audioLevel ?? 0, 0.65, accuracy: 1e-6)

        features.updateSpeakers([])
        XCTAssertTrue(features.snapshot.participants.allSatisfy { !$0.isSpeaking && $0.audioLevel == 0 })
    }
}
