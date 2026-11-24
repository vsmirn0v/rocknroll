import ConferenceCore
import MeetingEngine
import SwiftUI

private struct CalendarScrollRequest: Equatable {
    let id = UUID()
    let targetID: String
    let anchor: UnitPoint
    let animated: Bool
}

struct LastOutcomeDisplay: Equatable {
    let summaryText: String
    let pendingTasksCount: Int
    let totalTasksCount: Int
}

struct AttendedRowModel: Equatable {
    let id: String
    let meeting: CalendarMeeting
    let sessionID: UUID
    let timeAndCalendarText: String
    let summaryPreview: String?
    let openTasksCount: Int
    let showJoin: Bool
}

struct AdHocRowModel: Equatable {
    let id: String
    let sessionID: UUID
    let title: String
    let timeText: String
    let summaryPreview: String?
    let openTasksCount: Int
}

struct UnattendedRowModel: Equatable {
    let id: String
    let meeting: CalendarMeeting
    let timeAndCalendarText: String
    let isLinkless: Bool
}

struct UpcomingRowModel: Equatable {
    let id: String
    let meeting: CalendarMeeting
    let linkedSessionID: UUID?
    let isLinkless: Bool
    let isScheduledNow: Bool
    let isStarred: Bool
    let subtitleText: String
    let roomDetailText: String?
    let lastOutcome: LastOutcomeDisplay?
}

enum CalendarTimelineRow: Identifiable, Equatable {
    case dayHeader(id: String, dayStart: Date, title: String, isToday: Bool)
    case nowDivider(timeLabel: String)
    case emptyToday
    case attended(AttendedRowModel)
    case adHoc(AdHocRowModel)
    case unattended(UnattendedRowModel)
    case upcoming(UpcomingRowModel)
    case loadEarlier(hiddenCount: Int, nextAnchorDay: Date)

    var id: String {
        switch self {
        case .dayHeader(let id, _, _, _): return id
        case .nowDivider: return "calendar.now"
        case .emptyToday: return "calendar.emptyToday"
        case .attended(let model): return model.id
        case .adHoc(let model): return model.id
        case .unattended(let model): return model.id
        case .upcoming(let model): return model.id
        case .loadEarlier: return "calendar.loadEarlier"
        }
    }
}

/// Memoizes session inputs, outcome lookup indices, flattened rows, and date formatting
/// across SwiftUI renders without publishing state during view evaluation.
@MainActor
final class CalendarTimelineViewCache: ObservableObject {
    struct SessionKey: Equatable {
        let cardsRevision: UInt64
        let sessionsRevision: UInt64
        let outcomesRevision: UInt64
        let historyTopologyRevision: UInt64
        let replicaRevision: UInt64
        let liveSessionIDs: Set<UUID>
        let taskArchiveDates: [UUID: Date]
        let taskProfile: PersonalTaskProfile
    }

    fileprivate struct IndexedOutcome {
        let orderIndex: Int
        let endedAt: Date
        let seriesID: String?
        let display: LastOutcomeDisplay
    }

    struct SessionSnapshot {
        let key: SessionKey
        let sessions: [UnifiedCalendarSessionInput]
        private let indexedOutcomes: [IndexedOutcome]
        private let outcomesBySeriesID: [String: [Int]]
        private let outcomesByInvitation: [URL: [Int]]

        fileprivate init(
            key: SessionKey,
            indexedOutcomes: [IndexedOutcome],
            outcomesBySeriesID: [String: [Int]],
            outcomesByInvitation: [URL: [Int]],
            sessions: [UnifiedCalendarSessionInput]
        ) {
            self.key = key
            self.indexedOutcomes = indexedOutcomes
            self.outcomesBySeriesID = outcomesBySeriesID
            self.outcomesByInvitation = outcomesByInvitation
            self.sessions = sessions
        }

        func lastOutcome(invitation: URL?, series: String?, before: Date) -> LastOutcomeDisplay? {
            var bestOrder: Int?

            if let series, let indices = outcomesBySeriesID[series] {
                for idx in indices {
                    if indexedOutcomes[idx].endedAt < before {
                        bestOrder = idx
                        break
                    }
                }
            }

            if let invitation, let indices = outcomesByInvitation[invitation] {
                for idx in indices {
                    if let currentBest = bestOrder, idx >= currentBest {
                        break
                    }
                    let entry = indexedOutcomes[idx]
                    let conflictingSeries = series != nil && entry.seriesID != nil && entry.seriesID != series
                    if !conflictingSeries && entry.endedAt < before {
                        bestOrder = idx
                        break
                    }
                }
            }

            return bestOrder.map { indexedOutcomes[$0].display }
        }
    }

    struct TimelineKey: Equatable {
        let sessionKey: SessionKey
        let calendarTimelineRevision: UInt64
        let minuteBucket: Int64
        let filter: UnifiedCalendarFilter
        let includeEventsWithoutLinks: Bool
        let earliestVisibleDay: Date?
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
        let localeIdentifier: String
        let starredSignature: [String]
    }

    struct TimelineSnapshot {
        let key: TimelineKey
        let rows: [CalendarTimelineRow]
        let dayMarkers: [Date: CompactCalendarDayMarker]
        let dayRowIDByDayStart: [Date: String]
        let sortedDayStarts: [Date]
        let allSortedDayStarts: [Date]
        let hiddenEarlierCount: Int
        let todayRowID: String?
        let hasNowDivider: Bool

        func nearestDayStart(for date: Date, calendar: Calendar) -> Date? {
            let target = calendar.startOfDay(for: date)
            if dayRowIDByDayStart[target] != nil {
                return target
            }
            return allSortedDayStarts.min(by: {
                abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target))
            })
        }

        func exactDayRowID(for date: Date, calendar: Calendar) -> String? {
            let target = calendar.startOfDay(for: date)
            return dayRowIDByDayStart[target]
        }

        func nearestDayRowID(for date: Date, calendar: Calendar) -> String? {
            let target = calendar.startOfDay(for: date)
            if let exact = dayRowIDByDayStart[target] {
                return exact
            }
            guard let nearest = sortedDayStarts.min(by: {
                abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target))
            }) else {
                return nil
            }
            return dayRowIDByDayStart[nearest]
        }
    }

    private struct FormatterKey: Equatable {
        let localeIdentifier: String
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
    }

    private var sessionCache: SessionSnapshot?
    private var timelineCache: TimelineSnapshot?

    private var formatterKey: FormatterKey?
    private let dayMonthFormatter = DateFormatter()
    private let dayMonthYearFormatter = DateFormatter()
    private let timeOnlyFormatter = DateFormatter()
    private let dateShortTimeFormatter = DateFormatter()
    private let dateAbbreviatedFormatter = DateFormatter()

    func sessionSnapshot(
        workspace: NativeDesktopWorkspace,
        meetingLibrary: MeetingLibraryController,
        data: AssistantDataStore,
        workspaceSync: MacWorkspaceSyncCoordinator,
        journal: MeetingWorkspaceJournal
    ) -> SessionSnapshot {
        let liveIDs = Set(
            workspace.attention.meetings().flatMap {
                [$0.sessionID, $0.workspaceSessionID] + $0.segments.map(\.sessionID)
            }
        )
        let key = SessionKey(
            cardsRevision: meetingLibrary.cardsRevision,
            sessionsRevision: journal.sessionsRevision,
            outcomesRevision: data.outcomesRevision,
            historyTopologyRevision: workspaceSync.historyTopologyRevision,
            replicaRevision: workspaceSync.replicaRevision,
            liveSessionIDs: liveIDs,
            taskArchiveDates: data.taskArchiveDates,
            taskProfile: data.taskProfile
        )
        if let sessionCache, sessionCache.key == key {
            return sessionCache
        }

        let taskOnlyOutcomeIDs = Set(meetingLibrary.cards.compactMap { $0.outcomeState == .notStarted ? $0.outcomeID : nil })
        var outcomesByID: [UUID: MeetingOutcome] = [:]
        outcomesByID.reserveCapacity(data.outcomes.count)
        var indexedOutcomes: [IndexedOutcome] = []
        indexedOutcomes.reserveCapacity(data.outcomes.count)
        var outcomesBySeriesID: [String: [Int]] = [:]
        var outcomesByInvitation: [URL: [Int]] = [:]

        for outcome in data.outcomes {
            if outcomesByID[outcome.id] == nil {
                outcomesByID[outcome.id] = outcome
            }
            guard !taskOnlyOutcomeIDs.contains(outcome.id) else { continue }
            let operational = outcome.tasks.filter { data.isTaskOperational($0) }
            let pending = operational.reduce(0) { $0 + ($1.done ? 0 : 1) }
            let summaryText = MeetingOutcomePrompt.displayText(outcome.summary)
            let orderIndex = indexedOutcomes.count
            indexedOutcomes.append(
                IndexedOutcome(
                    orderIndex: orderIndex,
                    endedAt: outcome.endedAt,
                    seriesID: outcome.seriesID,
                    display: LastOutcomeDisplay(
                        summaryText: summaryText,
                        pendingTasksCount: pending,
                        totalTasksCount: operational.count
                    )
                )
            )
            if let seriesID = outcome.seriesID {
                outcomesBySeriesID[seriesID, default: []].append(orderIndex)
            }
            if let invitation = outcome.invitation {
                outcomesByInvitation[invitation, default: []].append(orderIndex)
            }
        }

        let savedIDs = Set(meetingLibrary.cards.map(\.sessionID))
        let journalOnly = journal.sessions.filter { $0.endedAt != nil && !savedIDs.contains($0.id) }.map { entry in
            MeetingLibraryCard(
                sessionID: entry.id,
                title: entry.title,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                state: .ended,
                hasNotes: false,
                noteID: nil,
                noteRevision: 0,
                notePreview: nil,
                outcomeID: nil,
                outcomeState: .notStarted,
                updatedAt: entry.endedAt ?? entry.startedAt,
                startProvenance: .recorded,
                outcomeEndFallback: nil
            )
        }

        let sessions: [UnifiedCalendarSessionInput] = (meetingLibrary.cards + journalOnly)
            .filter { card in
                workspaceSync.canonicalSessionID(card.sessionID) == card.sessionID &&
                    workspaceSync.historySessionID(card.sessionID) == card.sessionID
            }
            .map { card in
                let outcome = card.outcomeID.flatMap { outcomesByID[$0] }
                let association = workspaceSync.association(for: card.sessionID)
                let summaryRaw = outcome.map { MeetingOutcomePrompt.displayText($0.summary).trimmingCharacters(in: .whitespacesAndNewlines) }
                let summaryPreview = (summaryRaw?.isEmpty == false ? summaryRaw : nil)
                    ?? card.notePreview?.trimmingCharacters(in: .whitespacesAndNewlines)
                let openTasks = outcome?.tasks.filter { !$0.done }.count ?? 0
                return UnifiedCalendarSessionInput(
                    id: card.sessionID,
                    title: card.title,
                    startedAt: card.effectiveDate?.date ?? card.startedAt,
                    endedAt: card.endedAt,
                    invitation: outcome?.invitation,
                    roomKey: association?.roomKey,
                    calendarAssociation: association,
                    summaryPreview: summaryPreview?.isEmpty == false ? summaryPreview : nil,
                    openTasksCount: openTasks,
                    hasNotes: card.hasNotes,
                    isLive: liveIDs.contains(card.sessionID)
                )
            }

        let snapshot = SessionSnapshot(
            key: key,
            indexedOutcomes: indexedOutcomes,
            outcomesBySeriesID: outcomesBySeriesID,
            outcomesByInvitation: outcomesByInvitation,
            sessions: sessions
        )
        sessionCache = snapshot
        return snapshot
    }

    func timelineSnapshot(
        sessions: SessionSnapshot,
        calendar: CalendarMeetingStore,
        roomHistory: RoomHistoryStore,
        filter: UnifiedCalendarFilter,
        includeEventsWithoutLinks: Bool,
        earliestVisibleDay: Date?,
        displayCalendar: Calendar,
        locale: Locale
    ) -> TimelineSnapshot {
        let now = calendar.now
        let normalizedEarliestDay = earliestVisibleDay.map { displayCalendar.startOfDay(for: $0) }
        let starredRooms = roomHistory.rooms.filter(\.isStarred)
        let starredSignature = starredRooms.map { "\($0.id)|\($0.joinURL.absoluteString)" }
        let key = TimelineKey(
            sessionKey: sessions.key,
            calendarTimelineRevision: calendar.timelineRevision,
            minuteBucket: Int64((now.timeIntervalSinceReferenceDate / 60).rounded(.towardZero)),
            filter: filter,
            includeEventsWithoutLinks: includeEventsWithoutLinks,
            earliestVisibleDay: normalizedEarliestDay,
            calendarIdentifier: displayCalendar.identifier,
            timeZoneIdentifier: displayCalendar.timeZone.identifier,
            localeIdentifier: locale.identifier,
            starredSignature: starredSignature
        )
        if let timelineCache, timelineCache.key == key {
            return timelineCache
        }

        ensureFormatters(locale: locale, calendar: displayCalendar)

        let built = UnifiedCalendarTimelineBuilder.build(
            meetings: calendar.allTimelineMeetings,
            sessions: sessions.sessions,
            filter: filter,
            includeEventsWithoutLinks: includeEventsWithoutLinks,
            now: now,
            calendar: displayCalendar
        )

        let dayMarkers = built.dotsByDay.mapValues { summary in
            CompactCalendarDayMarker(
                primaryCount: summary.upcomingCount,
                secondaryCount: summary.recordedCount + summary.missedCount,
                hasAccent: summary.hasOpenTasks
            )
        }

        let todayStart = displayCalendar.startOfDay(for: now)
        let defaultCutoff: Date?
        switch filter {
        case .all:
            defaultCutoff = displayCalendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        case .past:
            defaultCutoff = displayCalendar.date(byAdding: .day, value: -14, to: todayStart) ?? todayStart
        case .upcoming:
            defaultCutoff = nil
        }
        let effectiveCutoff: Date? = defaultCutoff.map { baseCutoff in
            if let normalizedEarliestDay {
                return min(normalizedEarliestDay, baseCutoff)
            }
            return baseCutoff
        }

        let allSortedDayStarts = built.sections.map(\.dayStart)
        let visibleSections: [UnifiedCalendarDaySection]
        let hiddenEarlierSections: [UnifiedCalendarDaySection]
        let nextLoadEarlierAnchorDay: Date?

        switch filter {
        case .all:
            if let effectiveCutoff {
                hiddenEarlierSections = built.sections.filter { $0.dayStart < effectiveCutoff }
                visibleSections = built.sections.filter { $0.dayStart >= effectiveCutoff }
                nextLoadEarlierAnchorDay = hiddenEarlierSections.last?.dayStart
            } else {
                hiddenEarlierSections = []
                visibleSections = built.sections
                nextLoadEarlierAnchorDay = nil
            }
        case .past:
            if let effectiveCutoff {
                var visible: [UnifiedCalendarDaySection] = []
                var hidden: [UnifiedCalendarDaySection] = []
                var visibleItemCount = 0
                for section in built.sections {
                    if hidden.isEmpty && (section.dayStart >= effectiveCutoff || visibleItemCount < 15) {
                        visible.append(section)
                        visibleItemCount += section.items.count
                    } else {
                        hidden.append(section)
                    }
                }
                visibleSections = visible
                hiddenEarlierSections = hidden
                nextLoadEarlierAnchorDay = hidden.first?.dayStart
            } else {
                hiddenEarlierSections = []
                visibleSections = built.sections
                nextLoadEarlierAnchorDay = nil
            }
        case .upcoming:
            hiddenEarlierSections = []
            visibleSections = built.sections
            nextLoadEarlierAnchorDay = nil
        }

        let hiddenEarlierCount = hiddenEarlierSections.reduce(0) { $0 + $1.items.count }

        var starredURLs: Set<URL> = []
        var starredIdentities: Set<MeetingRoomIdentity> = []
        for room in starredRooms {
            starredURLs.insert(room.invitationURL)
            starredURLs.insert(room.joinURL)
            if let identity = MeetingRoomIdentity(room.joinURL, engine: room.engine) {
                starredIdentities.insert(identity)
            }
        }

        var rows: [CalendarTimelineRow] = []
        rows.reserveCapacity(visibleSections.count * 2 + visibleSections.reduce(0) { $0 + $1.items.count } + 1)
        if filter == .all, hiddenEarlierCount > 0, let anchorDay = nextLoadEarlierAnchorDay {
            rows.append(.loadEarlier(hiddenCount: hiddenEarlierCount, nextAnchorDay: anchorDay))
        }

        var dayRowIDByDayStart: [Date: String] = [:]
        var sortedDayStarts: [Date] = []
        var todayRowID: String?
        var hasNowDivider = false
        let nowDividerTime = timeOnlyFormatter.string(from: now)

        for section in visibleSections {
            let isToday = displayCalendar.isDateInToday(section.dayStart)
            let dayID = "day:\(Int64(section.dayStart.timeIntervalSince1970))"
            dayRowIDByDayStart[section.dayStart] = dayID
            sortedDayStarts.append(section.dayStart)
            if isToday {
                todayRowID = dayID
            }
            rows.append(
                .dayHeader(
                    id: dayID,
                    dayStart: section.dayStart,
                    title: formatDayHeaderTitle(section.dayStart, calendar: displayCalendar),
                    isToday: isToday
                )
            )

            if section.items.isEmpty, section.nowInsertionIndex != nil {
                hasNowDivider = true
                rows.append(.nowDivider(timeLabel: nowDividerTime))
                rows.append(.emptyToday)
            } else {
                for (index, item) in section.items.enumerated() {
                    if section.nowInsertionIndex == index {
                        hasNowDivider = true
                        rows.append(.nowDivider(timeLabel: nowDividerTime))
                    }
                    rows.append(
                        makeRow(
                            item: item,
                            sessions: sessions,
                            now: now,
                            displayCalendar: displayCalendar,
                            starredURLs: starredURLs,
                            starredIdentities: starredIdentities
                        )
                    )
                }
                if section.nowInsertionIndex == section.items.count {
                    hasNowDivider = true
                    rows.append(.nowDivider(timeLabel: nowDividerTime))
                }
            }
        }

        if filter == .past, hiddenEarlierCount > 0, let anchorDay = nextLoadEarlierAnchorDay {
            rows.append(.loadEarlier(hiddenCount: hiddenEarlierCount, nextAnchorDay: anchorDay))
        }

        let snapshot = TimelineSnapshot(
            key: key,
            rows: rows,
            dayMarkers: dayMarkers,
            dayRowIDByDayStart: dayRowIDByDayStart,
            sortedDayStarts: sortedDayStarts,
            allSortedDayStarts: allSortedDayStarts,
            hiddenEarlierCount: hiddenEarlierCount,
            todayRowID: todayRowID,
            hasNowDivider: hasNowDivider
        )
        timelineCache = snapshot
        return snapshot
    }

    private func ensureFormatters(locale: Locale, calendar: Calendar) {
        let key = FormatterKey(
            localeIdentifier: locale.identifier,
            calendarIdentifier: calendar.identifier,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        guard formatterKey != key else { return }
        formatterKey = key

        var localizedCal = calendar
        localizedCal.locale = locale

        for formatter in [dayMonthFormatter, dayMonthYearFormatter, timeOnlyFormatter, dateShortTimeFormatter, dateAbbreviatedFormatter] {
            formatter.locale = locale
            formatter.calendar = localizedCal
            formatter.timeZone = calendar.timeZone
        }

        dayMonthFormatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        dayMonthYearFormatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")

        timeOnlyFormatter.dateStyle = .none
        timeOnlyFormatter.timeStyle = .short

        dateShortTimeFormatter.dateStyle = .medium
        dateShortTimeFormatter.timeStyle = .short

        dateAbbreviatedFormatter.dateStyle = .medium
        dateAbbreviatedFormatter.timeStyle = .none
    }

    private func makeRow(
        item: UnifiedCalendarItem,
        sessions: SessionSnapshot,
        now: Date,
        displayCalendar: Calendar,
        starredURLs: Set<URL>,
        starredIdentities: Set<MeetingRoomIdentity>
    ) -> CalendarTimelineRow {
        switch item.kind {
        case .attended(let meeting, let session):
            let timeText = formatTimeRange(meeting, calendar: displayCalendar)
                + (meeting.calendarTitle.isEmpty ? "" : " · " + meeting.calendarTitle)
            return .attended(
                AttendedRowModel(
                    id: item.id,
                    meeting: meeting,
                    sessionID: session.id,
                    timeAndCalendarText: timeText,
                    summaryPreview: session.summaryPreview,
                    openTasksCount: session.openTasksCount,
                    showJoin: meeting.hasResolvedInvitation
                )
            )
        case .adHoc(let session):
            return .adHoc(
                AdHocRowModel(
                    id: item.id,
                    sessionID: session.id,
                    title: session.title,
                    timeText: formatSessionTimeLabel(startedAt: session.startedAt, endedAt: session.endedAt),
                    summaryPreview: session.summaryPreview,
                    openTasksCount: session.openTasksCount
                )
            )
        case .unattended(let meeting):
            let timeText = formatTimeRange(meeting, calendar: displayCalendar)
                + (meeting.calendarTitle.isEmpty ? "" : " · " + meeting.calendarTitle)
            return .unattended(
                UnattendedRowModel(
                    id: item.id,
                    meeting: meeting,
                    timeAndCalendarText: timeText,
                    isLinkless: item.isLinkless
                )
            )
        case .upcoming(let meeting, let linkedSession):
            let isScheduledNow = meeting.isScheduledNow(now)
            let isStarred: Bool
            if let url = meeting.invitation {
                if starredURLs.contains(url) {
                    isStarred = true
                } else if let identity = MeetingRoomIdentity(url, engine: meeting.engine) {
                    isStarred = starredIdentities.contains(identity)
                } else {
                    isStarred = false
                }
            } else {
                isStarred = false
            }
            let roomDetailText: String? = meeting.invitation.map { url in
                let identity = MeetingRoomIdentity(url, engine: meeting.engine)
                return [url.host, identity?.room].compactMap { $0 }.joined(separator: " · ")
            }
            let lastOutcome = sessions.lastOutcome(
                invitation: meeting.invitation,
                series: meeting.seriesID,
                before: meeting.start
            )
            return .upcoming(
                UpcomingRowModel(
                    id: item.id,
                    meeting: meeting,
                    linkedSessionID: linkedSession?.id,
                    isLinkless: item.isLinkless,
                    isScheduledNow: isScheduledNow,
                    isStarred: isStarred,
                    subtitleText: formatSubtitle(meeting, at: now, roomTitle: meeting.title, calendar: displayCalendar),
                    roomDetailText: roomDetailText?.isEmpty == false ? roomDetailText : nil,
                    lastOutcome: lastOutcome
                )
            )
        }
    }

    private func formatDayHeaderTitle(_ dayStart: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(dayStart) {
            return L("Today") + " · " + dayMonthFormatter.string(from: dayStart)
        }
        if calendar.isDateInYesterday(dayStart) {
            return L("Yesterday") + " · " + dayMonthFormatter.string(from: dayStart)
        }
        return dayMonthYearFormatter.string(from: dayStart)
    }

    private func formatTimeRange(_ meeting: CalendarMeeting, calendar: Calendar) -> String {
        if meeting.allDay {
            return dateAbbreviatedFormatter.string(from: meeting.start) + " · " + L("All day")
        }
        let start = dateShortTimeFormatter.string(from: meeting.start)
        let end = calendar.isDate(meeting.start, inSameDayAs: meeting.end)
            ? timeOnlyFormatter.string(from: meeting.end)
            : dateShortTimeFormatter.string(from: meeting.end)
        return start + " – " + end
    }

    private func formatSubtitle(_ meeting: CalendarMeeting, at now: Date, roomTitle: String, calendar: Calendar) -> String {
        let timing = meeting.end <= now ? L("Ended") : (meeting.isScheduledNow(now) ? L("Scheduled now") : L("Upcoming"))
        var parts = [timing + " · " + formatTimeRange(meeting, calendar: calendar)]
        if meeting.title != roomTitle {
            parts.append(meeting.title)
        }
        if !meeting.calendarTitle.isEmpty {
            parts.append(meeting.calendarTitle)
        }
        return parts.joined(separator: "\n")
    }

    private func formatSessionTimeLabel(startedAt: Date, endedAt: Date?) -> String {
        let start = dateShortTimeFormatter.string(from: startedAt)
        if let endedAt, endedAt > startedAt {
            let minutes = max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
            return start + " · " + L("%ld min", minutes)
        }
        return start
    }
}

struct NativeDesktopCalendarView: View {
    let workspace: NativeDesktopWorkspace
    let library: NativeDesktopLibrary
    private let cache: CalendarTimelineViewCache
    @ObservedObject private var calendar: CalendarMeetingStore
    @ObservedObject private var roomHistory: RoomHistoryStore
    @ObservedObject private var meetingLibrary: MeetingLibraryController
    @ObservedObject private var data: AssistantDataStore
    @ObservedObject private var workspaceSync: MacWorkspaceSyncCoordinator
    @ObservedObject private var journal: MeetingWorkspaceJournal

    @State private var filter: UnifiedCalendarFilter = .all
    @AppStorage("calendar.showEventsWithoutLinks") private var showEventsWithoutLinks = false
    @State private var earliestVisibleDay: Date?
    @State private var displayedMonth = Date()
    @State private var selectedDate: Date?
    @State private var pendingScrollDay: Date?
    @State private var scrollRequest: CalendarScrollRequest?
    @State private var showingCreateMeeting = false
    @State private var didInitialScroll = false
    @State private var pendingScrollForFilterChange = false
    @State private var displayCalendar = Calendar.current
    @Environment(\.locale) private var locale

    @MainActor
    init(
        workspace: NativeDesktopWorkspace,
        library: NativeDesktopLibrary,
        cache: CalendarTimelineViewCache? = nil
    ) {
        self.workspace = workspace
        self.library = library
        self.cache = cache ?? CalendarTimelineViewCache()
        self._calendar = ObservedObject(wrappedValue: library.calendar)
        self._roomHistory = ObservedObject(wrappedValue: library.history)
        self._meetingLibrary = ObservedObject(wrappedValue: workspace.attention.store.meetingLibrary)
        self._data = ObservedObject(wrappedValue: workspace.attention.store.assistant)
        self._workspaceSync = ObservedObject(wrappedValue: workspace.workspaceSync)
        self._journal = ObservedObject(wrappedValue: workspace.attention.store.meetingLibrary.workspaceJournal)
    }

    private var favoriteRoomOptions: [FavoriteRoomOption] {
        roomHistory.rooms.map {
            FavoriteRoomOption(id: $0.id, title: $0.displayTitle, invitationURL: $0.joinURL)
        }
    }

    var body: some View {
        let sessions = cache.sessionSnapshot(
            workspace: workspace,
            meetingLibrary: meetingLibrary,
            data: data,
            workspaceSync: workspaceSync,
            journal: journal
        )
        let snapshot = cache.timelineSnapshot(
            sessions: sessions,
            calendar: calendar,
            roomHistory: roomHistory,
            filter: filter,
            includeEventsWithoutLinks: showEventsWithoutLinks,
            earliestVisibleDay: earliestVisibleDay,
            displayCalendar: displayCalendar,
            locale: locale
        )

        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if wide {
                    leftNavigator(snapshot: snapshot)
                        .frame(width: 268)
                } else {
                    compactNavigator(snapshot: snapshot)
                }
                Divider()
                timelineColumn(snapshot: snapshot)
            }
        }
        .onChange(of: displayedMonth) { month in
            calendar.loadMonthIfNeeded(containing: month, calendar: displayCalendar)
        }
        .onChange(of: filter) { _ in
            pendingScrollForFilterChange = true
        }
        .onChange(of: snapshot.key) { _ in
            if !didInitialScroll && !snapshot.rows.isEmpty {
                didInitialScroll = true
                requestScrollToNowOrToday(snapshot: snapshot, animated: false)
            }
            if pendingScrollForFilterChange {
                pendingScrollForFilterChange = false
                if pendingScrollDay == nil {
                    switch filter {
                    case .all:
                        requestScrollToNowOrToday(snapshot: snapshot, animated: false)
                    case .past, .upcoming:
                        if let firstID = snapshot.rows.first?.id {
                            scrollRequest = CalendarScrollRequest(targetID: firstID, anchor: .top, animated: false)
                        }
                    }
                }
            }
            if let pending = pendingScrollDay,
               let target = snapshot.exactDayRowID(for: pending, calendar: displayCalendar) {
                pendingScrollDay = nil
                scrollRequest = CalendarScrollRequest(targetID: target, anchor: .top, animated: true)
            }
        }
        .navigationTitle(L("Calendar"))
        .sheet(isPresented: $showingCreateMeeting) {
            let suggestedOrigins = SiteOrigin.suggestedOrigins(
                rooms: roomHistory.rooms,
                calendarMeetings: calendar.meetings,
                fallbackOrigin: library.guestWebsiteOrigin
            )
            CreateCalendarMeetingSheet(
                initialDate: selectedDate ?? Date(),
                suggestedOrigins: suggestedOrigins,
                favoriteRooms: favoriteRoomOptions,
                preferredCalendarIDs: calendar.selected,
                defaultDisplayName: library.displayName,
                onOpenCalendarSettings: { workspace.openCalendarSettings() },
                onCreated: { result, createdRoom, saveFavorite in
                    if saveFavorite, let createdRoom {
                        workspace.saveCreatedRoomFavorite(createdRoom)
                    }
                    if result.meetingURL == nil && !showEventsWithoutLinks {
                        showEventsWithoutLinks = true
                    }
                    if (filter == .past && result.endAt > calendar.now) ||
                        (filter == .upcoming && result.endAt <= calendar.now) {
                        filter = .all
                    }
                    calendar.handleCreatedCalendarEvent(calendarID: result.calendarIdentifier, eventStart: result.startAt)
                    let targetDay = displayCalendar.startOfDay(for: result.startAt)
                    displayedMonth = targetDay
                    selectedDate = targetDay
                    let todayStart = displayCalendar.startOfDay(for: calendar.now)
                    let defaultCutoff = displayCalendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
                    if targetDay < defaultCutoff {
                        let expanded = displayCalendar.date(byAdding: .day, value: -7, to: targetDay) ?? targetDay
                        earliestVisibleDay = earliestVisibleDay.map { min($0, expanded) } ?? expanded
                    }
                    pendingScrollDay = targetDay
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            displayCalendar = Calendar.current
        }
    }

    private func leftNavigator(snapshot: CalendarTimelineViewCache.TimelineSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CompactMonthScrubberView(
                    displayedMonth: $displayedMonth,
                    selectedDate: selectedDate,
                    markersByDay: snapshot.dayMarkers,
                    calendar: displayCalendar,
                    allowEmptyDaySelection: true,
                    primaryDotColor: .orange,
                    secondaryDotColor: .green,
                    onSelectDay: { day in
                        selectedDate = day
                        requestScrollToDay(day, snapshot: snapshot)
                    },
                    onToday: {
                        let today = displayCalendar.startOfDay(for: Date())
                        selectedDate = today
                        requestScrollToNowOrToday(snapshot: snapshot, animated: true)
                    }
                )
                .accessibilityIdentifier("calendar.month.scrubber")

                legendBox
                calendarStatusBox
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func compactNavigator(snapshot: CalendarTimelineViewCache.TimelineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactMonthScrubberView(
                displayedMonth: $displayedMonth,
                selectedDate: selectedDate,
                markersByDay: snapshot.dayMarkers,
                calendar: displayCalendar,
                allowEmptyDaySelection: true,
                onSelectDay: { day in
                    selectedDate = day
                    requestScrollToDay(day, snapshot: snapshot)
                },
                onToday: {
                    let today = displayCalendar.startOfDay(for: Date())
                    selectedDate = today
                    requestScrollToNowOrToday(snapshot: snapshot, animated: true)
                }
            )
            calendarStatusBox
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var legendBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Legend"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            legendRow(color: .green, label: L("Past · recorded"))
            legendRow(color: .orange, label: L("Now / Planned"))
            legendRow(color: .secondary, label: L("Past · no recording"))
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var calendarStatusBox: some View {
        if !calendar.enabled {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Choose calendars to find your meetings"), systemImage: "calendar")
                    .font(.caption.weight(.medium))
                Button(L("Choose calendars")) { workspace.openCalendarSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if calendar.access == .denied {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Calendar access is off in System Settings."), systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L("Review calendar access")) { workspace.openCalendarSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if let error = calendar.error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(L("Try Again")) { calendar.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if calendar.selected.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("No calendars selected."), systemImage: "calendar")
                    .font(.caption)
                Button(L("Choose calendars")) { workspace.openCalendarSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        } else if calendar.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Loading calendars…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func timelineColumn(snapshot: CalendarTimelineViewCache.TimelineSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NativeSegmentedControl(
                    label: L("Calendar"),
                    selection: $filter,
                    options: UnifiedCalendarFilter.allCases.map { .init(value: $0, title: $0.title) }
                )
                .frame(maxWidth: 320)

                Spacer(minLength: 8)

                Toggle(L("Show events without link"), isOn: $showEventsWithoutLinks)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .accessibilityIdentifier("calendar.toggle.linkless")

                Button {
                    showingCreateMeeting = true
                } label: {
                    Label(L("New meeting"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("calendar.createMeeting")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if snapshot.rows.isEmpty {
                            emptyTimelineView
                        } else {
                            ForEach(snapshot.rows) { row in
                                CalendarTimelineRowView(
                                    row: row,
                                    workspace: workspace,
                                    library: library,
                                    calendar: calendar,
                                    roomHistory: roomHistory,
                                    onLoadEarlier: { anchorDay in
                                        earliestVisibleDay = displayCalendar.date(byAdding: .day, value: -30, to: anchorDay) ?? anchorDay
                                    }
                                )
                                .id(row.id)
                            }
                        }
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onAppear {
                    if !didInitialScroll && !snapshot.rows.isEmpty {
                        didInitialScroll = true
                        performInitialScroll(snapshot: snapshot, proxy: proxy)
                    }
                }
                .onChange(of: scrollRequest) { request in
                    guard let request else { return }
                    if request.animated {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(request.targetID, anchor: request.anchor)
                        }
                    } else {
                        proxy.scrollTo(request.targetID, anchor: request.anchor)
                    }
                }
            }
        }
    }

    private var emptyTimelineView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("No meetings with supported invitation links"))
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(L("New meeting")) { showingCreateMeeting = true }
                    .buttonStyle(.borderedProminent)
                if !calendar.enabled || calendar.selected.isEmpty {
                    Button(L("Choose calendars")) { workspace.openCalendarSettings() }
                }
            }
        }
        .padding(.vertical, 24)
    }

    private func requestScrollToDay(_ date: Date, snapshot: CalendarTimelineViewCache.TimelineSnapshot) {
        guard let targetDay = snapshot.nearestDayStart(for: date, calendar: displayCalendar) else { return }
        if let targetID = snapshot.dayRowIDByDayStart[targetDay] {
            scrollRequest = CalendarScrollRequest(targetID: targetID, anchor: .top, animated: true)
        } else {
            let expanded = displayCalendar.date(byAdding: .day, value: -7, to: targetDay) ?? targetDay
            earliestVisibleDay = earliestVisibleDay.map { min($0, expanded) } ?? expanded
            pendingScrollDay = targetDay
        }
    }

    private func requestScrollToNowOrToday(
        snapshot: CalendarTimelineViewCache.TimelineSnapshot,
        animated: Bool
    ) {
        if filter == .all, snapshot.hasNowDivider {
            scrollRequest = CalendarScrollRequest(targetID: "calendar.now", anchor: .center, animated: animated)
        } else if let todayRowID = snapshot.todayRowID {
            scrollRequest = CalendarScrollRequest(targetID: todayRowID, anchor: .top, animated: animated)
        } else if let firstID = snapshot.rows.first?.id {
            scrollRequest = CalendarScrollRequest(targetID: firstID, anchor: .top, animated: animated)
        }
    }

    private func performInitialScroll(snapshot: CalendarTimelineViewCache.TimelineSnapshot, proxy: ScrollViewProxy) {
        let targetID: String?
        let anchor: UnitPoint
        if filter == .all, snapshot.hasNowDivider {
            targetID = "calendar.now"
            anchor = .center
        } else if let todayRowID = snapshot.todayRowID {
            targetID = todayRowID
            anchor = .top
        } else {
            targetID = snapshot.rows.first?.id
            anchor = .top
        }
        guard let targetID else { return }
        proxy.scrollTo(targetID, anchor: anchor)
    }
}

/// Pure value-driven row view with zero `@ObservedObject` subscriptions so LazyVStack
/// materialization and teardown stay fast when scrolling or switching sections.
private struct CalendarTimelineRowView: View {
    let row: CalendarTimelineRow
    let workspace: NativeDesktopWorkspace
    let library: NativeDesktopLibrary
    let calendar: CalendarMeetingStore
    let roomHistory: RoomHistoryStore
    let onLoadEarlier: (Date) -> Void

    var body: some View {
        switch row {
        case .dayHeader(_, _, let title, let isToday):
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isToday ? Color.orange : Color.secondary)
                .padding(.top, 8)
                .padding(.bottom, 2)

        case .nowDivider(let timeLabel):
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                Text(L("Now") + " · " + timeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Rectangle()
                    .fill(Color.orange.opacity(0.35))
                    .frame(height: 1)
            }
            .padding(.vertical, 4)

        case .emptyToday:
            Text(L("No meetings today."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

        case .attended(let model):
            attendedRow(model)

        case .adHoc(let model):
            adHocRow(model)

        case .unattended(let model):
            unattendedRow(model)

        case .upcoming(let model):
            upcomingRow(model)

        case .loadEarlier(let hiddenCount, let nextAnchorDay):
            HStack {
                Button {
                    onLoadEarlier(nextAnchorDay)
                } label: {
                    Label(L("Show earlier (%ld)", hiddenCount), systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("calendar.loadEarlier")
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func attendedRow(_ model: AttendedRowModel) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(model.meeting.title).font(.headline).lineLimit(2)
                    if model.openTasksCount > 0 {
                        Text(L("%ld tasks", model.openTasksCount))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(model.timeAndCalendarText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let preview = model.summaryPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if model.showJoin {
                    Button(L("Join")) { library.open(model.meeting) }
                        .buttonStyle(.bordered)
                }
                Button(L("Open summary")) {
                    workspace.openMeetingHistory(model.sessionID, source: .calendar)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            calendarContextMenu(for: model.meeting)
        }
    }

    private func adHocRow(_ model: AdHocRowModel) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                    Text(model.title).font(.headline).lineLimit(2)
                    Text(L("Outside calendar"))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                    if model.openTasksCount > 0 {
                        Text(L("%ld tasks", model.openTasksCount))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(model.timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let preview = model.summaryPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(L("Open summary")) {
                workspace.openMeetingHistory(model.sessionID, source: .calendar)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private func unattendedRow(_ model: UnattendedRowModel) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                    Text(model.meeting.title).font(.headline).lineLimit(2)
                    Text(model.isLinkless ? L("No link") : L("No recording"))
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.45), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(model.timeAndCalendarText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.meeting.hasResolvedInvitation {
                Button(L("Join")) { library.open(model.meeting) }
                    .buttonStyle(.bordered)
            } else {
                Button(L("Choose room")) { calendar.choosingMeeting = model.meeting }
                    .buttonStyle(.bordered)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            calendarContextMenu(for: model.meeting)
        }
    }

    private func upcomingRow(_ model: UpcomingRowModel) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(model.meeting.title).font(.headline).lineLimit(2)
                    if model.isScheduledNow {
                        Text(L("Scheduled now"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if model.isLinkless {
                        Text(L("No link"))
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.45), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detail = model.roomDetailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let outcome = model.lastOutcome {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Last time: %@", outcome.summaryText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if outcome.pendingTasksCount > 0 {
                            Text(L("Open tasks: %ld of %ld", outcome.pendingTasksCount, outcome.totalTasksCount))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let url = model.meeting.invitation {
                    Button {
                        if roomHistory.matching(url, engine: model.meeting.engine) != nil {
                            roomHistory.toggleStar(url)
                        } else {
                            roomHistory.saveFavorite(url: url, title: model.meeting.title, engine: model.meeting.engine)
                        }
                    } label: {
                        Image(systemName: model.isStarred ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help(model.isStarred ? L("Remove from Favorites") : L("Add to Favorites"))
                }

                if let linkedSessionID = model.linkedSessionID {
                    Button(L("Open summary")) {
                        workspace.openMeetingHistory(linkedSessionID, source: .calendar)
                    }
                    .buttonStyle(.bordered)
                }

                if model.meeting.hasResolvedInvitation {
                    Button(L("Join")) { library.open(model.meeting) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Choose room")) { calendar.choosingMeeting = model.meeting }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(
            model.isScheduledNow ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(model.isScheduledNow ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            calendarContextMenu(for: model.meeting)
        }
    }

    @ViewBuilder
    private func calendarContextMenu(for meeting: CalendarMeeting) -> some View {
        if let url = meeting.invitation {
            Button(L("Meeting settings…")) {
                workspace.attention.editingPreset = .init(
                    invitation: url,
                    seriesID: meeting.seriesID,
                    title: meeting.title
                )
            }
        }
        Button(L("Choose another room")) { calendar.choosingMeeting = meeting }
        Button(L("Reminders…")) {
            calendar.reminders.editing = calendar.reminders.occurrence(for: meeting)
        }
    }
}
