import XCTest
@testable import ConferenceCore

final class UnifiedCalendarTimelineTests: XCTestCase {
    private var utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeMeeting(
        id: String,
        title: String,
        start: Date,
        end: Date,
        invitation: URL? = nil,
        engine: MeetingEngineKind? = .guest,
        seriesID: String = "series"
    ) -> CalendarMeeting {
        var meeting = CalendarMeeting(
            id: id,
            seriesID: seriesID,
            calendarID: "work",
            calendarTitle: "Work",
            title: title,
            start: start,
            end: end,
            links: invitation.map { [$0] } ?? []
        )
        meeting.invitation = invitation
        meeting.engine = invitation == nil ? nil : engine
        return meeting
    }

    func testAssociationAndRoomFallbackDeduplicateAttendedMeetings() {
        let now = date(2026, 11, 24, 15, 0)
        let invite1 = URL(string: "https://meet.example.test/calls/alpha")!
        let invite2 = URL(string: "https://meet.example.test/calls/beta")!
        let room1 = MeetingRoomIdentity(invite1, engine: .guest)!
        let room2 = MeetingRoomIdentity(invite2, engine: .guest)!

        let pastAttended = makeMeeting(
            id: "past-1",
            title: "Morning Standup",
            start: date(2026, 11, 24, 10, 0),
            end: date(2026, 11, 24, 10, 30),
            invitation: invite1,
            seriesID: "standup"
        )
        let pastFallback = makeMeeting(
            id: "past-2",
            title: "Design Review",
            start: date(2026, 11, 23, 14, 0),
            end: date(2026, 11, 23, 15, 0),
            invitation: invite2,
            seriesID: "design"
        )
        let upcoming = makeMeeting(
            id: "up-1",
            title: "Evening Sync",
            start: date(2026, 11, 24, 18, 0),
            end: date(2026, 11, 24, 18, 45),
            invitation: invite1,
            seriesID: "evening"
        )

        let assocSession = UnifiedCalendarSessionInput(
            id: UUID(),
            title: "Morning Standup",
            startedAt: date(2026, 11, 24, 10, 1),
            endedAt: date(2026, 11, 24, 10, 28),
            invitation: invite1,
            roomKey: room1.workspaceKey,
            calendarAssociation: MeetingCalendarAssociation(pastAttended, room: room1),
            summaryPreview: "Shipped calendar scrubber",
            openTasksCount: 2
        )
        let fallbackSession = UnifiedCalendarSessionInput(
            id: UUID(),
            title: "Design Review",
            startedAt: date(2026, 11, 23, 14, 5),
            endedAt: date(2026, 11, 23, 14, 50),
            invitation: invite2,
            roomKey: room2.workspaceKey,
            calendarAssociation: nil,
            summaryPreview: "Approved drafts"
        )
        let adHocSession = UnifiedCalendarSessionInput(
            id: UUID(),
            title: "Quick Ad-Hoc Call",
            startedAt: date(2026, 11, 23, 17, 0),
            endedAt: date(2026, 11, 23, 17, 20),
            invitation: URL(string: "https://meet.example.test/calls/adhoc")!,
            openTasksCount: 1
        )

        let result = UnifiedCalendarTimelineBuilder.build(
            meetings: [pastAttended, pastFallback, upcoming],
            sessions: [assocSession, fallbackSession, adHocSession],
            filter: .all,
            includeEventsWithoutLinks: false,
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.sections.count, 2)
        let nov23 = result.sections[0]
        let nov24 = result.sections[1]

        XCTAssertEqual(nov23.items.count, 2)
        if case .attended(let m, let s) = nov23.items[0].kind {
            XCTAssertEqual(m.id, "past-2")
            XCTAssertEqual(s.id, fallbackSession.id)
        } else {
            XCTFail("Expected fallback attended meeting")
        }
        if case .adHoc(let s) = nov23.items[1].kind {
            XCTAssertEqual(s.id, adHocSession.id)
        } else {
            XCTFail("Expected ad-hoc session")
        }

        XCTAssertEqual(nov24.items.count, 2)
        XCTAssertEqual(nov24.nowInsertionIndex, 1)
        if case .attended(let m, let s) = nov24.items[0].kind {
            XCTAssertEqual(m.id, "past-1")
            XCTAssertEqual(s.id, assocSession.id)
        } else {
            XCTFail("Expected associated attended meeting")
        }
        if case .upcoming(let m, _) = nov24.items[1].kind {
            XCTAssertEqual(m.id, "up-1")
        } else {
            XCTFail("Expected upcoming meeting")
        }

        let nov24Dots = result.dotsByDay[utcCalendar.startOfDay(for: now)]
        XCTAssertEqual(nov24Dots?.recordedCount, 1)
        XCTAssertEqual(nov24Dots?.upcomingCount, 1)
        XCTAssertEqual(nov24Dots?.hasOpenTasks, true)
    }

    func testLinklessToggleControlsVisibilityWithoutTouchingAdHocSessions() {
        let now = date(2026, 11, 24, 15, 0)
        let linklessPast = makeMeeting(
            id: "offline-1",
            title: "1-on-1 in Room B",
            start: date(2026, 11, 24, 11, 0),
            end: date(2026, 11, 24, 11, 30),
            invitation: nil
        )
        let linklessUpcoming = makeMeeting(
            id: "offline-2",
            title: "Coffee Chat",
            start: date(2026, 11, 25, 10, 0),
            end: date(2026, 11, 25, 10, 30),
            invitation: nil
        )
        let adHoc = UnifiedCalendarSessionInput(
            id: UUID(),
            title: "Direct Call",
            startedAt: date(2026, 11, 24, 12, 0),
            endedAt: date(2026, 11, 24, 12, 15)
        )

        let hiddenResult = UnifiedCalendarTimelineBuilder.build(
            meetings: [linklessPast, linklessUpcoming],
            sessions: [adHoc],
            filter: .all,
            includeEventsWithoutLinks: false,
            now: now,
            calendar: utcCalendar
        )
        XCTAssertEqual(hiddenResult.sections.flatMap(\.items).count, 1)
        if case .adHoc(let session) = hiddenResult.sections.first?.items.first?.kind {
            XCTAssertEqual(session.id, adHoc.id)
        } else {
            XCTFail("Ad-hoc session should still show even when linkless events are off")
        }

        let shownResult = UnifiedCalendarTimelineBuilder.build(
            meetings: [linklessPast, linklessUpcoming],
            sessions: [adHoc],
            filter: .all,
            includeEventsWithoutLinks: true,
            now: now,
            calendar: utcCalendar
        )
        let allItems = shownResult.sections.flatMap(\.items)
        XCTAssertEqual(allItems.count, 3)
        XCTAssertTrue(allItems.contains(where: { $0.id == "cal:offline-1" && $0.isLinkless && $0.isPast }))
        XCTAssertTrue(allItems.contains(where: { $0.id == "cal:offline-2" && $0.isLinkless && !$0.isPast }))
    }

    func testFilterPastOrdersNewestDayFirstAndNowAnchorAppearsWhenTodayHasNoItems() {
        let now = date(2026, 11, 24, 15, 0)
        let invite = URL(string: "https://meet.example.test/calls/room")!
        let pastDay1 = makeMeeting(
            id: "p1",
            title: "Old",
            start: date(2026, 11, 20, 10, 0),
            end: date(2026, 11, 20, 10, 30),
            invitation: invite
        )
        let pastDay2 = makeMeeting(
            id: "p2",
            title: "Newer",
            start: date(2026, 11, 22, 10, 0),
            end: date(2026, 11, 22, 10, 30),
            invitation: invite
        )
        let futureDay = makeMeeting(
            id: "f1",
            title: "Future",
            start: date(2026, 11, 26, 10, 0),
            end: date(2026, 11, 26, 10, 30),
            invitation: invite
        )

        let pastOnly = UnifiedCalendarTimelineBuilder.build(
            meetings: [pastDay1, pastDay2, futureDay],
            sessions: [],
            filter: .past,
            now: now,
            calendar: utcCalendar
        )
        XCTAssertEqual(pastOnly.sections.map(\.dayStart), [
            date(2026, 11, 22, 0, 0),
            date(2026, 11, 20, 0, 0),
        ])
        XCTAssertNil(pastOnly.sections.first?.nowInsertionIndex)

        let all = UnifiedCalendarTimelineBuilder.build(
            meetings: [pastDay1, pastDay2, futureDay],
            sessions: [],
            filter: .all,
            now: now,
            calendar: utcCalendar
        )
        let todaySection = all.sections.first { utcCalendar.isDate($0.dayStart, inSameDayAs: now) }
        XCTAssertEqual(todaySection?.items.isEmpty, true)
        XCTAssertEqual(todaySection?.nowInsertionIndex, 0)
    }

    func testCalendarMeetingDraftValidationRejectsNonPositiveDuration() throws {
        let start = date(2026, 11, 24, 18, 0)
        let invalid = CalendarMeetingDraft(title: "Bad", startAt: start, endAt: start)
        XCTAssertThrowsError(try CalendarMeetingWriter.validateDraft(invalid)) { error in
            XCTAssertEqual(error as? CalendarMeetingWriteError, .invalidDateRange)
        }

        let valid = CalendarMeetingDraft(
            title: "Good",
            startAt: start,
            endAt: start.addingTimeInterval(1800)
        )
        XCTAssertNoThrow(try CalendarMeetingWriter.validateDraft(valid))
    }
}
