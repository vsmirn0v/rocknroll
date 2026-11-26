import ConferenceCore
import SwiftUI
import UIKit

enum IOSMeetingDetailTab: String, CaseIterable, Identifiable {
    case summary
    case notes
    case transcript
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return L("Summary")
        case .notes: return L("Notes")
        case .transcript: return L("Transcript")
        case .settings: return L("Settings")
        }
    }
}

struct IOSMeetingDetailView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    let sessionID: UUID
    var skills: IOSAssistantSkillsController? = nil

    @State private var linkedRecordID: UUID?
    @State private var tab: IOSMeetingDetailTab = .summary
    @State private var noteText = ""
    @State private var previewNotes = false

    @State private var editingOutcome = false
    @State private var summaryDraft = ""
    @State private var decisionsDraft = ""
    @State private var questionsDraft = ""
    @State private var selectedVersion: SyncedOutcomeVersionSnapshot?

    @State private var showingAddTask = false
    @State private var editingTask: IOSMeetingTaskItem?
    @State private var newTaskText = ""
    @State private var newTaskOwner = ""
    @State private var newTaskDue = ""
    @State private var newTaskHasReminder = false
    @State private var newTaskReminder = Date().addingTimeInterval(3600)

    @State private var transcriptEvents: [SyncedTranscriptEvent] = []
    @State private var foldedTranscriptIndex: [String: String] = [:]
    @State private var transcriptIsLocalOnly = false
    @State private var transcriptSearch = ""
    @State private var copiedTranscriptFeedback = false
    @State private var cachedPreviewMarkdown: AttributedString?
    @State private var cachedPreviewSource = ""

    @State private var transitionChoice: IOSSameRoomTransitionMode?
    @State private var useSeriesScope = false
    @State private var autoJoinChoice: Bool?
    @State private var autoFacilitatorSkillID: String?
    @State private var availableSkills: [AssistantSkill] = []
    @State private var aboutDraft = ""
    @State private var mattersDraft = ""
    @State private var neverDraft = ""
    @State private var peopleDraft = ""
    @State private var jiraBoardURLDraft = ""
    @State private var jiraProjectKeysDraft = ""
    @State private var autoExportOverridesDraft = MeetingAutoExportOverrides()
    @State private var newRuleDraft = ""
    @State private var settingsSaved = false
    @State private var isLoadingContext = false
    @State private var meetingSnapshots: [MeetingSnapshotRecord] = []
    @State private var loadedSnapshotKey = ""
    @State private var currentSnapshotKey = ""
    @State private var selectedSnapshotID: UUID?

    private var resolvedSessionID: UUID {
        workspace.canonicalSessionID(for: sessionID)
    }

    private var snapshotSessionIDs: [UUID] {
        workspace.relatedSnapshotSessionIDs(for: sessionID)
    }

    private var snapshotSessionKey: String {
        snapshotSessionIDs.map(\.uuidString).joined(separator: ",")
    }

    private var visibleMeetingSnapshots: [MeetingSnapshotRecord] {
        loadedSnapshotKey == snapshotSessionKey ? meetingSnapshots : []
    }

    private var selectedSnapshotBinding: Binding<MeetingSnapshotRecord?> {
        Binding(
            get: {
                guard let id = selectedSnapshotID else { return nil }
                return visibleMeetingSnapshots.first(where: { $0.id == id })
            },
            set: { selectedSnapshotID = $0?.id }
        )
    }

    private var session: IOSMeetingSessionItem? {
        workspace.sessions.first { $0.id == resolvedSessionID }
    }

    private var outcome: IOSMeetingOutcomeItem? {
        workspace.outcomesBySession[resolvedSessionID]
    }

    private var note: IOSMeetingNoteItem? {
        workspace.notesBySession[resolvedSessionID]
    }

    private var sessionTasks: [IOSMeetingTaskItem] {
        workspace.tasks.filter { $0.sessionID == resolvedSessionID }
    }

    private var preferredSeriesID: String? {
        let local = session?.calendarSeriesID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let external = session?.externalSeriesID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !local.isEmpty, workspace.settings(for: "series:" + local) != nil,
           external.isEmpty || workspace.settings(for: "series:" + external) == nil {
            return local
        }
        if !external.isEmpty { return external }
        return local.isEmpty ? nil : local
    }

    private func scopeDescriptor(useSeries: Bool) -> (key: String, kind: SyncedMeetingContextSettings.ScopeKind) {
        if useSeries, let series = preferredSeriesID, !series.isEmpty {
            return ("series:" + series, .calendarSeries)
        }
        if let room = session?.invitation?.absoluteString ?? session?.roomIdentity, !room.isEmpty {
            return ("room:" + room, .room)
        }
        return ("session:" + sessionID.uuidString, .room)
    }

    private var contextScopeKey: String {
        scopeDescriptor(useSeries: useSeriesScope).key
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(IOSMeetingDetailTab.allCases) { item in
                        let isSelected = tab == item
                        Button {
                            tab = item
                        } label: {
                            Text(item.title)
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
            .accessibilityIdentifier("workspace.detail.tab")

            let sources = workspace.linkedHistorySources(for: sessionID)
            if !sources.isEmpty {
                Menu(L("Linked meeting records")) {
                    ForEach(sources) { source in
                        Button(source.title + " · " + source.startedAt.formatted(date: .abbreviated, time: .shortened)) {
                            linkedRecordID = source.id
                        }
                    }
                }.padding(.bottom, 6)
            }

            switch tab {
            case .summary:
                summaryView
            case .notes:
                notesView
            case .transcript:
                transcriptView
            case .settings:
                settingsView
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(session?.title ?? L("Meeting"))
        .navigationDestination(item: $linkedRecordID) { id in
            IOSMeetingDetailView(workspace: workspace, sync: sync, sessionID: id, skills: skills)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if tab == .transcript && !transcriptEvents.isEmpty {
                    Button {
                        copyTranscript()
                    } label: {
                        Image(systemName: copiedTranscriptFeedback ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(L("Copy transcript"))
                    Button {
                        exportTranscriptMarkdown()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(L("Export transcript"))
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("Done")) {
                    if tab == .settings {
                        flushPendingJiraDraftsIfNeeded()
                    }
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onAppear {
            loadInitialState()
        }
        .onChange(of: sessionID) { _, _ in
            loadInitialState()
            Task { await loadTranscript() }
        }
        .onChange(of: tab) { oldTab, _ in
            if oldTab == .settings {
                flushPendingJiraDraftsIfNeeded()
            }
        }
        .onChange(of: previewNotes) { _, isPreview in
            if isPreview { refreshNotePreviewIfNeeded() }
        }
        .onChange(of: noteText) { _, _ in
            if previewNotes { refreshNotePreviewIfNeeded() }
        }
        .task(id: sessionID) {
            await loadTranscript()
        }
        .onDisappear {
            flushPendingJiraDraftsIfNeeded()
            Task { await workspace.flushNotesNow() }
        }
        .sheet(item: $editingTask) { task in IOSMeetingTaskEditor(workspace: workspace, task: task) }
        .sheet(isPresented: $showingAddTask) {
            NavigationStack {
                Form {
                    Section(L("Task")) {
                        TextField(L("What needs to be done?"), text: $newTaskText)
                        TextField(L("Owner"), text: $newTaskOwner)
                        TextField(L("Due day (optional, e.g. 2026-12-01)"), text: $newTaskDue)
                    }
                    Section {
                        Toggle(L("Remind me"), isOn: $newTaskHasReminder)
                        if newTaskHasReminder {
                            DatePicker(L("Reminder"), selection: $newTaskReminder, in: Date()...)
                        }
                    }
                }
                .navigationTitle(L("New Task"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Cancel")) { showingAddTask = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Add")) {
                            let text = newTaskText
                            let owner = newTaskOwner
                            let due = newTaskDue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newTaskDue
                            let reminder = newTaskHasReminder ? newTaskReminder : nil
                            newTaskText = ""
                            newTaskOwner = ""
                            newTaskDue = ""
                            newTaskHasReminder = false
                            showingAddTask = false
                            Task {
                                await workspace.addTask(
                                    sessionID: sessionID,
                                    text: text,
                                    owner: owner,
                                    dueDay: due,
                                    reminderAt: reminder
                                )
                            }
                        }
                        .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedVersion.map { IdentifiableVersion(snapshot: $0) } },
            set: { selectedVersion = $0?.snapshot }
        )) { item in
            NavigationStack {
                List {
                    Section(L("Summary")) {
                        Text(item.snapshot.summary)
                    }
                    if !item.snapshot.decisions.isEmpty {
                        Section(L("Decisions")) {
                            ForEach(Array(item.snapshot.decisions.enumerated()), id: \.offset) { _, decision in
                                Text(decision)
                            }
                        }
                    }
                    if !item.snapshot.openQuestions.isEmpty {
                        Section(L("Open Questions")) {
                            ForEach(Array(item.snapshot.openQuestions.enumerated()), id: \.offset) { _, question in
                                Text(question)
                            }
                        }
                    }
                }
                .navigationTitle(L("Previous Version"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Close")) { selectedVersion = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Restore")) {
                            let restored = item.snapshot
                            selectedVersion = nil
                            Task {
                                await workspace.saveEditedOutcome(
                                    sessionID: sessionID,
                                    summary: restored.summary,
                                    decisions: restored.decisions,
                                    openQuestions: restored.openQuestions
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Summary Tab

    private var summaryView: some View {
        List {
            if let session {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                            if let endedAt = session.endedAt, endedAt > session.startedAt {
                                let mins = max(1, Int((endedAt.timeIntervalSince(session.startedAt) / 60).rounded()))
                                Text(L("Duration: %ld min", mins))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            editingOutcome = false
                            Task { await workspace.generateOutcomeNow(sessionID: resolvedSessionID) }
                        } label: {
                            if workspace.generatingSessionIDs.contains(resolvedSessionID) {
                                ProgressView()
                            } else {
                                Label(
                                    outcome == nil ? L("Generate Summary") : L("Regenerate"),
                                    systemImage: "sparkles"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(workspace.generatingSessionIDs.contains(resolvedSessionID))
                    }

                    if let error = workspace.outcomeErrors[resolvedSessionID] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if !visibleMeetingSnapshots.isEmpty {
                IOSMeetingSnapshotsSection(snapshots: visibleMeetingSnapshots) { snap in
                    selectedSnapshotID = snap.id
                }
            }

            if let outcome {
                Section {
                    if editingOutcome {
                        TextEditor(text: $summaryDraft)
                            .frame(minHeight: 110)
                    } else if !outcome.summary.isEmpty {
                        Text(outcome.summary)
                            .font(.body)
                    } else {
                        Text(L("Summary pending…"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(L("Summary"))
                        Spacer()
                        Button(editingOutcome ? L("Save") : L("Edit")) {
                            if editingOutcome {
                                let decs = decisionsDraft.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                let qs = questionsDraft.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                editingOutcome = false
                                Task {
                                    await workspace.saveEditedOutcome(
                                        sessionID: resolvedSessionID,
                                        summary: summaryDraft,
                                        decisions: decs,
                                        openQuestions: qs
                                    )
                                }
                            } else {
                                summaryDraft = outcome.summary
                                decisionsDraft = outcome.decisions.joined(separator: "\n")
                                questionsDraft = outcome.openQuestions.joined(separator: "\n")
                                editingOutcome = true
                            }
                        }
                        .font(.caption)
                        .disabled(workspace.generatingSessionIDs.contains(resolvedSessionID))
                    }
                }

                if editingOutcome || !outcome.decisions.isEmpty {
                    Section(L("Decisions")) {
                        if editingOutcome {
                            TextEditor(text: $decisionsDraft)
                                .frame(minHeight: 70)
                        } else {
                            ForEach(Array(outcome.decisions.enumerated()), id: \.offset) { _, decision in
                                Label(decision, systemImage: "checkmark.seal")
                            }
                        }
                    }
                }

                if editingOutcome || !outcome.openQuestions.isEmpty {
                    Section(L("Open Questions")) {
                        if editingOutcome {
                            TextEditor(text: $questionsDraft)
                                .frame(minHeight: 70)
                        } else {
                            ForEach(Array(outcome.openQuestions.enumerated()), id: \.offset) { _, question in
                                Label(question, systemImage: "questionmark.circle")
                            }
                        }
                    }
                }

                if !outcome.reviewCandidates.isEmpty {
                    Section(L("Possible Duplicate Tasks to Review")) {
                        ForEach(outcome.reviewCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(candidate.text).font(.subheadline)
                                if !candidate.owner.isEmpty {
                                    Text(candidate.owner).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button(L("Add Task")) {
                                        Task { await workspace.acceptReviewCandidate(candidate, sessionID: sessionID) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    Button(L("Dismiss")) {
                                        Task { await workspace.dismissReviewCandidate(candidate.id, sessionID: sessionID) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !outcome.versions.isEmpty {
                    Section(L("Other Generated Versions")) {
                        ForEach(Array(outcome.versions.enumerated()), id: \.offset) { _, version in
                            Button {
                                selectedVersion = version
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Version #%ld", version.revision))
                                        .font(.subheadline.weight(.medium))
                                    Text(version.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                if sessionTasks.isEmpty {
                    Text(L("No action items yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionTasks) { task in
                        HStack(spacing: 10) {
                            Button {
                                Task { await workspace.toggleTaskDone(task.id) }
                            } label: {
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.done ? .green : .secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Task completed"))
                            .accessibilityValue(task.done ? L("Done") : L("Open"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.text)
                                    .strikethrough(task.done)
                                    .foregroundStyle(task.done ? .secondary : .primary)
                                if !task.owner.isEmpty || task.dueDay != nil {
                                    Text([task.owner, task.dueDay].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(L("Edit")) { editingTask = task }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L("Tasks"))
                    Spacer()
                    Button(L("Add Task")) { showingAddTask = true }
                        .font(.caption)
                }
            }

            Section(L("Obsidian on Mac")) {
                if let receipt = session?.obsidianReceipt {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(obsidianStateLabel(receipt.state), systemImage: obsidianStateIcon(receipt.state))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(receipt.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let path = receipt.relativePath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let err = receipt.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let included = receipt.transcriptIncluded, receipt.state == "exported" {
                            Text(included ? L("Transcript included") : L("Transcript was unavailable on the Mac."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L("Not exported to Obsidian yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await workspace.requestSaveInObsidian(sessionID: sessionID) }
                } label: {
                    Label(L("Save in Obsidian on Mac"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!sync.enabled)
                if transcriptIsLocalOnly, transcriptEvents.contains(where: { $0.kind == "transcript" }) {
                    Text(L("This transcript is stored locally on this iPhone. Obsidian export uses the transcript available on the Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .task(id: snapshotSessionKey) {
            currentSnapshotKey = snapshotSessionKey
            let loaded = await MeetingSnapshotStore.shared.snapshots(for: snapshotSessionIDs)
            guard !Task.isCancelled, currentSnapshotKey == snapshotSessionKey else { return }
            meetingSnapshots = loaded
            loadedSnapshotKey = snapshotSessionKey
        }
        .onReceive(NotificationCenter.default.publisher(for: MeetingSnapshotStore.didChangeNotification)) { notification in
            if let changedID = notification.userInfo?["sessionID"] as? UUID,
               !snapshotSessionIDs.contains(changedID) {
                return
            }
            let targetKey = snapshotSessionKey
            let targetIDs = snapshotSessionIDs
            Task {
                let loaded = await MeetingSnapshotStore.shared.snapshots(for: targetIDs)
                guard currentSnapshotKey == targetKey else { return }
                meetingSnapshots = loaded
                loadedSnapshotKey = targetKey
            }
        }
        .sheet(item: selectedSnapshotBinding) { snap in
            IOSMeetingSnapshotLightboxView(
                record: snap,
                onSaveCaption: { caption in
                    Task {
                        _ = try? await MeetingSnapshotStore.shared.updateCaption(caption, snapshotID: snap.id, sessionID: snap.sessionID)
                        let loaded = await MeetingSnapshotStore.shared.snapshots(for: snapshotSessionIDs)
                        meetingSnapshots = loaded
                        loadedSnapshotKey = snapshotSessionKey
                    }
                },
                onDelete: {
                    Task {
                        try? await MeetingSnapshotStore.shared.delete(snapshotID: snap.id, sessionID: snap.sessionID)
                        selectedSnapshotID = nil
                        let loaded = await MeetingSnapshotStore.shared.snapshots(for: snapshotSessionIDs)
                        meetingSnapshots = loaded
                        loadedSnapshotKey = snapshotSessionKey
                    }
                }
            )
        }
    }

    // MARK: - Notes Tab

    private var notesView: some View {
        VStack(spacing: 10) {
            if note?.hasConflictMarkers == true {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("Concurrent note edits created conflict markers below. Review and keep the text you want."))
                        .font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }

            Picker(L("Note View"), selection: $previewNotes) {
                Text(L("Edit Markdown")).tag(false)
                Text(L("Preview")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if previewNotes {
                ScrollView {
                    let source = noteText.isEmpty ? L("_No notes yet._") : noteText
                    if let attributed = (cachedPreviewSource == source ? cachedPreviewMarkdown : nil)
                        ?? (try? AttributedString(markdown: source)) {
                        Text(attributed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        Text(noteText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            } else {
                TextEditor(text: $noteText)
                    .font(.body)
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom)
                    .onChange(of: noteText) { _, newValue in
                        workspace.updateNoteDraft(newValue, for: sessionID)
                    }
            }
        }
    }

    // MARK: - Transcript Tab

    private var transcriptView: some View {
        let trimmed = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).workspaceFolded
        let filtered = trimmed.isEmpty ? transcriptEvents : transcriptEvents.filter { event in
            let haystack = foldedTranscriptIndex[event.id]
                ?? "\((event.speaker ?? "")) \(event.text)".workspaceFolded
            return haystack.contains(trimmed)
        }

        return VStack(spacing: 8) {
            if transcriptIsLocalOnly {
                Label(
                    L("Stored locally or in transcript backup folder (aged out of iCloud sync)"),
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }

            TextField(L("Filter transcript"), text: $transcriptSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if !transcriptEvents.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        copyTranscript()
                    } label: {
                        Label(
                            copiedTranscriptFeedback ? L("Copied") : L("Copy transcript"),
                            systemImage: copiedTranscriptFeedback ? "checkmark" : "doc.on.doc"
                        )
                        .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workspace.transcript.copy")

                    Button {
                        exportTranscriptMarkdown()
                    } label: {
                        Label(L("Export Markdown"), systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workspace.transcript.export")

                    Spacer()
                }
                .padding(.horizontal)
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    L("No Transcript"),
                    systemImage: "text.alignleft",
                    description: Text(L("Speech transcripts and chat messages from Mac and iPhone appear here."))
                )
            } else {
                List(filtered) { event in
                    let isAssistant = AssistantSpeechLedger.isAssistantSpeaker(event.speaker, role: event.speakerRole)
                    let speakerLabel = isAssistant
                        ? L("Rock Assistant")
                        : AssistantSpeechLedger.displayAuthor(
                            speaker: event.speaker,
                            isOwn: event.isOwn,
                            speakerRole: event.speakerRole,
                            youLabel: L("You")
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(speakerLabel.isEmpty ? L("Speaker") : speakerLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isAssistant ? Color.purple : (event.isOwn ? Color.accentColor : .secondary))
                            Spacer()
                            Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Settings Tab

    private var settingsView: some View {
        let currentRules = workspace.settings(for: contextScopeKey)?.guidanceRules.values
            .map(\.value)
            .filter { !$0.deleted } ?? []

        return Form {
            if let series = preferredSeriesID, !series.isEmpty {
                Section {
                    Toggle(L("Apply to entire calendar series"), isOn: $useSeriesScope)
                        .onChange(of: useSeriesScope) { oldValue, _ in
                            let oldScope = scopeDescriptor(useSeries: oldValue)
                            flushPendingJiraDraftsIfNeeded(scopeKeyOverride: oldScope.key, scopeKindOverride: oldScope.kind)
                            loadContextFields()
                        }
                }
            }

            Section {
                Picker(L("Automatic joining"), selection: $autoJoinChoice) {
                    Text(L("Use default")).tag(Bool?.none)
                    Text(L("Always auto-join")).tag(Bool?.some(true))
                    Text(L("Never auto-join")).tag(Bool?.some(false))
                }
                .onChange(of: autoJoinChoice) { _, _ in
                    guard !isLoadingContext else { return }
                    saveCurrentContextSettings()
                }
                Picker(L("Auto-engage role assistant"), selection: $autoFacilitatorSkillID) {
                    Text(L("Off")).tag(String?.none)
                    ForEach(availableSkills) { skill in
                        Text(skill.name).tag(String?.some(skill.id))
                    }
                    if let saved = autoFacilitatorSkillID, !saved.isEmpty,
                       !availableSkills.contains(where: { $0.id == saved }) {
                        Text(saved).tag(String?.some(saved))
                    }
                }
                .onChange(of: autoFacilitatorSkillID) { _, _ in
                    guard !isLoadingContext else { return }
                    saveCurrentContextSettings()
                }
            } header: {
                Text(L("Joining & Role Assistant"))
            } footer: {
                Text(L("Keep this Off on shared team calls so multiple assistants do not talk over each other."))
            }

            Section(L("Back-to-back in this meeting")) {
                Picker(L("Same-room transition"), selection: $transitionChoice) {
                    Text(L("Use default")).tag(IOSSameRoomTransitionMode?.none)
                    ForEach(IOSSameRoomTransitionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(IOSSameRoomTransitionMode?.some(mode))
                    }
                }
                .onChange(of: transitionChoice) { _, _ in
                    guard !isLoadingContext else { return }
                    saveCurrentContextSettings()
                }
            }

            Section {
                TextField(
                    skills?.teamContext.defaultJiraBoardURL.isEmpty == false
                        ? (skills?.teamContext.defaultJiraBoardURL ?? "")
                        : "https://jira.example.com/secure/RapidBoard.jspa?rapidView=1",
                    text: $jiraBoardURLDraft
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { saveCurrentContextSettings() }
                TextField(
                    skills?.teamContext.defaultJiraProjectKey.isEmpty == false
                        ? L("Default: %@", skills?.teamContext.defaultJiraProjectKey ?? "")
                        : L("Jira project keys (e.g. SDBPROD, SPS)"),
                    text: $jiraProjectKeysDraft
                )
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onSubmit { saveCurrentContextSettings() }
                Button(L("Save Jira Settings")) {
                    saveCurrentContextSettings()
                }
                if settingsSaved {
                    Label(L("Saved"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text(L("Jira Board & Project"))
            } footer: {
                Text(L("Leave empty to use the app default Jira board and project keys."))
            }

            Section {
                autoExportOverridePicker(
                    L("Auto-generate summary after meeting"),
                    selection: autoExportBinding(\.autoGenerateSummary)
                )
                autoExportOverridePicker(
                    L("Auto-sync tasks after summary"),
                    selection: autoExportBinding(\.autoSyncTasks)
                )
                autoExportOverridePicker(
                    L("Obsidian auto-export"),
                    selection: autoExportBinding(\.autoExport)
                )
                autoExportOverridePicker(
                    L("Export transcript"),
                    selection: autoExportBinding(\.includeTranscript)
                )
                autoExportOverridePicker(
                    L("Export summary"),
                    selection: autoExportBinding(\.includeSummary)
                )
                autoExportOverridePicker(
                    L("Export notes"),
                    selection: autoExportBinding(\.includeNotes)
                )
                autoExportOverridePicker(
                    L("Export tasks"),
                    selection: autoExportBinding(\.includeTasks)
                )
                autoExportOverridePicker(
                    L("Export decisions"),
                    selection: autoExportBinding(\.includeDecisions)
                )
                autoExportOverridePicker(
                    L("Export open questions"),
                    selection: autoExportBinding(\.includeQuestions)
                )
                if !autoExportOverridesDraft.isEmpty {
                    Button(L("Reset export settings to defaults"), role: .destructive) {
                        autoExportOverridesDraft = .init()
                        saveCurrentContextSettings()
                    }
                }
            } header: {
                Text(L("Automatic Export & Post-Meeting"))
            } footer: {
                Text(L("Fields left on Use default follow your global app and Obsidian layout settings."))
            }

            Section(L("Assistant Context")) {
                TextField(L("What this meeting is about"), text: $aboutDraft, axis: .vertical)
                TextField(L("What matters most"), text: $mattersDraft, axis: .vertical)
                TextField(L("Never mention or focus on"), text: $neverDraft, axis: .vertical)
                TextField(L("People to listen for (comma separated)"), text: $peopleDraft)
                Button(L("Save Meeting Settings")) {
                    saveCurrentContextSettings()
                }
                if settingsSaved {
                    Label(L("Saved"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section(L("Private Guidance")) {
                HStack {
                    TextField(L("Add private guidance rule…"), text: $newRuleDraft)
                    Button(L("Add")) {
                        let text = newRuleDraft
                        newRuleDraft = ""
                        let kind: SyncedMeetingContextSettings.ScopeKind = useSeriesScope ? .calendarSeries : .room
                        Task {
                            await workspace.addGuidanceRule(
                                text,
                                scopeKey: contextScopeKey,
                                scopeKind: kind,
                                title: session?.title ?? L("Meeting")
                            )
                        }
                    }
                    .disabled(newRuleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(currentRules) { rule in
                    HStack {
                        Text(rule.text)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await workspace.removeGuidanceRule(id: rule.id, scopeKey: contextScopeKey) }
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L("Delete"))
                        .accessibilityValue(rule.text)
                    }
                }
            }
        }
    }

    private func autoExportBinding(_ keyPath: WritableKeyPath<MeetingAutoExportOverrides, Bool?>) -> Binding<Bool?> {
        Binding(
            get: { autoExportOverridesDraft[keyPath: keyPath] },
            set: { newValue in
                autoExportOverridesDraft[keyPath: keyPath] = newValue
                guard !isLoadingContext else { return }
                saveCurrentContextSettings()
            }
        )
    }

    private func autoExportOverridePicker(_ title: String, selection: Binding<Bool?>) -> some View {
        Picker(title, selection: selection) {
            Text(L("Use default")).tag(Bool?.none)
            Text(L("On")).tag(Bool?.some(true))
            Text(L("Off")).tag(Bool?.some(false))
        }
    }

    private func saveCurrentContextSettings(
        scopeKeyOverride: String? = nil,
        scopeKindOverride: SyncedMeetingContextSettings.ScopeKind? = nil
    ) {
        let people = peopleDraft.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let projectKeys = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: jiraProjectKeysDraft)
        let currentScope = scopeDescriptor(useSeries: useSeriesScope)
        let targetScopeKey = scopeKeyOverride ?? currentScope.key
        let targetKind = scopeKindOverride ?? currentScope.kind
        let titleSnapshot = session?.title ?? L("Meeting")
        let transitionSnapshot = transitionChoice?.rawValue
        let aboutSnapshot = aboutDraft
        let mattersSnapshot = mattersDraft
        let neverSnapshot = neverDraft
        let autoJoinSnapshot = autoJoinChoice
        let autoSkillSnapshot = autoFacilitatorSkillID
        let rawBoard = jiraBoardURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBoardSnapshot = SyncedMeetingContextSettings.normalizedBoardURLString(from: rawBoard)
        let hasInvalidBoardInput = !rawBoard.isEmpty && normalizedBoardSnapshot == nil
        let shouldUpdateBoardURL = !hasInvalidBoardInput
        if let normalizedBoardSnapshot, scopeKeyOverride == nil {
            jiraBoardURLDraft = normalizedBoardSnapshot
        }
        if !projectKeys.isEmpty, scopeKeyOverride == nil {
            jiraProjectKeysDraft = projectKeys.joined(separator: ", ")
        }
        let autoExportSnapshot = autoExportOverridesDraft
        let existingSettings = workspace.settings(for: targetScopeKey)
        let otherFieldsChanged: Bool = {
            let savedAbout = existingSettings?.about?.value ?? ""
            let savedMatters = existingSettings?.matters?.value ?? ""
            let savedNever = existingSettings?.never?.value ?? ""
            let savedPeople = existingSettings?.people?.value ?? []
            let savedAutoJoin = existingSettings?.autoJoin?.value
            let savedSkill = existingSettings?.autoFacilitatorSkillID?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAutoSkill = autoSkillSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedTransition = existingSettings?.sameRoomTransition?.value
            let savedProjects = existingSettings?.jiraProjectKeys?.value ?? []
            let savedAutoExport = existingSettings?.autoExportSettings?.overrides ?? .init()
            return aboutSnapshot != savedAbout
                || mattersSnapshot != savedMatters
                || neverSnapshot != savedNever
                || people != savedPeople
                || autoJoinSnapshot != savedAutoJoin
                || (cleanAutoSkill?.isEmpty == true ? nil : cleanAutoSkill) != (savedSkill?.isEmpty == true ? nil : savedSkill)
                || transitionSnapshot != savedTransition
                || projectKeys != savedProjects
                || autoExportSnapshot != savedAutoExport
        }()
        Task {
            await workspace.saveContextSettings(
                scopeKey: targetScopeKey,
                scopeKind: targetKind,
                title: titleSnapshot,
                sameRoomTransition: transitionSnapshot,
                about: aboutSnapshot,
                matters: mattersSnapshot,
                never: neverSnapshot,
                people: people,
                autoJoin: autoJoinSnapshot,
                updateAutoJoin: true,
                autoFacilitatorSkillID: autoSkillSnapshot,
                updateAutoFacilitatorSkillID: true,
                jiraBoardURL: normalizedBoardSnapshot ?? "",
                updateJiraBoardURL: shouldUpdateBoardURL,
                jiraProjectKeys: projectKeys,
                updateJiraProjectKeys: true,
                autoExportOverrides: autoExportSnapshot,
                updateAutoExportOverrides: true
            )
            if shouldUpdateBoardURL || otherFieldsChanged {
                settingsSaved = true
                try? await Task.sleep(for: .seconds(2))
                settingsSaved = false
            }
        }
    }

    // MARK: - Helpers

    private func loadInitialState() {
        editingOutcome = false
        noteText = workspace.noteDraft(for: sessionID)
        useSeriesScope = (preferredSeriesID?.isEmpty == false)
        availableSkills = (skills?.skills ?? DefaultAssistantSkills.all).filter(\.enabled)
        loadContextFields()
        if previewNotes { refreshNotePreviewIfNeeded() }
    }

    private func refreshNotePreviewIfNeeded() {
        let source = noteText.isEmpty ? L("_No notes yet._") : noteText
        guard source != cachedPreviewSource || cachedPreviewMarkdown == nil else { return }
        cachedPreviewSource = source
        cachedPreviewMarkdown = try? AttributedString(markdown: source)
    }

    private func loadContextFields() {
        isLoadingContext = true
        defer { isLoadingContext = false }
        let settings = workspace.settings(for: contextScopeKey)
        autoJoinChoice = settings?.autoJoin?.value
        let rawSkill = settings?.autoFacilitatorSkillID?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        autoFacilitatorSkillID = rawSkill.isEmpty ? nil : rawSkill
        transitionChoice = settings?.sameRoomTransition?.value.flatMap(IOSSameRoomTransitionMode.init(rawValue:))
        aboutDraft = settings?.about?.value ?? ""
        mattersDraft = settings?.matters?.value ?? ""
        neverDraft = settings?.never?.value ?? ""
        peopleDraft = settings?.people?.value.joined(separator: ", ") ?? ""
        jiraBoardURLDraft = settings?.jiraBoardURL?.value ?? ""
        jiraProjectKeysDraft = settings?.jiraProjectKeys?.value?.joined(separator: ", ") ?? ""
        autoExportOverridesDraft = settings?.autoExportSettings?.overrides ?? .init()
    }

    private func flushPendingJiraDraftsIfNeeded(
        scopeKeyOverride: String? = nil,
        scopeKindOverride: SyncedMeetingContextSettings.ScopeKind? = nil
    ) {
        guard !isLoadingContext else { return }
        let targetKey = scopeKeyOverride ?? contextScopeKey
        let settings = workspace.settings(for: targetKey)
        let savedBoard = (settings?.jiraBoardURL?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBoard = jiraBoardURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDraftBoard = SyncedMeetingContextSettings.normalizedBoardURLString(from: rawBoard)
        let boardDirty: Bool = {
            if rawBoard.isEmpty {
                return !savedBoard.isEmpty
            }
            guard let valid = normalizedDraftBoard else { return false }
            return valid != savedBoard
        }()
        let savedProjects = settings?.jiraProjectKeys?.value ?? []
        let draftProjects = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: jiraProjectKeysDraft)
        guard boardDirty || draftProjects != savedProjects else { return }
        saveCurrentContextSettings(scopeKeyOverride: scopeKeyOverride, scopeKindOverride: scopeKindOverride)
    }

    private func copyTranscript() {
        let text = TranscriptExportFormatter.formatPlainText(
            events: transcriptEvents,
            meetingTitle: session?.title,
            startedAt: session?.startedAt
        )
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copiedTranscriptFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedTranscriptFeedback = false
        }
    }

    private func exportTranscriptMarkdown() {
        let title = session?.title ?? L("Meeting")
        let startedAt = session?.startedAt ?? .distantPast
        let markdown = TranscriptExportFormatter.formatMarkdown(
            events: transcriptEvents,
            title: title,
            startedAt: startedAt,
            endedAt: session?.endedAt
        )
        guard !markdown.isEmpty else { return }
        let fileName = TranscriptExportFormatter.suggestedFileName(title: title, startedAt: session?.startedAt)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            presentActivitySheet(items: [url])
        } catch {
            AppDiagnostics.log("transcript-export-error", ["error": error.localizedDescription])
        }
    }

    private func presentActivitySheet(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController {
            presenter = next
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: 80, width: 1, height: 1)
        }
        presenter.present(sheet, animated: true)
    }

    private func loadTranscript() async {
        let (events, isLocal) = await workspace.historyTranscriptForDisplay(sessionID: sessionID)
        var index: [String: String] = Dictionary(minimumCapacity: events.count)
        for event in events {
            index[event.id] = "\((event.speaker ?? "")) \(event.text)".workspaceFolded
        }
        transcriptEvents = events
        foldedTranscriptIndex = index
        transcriptIsLocalOnly = isLocal
    }

    private func obsidianStateLabel(_ state: String) -> String {
        switch state {
        case "exported": return L("Exported to Obsidian")
        case "conflict": return L("Obsidian conflict — edit protected")
        case "held": return L("Held pending Obsidian policy")
        default: return L("Queued for Mac Obsidian export")
        }
    }

    private func obsidianStateIcon(_ state: String) -> String {
        switch state {
        case "exported": return "checkmark.circle.fill"
        case "conflict": return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }

    private struct IdentifiableVersion: Identifiable {
        var id: String { "\(snapshot.revision)-\(snapshot.deviceID)" }
        let snapshot: SyncedOutcomeVersionSnapshot
    }
}
