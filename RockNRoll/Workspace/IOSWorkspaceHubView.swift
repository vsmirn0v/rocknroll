import ConferenceCore
import MeetingEngine
import SwiftUI

enum IOSWorkspaceHubTab: String, CaseIterable, Identifiable {
    case ask
    case history
    case calendar
    case tasks
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return L("Ask")
        case .history: return L("Meetings")
        case .calendar: return L("Calendar")
        case .tasks: return L("Tasks")
        case .search: return L("Search")
        }
    }
}

struct IOSWorkspaceHubView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    var talk: IOSAssistantTalkController? = nil
    var speech: IOSAssistantSpeechCoordinator? = nil
    var skills: IOSAssistantSkillsController? = nil
    var facilitator: IOSAutonomousMeetingFacilitator? = nil
    var board: IOSAssistantBoardController? = nil
    var calendar: CalendarMeetingStore? = nil
    var history: RoomHistoryStore? = nil
    var continuation: MeetingContinuationCoordinator? = nil
    var suggestedSiteOrigins: [URL] = []
    var defaultDisplayName: String = ""
    var onJoinCalendarMeeting: ((CalendarMeeting) -> Void)? = nil
    var onOpenCalendarSettings: (() -> Void)? = nil
    var onSaveCreatedRoomFavorite: ((CreatedMeetingRoom) -> Void)? = nil
    var candidatesProvider: (() -> [JoinableMeetingCandidate])? = nil
    var onJoinMultiple: (([JoinableMeetingCandidate], String, Bool) -> Void)? = nil
    let initialTab: IOSWorkspaceHubTab

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedTab: IOSWorkspaceHubTab
    @State private var selectedSessionID: UUID?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showingSettings = false
    @State private var showingSkillsSheet = false
    @State private var showingBoardSheet = false
    @State private var showingMultiJoinSheet = false
    @State private var renamingSession: IOSMeetingSessionItem?
    @State private var renameDraft = ""
    @State private var pendingDeleteSession: IOSMeetingSessionItem?
    @AppStorage("ios.workspace.showEmptyMeetings") private var showEmptyMeetings = false
    @State private var showingHistoryMonthGrid = false
    @State private var historyScrubberMonth = Date()
    @State private var selectedHistoryDay: Date?
    @State private var historyCalendar = Calendar.current
    @State private var searchQuery = ""
    @State private var searchHits: [IOSWorkspaceSearchHit] = []

    private var visibleHistory: [IOSMeetingSessionItem] {
        workspace.visibleHistorySessions(includeEmpty: showEmptyMeetings)
    }

    init(
        workspace: IOSWorkspaceCoordinator,
        sync: RoomSyncCoordinator,
        assistant: IOSAssistantCoordinator,
        talk: IOSAssistantTalkController? = nil,
        speech: IOSAssistantSpeechCoordinator? = nil,
        skills: IOSAssistantSkillsController? = nil,
        facilitator: IOSAutonomousMeetingFacilitator? = nil,
        board: IOSAssistantBoardController? = nil,
        calendar: CalendarMeetingStore? = nil,
        history: RoomHistoryStore? = nil,
        continuation: MeetingContinuationCoordinator? = nil,
        suggestedSiteOrigins: [URL] = [],
        defaultDisplayName: String = "",
        onJoinCalendarMeeting: ((CalendarMeeting) -> Void)? = nil,
        onOpenCalendarSettings: (() -> Void)? = nil,
        onSaveCreatedRoomFavorite: ((CreatedMeetingRoom) -> Void)? = nil,
        candidatesProvider: (() -> [JoinableMeetingCandidate])? = nil,
        onJoinMultiple: (([JoinableMeetingCandidate], String, Bool) -> Void)? = nil,
        initialTab: IOSWorkspaceHubTab = .history
    ) {
        self.workspace = workspace
        self.sync = sync
        self.assistant = assistant
        self.talk = talk
        self.speech = speech
        self.skills = skills
        self.facilitator = facilitator
        self.board = board
        self.calendar = calendar
        self.history = history
        self.continuation = continuation
        self.suggestedSiteOrigins = suggestedSiteOrigins
        self.defaultDisplayName = defaultDisplayName
        self.onJoinCalendarMeeting = onJoinCalendarMeeting
        self.onOpenCalendarSettings = onOpenCalendarSettings
        self.onSaveCreatedRoomFavorite = onSaveCreatedRoomFavorite
        self.candidatesProvider = candidatesProvider
        self.onJoinMultiple = onJoinMultiple
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            VStack(spacing: 0) {
                tabSelector
                if sizeClass == .regular {
                    historyList
                } else {
                    tabDetailContent
                }
            }
            .navigationTitle(L("Assistant"))
            .toolbar { hubToolbar }
        } detail: {
            Group {
                if sizeClass == .regular && selectedTab != .history {
                    tabDetailContent
                        .navigationTitle(selectedTab.title)
                } else if let selectedID = selectedSessionID ?? visibleHistory.first?.id {
                    IOSMeetingDetailView(workspace: workspace, sync: sync, sessionID: selectedID, skills: skills)
                } else {
                    ContentUnavailableView(
                        L("No Meetings Yet"),
                        systemImage: "note.text",
                        description: Text(L("Recorded meetings, summaries, notes, and tasks synced from your Mac and iPhone appear here."))
                    )
                }
            }
            .toolbar {
                if sizeClass == .regular {
                    trailingHubToolbarItems
                }
            }
        }
        .onChange(of: sizeClass) { _, newClass in
            if newClass == .compact && selectedTab != .history {
                compactColumn = .sidebar
            }
        }
        .onChange(of: showingBoardSheet) { _, isShowing in
            board?.isInlineSheetActive = isShowing
        }
        .onDisappear {
            board?.isInlineSheetActive = false
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                IOSAssistantSettingsView(
                    workspace: workspace,
                    sync: sync,
                    assistant: assistant,
                    skills: skills,
                    board: board
                )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("Done")) { showingSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSkillsSheet) {
            if let skills, let board {
                NavigationStack {
                    IOSAssistantSkillsView(skills: skills, board: board)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("Done")) { showingSkillsSheet = false }
                            }
                        }
                }
            }
        }
        .modifier(
            IOSOptionalObservedBoardSheetModifier(
                board: board,
                showingBoardSheet: $showingBoardSheet,
                showingSkillsSheet: showingSkillsSheet,
                showingSettings: showingSettings,
                defaultBoardURL: board?.defaultBoardURLForTarget?(selectedSessionID)
                    ?? board?.defaultBoardURLProvider?()
                    ?? workspace.resolvedJiraBoardConfig(
                        for: selectedSessionID,
                        defaultBoardURL: skills?.teamContext.defaultJiraBoardURL ?? "",
                        defaultProjectKey: skills?.teamContext.defaultJiraProjectKey ?? "",
                        lastBoardURL: skills?.lastBoardURL,
                        jiraSettings: workspace.taskSync.preferences.jira
                    ).boardURL?.absoluteString
                    ?? ""
            )
        )
        .confirmationDialog(
            L("Delete Meeting?"),
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let session = pendingDeleteSession {
                Button(L("Delete"), role: .destructive) {
                    Task { await workspace.deleteSession(session.id) }
                    pendingDeleteSession = nil
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingDeleteSession = nil }
        } message: {
            if let session = pendingDeleteSession {
                Text(session.title)
            }
        }
        .sheet(isPresented: $showingMultiJoinSheet) {
            if let skills {
                IOSMultiMeetingRockJoinSheet(
                    candidates: candidatesProvider?() ?? [],
                    skills: skills
                ) { chosen, skillID, enableVoice in
                    onJoinMultiple?(chosen, skillID, enableVoice)
                }
            }
        }
        .alert(L("Rename Meeting"), isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField(L("Title"), text: $renameDraft)
            Button(L("Cancel"), role: .cancel) { renamingSession = nil }
            Button(L("Save")) {
                if let session = renamingSession {
                    let title = renameDraft
                    renamingSession = nil
                    Task { await workspace.renameSession(session.id, title: title) }
                }
            }
        }
        .task {
            await workspace.reloadFromStore()
        }
    }

    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(IOSWorkspaceHubTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    let labelText = (tab == .tasks && workspace.openTasksCount > 0)
                        ? "\(tab.title) (\(workspace.openTasksCount))"
                        : tab.title
                    Button {
                        selectedTab = tab
                        if sizeClass == .regular {
                            compactColumn = tab == .history ? .sidebar : .detail
                        }
                    } label: {
                        Text(labelText)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 36)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.rockBrandTint : .primary)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("workspace.hub.mode")
    }

    @ViewBuilder
    private var tabDetailContent: some View {
        switch selectedTab {
        case .ask:
            if let talk, let speech {
                IOSAssistantTalkView(talk: talk, speech: speech)
            } else {
                IOSStandaloneAskView(workspace: workspace, assistant: assistant)
            }
        case .history:
            historyList
        case .calendar:
            IOSUnifiedCalendarView(
                workspace: workspace,
                calendar: calendar,
                history: history,
                continuation: continuation,
                suggestedSiteOrigins: suggestedSiteOrigins,
                defaultDisplayName: defaultDisplayName,
                onOpenMeeting: { sessionID in
                    openMeeting(sessionID)
                },
                onJoinCalendarMeeting: onJoinCalendarMeeting,
                onOpenCalendarSettings: onOpenCalendarSettings,
                onSaveCreatedRoomFavorite: onSaveCreatedRoomFavorite
            )
        case .tasks:
            IOSPersonalTasksView(workspace: workspace) { sessionID in
                openMeeting(sessionID)
            }
        case .search:
            searchView
        }
    }

    @ToolbarContentBuilder
    private var hubToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L("Done")) { dismiss() }
        }
        if sizeClass != .regular {
            trailingHubToolbarItems
        }
    }

    @ToolbarContentBuilder
    private var trailingHubToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectedTab == .history || sizeClass == .regular {
                Menu {
                    Toggle(L("Show empty meetings"), isOn: $showEmptyMeetings)
                } label: {
                    Image(systemName: showEmptyMeetings ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(L("Show empty meetings"))
            }

            if skills != nil {
                Menu {
                    Button {
                        showingSkillsSheet = true
                    } label: {
                        Label(L("Skills, Prompts & People.md"), systemImage: "doc.text.magnifyingglass")
                    }
                    if board != nil {
                        Button {
                            showingBoardSheet = true
                        } label: {
                            Label(L("Open Assistant Board"), systemImage: "macwindow")
                        }
                    }
                    if onJoinMultiple != nil {
                        Button {
                            showingMultiJoinSheet = true
                        } label: {
                            Label(L("Join Meetings with Rock…"), systemImage: "person.2.wave.2")
                        }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .accessibilityLabel(L("Assistant Tools"))
            }

            Button {
                Task { await workspace.synchronizeNow() }
            } label: {
                if workspace.isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .accessibilityLabel(L("Sync Now"))
            .disabled(!sync.enabled || workspace.isSyncing)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("workspace.hub.settings")
            .accessibilityLabel(L("Assistant Settings"))
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let allHistory = workspace.historySessions
        let history = visibleHistory
        if allHistory.isEmpty {
            ContentUnavailableView(
                L("No Meetings Yet"),
                systemImage: "note.text",
                description: Text(L("Start or join a meeting on iPhone or Mac to capture synced notes, summaries, and tasks."))
            )
        } else if history.isEmpty {
            ContentUnavailableView {
                Label(L("Empty Meetings Hidden"), systemImage: "eye.slash")
            } description: {
                Text(L("Empty or test meetings are hidden by default."))
            } actions: {
                Button(L("Show empty meetings")) { showEmptyMeetings = true }
            }
        } else {
            let openTaskCounts = workspace.tasks.reduce(into: [UUID: Int]()) { counts, task in
                if !task.done {
                    counts[task.sessionID, default: 0] += 1
                }
            }
            let sections = historySections(from: history)
            let markers = historyDayMarkers(for: sections)
            let activeDay = selectedHistoryDay ?? sections.first?.dayStart
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            CompactWeekStripView(
                                referenceDate: activeDay ?? Date(),
                                selectedDate: activeDay,
                                markersByDay: markers,
                                calendar: historyCalendar,
                                onSelectDay: { day in
                                    jumpToHistoryDay(day, sections: sections, proxy: proxy)
                                }
                            )
                            Button {
                                if !showingHistoryMonthGrid {
                                    historyScrubberMonth = activeDay ?? Date()
                                }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingHistoryMonthGrid.toggle()
                                }
                            } label: {
                                Image(systemName: showingHistoryMonthGrid ? "calendar.circle.fill" : "calendar")
                                    .font(.title3)
                                    .foregroundStyle(showingHistoryMonthGrid ? Color.rockBrandTint : .secondary)
                                    .frame(minWidth: 36, minHeight: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Jump to date"))
                            .accessibilityIdentifier("ios.history.calendar.toggle")
                        }
                        if showingHistoryMonthGrid {
                            CompactMonthScrubberView(
                                displayedMonth: $historyScrubberMonth,
                                selectedDate: activeDay,
                                markersByDay: markers,
                                calendar: historyCalendar,
                                onSelectDay: { day in
                                    jumpToHistoryDay(day, sections: sections, proxy: proxy)
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showingHistoryMonthGrid = false
                                    }
                                },
                                onToday: {
                                    let today = historyCalendar.startOfDay(for: Date())
                                    if sections.contains(where: { historyCalendar.isDate($0.dayStart, inSameDayAs: today) }) {
                                        jumpToHistoryDay(today, sections: sections, proxy: proxy)
                                    } else if let latest = sections.first?.dayStart {
                                        jumpToHistoryDay(latest, sections: sections, proxy: proxy)
                                    }
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showingHistoryMonthGrid = false
                                    }
                                }
                            )
                            .accessibilityIdentifier("ios.history.calendar.scrubber")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))

                    List(selection: sizeClass == .regular ? $selectedSessionID : .constant(nil)) {
                        ForEach(sections, id: \.dayStart) { section in
                            Section {
                                ForEach(section.sessions) { session in
                                    Button {
                                        selectedHistoryDay = section.dayStart
                                        openMeeting(session.id)
                                    } label: {
                                        meetingRow(session, openTasks: openTaskCounts[session.id] ?? 0)
                                    }
                                    .buttonStyle(.plain)
                                    .tag(session.id)
                                    .id(session.id)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDeleteSession = session
                                        } label: {
                                            Label(L("Delete"), systemImage: "trash")
                                        }
                                        Button {
                                            renameDraft = session.title
                                            renamingSession = session
                                        } label: {
                                            Label(L("Rename"), systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(historyDayTitle(section.dayStart))
                                    Spacer()
                                    Text("\(section.sessions.count)")
                                        .foregroundStyle(.secondary)
                                }
                                .id(section.dayStart)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await workspace.synchronizeNow()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                        historyCalendar = Calendar.current
                    }
                }
            }
        }
    }

    private func historySections(from items: [IOSMeetingSessionItem]) -> [(dayStart: Date, sessions: [IOSMeetingSessionItem])] {
        Dictionary(grouping: items) { item in
            historyCalendar.startOfDay(for: item.startedAt)
        }
        .map { entry in
            (
                dayStart: entry.key,
                sessions: entry.value.sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
            )
        }
        .sorted { $0.dayStart > $1.dayStart }
    }

    private func historyDayMarkers(for sections: [(dayStart: Date, sessions: [IOSMeetingSessionItem])]) -> [Date: CompactCalendarDayMarker] {
        var markers: [Date: CompactCalendarDayMarker] = [:]
        for section in sections {
            markers[section.dayStart] = CompactCalendarDayMarker(primaryCount: section.sessions.count)
        }
        return markers
    }

    private func historyDayTitle(_ dayStart: Date) -> String {
        if historyCalendar.isDateInToday(dayStart) {
            return L("Today") + " · " + dayStart.formatted(.dateTime.day().month(.wide))
        }
        if historyCalendar.isDateInYesterday(dayStart) {
            return L("Yesterday") + " · " + dayStart.formatted(.dateTime.day().month(.wide))
        }
        return dayStart.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func jumpToHistoryDay(
        _ day: Date,
        sections: [(dayStart: Date, sessions: [IOSMeetingSessionItem])],
        proxy: ScrollViewProxy
    ) {
        let target = historyCalendar.startOfDay(for: day)
        guard let section = sections.first(where: { historyCalendar.isDate($0.dayStart, inSameDayAs: target) }) else {
            return
        }
        selectedHistoryDay = section.dayStart
        historyScrubberMonth = section.dayStart
        if sizeClass == .regular,
           let firstID = section.sessions.first?.id,
           !section.sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = firstID
        }
        if let firstID = section.sessions.first?.id {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(firstID, anchor: .top)
            }
        }
    }

    private func meetingRow(_ session: IOSMeetingSessionItem, openTasks: Int) -> some View {
        let outcome = workspace.outcomesBySession[session.id]
        let note = workspace.notesBySession[session.id]

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                obsidianBadge(for: session.obsidianReceipt)
            }

            HStack(spacing: 8) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let endedAt = session.endedAt, endedAt > session.startedAt {
                    let minutes = max(1, Int((endedAt.timeIntervalSince(session.startedAt) / 60).rounded()))
                    Text(L("· %ld min", minutes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if openTasks > 0 {
                    Text(L("%ld tasks", openTasks))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if note?.isEmpty == false {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = outcome?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let preview = note?.markdown.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func obsidianBadge(for receipt: ObsidianSyncReceipt?) -> some View {
        if let receipt {
            switch receipt.state {
            case "exported":
                Label(L("Obsidian"), systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case "conflict":
                Label(L("Conflict"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            default:
                Label(L("Queued"), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("Search meetings, notes, summaries, tasks"), text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchHits = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L("Clear"))
                }
            }
            .padding(10)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .task(id: searchQuery) {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchHits = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                searchHits = await workspace.search(query: searchQuery)
            }

            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    L("Search Workspace"),
                    systemImage: "magnifyingglass",
                    description: Text(L("Find any synced meeting title, Markdown note, summary, or task."))
                )
            } else if searchHits.isEmpty {
                ContentUnavailableView(
                    L("No Results"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L("No meetings matched “%@”.", searchQuery))
                )
            } else {
                List(searchHits) { hit in
                    Button {
                        openMeeting(hit.sessionID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title).font(.headline)
                            Text(hit.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func openMeeting(_ sessionID: UUID) {
        selectedSessionID = sessionID
        if sizeClass == .regular {
            selectedTab = .history
        }
        compactColumn = .detail
    }
}

private struct IOSStandaloneAskView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    @StateObject private var speech: IOSAssistantSpeechCoordinator
    @StateObject private var talk: IOSAssistantTalkController

    init(workspace: IOSWorkspaceCoordinator, assistant: IOSAssistantCoordinator) {
        self.workspace = workspace
        self.assistant = assistant
        let speech = IOSAssistantSpeechCoordinator()
        _speech = StateObject(wrappedValue: speech)
        _talk = StateObject(wrappedValue: IOSAssistantTalkController(workspace: workspace, assistant: assistant, speech: speech))
    }

    var body: some View {
        IOSAssistantTalkView(talk: talk, speech: speech)
    }
}

private struct IOSOptionalObservedBoardSheetModifier: ViewModifier {
    var board: IOSAssistantBoardController?
    @Binding var showingBoardSheet: Bool
    let showingSkillsSheet: Bool
    let showingSettings: Bool
    let defaultBoardURL: String

    func body(content: Content) -> some View {
        if let board {
            content.modifier(
                IOSObservedBoardSheetModifier(
                    board: board,
                    showingBoardSheet: $showingBoardSheet,
                    showingSkillsSheet: showingSkillsSheet,
                    showingSettings: showingSettings,
                    defaultBoardURL: defaultBoardURL
                )
            )
        } else {
            content
        }
    }
}

private struct IOSObservedBoardSheetModifier: ViewModifier {
    @ObservedObject var board: IOSAssistantBoardController
    @Binding var showingBoardSheet: Bool
    let showingSkillsSheet: Bool
    let showingSettings: Bool
    let defaultBoardURL: String

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { showingBoardSheet || (board.isPresented && !board.isInlineSheetActive && !showingSkillsSheet && !showingSettings) },
            set: { newValue in
                showingBoardSheet = newValue
                if !newValue { board.isPresented = false }
            }
        )) {
            IOSAssistantBoardSheet(
                controller: board,
                defaultBoardURL: defaultBoardURL
            )
        }
    }
}
