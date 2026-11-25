import AppKit
import ConferenceCore
import LiveKitWebRTC
import MeetingEngine
import XCTest
@testable import RockNativeDesktop

private final class InstantRoomTestStorage: RoomHistoryStorage {
    private var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

@MainActor private final class InstantRoomTestEngine: NativeDesktopMeetingEngine {
    var supportsVoiceReply = false
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var supportsLocalTranscription: Bool { true }
    var factory: LKRTCPeerConnectionFactory? { nil }
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] { [] }

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot = .init(
            phase: .connected,
            microphoneOn: false,
            cameraOn: false,
            playoutOn: !quiet,
            participants: [.init(id: "me", name: name, isLocal: true)]
        )
        onState?(snapshot)
    }

    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws { snapshot.cameraOn = enabled; onState?(snapshot) }
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func leave() async -> Bool { snapshot.phase = .left; onState?(snapshot); return true }
}

@MainActor
final class InstantMeetingParityTests: XCTestCase {
    private func makeWorkspace(
        historyURLs: [URL] = [],
        defaults: UserDefaults,
        clipboard: @escaping @MainActor (String) -> Void = { _ in }
    ) -> NativeDesktopWorkspace {
        let history = RoomHistoryStore(storage: InstantRoomTestStorage())
        for (idx, url) in historyURLs.enumerated() {
            history.saveFavorite(url: url, title: "Prior \(idx)", engine: .guest)
        }
        let library = NativeDesktopLibrary(
            preferences: defaults,
            history: history,
            syncStorage: InstantRoomTestStorage()
        )
        library.displayName = "Vitalii"
        let workspace = NativeDesktopWorkspace(
            library: library,
            detect: { url in .verified(.guest(endpoint: url)) },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(
                    destination: destination,
                    name: name,
                    title: title,
                    quiet: quiet,
                    engine: InstantRoomTestEngine()
                )
            }
        )
        var remembered: [URL] = []
        var forgotten: [URL] = []
        var dismissed = Set<String>()
        workspace.instantRoomPreferencesDefaults = defaults
        workspace.instantRoomAccountsProvider = { [] }
        workspace.instantRoomRememberedOriginsProvider = { remembered }
        workspace.instantRoomDismissedOriginsProvider = { dismissed }
        workspace.rememberInstantOriginHandler = { origin, _, restore in
            if restore { dismissed.remove(origin.absoluteString) }
            if !dismissed.contains(origin.absoluteString) && !remembered.contains(origin) {
                remembered.insert(origin, at: 0)
            }
        }
        workspace.forgetInstantOriginHandler = { origin in
            remembered.removeAll { $0 == origin }
            dismissed.insert(origin.absoluteString)
            forgotten.append(origin)
        }
        workspace.copyInvitationToClipboard = clipboard
        _ = forgotten
        return workspace
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "instant-meeting-parity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func spin(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for async condition", file: file, line: line)
    }

    func testStartInstantRoomCopiesLinkSavesOriginAndJoinsWithCopiedFlag() async throws {
        let defaults = try makeIsolatedDefaults()
        let origin = try XCTUnwrap(URL(string: "https://meet.example.com"))
        let priorURL = try XCTUnwrap(URL(string: "https://meet.example.com/calls/prior-room"))
        let inviteURL = try XCTUnwrap(URL(string: "https://meet.example.com/calls/instant-1"))

        var copiedTexts: [String] = []
        var createdOrigins: [URL] = []
        let workspace = makeWorkspace(historyURLs: [priorURL], defaults: defaults) { copiedTexts.append($0) }
        addTeardownBlock { _ = await workspace.leave() }

        workspace.createInstantRoomHandler = { requestedOrigin, _ in
            createdOrigins.append(requestedOrigin)
            return CreatedMeetingRoom(
                origin: requestedOrigin,
                engine: .guest,
                roomID: "instant-1",
                title: "Vitalii’s meeting",
                invitationURL: inviteURL,
                destination: try .verified(inviteURL, engine: .guest)
            )
        }

        await workspace.startInstantRoom()

        XCTAssertEqual(createdOrigins, [origin])
        XCTAssertEqual(copiedTexts, [inviteURL.absoluteString])
        XCTAssertEqual(InstantRoomPreferences.loadLastOrigin(defaults: defaults), origin)
        XCTAssertEqual(workspace.instantRoomPreferredOrigin, origin)
        XCTAssertNil(workspace.instantRoomError)
        XCTAssertNil(workspace.instantRoomAuthChallengeOrigin)

        try await spin { workspace.selectedMeeting != nil && !workspace.preparing }
        let model = try XCTUnwrap(workspace.selectedMeeting)
        XCTAssertEqual(model.invitation, inviteURL)
        XCTAssertTrue(model.invitationCopiedOnJoin)
        XCTAssertFalse(model.snapshot.microphoneOn)
        XCTAssertFalse(model.snapshot.cameraOn)
    }

    func testStartInstantRoomAuthChallengeSetsSignInOriginWithoutError() async throws {
        let defaults = try makeIsolatedDefaults()
        let origin = try XCTUnwrap(URL(string: "https://auth.example.com"))
        let priorURL = try XCTUnwrap(URL(string: "https://auth.example.com/calls/prior"))
        let workspace = makeWorkspace(historyURLs: [priorURL], defaults: defaults)
        addTeardownBlock { _ = await workspace.leave() }

        workspace.createInstantRoomHandler = { requestedOrigin, _ in
            throw SiteAuthError.signInRequired(origin: requestedOrigin, engine: .guest)
        }

        await workspace.startInstantRoom()

        XCTAssertEqual(workspace.instantRoomAuthChallengeOrigin, origin)
        XCTAssertNil(workspace.instantRoomError)
        XCTAssertTrue(workspace.meetings.isEmpty)
        XCTAssertFalse(workspace.isCreatingInstantRoom)
    }

    func testStartInstantRoomGenericFailureRecordsError() async throws {
        let defaults = try makeIsolatedDefaults()
        let priorURL = try XCTUnwrap(URL(string: "https://fail.example.com/calls/prior"))
        let workspace = makeWorkspace(historyURLs: [priorURL], defaults: defaults)
        addTeardownBlock { _ = await workspace.leave() }

        workspace.createInstantRoomHandler = { _, _ in
            throw NSError(domain: "InstantTest", code: 503, userInfo: [NSLocalizedDescriptionKey: "Server unavailable"])
        }

        await workspace.startInstantRoom()

        XCTAssertEqual(workspace.instantRoomError, "Server unavailable")
        XCTAssertNil(workspace.instantRoomAuthChallengeOrigin)
        XCTAssertTrue(workspace.meetings.isEmpty)
        XCTAssertFalse(workspace.isCreatingInstantRoom)
    }

    func testStartInstantRoomWithoutOriginPromptsRoomSheet() async throws {
        let defaults = try makeIsolatedDefaults()
        let workspace = makeWorkspace(historyURLs: [], defaults: defaults)
        addTeardownBlock { _ = await workspace.leave() }

        XCTAssertNil(workspace.preferredInstantOrigin)
        await workspace.startInstantRoom()

        XCTAssertTrue(workspace.showCreateRoomSheetRequested)
        XCTAssertFalse(workspace.isCreatingInstantRoom)
    }

    func testSelectInstantOriginPersistsCanonicalURL() throws {
        let defaults = try makeIsolatedDefaults()
        let workspace = makeWorkspace(historyURLs: [], defaults: defaults)
        let inputURL = try XCTUnwrap(URL(string: "https://team.example.org/calls/standup?foo=bar"))
        let expected = try XCTUnwrap(URL(string: "https://team.example.org"))

        workspace.selectInstantOrigin(inputURL)

        XCTAssertEqual(workspace.instantRoomPreferredOrigin, expected)
        XCTAssertEqual(InstantRoomPreferences.loadLastOrigin(defaults: defaults), expected)
    }

    func testMeetingModelCopyInvitationLinkIncrementsRevisionAndWritesPasteboard() throws {
        let inviteURL = try XCTUnwrap(URL(string: "https://meet.example.com/calls/copy-test"))
        let destination: JoinDestination = try .verified(inviteURL, engine: .guest)
        let model = NativeDesktopMeetingModel(
            destination: destination,
            name: "Vitalii",
            title: "Copy test",
            quiet: false,
            engine: InstantRoomTestEngine()
        )
        XCTAssertEqual(model.copiedToastRevision, 0)

        model.copyInvitationLink()

        XCTAssertEqual(model.copiedToastRevision, 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), inviteURL.absoluteString)
    }

    func testInvitationQRGeneratorHandlesValidURLAndEmptyInput() {
        let image = NativeDesktopInvitationQR.image(for: "https://meet.example.com/calls/qr-test")
        XCTAssertNotNil(image)
        if let image {
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
        XCTAssertNil(NativeDesktopInvitationQR.image(for: ""))
        XCTAssertNil(NativeDesktopInvitationQR.image(for: "   "))
    }

    func testRemoveInstantOriginForgetsOriginAndExcludesReservedTestHosts() throws {
        let defaults = try makeIsolatedDefaults()
        let realURL = try XCTUnwrap(URL(string: "https://telemost.360.yandex.ru/j/room-99"))
        let testURL = try XCTUnwrap(URL(string: "https://example.test/calls/leak"))
        let workspace = makeWorkspace(historyURLs: [testURL, realURL], defaults: defaults)
        let canonical = try XCTUnwrap(URL(string: "https://telemost.yandex.ru"))

        XCTAssertEqual(workspace.instantAvailableOrigins, [canonical])
        workspace.selectInstantOrigin(canonical)
        XCTAssertEqual(workspace.preferredInstantOrigin, canonical)

        workspace.removeInstantOrigin(canonical)
        XCTAssertNil(workspace.preferredInstantOrigin)
        XCTAssertTrue(workspace.instantAvailableOrigins.isEmpty)
        XCTAssertNil(InstantRoomPreferences.loadLastOrigin(defaults: defaults))
    }
}
