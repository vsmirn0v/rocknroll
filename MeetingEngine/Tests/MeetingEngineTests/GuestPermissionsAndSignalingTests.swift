import Foundation
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
}
