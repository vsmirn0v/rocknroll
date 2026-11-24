import ConferenceCore
import MeetingEngine
import SwiftUI

struct NativeDesktopCalendarView: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var library: NativeDesktopLibrary
    @ObservedObject private var calendar: CalendarMeetingStore
    @ObservedObject private var meetingLibrary: MeetingLibraryController
    @ObservedObject private var data: AssistantDataStore
    @ObservedObject private var workspaceSync: MacWorkspaceSyncCoordinator
    @ObservedObject private var journal: MeetingWorkspaceJournal
    let suggestedOrigins: [URL]

    @State private var filter: UnifiedCalendarFilter = .all
    @AppStorage("calendar.showEventsWithoutLinks") private var showEventsWithoutLinks = false
    @State private var displayedMonth = Date()
    @State private var selectedDate: Date?
    @State private var pendingScrollDay: Date?
    @State private var showingCreateMeeting = false
    @State private var didInitialScroll = false
    @State private var displayCalendar = Calendar.current
    @Environment(\.locale) private var locale

    init(workspace: NativeDesktopWorkspace, library: NativeDesktopLibrary, suggestedOrigins: [URL]) {
        self.workspace = workspace
        self.library = library
        self._calendar = ObservedObject(wrappedValue: library.calendar)
        self._meetingLibrary = ObservedObject(wrappedValue: workspace.attention.store.meetingLibrary)
        self._data = ObservedObject(wrappedValue: workspace.attention.store.assistant)
        self._workspaceSync = ObservedObject(wrappedValue: workspace.workspaceSync)
        self._journal = ObservedObject(wrappedValue: workspace.attention.store.meetingLibrary.workspaceJournal)
        self.suggestedOrigins = suggestedOrigins
    }

    private var sessionInputs: [UnifiedCalendarSessionInput] {
        let outcomesByID = Dictionary(data.outcomes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveIDs = Set(
            workspace.attention.meetings().flatMap {
                [$0.sessionID, $0.workspaceSessionID] + $0.segments.map(\.sessionID)
            }
        )
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
        return (meetingLibrary.cards + journalOnly)
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
    }

    private var favoriteRoomOptions: [FavoriteRoomOption] {
        library.history.rooms.map {
            FavoriteRoomOption(id: $0.id, title: $0.displayTitle, invitationURL: $0.joinURL)
        }
    }

    var body: some View {
        let timeline = UnifiedCalendarTimelineBuilder.build(
            meetings: calendar.allTimelineMeetings,
            sessions: sessionInputs,
            filter: filter,
            includeEventsWithoutLinks: showEventsWithoutLinks,
            now: calendar.now,
            calendar: displayCalendar
        )
        let dayMarkers = timeline.dotsByDay.mapValues { summary in
            CompactCalendarDayMarker(
                primaryCount: summary.upcomingCount,
                secondaryCount: summary.recordedCount + summary.missedCount,
                hasAccent: summary.hasOpenTasks
            )
        }

        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let wide = geometry.size.width >= 760
                Group {
                    if wide {
                        HStack(spacing: 0) {
                            leftNavigator(dayMarkers: dayMarkers, sections: timeline.sections, proxy: proxy)
                                .frame(width: 268)
                            Divider()
                            timelineColumn(sections: timeline.sections, proxy: proxy)
                        }
                    } else {
                        VStack(spacing: 0) {
                            compactNavigator(dayMarkers: dayMarkers, sections: timeline.sections, proxy: proxy)
                            Divider()
                            timelineColumn(sections: timeline.sections, proxy: proxy)
                        }
                    }
                }
            }
            .onChange(of: displayedMonth) { month in
                calendar.loadMonthIfNeeded(containing: month, calendar: displayCalendar)
            }
            .onChange(of: timeline.sections.map(\.dayStart)) { _ in
                if !didInitialScroll && !timeline.sections.isEmpty {
                    didInitialScroll = true
                    scrollToNowOrToday(sections: timeline.sections, proxy: proxy, animated: false)
                }
                if let pending = pendingScrollDay {
                    let target = displayCalendar.startOfDay(for: pending)
                    if timeline.sections.contains(where: { displayCalendar.isDate($0.dayStart, inSameDayAs: target) }) {
                        pendingScrollDay = nil
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
            .onAppear {
                if !didInitialScroll && !timeline.sections.isEmpty {
                    didInitialScroll = true
                    scrollToNowOrToday(sections: timeline.sections, proxy: proxy, animated: false)
                }
            }
        }
        .navigationTitle(L("Calendar"))
        .sheet(isPresented: $showingCreateMeeting) {
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
                    pendingScrollDay = targetDay
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            displayCalendar = Calendar.current
        }
    }

    private func leftNavigator(
        dayMarkers: [Date: CompactCalendarDayMarker],
        sections: [UnifiedCalendarDaySection],
        proxy: ScrollViewProxy
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CompactMonthScrubberView(
                    displayedMonth: $displayedMonth,
                    selectedDate: selectedDate,
                    markersByDay: dayMarkers,
                    calendar: displayCalendar,
                    allowEmptyDaySelection: true,
                    primaryDotColor: .orange,
                    secondaryDotColor: .green,
                    onSelectDay: { day in
                        selectedDate = day
                        scrollToDay(day, sections: sections, proxy: proxy)
                    },
                    onToday: {
                        let today = displayCalendar.startOfDay(for: Date())
                        selectedDate = today
                        scrollToNowOrToday(sections: sections, proxy: proxy, animated: true)
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

    private func compactNavigator(
        dayMarkers: [Date: CompactCalendarDayMarker],
        sections: [UnifiedCalendarDaySection],
        proxy: ScrollViewProxy
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactMonthScrubberView(
                displayedMonth: $displayedMonth,
                selectedDate: selectedDate,
                markersByDay: dayMarkers,
                calendar: displayCalendar,
                allowEmptyDaySelection: true,
                onSelectDay: { day in
                    selectedDate = day
                    scrollToDay(day, sections: sections, proxy: proxy)
                },
                onToday: {
                    let today = displayCalendar.startOfDay(for: Date())
                    selectedDate = today
                    scrollToNowOrToday(sections: sections, proxy: proxy, animated: true)
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

    private func timelineColumn(sections: [UnifiedCalendarDaySection], proxy: ScrollViewProxy) -> some View {
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if sections.isEmpty {
                        emptyTimelineView
                    } else {
                        ForEach(sections) { section in
                            daySectionView(section)
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity)
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

    private func daySectionView(_ section: UnifiedCalendarDaySection) -> some View {
        let isToday = displayCalendar.isDateInToday(section.dayStart)
        return VStack(alignment: .leading, spacing: 10) {
            Text(dayHeaderTitle(section.dayStart))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isToday ? Color.orange : Color.secondary)
                .id(section.dayStart)

            if section.items.isEmpty, section.nowInsertionIndex != nil {
                nowDivider
                Text(L("No meetings today."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    if section.nowInsertionIndex == index {
                        nowDivider
                    }
                    timelineRow(item)
                }
                if section.nowInsertionIndex == section.items.count {
                    nowDivider
                }
            }
        }
    }

    private var nowDivider: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
            Text(L("Now") + " · " + calendar.now.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Rectangle()
                .fill(Color.orange.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .id("calendar.now")
    }

    @ViewBuilder
    private func timelineRow(_ item: UnifiedCalendarItem) -> some View {
        switch item.kind {
        case .attended(let meeting, let session):
            attendedRow(meeting: meeting, session: session)
        case .adHoc(let session):
            adHocRow(session: session)
        case .unattended(let meeting):
            unattendedRow(meeting: meeting, isLinkless: item.isLinkless)
        case .upcoming(let meeting, let linkedSession):
            upcomingRow(meeting: meeting, linkedSession: linkedSession, isLinkless: item.isLinkless)
        }
    }

    private func attendedRow(meeting: CalendarMeeting, session: UnifiedCalendarSessionInput) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(meeting.title).font(.headline).lineLimit(2)
                    if session.openTasksCount > 0 {
                        Text(L("%ld tasks", session.openTasksCount))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(CalendarMeetingPresentation.timeRange(meeting) + (meeting.calendarTitle.isEmpty ? "" : " · " + meeting.calendarTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let preview = session.summaryPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if meeting.hasResolvedInvitation {
                    Button(L("Join")) { library.open(meeting) }
                        .buttonStyle(.bordered)
                }
                Button(L("Open summary")) {
                    workspace.openMeetingHistory(session.id, source: .calendar)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            calendarContextMenu(for: meeting)
        }
    }

    private func adHocRow(session: UnifiedCalendarSessionInput) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                    Text(session.title).font(.headline).lineLimit(2)
                    Text(L("Outside calendar"))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                    if session.openTasksCount > 0 {
                        Text(L("%ld tasks", session.openTasksCount))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(sessionTimeLabel(startedAt: session.startedAt, endedAt: session.endedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let preview = session.summaryPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(L("Open summary")) {
                workspace.openMeetingHistory(session.id, source: .calendar)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private func unattendedRow(meeting: CalendarMeeting, isLinkless: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                    Text(meeting.title).font(.headline).lineLimit(2)
                    Text(isLinkless ? L("No link") : L("No recording"))
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.45), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(CalendarMeetingPresentation.timeRange(meeting) + (meeting.calendarTitle.isEmpty ? "" : " · " + meeting.calendarTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if meeting.hasResolvedInvitation {
                Button(L("Join")) { library.open(meeting) }
                    .buttonStyle(.bordered)
            } else {
                Button(L("Choose room")) { calendar.choosingMeeting = meeting }
                    .buttonStyle(.bordered)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            calendarContextMenu(for: meeting)
        }
    }

    private func upcomingRow(
        meeting: CalendarMeeting,
        linkedSession: UnifiedCalendarSessionInput?,
        isLinkless: Bool
    ) -> some View {
        let isScheduledNow = meeting.isScheduledNow(calendar.now)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(meeting.title).font(.headline).lineLimit(2)
                    if isScheduledNow {
                        Text(L("Scheduled now"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if isLinkless {
                        Text(L("No link"))
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.45), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(CalendarMeetingPresentation.subtitle(meeting, at: calendar.now, roomTitle: meeting.title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let url = meeting.invitation {
                    Text(roomDetail(url, engine: meeting.engine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                AssistantLastOutcome(
                    assistant: data,
                    invitation: meeting.invitation,
                    series: meeting.seriesID,
                    before: meeting.start
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let url = meeting.invitation {
                    let isStarred = library.history.matching(url, engine: meeting.engine)?.isStarred == true
                    Button {
                        if library.history.matching(url, engine: meeting.engine) != nil {
                            library.history.toggleStar(url)
                        } else {
                            library.history.saveFavorite(url: url, title: meeting.title, engine: meeting.engine)
                        }
                    } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help(isStarred ? L("Remove from Favorites") : L("Add to Favorites"))
                }

                if let linkedSession {
                    Button(L("Open summary")) {
                        workspace.openMeetingHistory(linkedSession.id, source: .calendar)
                    }
                    .buttonStyle(.bordered)
                }

                if meeting.hasResolvedInvitation {
                    Button(L("Join")) { library.open(meeting) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Choose room")) { calendar.choosingMeeting = meeting }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(
            isScheduledNow ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isScheduledNow ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            calendarContextMenu(for: meeting)
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

    private func scrollToDay(_ date: Date, sections: [UnifiedCalendarDaySection], proxy: ScrollViewProxy) {
        let target = displayCalendar.startOfDay(for: date)
        if sections.contains(where: { displayCalendar.isDate($0.dayStart, inSameDayAs: target) }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
        } else if let nearest = sections.min(by: {
            abs($0.dayStart.timeIntervalSince(target)) < abs($1.dayStart.timeIntervalSince(target))
        }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(nearest.dayStart, anchor: .top)
            }
        }
    }

    private func scrollToNowOrToday(
        sections: [UnifiedCalendarDaySection],
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let action = {
            if filter == .all, sections.contains(where: { $0.nowInsertionIndex != nil }) {
                proxy.scrollTo("calendar.now", anchor: .center)
            } else if let today = sections.first(where: { displayCalendar.isDateInToday($0.dayStart) })?.dayStart {
                proxy.scrollTo(today, anchor: .top)
            } else if let first = sections.first?.dayStart {
                proxy.scrollTo(first, anchor: .top)
            }
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { action() }
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    private func dayHeaderTitle(_ dayStart: Date) -> String {
        if displayCalendar.isDateInToday(dayStart) {
            return L("Today") + " · " + dayStart.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
        }
        if displayCalendar.isDateInYesterday(dayStart) {
            return L("Yesterday") + " · " + dayStart.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
        }
        return dayStart.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(locale))
    }

    private func sessionTimeLabel(startedAt: Date, endedAt: Date?) -> String {
        let start = startedAt.formatted(date: .abbreviated, time: .shortened)
        if let endedAt, endedAt > startedAt {
            let minutes = max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
            return start + " · " + L("%ld min", minutes)
        }
        return start
    }

    private func roomDetail(_ url: URL, engine: MeetingEngineKind?) -> String {
        let identity = MeetingRoomIdentity(url, engine: engine)
        return [url.host, identity?.room].compactMap { $0 }.joined(separator: " · ")
    }
}
