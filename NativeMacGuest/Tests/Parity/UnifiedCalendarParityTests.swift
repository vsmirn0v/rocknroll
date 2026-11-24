import AppKit
import ConferenceCore
import Foundation
import LiveKitWebRTC
import SwiftUI
import XCTest
@testable import RockNativeDesktop

private final class ParityRoomStorage: RoomHistoryStorage, ReminderStorage, @unchecked Sendable {
    var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

@MainActor
private final class ParityNotifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}

private actor ParityCalendarReader: CalendarReading {
    var events: [CalendarMeeting]
    var rangeEvents: [CalendarMeeting]
    init(events: [CalendarMeeting] = [], rangeEvents: [CalendarMeeting] = []) {
        self.events = events
        self.rangeEvents = rangeEvents
    }
    func access() -> CalendarAccess { .allowed }
    func requestAccess() -> Bool { true }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot {
        CalendarSnapshot(
            calendars: [
                .init(id: "work", name: "Work", source: "iCloud"),
                .init(id: "created-cal", name: "Team", source: "iCloud"),
            ],
            meetings: events.filter { selected.contains($0.calendarID) }
        )
    }
    func readRange(selected: Set<String>, interval: DateInterval, knownOrigins: Set<String>, aliases: [String: URL]) async -> [CalendarMeeting] {
        rangeEvents.filter { selected.contains($0.calendarID) && $0.end >= interval.start && $0.start <= interval.end }
    }
}

@MainActor
private final class ParityNoCloud: RoomCloudTransport {
    func connect() async throws -> RoomCloudSession { throw RoomCloudError.noAccount }
    func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges { .init(records: [], token: nil) }
    func save(_ records: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] { records }
    func clear(session: RoomCloudSession) async throws {}
}

private final class ParityNoopNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}

@MainActor
private final class ParityNoopEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    func connect(invitation: URL, name: String, quiet: Bool) async throws { snapshot.phase = .connected; onState?(snapshot) }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {}
    func leave() async -> Bool { snapshot.phase = .left; onState?(snapshot); return true }
}

@MainActor
private final class ParityNoContinuation: MeetingContinuationTransport {
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

@MainActor
final class UnifiedCalendarParityTests: XCTestCase {
    func testSidebarSectionOrderPromotesCalendarBeforeMeetingHistory() {
        let sections = NativeDesktopWorkspace.Section.allCases
        guard let calendarIdx = sections.firstIndex(of: .calendar),
              let historyIdx = sections.firstIndex(of: .history) else {
            return XCTFail("Expected both .calendar and .history in Section.allCases")
        }
        XCTAssertEqual(calendarIdx, 2)
        XCTAssertEqual(historyIdx, 3)
    }

    func testAutoJoinIgnoresPastAndLinklessCalendarMeetings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pastMeeting = CalendarMeeting(
            id: "past-30d",
            seriesID: "past",
            calendarID: "work",
            calendarTitle: "Work",
            title: "Past Meeting",
            start: now.addingTimeInterval(-10 * 86_400),
            end: now.addingTimeInterval(-10 * 86_400 + 1800)
        )
        pastMeeting.invitation = URL(string: "https://meet.example.test/past")!
        pastMeeting.engine = .guest

        let linklessNow = CalendarMeeting(
            id: "linkless-now",
            seriesID: "linkless",
            calendarID: "work",
            calendarTitle: "Work",
            title: "Offline Lunch",
            start: now.addingTimeInterval(30),
            end: now.addingTimeInterval(1800)
        )

        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [pastMeeting, linklessNow], at: now))
    }

    func testHandleCreatedCalendarEventEnablesCalendarSelectsIDAndKeepsUpcomingScoped() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = "UnifiedCalendarParityTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }

        var pastEvent = CalendarMeeting(
            id: "past",
            seriesID: "s1",
            calendarID: "created-cal",
            calendarTitle: "Team",
            title: "Past Created",
            start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-3600)
        )
        pastEvent.invitation = URL(string: "https://meet.example.test/past")!
        pastEvent.engine = .guest

        var futureEvent = CalendarMeeting(
            id: "future",
            seriesID: "s2",
            calendarID: "created-cal",
            calendarTitle: "Team",
            title: "Future Created",
            start: now.addingTimeInterval(1800),
            end: now.addingTimeInterval(3600)
        )
        futureEvent.invitation = URL(string: "https://meet.example.test/future")!
        futureEvent.engine = .guest

        let linklessFuture = CalendarMeeting(
            id: "linkless-future",
            seriesID: "s3",
            calendarID: "created-cal",
            calendarTitle: "Team",
            title: "Offline Sync",
            start: now.addingTimeInterval(5400),
            end: now.addingTimeInterval(7200)
        )

        let reader = ParityCalendarReader(events: [pastEvent, futureEvent, linklessFuture])
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: ParityRoomStorage(),
            notifications: ParityNotifications()
        )
        let store = CalendarMeetingStore(
            reader: reader,
            detector: VendorEndpointResolver.makeDetector(),
            preferences: prefs,
            storage: ParityRoomStorage(),
            reminders: reminders,
            isMac: true,
            clock: { now }
        )
        store.knownEngine = { _ in .guest }

        XCTAssertFalse(store.enabled)
        store.handleCreatedCalendarEvent(calendarID: "created-cal")

        for _ in 0..<40 where store.loading || store.meetings.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(store.enabled)
        XCTAssertTrue(store.selected.contains("created-cal"))
        XCTAssertEqual(store.upcoming.map(\.id), ["future"])
        XCTAssertEqual(Set(store.allTimelineMeetings.map(\.id)), Set(["past", "future", "linkless-future"]))
    }

    func testCalendarTabEnterAndExitPerformanceWithLargeSchedule() async throws {
        let now = Date()
        let suite = "UnifiedCalendarPerfTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "calendarMeetings.enabled")
        prefs.set(["work"], forKey: "calendarMeetings.selected")
        defer { prefs.removePersistentDomain(forName: suite) }

        var generatedEvents: [CalendarMeeting] = []
        generatedEvents.reserveCapacity(250)
        for index in 0..<250 {
            // Span -30d to +20d with most events in the past before Today so "Now" sits deep in the list.
            let dayOffset = (index < 180) ? -(index % 30 + 1) : ((index - 180) % 20)
            let start = now.addingTimeInterval(Double(dayOffset) * 86_400 + Double((index % 8) - 4) * 1_800)
            let invite = URL(string: "https://meet.example.test/calls/perf-room-\(index % 35)")!
            var meeting = CalendarMeeting(
                id: "perf-cal-\(index)",
                seriesID: "perf-series-\(index % 35)",
                calendarID: "work",
                calendarTitle: "Work",
                title: "Sync Meeting #\(index)",
                start: start,
                end: start.addingTimeInterval(1_800),
                links: [invite]
            )
            meeting.invitation = invite
            meeting.engine = .guest
            generatedEvents.append(meeting)
        }

        let reader = ParityCalendarReader(events: generatedEvents)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ParityNoopNetwork.self]
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: ParityRoomStorage(),
            notifications: ParityNotifications()
        )
        let calendarStore = CalendarMeetingStore(
            reader: reader,
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: sessionConfig)),
            preferences: prefs,
            storage: ParityRoomStorage(),
            reminders: reminders,
            isMac: true,
            clock: { now }
        )
        calendarStore.knownEngine = { _ in .guest }

        let attention = desktopTestAttention()
        let library = NativeDesktopLibrary(
            preferences: prefs,
            history: RoomHistoryStore(storage: ParityRoomStorage()),
            syncStorage: ParityRoomStorage(),
            cloudTransport: ParityNoCloud(),
            calendar: calendarStore,
            continuationTransport: ParityNoContinuation()
        )
        library.displayName = "Perf User"
        library.setup.suspendForMeeting()

        let workspace = NativeDesktopWorkspace(
            library: library,
            detect: { _ in .unknown },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(
                    destination: destination,
                    name: name,
                    title: title,
                    quiet: quiet,
                    engine: ParityNoopEngine()
                )
            },
            attention: attention
        )
        addTeardownBlock {
            _ = await workspace.leave()
            await MainActor.run { attention.stop() }
        }

        let store = attention.store
        await store.waitForMeetingLibrary()
        for index in 0..<150 {
            let start = now.addingTimeInterval(-Double((index % 60) + 1) * 43_200)
            let end = start.addingTimeInterval(1_800)
            let session = MeetingSessionRecord(
                title: "Recorded Sync \(index)",
                startedAt: start,
                endedAt: end,
                state: .ended
            )
            try await store.meetingLibrary.store.upsertSession(session)
            if index < 80 {
                let invite = URL(string: "https://meet.example.test/calls/perf-room-\(index % 35)")!
                try await store.meetingLibrary.store.saveOutcome(
                    MeetingOutcome(
                        meetingID: session.id,
                        meetingTitle: session.title,
                        invitation: invite,
                        seriesID: "perf-series-\(index % 35)",
                        endedAt: end,
                        summary: "Completed review for item \(index)",
                        decisions: ["Ship optimization \(index)"]
                    ),
                    state: .ready
                )
            }
        }
        await store.meetingLibrary.refresh()
        store.assistant.restorePersistedOutcomes(try await store.meetingLibrary.store.outcomes())
        calendarStore.refresh()
        for _ in 0..<60 where calendarStore.loading || calendarStore.meetings.count < 250 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(calendarStore.meetings.count, 250)

        let host = NSHostingView(rootView: AnyView(NativeDesktopHomeView(workspace: workspace, library: library)))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Calendar perf test \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.close() }

        func flushFrame() async {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }

        func measureSeconds(_ block: () async -> Void) async -> Double {
            let start = ContinuousClock.now
            await block()
            let elapsed = start.duration(to: .now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }

        await flushFrame()

        let enter1 = await measureSeconds {
            workspace.selection = .calendar
            await flushFrame()
        }
        let exit1 = await measureSeconds {
            workspace.selection = .home
            await flushFrame()
        }
        let enter2 = await measureSeconds {
            workspace.selection = .calendar
            await flushFrame()
        }
        let exitToHistory = await measureSeconds {
            workspace.selection = .history
            await flushFrame()
        }

        let total = enter1 + exit1 + enter2 + exitToHistory
        print(String(format: "CalendarPerf(250cal,150sess,80out): enter1=%.3fs exit1=%.3fs enter2=%.3fs exitToHistory=%.3fs total=%.3fs",
                     enter1, exit1, enter2, exitToHistory, total))

        XCTAssertLessThan(enter1, 0.5, "Entering Calendar took \(enter1)s")
        XCTAssertLessThan(exit1, 0.5, "Exiting Calendar to Home took \(exit1)s")
        XCTAssertLessThan(enter2, 0.5, "Re-entering Calendar took \(enter2)s")
        XCTAssertLessThan(exitToHistory, 1.0, "Exiting Calendar to History took \(exitToHistory)s")
        XCTAssertLessThan(total, 2.0, "Combined Calendar transitions took \(total)s")
    }

    func testCalendarWindowingPreservesAllDayMarkersAndExpandsForOlderScrubTarget() async throws {
        var displayCalendar = Calendar(identifier: .gregorian)
        displayCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1_795_521_600) // Fixed UTC midday
        let oldDayStart = displayCalendar.startOfDay(for: displayCalendar.date(byAdding: .day, value: -45, to: now)!)
        let recentPastDayStart = displayCalendar.startOfDay(for: displayCalendar.date(byAdding: .day, value: -2, to: now)!)
        let futureDayStart = displayCalendar.startOfDay(for: displayCalendar.date(byAdding: .day, value: 10, to: now)!)

        let suite = "UnifiedCalendarWindowTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "calendarMeetings.enabled")
        prefs.set(["work"], forKey: "calendarMeetings.selected")
        defer { prefs.removePersistentDomain(forName: suite) }

        func makeMeeting(id: String, start: Date) -> CalendarMeeting {
            let invite = URL(string: "https://meet.example.test/calls/\(id)")!
            var meeting = CalendarMeeting(
                id: id,
                seriesID: "series-\(id)",
                calendarID: "work",
                calendarTitle: "Work",
                title: "Meeting \(id)",
                start: start,
                end: start.addingTimeInterval(1_800),
                links: [invite]
            )
            meeting.invitation = invite
            meeting.engine = .guest
            return meeting
        }

        let oldMeeting = makeMeeting(id: "old-45d", start: oldDayStart.addingTimeInterval(36_000))
        let recentMeeting = makeMeeting(id: "recent-2d", start: recentPastDayStart.addingTimeInterval(36_000))
        let futureMeeting = makeMeeting(id: "future-10d", start: futureDayStart.addingTimeInterval(36_000))

        let reader = ParityCalendarReader(events: [oldMeeting, recentMeeting, futureMeeting])
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ParityNoopNetwork.self]
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: ParityRoomStorage(),
            notifications: ParityNotifications()
        )
        let calendarStore = CalendarMeetingStore(
            reader: reader,
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: sessionConfig)),
            preferences: prefs,
            storage: ParityRoomStorage(),
            reminders: reminders,
            isMac: true,
            clock: { now }
        )
        calendarStore.knownEngine = { _ in .guest }

        let attention = desktopTestAttention()
        let library = NativeDesktopLibrary(
            preferences: prefs,
            history: RoomHistoryStore(storage: ParityRoomStorage()),
            syncStorage: ParityRoomStorage(),
            cloudTransport: ParityNoCloud(),
            calendar: calendarStore,
            continuationTransport: ParityNoContinuation()
        )
        library.setup.suspendForMeeting()

        let workspace = NativeDesktopWorkspace(
            library: library,
            detect: { _ in .unknown },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(
                    destination: destination,
                    name: name,
                    title: title,
                    quiet: quiet,
                    engine: ParityNoopEngine()
                )
            },
            attention: attention
        )
        addTeardownBlock {
            _ = await workspace.leave()
            await MainActor.run { attention.stop() }
        }

        let store = attention.store
        await store.waitForMeetingLibrary()
        let oldSession = MeetingSessionRecord(
            title: "Recorded 45d Ago",
            startedAt: oldDayStart.addingTimeInterval(43_200),
            endedAt: oldDayStart.addingTimeInterval(45_000),
            state: .ended
        )
        try await store.meetingLibrary.store.upsertSession(oldSession)
        await store.meetingLibrary.refresh()

        calendarStore.refresh()
        for _ in 0..<40 where calendarStore.loading || calendarStore.meetings.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(calendarStore.meetings.count, 3)

        let cache = CalendarTimelineViewCache()
        let sessions = cache.sessionSnapshot(
            workspace: workspace,
            meetingLibrary: store.meetingLibrary,
            data: store.assistant,
            workspaceSync: workspace.workspaceSync,
            journal: store.meetingLibrary.workspaceJournal
        )

        let initial = cache.timelineSnapshot(
            sessions: sessions,
            calendar: calendarStore,
            roomHistory: library.history,
            filter: .all,
            includeEventsWithoutLinks: true,
            earliestVisibleDay: nil,
            displayCalendar: displayCalendar,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertGreaterThan(initial.hiddenEarlierCount, 0)
        XCTAssertTrue(initial.rows.contains(where: { row in
            if case .loadEarlier = row { return true }
            return false
        }))
        XCTAssertNotNil(initial.dayMarkers[oldDayStart])
        XCTAssertNotNil(initial.dayMarkers[recentPastDayStart])
        XCTAssertNotNil(initial.dayMarkers[futureDayStart])
        XCTAssertNil(initial.dayRowIDByDayStart[oldDayStart])
        XCTAssertNotNil(initial.dayRowIDByDayStart[recentPastDayStart])
        XCTAssertNotNil(initial.dayRowIDByDayStart[futureDayStart])
        XCTAssertEqual(initial.nearestDayStart(for: oldDayStart, calendar: displayCalendar), oldDayStart)

        let expanded = cache.timelineSnapshot(
            sessions: sessions,
            calendar: calendarStore,
            roomHistory: library.history,
            filter: .all,
            includeEventsWithoutLinks: true,
            earliestVisibleDay: oldDayStart,
            displayCalendar: displayCalendar,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(expanded.hiddenEarlierCount, 0)
        XCTAssertFalse(expanded.rows.contains(where: { row in
            if case .loadEarlier = row { return true }
            return false
        }))
        XCTAssertNotNil(expanded.dayRowIDByDayStart[oldDayStart])
    }
}
