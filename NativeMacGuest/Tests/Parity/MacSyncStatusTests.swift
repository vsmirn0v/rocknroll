import AppKit
import ApplicationServices
import ConferenceCore
import LiveKitWebRTC
import SwiftUI
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

private final class SyncStatusTestStorage: RoomHistoryStorage, ReminderStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

private actor SyncStatusTestCalendarReader: CalendarReading {
    func access() -> CalendarAccess { .notDetermined }
    func requestAccess() -> Bool { false }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        .init(calendars: [], meetings: [])
    }
}

private final class SyncStatusNoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}

@MainActor private final class SyncStatusTestNotifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}

@MainActor private final class SyncStatusTestCloud: RoomCloudTransport {
    var session = RoomCloudSession(account: "test-account", generation: "gen-1")
    func connect() async throws -> RoomCloudSession { session }
    func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges { .init(records: [], token: nil) }
    func save(_ records: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] { records }
    func clear(session: RoomCloudSession) async throws {}
}

@MainActor private final class SyncStatusTestContinuation: MeetingContinuationTransport {
    func connect(account: String) async throws {}
    func jams() async throws -> [ActiveJam] { [] }
    func publish(_ jam: ActiveJam) async throws {}
    func withdraw(deviceID: String, sessionID: UUID?) async throws {}
    func claim(_ transfer: JamTransfer) async throws { throw ContinuationError.unavailable }
    func transfer(sourceSession: UUID) async throws -> JamTransfer? { nil }
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
        throw ContinuationError.unavailable
    }
    func clear() async throws {}
}

@MainActor private final class SyncStatusTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    func connect(invitation: URL, name: String, quiet: Bool) async throws {}
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws {}
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws {}
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {}
    func leave() async -> Bool { true }
}

@MainActor
final class MacSyncStatusTests: XCTestCase {
    private func snapshot(
        enabled: Bool = false,
        busy: Bool = false,
        syncState: RoomSyncCoordinator.SyncState = .off,
        status: String = L("Stored on this device"),
        storageWarning: String? = nil,
        hasNameChoice: Bool = false,
        needsFreshAccount: Bool = false,
        includeRecent: Bool = true,
        syncWorkspace: Bool = true,
        shareCalendar: Bool = true,
        handoffEnabled: Bool = true,
        transcriptRetention: TranscriptSyncRetention = .days30,
        workspaceIsSyncing: Bool = false,
        workspaceSyncError: String? = nil
    ) -> MacSyncStatusPresentation.Snapshot {
        .init(
            enabled: enabled,
            busy: busy,
            syncState: syncState,
            status: status,
            storageWarning: storageWarning,
            hasNameChoice: hasNameChoice,
            needsFreshAccount: needsFreshAccount,
            includeRecent: includeRecent,
            syncWorkspace: syncWorkspace,
            shareCalendar: shareCalendar,
            handoffEnabled: handoffEnabled,
            transcriptRetention: transcriptRetention,
            workspaceIsSyncing: workspaceIsSyncing,
            workspaceSyncError: workspaceSyncError,
            lastLibrarySyncAt: nil,
            nextRetryAt: nil
        )
    }

    func testSyncOffShowsMeetingsScopeAndEnablePrompt() {
        let model = MacSyncStatusPresentation(snapshot())
        XCTAssertEqual(model.cardTitle, L("Meetings sync"))
        XCTAssertEqual(model.cardSubtitle, L("On this Mac · Enable iCloud"))
        XCTAssertEqual(model.iconName, "icloud.slash")
        XCTAssertEqual(model.tone, .neutral)
        XCTAssertFalse(model.showsSpinner)
        XCTAssertEqual(model.popoverBadge, L("Off"))
        XCTAssertEqual(model.statusDetail, L("Stored on this Mac only"))
        XCTAssertTrue(model.syncedItems.isEmpty)
    }

    func testSyncOnUpToDateReflectsSyncedCategories() {
        let model = MacSyncStatusPresentation(snapshot(
            enabled: true,
            syncState: .upToDate,
            status: L("Up to date"),
            includeRecent: false,
            syncWorkspace: true,
            shareCalendar: false,
            handoffEnabled: true,
            transcriptRetention: .days14
        ))
        XCTAssertEqual(model.cardTitle, L("Meetings sync"))
        XCTAssertEqual(model.cardSubtitle, L("Synced with iCloud"))
        XCTAssertEqual(model.iconName, "checkmark.icloud")
        XCTAssertEqual(model.tone, .ok)
        XCTAssertFalse(model.showsSpinner)
        XCTAssertEqual(model.popoverBadge, L("Up to date"))
        XCTAssertEqual(model.syncedItems, [
            L("Saved rooms & favorites"),
            L("Meeting history, summaries, notes & tasks"),
            L("Active meeting handoff"),
            L("Raw transcripts · %@", TranscriptSyncRetention.days14.title)
        ])
    }

    func testSyncingStateShowsSpinnerForRoomAndWorkspaceSync() {
        let roomBusy = MacSyncStatusPresentation(snapshot(
            enabled: true,
            busy: true,
            syncState: .syncing,
            status: L("Connecting to iCloud…")
        ))
        XCTAssertTrue(roomBusy.showsSpinner)
        XCTAssertEqual(roomBusy.tone, .active)
        XCTAssertEqual(roomBusy.cardSubtitle, L("Syncing with iCloud…"))
        XCTAssertEqual(roomBusy.popoverBadge, L("Syncing…"))

        let workspaceBusy = MacSyncStatusPresentation(snapshot(
            enabled: true,
            syncState: .upToDate,
            status: L("Up to date"),
            workspaceIsSyncing: true
        ))
        XCTAssertTrue(workspaceBusy.showsSpinner)
        XCTAssertEqual(workspaceBusy.tone, .active)
    }

    func testPendingErrorConflictAndAccountChangedStates() {
        let pending = MacSyncStatusPresentation(snapshot(enabled: true, syncState: .pending, status: L("Changes pending")))
        XCTAssertEqual(pending.iconName, "icloud.and.arrow.up")
        XCTAssertEqual(pending.tone, .warning)
        XCTAssertEqual(pending.cardSubtitle, L("Changes pending"))

        let unavailable = MacSyncStatusPresentation(snapshot(enabled: true, syncState: .unavailable, status: L("iCloud unavailable. Your changes stay on this device.")))
        XCTAssertEqual(unavailable.iconName, "exclamationmark.icloud")
        XCTAssertEqual(unavailable.tone, .warning)
        XCTAssertEqual(unavailable.cardSubtitle, L("iCloud unavailable"))

        let workspaceError = MacSyncStatusPresentation(snapshot(enabled: true, syncState: .upToDate, status: L("Up to date"), workspaceSyncError: "Workspace error"))
        XCTAssertEqual(workspaceError.iconName, "exclamationmark.icloud")
        XCTAssertEqual(workspaceError.tone, .warning)
        XCTAssertEqual(workspaceError.cardSubtitle, L("Sync issue · Retry"))
        XCTAssertEqual(workspaceError.statusDetail, "Workspace error")
        XCTAssertFalse(workspaceError.showsSpinner)

        let conflict = MacSyncStatusPresentation(snapshot(enabled: true, syncState: .nameConflict, hasNameChoice: true))
        XCTAssertEqual(conflict.cardSubtitle, L("Choose display name"))
        XCTAssertEqual(conflict.popoverBadge, L("Action needed"))

        let accountChanged = MacSyncStatusPresentation(snapshot(enabled: false, syncState: .accountChanged, status: L("Apple Account changed. Start fresh to sync with this account."), needsFreshAccount: true))
        XCTAssertEqual(accountChanged.cardSubtitle, L("Apple Account changed"))
        XCTAssertEqual(accountChanged.popoverBadge, L("Action needed"))
    }

    func testOpenSyncSettingsNavigatesToGeneralAndSetsRevealID() {
        let fixture = makeFixture()
        let workspace = fixture.workspace
        workspace.settingsTab = 3
        workspace.selection = .home

        workspace.openSyncSettings()

        XCTAssertEqual(workspace.selection, .settings)
        XCTAssertEqual(workspace.settingsTab, 0)
        XCTAssertEqual(workspace.settingsRevealID, "settings.sync")
    }

    func testSidebarSyncCardClicksOpenPopoverEnableSyncAndNavigateToSettings() async throws {
        let fixture = makeFixture()
        let workspace = fixture.workspace
        let library = fixture.library
        XCTAssertFalse(library.sync.enabled)

        let host = NSHostingView(rootView: AnyView(NativeDesktopHomeView(workspace: workspace, library: library)))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sync status hit testing \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }
        await settleUI(host)

        let syncButton = try XCTUnwrap(accessibilityElement(in: window, identifier: "sidebar.sync-status"))
        func hasPopoverWindow() -> Bool {
            NSApp.windows.contains { $0.isVisible && $0.className.localizedCaseInsensitiveContains("Popover") }
        }
        try clickTrailingArea(syncButton, in: window)
        await settleUI(host)
        if !hasPopoverWindow() {
            let pressStatus = AXUIElementPerformAction(syncButton, kAXPressAction as CFString)
            await settleUI(host)
            XCTFail("Trailing click did not open popover; AXPress=\(pressStatus.rawValue), hasPopoverAfterPress=\(hasPopoverWindow())")
        }

        let enableButton = try await eventuallyElement(identifier: "sync-popover.enable")
        XCTAssertNotNil(accessibilityElement(in: nil, identifier: "sync-popover.settings"))

        XCTAssertEqual(AXUIElementPerformAction(enableButton, kAXPressAction as CFString), .success)
        try await eventually { library.sync.enabled }
        _ = try await eventuallyElement(identifier: "sync-popover.sync-now")

        let settingsButton = try await eventuallyElement(identifier: "sync-popover.settings")
        XCTAssertEqual(AXUIElementPerformAction(settingsButton, kAXPressAction as CFString), .success)
        try await eventually { workspace.selection == .settings && workspace.settingsTab == 0 && workspace.settingsRevealID == nil }
    }

    // MARK: - Helpers

    private struct Fixture {
        let workspace: NativeDesktopWorkspace
        let library: NativeDesktopLibrary
    }

    private func makeFixture() -> Fixture {
        let domain = "native-sync-status-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        addTeardownBlock { preferences.removePersistentDomain(forName: domain) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStatusNoNetwork.self]
        let reminders = CalendarReminderCoordinator(
            preferences: preferences,
            storage: SyncStatusTestStorage(),
            notifications: SyncStatusTestNotifications()
        )
        let calendar = CalendarMeetingStore(
            reader: SyncStatusTestCalendarReader(),
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: configuration)),
            preferences: preferences,
            storage: SyncStatusTestStorage(),
            reminders: reminders,
            isMac: true
        )
        let library = NativeDesktopLibrary(
            preferences: preferences,
            history: RoomHistoryStore(storage: SyncStatusTestStorage()),
            syncStorage: SyncStatusTestStorage(),
            cloudTransport: SyncStatusTestCloud(),
            calendar: calendar,
            continuationTransport: SyncStatusTestContinuation()
        )
        library.displayName = "Sync status fixture"
        library.setup.suspendForMeeting()
        let workspace = NativeDesktopWorkspace(
            library: library,
            detect: { .verified(.guest(endpoint: $0)) },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(
                    destination: destination,
                    name: name,
                    title: title,
                    quiet: quiet,
                    engine: SyncStatusTestEngine()
                )
            },
            attention: desktopTestAttention()
        )
        return Fixture(workspace: workspace, library: library)
    }

    private func settleUI(_ host: NSView) async {
        for _ in 0..<4 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard condition() else {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            throw CancellationError()
        }
    }

    private func eventuallyElement(identifier: String, file: StaticString = #filePath, line: UInt = #line) async throws -> AXUIElement {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let found = accessibilityElement(in: nil, identifier: identifier) {
                return found
            }
            try await Task.sleep(for: .milliseconds(15))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for AX element \(identifier)", file: file, line: line)
        throw CancellationError()
    }

    private func accessibilityValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func accessibilityNodes(in window: NSWindow?) -> [AXUIElement] {
        func children(_ root: AXUIElement) -> [AXUIElement] {
            (accessibilityValue(root, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        func walk(_ root: AXUIElement) -> [AXUIElement] { [root] + children(root).flatMap(walk) }
        let app = AXUIElementCreateApplication(getpid())
        guard let window else { return walk(app) }
        guard let target = children(app).first(where: { accessibilityValue($0, kAXTitleAttribute) as? String == window.title }) else {
            return []
        }
        return walk(target)
    }

    private func accessibilityElement(in window: NSWindow?, identifier: String) -> AXUIElement? {
        accessibilityNodes(in: window).first {
            accessibilityValue($0, kAXIdentifierAttribute) as? String == identifier
        }
    }

    private func clickTrailingArea(_ element: AXUIElement, in window: NSWindow) throws {
        let position = try XCTUnwrap(accessibilityValue(element, kAXPositionAttribute)) as! AXValue
        let size = try XCTUnwrap(accessibilityValue(element, kAXSizeAttribute)) as! AXValue
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        XCTAssertTrue(AXValueGetValue(position, .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(size, .cgSize, &dimensions))
        XCTAssertGreaterThan(dimensions.width, 140)
        let y = origin.y + dimensions.height / 2
        let x = origin.x + dimensions.width - 8
        let screenPoint = NSPoint(x: x, y: NSScreen.screens[0].frame.maxY - y)
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            window.sendEvent(event)
        }
    }
}
