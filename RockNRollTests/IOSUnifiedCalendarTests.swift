import ConferenceCore
import XCTest
@testable import RockNRoll

private final class IOSCalendarTestStorage: RoomHistoryStorage, ReminderStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

@MainActor
private final class IOSCalendarMockNotifications: ReminderNotifying {
    func authorization() async -> ReminderAuthorization { .notDetermined }
    func request(sensitive: Bool) async throws -> Bool { false }
    func pending() async -> [String: String] { [:] }
    func add(_ reminder: ReminderNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(occurrenceIDs: Set<String>) async {}
    func removeAllDelivered() async {}
}

private actor IOSRangeMockReader: CalendarReading {
    let defaultEvents: [CalendarMeeting]
    let rangeEvents: [CalendarMeeting]
    init(defaultEvents: [CalendarMeeting], rangeEvents: [CalendarMeeting]) {
        self.defaultEvents = defaultEvents
        self.rangeEvents = rangeEvents
    }
    func access() -> CalendarAccess { .allowed }
    func requestAccess() -> Bool { true }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot {
        CalendarSnapshot(
            calendars: [.init(id: "work", name: "Work", source: "iCloud")],
            meetings: defaultEvents.filter { selected.contains($0.calendarID) }
        )
    }
    func readRange(selected: Set<String>, interval: DateInterval, knownOrigins: Set<String>, aliases: [String: URL]) async -> [CalendarMeeting] {
        rangeEvents.filter { selected.contains($0.calendarID) && $0.end >= interval.start && $0.start <= interval.end }
    }
}

@MainActor
final class IOSUnifiedCalendarTests: XCTestCase {
    func testWorkspaceHubIncludesCalendarTab() {
        XCTAssertTrue(IOSWorkspaceHubTab.allCases.contains(.calendar))
        XCTAssertEqual(IOSWorkspaceHubTab.calendar.id, "calendar")
    }

    func testAllTimelineMeetingsMergesLoadedOlderMonthWithoutMutatingUpcoming() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = "IOSUnifiedCalendarTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "calendarMeetings.enabled")
        prefs.set(["work"], forKey: "calendarMeetings.selected")
        defer { prefs.removePersistentDomain(forName: suite) }

        var upcoming = CalendarMeeting(
            id: "up-1",
            seriesID: "s-up",
            calendarID: "work",
            calendarTitle: "Work",
            title: "Upcoming Meeting",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(5400)
        )
        upcoming.invitation = URL(string: "https://meet.example.test/up")!
        upcoming.engine = .guest

        let olderMonthDate = now.addingTimeInterval(-75 * 86_400)
        var older = CalendarMeeting(
            id: "old-1",
            seriesID: "s-old",
            calendarID: "work",
            calendarTitle: "Work",
            title: "Older Month Meeting",
            start: olderMonthDate,
            end: olderMonthDate.addingTimeInterval(1800)
        )
        older.invitation = URL(string: "https://meet.example.test/old")!
        older.engine = .guest

        let reader = IOSRangeMockReader(defaultEvents: [upcoming], rangeEvents: [older])
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: IOSCalendarTestStorage(),
            notifications: IOSCalendarMockNotifications()
        )
        let store = CalendarMeetingStore(
            reader: reader,
            detector: VendorEndpointResolver.makeDetector(),
            preferences: prefs,
            storage: IOSCalendarTestStorage(),
            reminders: reminders,
            isMac: false,
            clock: { now }
        )
        store.knownEngine = { _ in .guest }
        store.refresh()

        for _ in 0..<40 where store.loading || store.meetings.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(store.upcoming.map(\.id), ["up-1"])

        store.loadMonthIfNeeded(containing: olderMonthDate)
        for _ in 0..<40 where store.extraRangeMeetings.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(store.allTimelineMeetings.map(\.id), ["old-1", "up-1"])
        XCTAssertEqual(store.upcoming.map(\.id), ["up-1"])
    }

    func testHandleCreatedCalendarEventReloadsRememberedExtraMonthAfterRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = "IOSUnifiedCalendarTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "calendarMeetings.enabled")
        prefs.set(["work"], forKey: "calendarMeetings.selected")
        defer { prefs.removePersistentDomain(forName: suite) }

        var defaultUpcoming = CalendarMeeting(
            id: "up-default",
            seriesID: "s-up",
            calendarID: "work",
            calendarTitle: "Work",
            title: "Near Meeting",
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(5400)
        )
        defaultUpcoming.invitation = URL(string: "https://meet.example.test/up-default")!
        defaultUpcoming.engine = .guest

        let futureStart = now.addingTimeInterval(75 * 86_400)
        var farFutureCreated = CalendarMeeting(
            id: "far-created",
            seriesID: "s-far",
            calendarID: "work",
            calendarTitle: "Work",
            title: "Far Future Created Meeting",
            start: futureStart,
            end: futureStart.addingTimeInterval(1800)
        )
        farFutureCreated.invitation = URL(string: "https://meet.example.test/far-created")!
        farFutureCreated.engine = .guest

        let reader = IOSRangeMockReader(defaultEvents: [defaultUpcoming], rangeEvents: [farFutureCreated])
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: IOSCalendarTestStorage(),
            notifications: IOSCalendarMockNotifications()
        )
        let store = CalendarMeetingStore(
            reader: reader,
            detector: VendorEndpointResolver.makeDetector(),
            preferences: prefs,
            storage: IOSCalendarTestStorage(),
            reminders: reminders,
            isMac: false,
            clock: { now }
        )
        store.knownEngine = { _ in .guest }

        store.handleCreatedCalendarEvent(calendarID: "work", eventStart: futureStart)

        for _ in 0..<60 where store.loading || store.meetings.isEmpty || store.extraRangeMeetings.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(store.upcoming.map(\.id), ["up-default"])
        XCTAssertEqual(store.allTimelineMeetings.map(\.id), ["up-default", "far-created"])
    }
}
