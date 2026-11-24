import ConferenceCore
import Foundation
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
}
