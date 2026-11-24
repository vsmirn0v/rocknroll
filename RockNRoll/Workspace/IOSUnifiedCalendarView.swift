import ConferenceCore
import MeetingEngine
import SwiftUI

struct IOSUnifiedCalendarView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    var calendar: CalendarMeetingStore?
    var history: RoomHistoryStore?
    var continuation: MeetingContinuationCoordinator?
    var suggestedSiteOrigins: [URL] = []
    var defaultDisplayName: String = ""
    let onOpenMeeting: (UUID) -> Void
    var onJoinCalendarMeeting: ((CalendarMeeting) -> Void)?
    var onOpenCalendarSettings: (() -> Void)?
    var onSaveCreatedRoomFavorite: ((CreatedMeetingRoom) -> Void)?

    var body: some View {
        if let calendar {
            IOSObservedUnifiedCalendarView(
                workspace: workspace,
                calendar: calendar,
                history: history,
                continuation: continuation,
                suggestedSiteOrigins: suggestedSiteOrigins,
                defaultDisplayName: defaultDisplayName,
                onOpenMeeting: onOpenMeeting,
                onJoinCalendarMeeting: onJoinCalendarMeeting,
                onOpenCalendarSettings: onOpenCalendarSettings,
                onSaveCreatedRoomFavorite: onSaveCreatedRoomFavorite
            )
        } else {
            IOSUnifiedCalendarBody(
                workspace: workspace,
                calendar: nil,
                history: history,
                continuation: continuation,
                meetings: [],
                now: Date(),
                calendarEnabled: false,
                calendarAccess: .notDetermined,
                selectedCalendarIDs: [],
                calendarLoading: false,
                calendarError: nil,
                suggestedSiteOrigins: suggestedSiteOrigins,
                defaultDisplayName: defaultDisplayName,
                onOpenMeeting: onOpenMeeting,
                onJoinCalendarMeeting: onJoinCalendarMeeting,
                onOpenCalendarSettings: onOpenCalendarSettings,
                onSaveCreatedRoomFavorite: onSaveCreatedRoomFavorite
            )
        }
    }
}

private struct IOSObservedUnifiedCalendarView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var calendar: CalendarMeetingStore
    var history: RoomHistoryStore?
    var continuation: MeetingContinuationCoordinator?
    var suggestedSiteOrigins: [URL]
    var defaultDisplayName: String
    let onOpenMeeting: (UUID) -> Void
    var onJoinCalendarMeeting: ((CalendarMeeting) -> Void)?
    var onOpenCalendarSettings: (() -> Void)?
    var onSaveCreatedRoomFavorite: ((CreatedMeetingRoom) -> Void)?

    var body: some View {
        IOSUnifiedCalendarBody(
            workspace: workspace,
            calendar: calendar,
            history: history,
            continuation: continuation,
            meetings: calendar.allTimelineMeetings,
            now: calendar.now,
            calendarEnabled: calendar.enabled || !calendar.syncedRemoteMeetings.isEmpty,
            calendarAccess: calendar.access,
            selectedCalendarIDs: calendar.selected,
            calendarLoading: calendar.loading,
            calendarError: calendar.error,
            suggestedSiteOrigins: suggestedSiteOrigins,
            defaultDisplayName: defaultDisplayName,
            onOpenMeeting: onOpenMeeting,
            onJoinCalendarMeeting: onJoinCalendarMeeting,
            onOpenCalendarSettings: onOpenCalendarSettings,
            onSaveCreatedRoomFavorite: onSaveCreatedRoomFavorite
        )
        .sheet(item: $calendar.choosingMeeting) { meeting in
            if let history {
                CalendarRoomBindingView(meeting: meeting, calendar: calendar, history: history)
            }
        }
        .modifier(CalendarReminderSheet(reminders: calendar.reminders, isActive: { true }))
    }
}

private struct IOSUnifiedCalendarBody: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    var calendar: CalendarMeetingStore?
    var history: RoomHistoryStore?
    var continuation: MeetingContinuationCoordinator?
    let meetings: [CalendarMeeting]
    let now: Date
    let calendarEnabled: Bool
    let calendarAccess: CalendarAccess
    let selectedCalendarIDs: Set<String>
    let calendarLoading: Bool
    let calendarError: String?
    let suggestedSiteOrigins: [URL]
    let defaultDisplayName: String
    let onOpenMeeting: (UUID) -> Void
    let onJoinCalendarMeeting: ((CalendarMeeting) -> Void)?
    let onOpenCalendarSettings: (() -> Void)?
    let onSaveCreatedRoomFavorite: ((CreatedMeetingRoom) -> Void)?

    @State private var filter: UnifiedCalendarFilter = .all
    @AppStorage("calendar.showEventsWithoutLinks") private var showEventsWithoutLinks = false
    @State private var showingMonthScrubber = false
    @State private var displayedMonth = Date()
    @State private var selectedDate: Date?
    @State private var pendingScrollDay: Date?
    @State private var showingCreateMeeting = false
    @State private var didInitialScroll = false
    @State private var displayCalendar = Calendar.current
    @Environment(\.locale) private var locale

    private var sessionInputs: [UnifiedCalendarSessionInput] {
        let openTaskCounts = workspace.tasks.reduce(into: [UUID: Int]()) { counts, task in
            if !task.done {
                counts[task.sessionID, default: 0] += 1
            }
        }
        return workspace.visibleHistorySessions(includeEmpty: false).map { session in
            let outcome = workspace.outcomesBySession[session.id]
            let note = workspace.notesBySession[session.id]
            let summaryTrimmed = outcome?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let noteTrimmed = note?.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (summaryTrimmed?.isEmpty == false ? summaryTrimmed : nil)
                ?? (noteTrimmed?.isEmpty == false ? noteTrimmed : nil)
            let association = workspace.calendarAssociation(for: session.id)
            return UnifiedCalendarSessionInput(
                id: session.id,
                title: session.title,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                invitation: session.invitation,
                roomKey: association?.roomKey ?? (session.roomIdentity.isEmpty ? nil : session.roomIdentity),
                calendarAssociation: association,
                summaryPreview: preview,
                openTasksCount: openTaskCounts[session.id] ?? 0,
                hasNotes: note?.isEmpty == false,
                isLive: session.endedAt == nil && session.state == "active"
            )
        }
    }

    private var favoriteRoomOptions: [FavoriteRoomOption] {
        (history?.rooms ?? []).map {
            FavoriteRoomOption(id: $0.id, title: $0.displayTitle, invitationURL: $0.joinURL)
        }
    }

    var body: some View {
        let timeline = UnifiedCalendarTimelineBuilder.build(
            meetings: meetings,
            sessions: sessionInputs,
            filter: filter,
            includeEventsWithoutLinks: showEventsWithoutLinks,
            now: now,
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
            VStack(spacing: 0) {
                headerControls(sections: timeline.sections, dayMarkers: dayMarkers, proxy: proxy)

                List {
                    statusBannerSection

                    if timeline.sections.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("No meetings with supported invitation links"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button {
                                    showingCreateMeeting = true
                                } label: {
                                    Label(L("New meeting"), systemImage: "plus.circle.fill")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    } else {
                        ForEach(timeline.sections) { section in
                            Section {
                                if section.items.isEmpty, section.nowInsertionIndex != nil {
                                    nowDividerRow
                                    Text(L("No meetings today."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                        if section.nowInsertionIndex == index {
                                            nowDividerRow
                                        }
                                        timelineRow(item)
                                            .id(item.id)
                                    }
                                    if section.nowInsertionIndex == section.items.count {
                                        nowDividerRow
                                    }
                                }
                            } header: {
                                Text(dayHeaderTitle(section.dayStart))
                                    .foregroundStyle(displayCalendar.isDateInToday(section.dayStart) ? Color.rockBrandTint : .secondary)
                                    .id(section.dayStart)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .onChange(of: displayedMonth) { _, month in
                calendar?.loadMonthIfNeeded(containing: month, calendar: displayCalendar)
            }
            .onChange(of: timeline.sections.map(\.dayStart)) { _, _ in
                if !didInitialScroll && !timeline.sections.isEmpty {
                    didInitialScroll = true
                    scrollToNowOrToday(sections: timeline.sections, proxy: proxy, animated: false)
                }
                if let pending = pendingScrollDay {
                    let target = displayCalendar.startOfDay(for: pending)
                    if let section = timeline.sections.first(where: { displayCalendar.isDate($0.dayStart, inSameDayAs: target) }) {
                        pendingScrollDay = nil
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(scrollAnchor(for: section), anchor: .top)
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
        .sheet(isPresented: $showingCreateMeeting) {
            CreateCalendarMeetingSheet(
                initialDate: selectedDate ?? Date(),
                suggestedOrigins: suggestedSiteOrigins,
                favoriteRooms: favoriteRoomOptions,
                preferredCalendarIDs: selectedCalendarIDs,
                defaultDisplayName: defaultDisplayName,
                onOpenCalendarSettings: onOpenCalendarSettings,
                onCreated: { result, createdRoom, saveFavorite in
                    if saveFavorite, let createdRoom {
                        onSaveCreatedRoomFavorite?(createdRoom)
                    }
                    if result.meetingURL == nil && !showEventsWithoutLinks {
                        showEventsWithoutLinks = true
                    }
                    if (filter == .past && result.endAt > now) ||
                        (filter == .upcoming && result.endAt <= now) {
                        filter = .all
                    }
                    calendar?.handleCreatedCalendarEvent(calendarID: result.calendarIdentifier, eventStart: result.startAt)
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

    private func headerControls(
        sections: [UnifiedCalendarDaySection],
        dayMarkers: [Date: CompactCalendarDayMarker],
        proxy: ScrollViewProxy
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker(L("Calendar"), selection: $filter) {
                    ForEach(UnifiedCalendarFilter.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingMonthScrubber.toggle()
                    }
                } label: {
                    Image(systemName: showingMonthScrubber ? "calendar.circle.fill" : "calendar")
                        .font(.title3)
                        .foregroundStyle(showingMonthScrubber ? Color.rockBrandTint : .secondary)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Jump to date"))

                Menu {
                    Toggle(L("Show events without link"), isOn: $showEventsWithoutLinks)
                    if let onOpenCalendarSettings {
                        Button {
                            onOpenCalendarSettings()
                        } label: {
                            Label(L("Calendars"), systemImage: "calendar.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .accessibilityLabel(L("More"))

                Button {
                    showingCreateMeeting = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.rockBrandTint)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("New meeting"))
                .accessibilityIdentifier("ios.calendar.createMeeting")
            }

            if showingMonthScrubber {
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private var statusBannerSection: some View {
        if let onOpenCalendarSettings, (!calendarEnabled || calendarAccess == .denied || selectedCalendarIDs.isEmpty) {
            Section {
                if !calendarEnabled || selectedCalendarIDs.isEmpty {
                    Button {
                        onOpenCalendarSettings()
                    } label: {
                        Label(L("Choose calendars"), systemImage: "calendar")
                    }
                } else if calendarAccess == .denied {
                    Button {
                        onOpenCalendarSettings()
                    } label: {
                        Label(L("Review calendar access"), systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
            }
        } else if calendarLoading {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L("Checking calendar…")).foregroundStyle(.secondary)
                }
            }
        } else if let calendarError {
            Section {
                Text(calendarError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var nowDividerRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.orange).frame(width: 8, height: 8)
            Text(L("Now") + " · " + now.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1)
        }
        .listRowSeparator(.hidden)
        .id("calendar.now")
    }

    @ViewBuilder
    private func timelineRow(_ item: UnifiedCalendarItem) -> some View {
        switch item.kind {
        case .attended(let meeting, let session):
            Button {
                onOpenMeeting(session.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text(meeting.title).font(.headline).lineLimit(2)
                        Spacer()
                        if session.openTasksCount > 0 {
                            Text(L("%ld tasks", session.openTasksCount))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(CalendarMeetingPresentation.compactTimeRange(meeting) + (meeting.calendarTitle.isEmpty ? "" : " · " + meeting.calendarTitle))
                        .font(.caption).foregroundStyle(.secondary)
                    if let preview = session.summaryPreview, !preview.isEmpty {
                        Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

        case .adHoc(let session):
            Button {
                onOpenMeeting(session.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                        Text(session.title).font(.headline).lineLimit(2)
                        Spacer()
                        Text(L("Outside calendar"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.14), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if let preview = session.summaryPreview, !preview.isEmpty {
                        Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

        case .unattended(let meeting):
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                        Text(meeting.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    Text(CalendarMeetingPresentation.compactTimeRange(meeting) + " · " + (item.isLinkless ? L("No link") : L("No recording")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if meeting.hasResolvedInvitation, let onJoinCalendarMeeting {
                    Button(L("Join")) { onJoinCalendarMeeting(meeting) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if let calendar, history != nil {
                    Button(L("Choose room")) { calendar.choosingMeeting = meeting }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

        case .upcoming(let meeting, let linkedSession):
            upcomingCard(meeting: meeting, linkedSession: linkedSession, isLinkless: item.isLinkless)
        }
    }

    private func upcomingCard(
        meeting: CalendarMeeting,
        linkedSession: UnifiedCalendarSessionInput?,
        isLinkless: Bool
    ) -> some View {
        let active = continuation?.candidates.first {
            $0.isRecent(at: Date()) && MeetingRoomIdentity($0.invitation, engine: $0.engine) == meeting.roomIdentity
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text(meeting.title).font(.headline).lineLimit(2)
                    }
                    Text(CalendarMeetingPresentation.compactTimeRange(meeting))
                        .font(.subheadline).foregroundStyle(.secondary)
                    let meta = [meeting.calendarTitle, meeting.invitation?.host(), isLinkless ? L("No link") : nil]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let url = meeting.invitation, let history {
                    let favorite = history.matching(url, engine: meeting.engine)
                    Button {
                        if let favorite, favorite.isStarred {
                            history.toggleStar(favorite.invitationURL)
                        } else {
                            history.saveFavorite(url: url, title: meeting.title, engine: meeting.engine)
                        }
                    } label: {
                        Image(systemName: favorite?.isStarred == true ? "star.fill" : "star")
                            .foregroundStyle(.orange)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 10) {
                if let active, let continuation {
                    Button {
                        continuation.begin(active, companion: false)
                    } label: {
                        Label(active.isSharingScreen ? L("Move here and stop sharing") : L("Continue on this device"), systemImage: "video")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if meeting.hasResolvedInvitation, let onJoinCalendarMeeting {
                    Button {
                        onJoinCalendarMeeting(meeting)
                    } label: {
                        Label(L("Join"), systemImage: "video")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if let calendar, history != nil {
                    Button {
                        calendar.choosingMeeting = meeting
                    } label: {
                        Label(L("Choose room"), systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let linkedSession {
                    Button(L("Open summary")) {
                        onOpenMeeting(linkedSession.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                if let calendar, meeting.invitation != nil {
                    Menu {
                        Button(L("Reminders")) {
                            calendar.reminders.editing = calendar.reminders.occurrence(for: meeting)
                        }
                        if history != nil {
                            Button(L("Choose another room")) {
                                calendar.choosingMeeting = meeting
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 32, height: 32)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func scrollAnchor(for section: UnifiedCalendarDaySection) -> AnyHashable {
        section.items.first?.id ?? "calendar.now"
    }

    private func scrollToDay(_ date: Date, sections: [UnifiedCalendarDaySection], proxy: ScrollViewProxy) {
        let target = displayCalendar.startOfDay(for: date)
        if let exact = sections.first(where: { displayCalendar.isDate($0.dayStart, inSameDayAs: target) }) {
            let anchorID = scrollAnchor(for: exact)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        } else if let nearest = sections.min(by: {
            abs($0.dayStart.timeIntervalSince(target)) < abs($1.dayStart.timeIntervalSince(target))
        }) {
            let anchorID = scrollAnchor(for: nearest)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchorID, anchor: .top)
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
            } else if let todaySection = sections.first(where: { displayCalendar.isDateInToday($0.dayStart) }) {
                proxy.scrollTo(scrollAnchor(for: todaySection), anchor: .top)
            } else if let firstSection = sections.first {
                proxy.scrollTo(scrollAnchor(for: firstSection), anchor: .top)
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
}
