import Foundation

public enum UnifiedCalendarFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case past
    case upcoming

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return L("All")
        case .past: return L("Past")
        case .upcoming: return L("Planned")
        }
    }
}

public struct CalendarDayDotSummary: Equatable, Sendable {
    public let dayStart: Date
    public var recordedCount: Int
    public var upcomingCount: Int
    public var missedCount: Int
    public var hasOpenTasks: Bool

    public init(
        dayStart: Date,
        recordedCount: Int = 0,
        upcomingCount: Int = 0,
        missedCount: Int = 0,
        hasOpenTasks: Bool = false
    ) {
        self.dayStart = dayStart
        self.recordedCount = recordedCount
        self.upcomingCount = upcomingCount
        self.missedCount = missedCount
        self.hasOpenTasks = hasOpenTasks
    }

    public var totalCount: Int { recordedCount + upcomingCount + missedCount }
}

public struct UnifiedCalendarSessionInput: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let endedAt: Date?
    public let invitation: URL?
    public let roomKey: String?
    public let calendarAssociation: MeetingCalendarAssociation?
    public let summaryPreview: String?
    public let openTasksCount: Int
    public let hasNotes: Bool
    public let isLive: Bool

    public init(
        id: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        invitation: URL? = nil,
        roomKey: String? = nil,
        calendarAssociation: MeetingCalendarAssociation? = nil,
        summaryPreview: String? = nil,
        openTasksCount: Int = 0,
        hasNotes: Bool = false,
        isLive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.invitation = invitation
        self.roomKey = roomKey
        self.calendarAssociation = calendarAssociation
        self.summaryPreview = summaryPreview
        self.openTasksCount = openTasksCount
        self.hasNotes = hasNotes
        self.isLive = isLive
    }
}

public enum UnifiedCalendarItemKind: Equatable, Sendable {
    case attended(meeting: CalendarMeeting, session: UnifiedCalendarSessionInput)
    case adHoc(session: UnifiedCalendarSessionInput)
    case unattended(meeting: CalendarMeeting)
    case upcoming(meeting: CalendarMeeting, linkedSession: UnifiedCalendarSessionInput?)
}

public struct UnifiedCalendarItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let sortDate: Date
    public let endDate: Date?
    public let title: String
    public let isPast: Bool
    public let isLinkless: Bool
    public let kind: UnifiedCalendarItemKind

    public init(
        id: String,
        sortDate: Date,
        endDate: Date?,
        title: String,
        isPast: Bool,
        isLinkless: Bool,
        kind: UnifiedCalendarItemKind
    ) {
        self.id = id
        self.sortDate = sortDate
        self.endDate = endDate
        self.title = title
        self.isPast = isPast
        self.isLinkless = isLinkless
        self.kind = kind
    }
}

public struct UnifiedCalendarDaySection: Identifiable, Equatable, Sendable {
    public var id: Date { dayStart }
    public let dayStart: Date
    public let items: [UnifiedCalendarItem]
    public let nowInsertionIndex: Int?

    public init(dayStart: Date, items: [UnifiedCalendarItem], nowInsertionIndex: Int? = nil) {
        self.dayStart = dayStart
        self.items = items
        self.nowInsertionIndex = nowInsertionIndex
    }
}

public enum UnifiedCalendarTimelineBuilder {
    public static func build(
        meetings: [CalendarMeeting],
        sessions: [UnifiedCalendarSessionInput],
        filter: UnifiedCalendarFilter = .all,
        includeEventsWithoutLinks: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (sections: [UnifiedCalendarDaySection], dotsByDay: [Date: CalendarDayDotSummary]) {
        var uniqueSessions: [UnifiedCalendarSessionInput] = []
        var seenSessionIDs: Set<UUID> = []
        for session in sessions where seenSessionIDs.insert(session.id).inserted {
            uniqueSessions.append(session)
        }

        var uniqueMeetings: [CalendarMeeting] = []
        var seenMeetingIDs: Set<String> = []
        for meeting in meetings.sorted(by: { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }) {
            if seenMeetingIDs.insert(meeting.id).inserted {
                uniqueMeetings.append(meeting)
            }
        }

        var matchedSessionByMeetingID: [String: UnifiedCalendarSessionInput] = [:]
        var claimedSessionIDs: Set<UUID> = []

        // Pass 1: Exact calendar occurrence association match.
        for meeting in uniqueMeetings {
            let meetingOccID = occurrenceID(for: meeting)
            let candidates = uniqueSessions.filter { session in
                guard !claimedSessionIDs.contains(session.id),
                      let assoc = session.calendarAssociation else {
                    return false
                }
                return assoc.occurrenceID == meetingOccID
            }
            if let best = candidates.min(by: {
                abs($0.startedAt.timeIntervalSince(meeting.start)) < abs($1.startedAt.timeIntervalSince(meeting.start))
            }) {
                matchedSessionByMeetingID[meeting.id] = best
                claimedSessionIDs.insert(best.id)
            }
        }

        // Pass 2: Room-key + scheduled time-window overlap fallback for unlinked sessions.
        for meeting in uniqueMeetings where matchedSessionByMeetingID[meeting.id] == nil {
            guard let meetingRoomKey = resolvedRoomKey(for: meeting) else { continue }
            let windowStart = meeting.start.addingTimeInterval(-15 * 60)
            let windowEnd = meeting.end.addingTimeInterval(MeetingCalendarAssociation.rejoinGrace)
            let candidates = uniqueSessions.filter { session in
                guard !claimedSessionIDs.contains(session.id),
                      session.calendarAssociation == nil,
                      let sessionKey = resolvedRoomKey(for: session),
                      sessionKey == meetingRoomKey else {
                    return false
                }
                return session.startedAt >= windowStart && session.startedAt <= windowEnd
            }
            if let best = candidates.min(by: {
                abs($0.startedAt.timeIntervalSince(meeting.start)) < abs($1.startedAt.timeIntervalSince(meeting.start))
            }) {
                matchedSessionByMeetingID[meeting.id] = best
                claimedSessionIDs.insert(best.id)
            }
        }

        var allItems: [UnifiedCalendarItem] = []

        for meeting in uniqueMeetings {
            let isLinkless = !meeting.hasResolvedInvitation && meeting.links.isEmpty && !meeting.requiresChoice
            let matchedSession = matchedSessionByMeetingID[meeting.id]
            if isLinkless && !includeEventsWithoutLinks && matchedSession == nil {
                continue
            }

            let isPast = meeting.end <= now && matchedSession?.isLive != true
            let kind: UnifiedCalendarItemKind
            if !isPast {
                kind = .upcoming(meeting: meeting, linkedSession: matchedSession)
            } else if let matchedSession {
                kind = .attended(meeting: meeting, session: matchedSession)
            } else {
                kind = .unattended(meeting: meeting)
            }

            allItems.append(
                UnifiedCalendarItem(
                    id: "cal:" + meeting.id,
                    sortDate: meeting.start,
                    endDate: meeting.end,
                    title: meeting.title,
                    isPast: isPast,
                    isLinkless: isLinkless,
                    kind: kind
                )
            )
        }

        for session in uniqueSessions where !claimedSessionIDs.contains(session.id) {
            let isPast = !session.isLive
            allItems.append(
                UnifiedCalendarItem(
                    id: "session:" + session.id.uuidString,
                    sortDate: session.startedAt,
                    endDate: session.endedAt,
                    title: session.title,
                    isPast: isPast,
                    isLinkless: session.invitation == nil,
                    kind: .adHoc(session: session)
                )
            )
        }

        var dotsByDay: [Date: CalendarDayDotSummary] = [:]
        for item in allItems {
            let dayStart = calendar.startOfDay(for: item.sortDate)
            var summary = dotsByDay[dayStart] ?? CalendarDayDotSummary(dayStart: dayStart)
            switch item.kind {
            case .attended(_, let session):
                summary.recordedCount += 1
                if session.openTasksCount > 0 { summary.hasOpenTasks = true }
            case .adHoc(let session):
                if item.isPast {
                    summary.recordedCount += 1
                } else {
                    summary.upcomingCount += 1
                }
                if session.openTasksCount > 0 { summary.hasOpenTasks = true }
            case .unattended:
                summary.missedCount += 1
            case .upcoming(_, let linkedSession):
                summary.upcomingCount += 1
                if (linkedSession?.openTasksCount ?? 0) > 0 { summary.hasOpenTasks = true }
            }
            dotsByDay[dayStart] = summary
        }

        let filteredItems: [UnifiedCalendarItem]
        switch filter {
        case .all:
            filteredItems = allItems
        case .past:
            filteredItems = allItems.filter(\.isPast)
        case .upcoming:
            filteredItems = allItems.filter { !$0.isPast }
        }

        var grouped = Dictionary(grouping: filteredItems) { item in
            calendar.startOfDay(for: item.sortDate)
        }

        let todayStart = calendar.startOfDay(for: now)
        if filter == .all, !filteredItems.isEmpty, grouped[todayStart] == nil {
            grouped[todayStart] = []
        }

        let sortedDayStarts: [Date]
        switch filter {
        case .past:
            sortedDayStarts = grouped.keys.sorted(by: >)
        case .all, .upcoming:
            sortedDayStarts = grouped.keys.sorted(by: <)
        }

        let sections = sortedDayStarts.map { dayStart in
            let dayItems = (grouped[dayStart] ?? []).sorted { lhs, rhs in
                if lhs.sortDate != rhs.sortDate {
                    return filter == .past ? lhs.sortDate > rhs.sortDate : lhs.sortDate < rhs.sortDate
                }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id < rhs.id
            }
            let nowIndex: Int?
            if filter == .all && calendar.isDate(dayStart, inSameDayAs: todayStart) {
                nowIndex = dayItems.firstIndex(where: { !$0.isPast }) ?? dayItems.count
            } else {
                nowIndex = nil
            }
            return UnifiedCalendarDaySection(
                dayStart: dayStart,
                items: dayItems,
                nowInsertionIndex: nowIndex
            )
        }

        return (sections, dotsByDay)
    }

    private static func occurrenceID(for meeting: CalendarMeeting) -> String {
        let occurrence = meeting.originalOccurrenceStart ?? meeting.start
        return (meeting.externalSeriesID ?? meeting.seriesID) + "|" +
            String(Int64(occurrence.timeIntervalSince1970.rounded(.towardZero)))
    }

    private static func resolvedRoomKey(for meeting: CalendarMeeting) -> String? {
        if let key = meeting.roomIdentity?.workspaceKey { return key }
        for url in meeting.links {
            if let identity = MeetingRoomIdentity(url, engine: meeting.engine) {
                return identity.workspaceKey
            }
        }
        return nil
    }

    private static func resolvedRoomKey(for session: UnifiedCalendarSessionInput) -> String? {
        if let roomKey = session.roomKey, !roomKey.isEmpty { return roomKey }
        if let invitation = session.invitation, let identity = MeetingRoomIdentity(invitation) {
            return identity.workspaceKey
        }
        return session.calendarAssociation?.roomKey
    }
}
