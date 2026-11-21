import ConferenceCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSAssistantSkillsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case skills
        case prompts
        case people
        case realtimeBoard

        var id: String { rawValue }
        var title: String {
            switch self {
            case .skills: return L("Skills")
            case .prompts: return L("Prompts")
            case .people: return L("People")
            case .realtimeBoard: return L("Realtime & Board")
            }
        }
    }

    @ObservedObject var skills: IOSAssistantSkillsController
    @ObservedObject var board: IOSAssistantBoardController

    @State private var selectedTab: Tab = .skills
    @State private var editingSkill: AssistantSkill?
    @State private var selectedPromptKind: AssistantPromptKind = .basePersona
    @State private var promptDraft = ""
    @State private var boardURLDraft = ""
    @State private var projectKeyDraft = ""
    @State private var teamNotesDraft = ""
    @State private var editingPerson: AssistantPersonEntry?
    @State private var realtimeKeyDraft = ""
    @State private var statusBanner: String?
    @State private var pickingVaultFolder = false
    @State private var showingBoardSheet = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .skills:
                skillsTab
            case .prompts:
                promptsTab
            case .people:
                peopleTab
            case .realtimeBoard:
                realtimeBoardTab
            }
        }
        .navigationTitle(L("Skills, Prompts & Knowledge"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDrafts() }
        .sheet(item: $editingSkill) { draft in
            IOSSkillEditorSheet(skill: draft) { updated in
                do {
                    _ = try skills.saveSkill(updated)
                    statusBanner = L("Saved skill “%@”.", updated.name)
                } catch {
                    statusBanner = error.localizedDescription
                }
            }
        }
        .sheet(item: $editingPerson) { person in
            IOSPersonEditorSheet(person: person) { updated in
                do {
                    _ = try skills.upsertPerson(updated)
                    statusBanner = L("Saved %@ in People.md.", updated.displayName)
                } catch {
                    statusBanner = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showingBoardSheet) {
            IOSAssistantBoardSheet(
                controller: board,
                defaultBoardURL: skills.teamContext.defaultJiraBoardURL
            )
        }
        .fileImporter(isPresented: $pickingVaultFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                do {
                    try skills.setObsidianFolder(url: url)
                    loadDrafts()
                    statusBanner = L("Connected Obsidian folder.")
                } catch {
                    statusBanner = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Skills Tab

    private var skillsTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skills.isObsidianBacked ? L("Obsidian Vault Connected") : L("Local Documents Storage"))
                            .font(.subheadline.weight(.semibold))
                        Text(skills.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                Button(L("Choose Obsidian / iCloud Folder…")) {
                    pickingVaultFolder = true
                }
                if skills.isObsidianBacked {
                    Button(L("Use App Documents Folder"), role: .destructive) {
                        skills.clearObsidianFolder()
                        loadDrafts()
                    }
                }
                Button(L("Reload from Disk")) {
                    skills.refresh()
                    loadDrafts()
                }
            } header: {
                Text(L("Markdown Storage"))
            }

            Section {
                Button {
                    editingSkill = AssistantSkill(
                        id: "custom-\(Int.random(in: 100...999))",
                        name: L("Custom Facilitator Skill"),
                        role: L("Custom meeting role"),
                        triggers: [],
                        instructions: "# Role\n\n# Steps\n- Listen carefully\n- Keep the team aligned"
                    )
                } label: {
                    Label(L("New Skill"), systemImage: "plus.circle")
                }

                ForEach(skills.skills) { skill in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { skill.enabled },
                            set: { newValue in
                                var copy = skill
                                copy.enabled = newValue
                                _ = try? skills.saveSkill(copy)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name).font(.headline)
                                if !skill.role.isEmpty {
                                    Text(skill.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(skill.sourceRelativePath ?? "Skills/\(skill.id).md")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Button(L("Edit")) {
                            editingSkill = skill
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            try? skills.deleteSkill(id: skill.id)
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                    }
                }

                Button(L("Restore Default Skills")) {
                    try? skills.restoreDefaultSkill(id: nil)
                }
            } header: {
                Text(L("Assistant Skills (Skills/*.md)"))
            }

            if let statusBanner {
                Section {
                    Text(statusBanner).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Core Prompts Tab

    private var promptsTab: some View {
        Form {
            Section {
                Picker(L("Prompt File"), selection: $selectedPromptKind) {
                    ForEach(AssistantPromptKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: selectedPromptKind) { _, newKind in
                    promptDraft = skills.promptText(for: newKind)
                }

                Text(selectedPromptKind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text(selectedPromptKind.relativePath)) {
                TextEditor(text: $promptDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 260)

                HStack {
                    Button(L("Save Prompt")) {
                        do {
                            _ = try skills.savePrompt(selectedPromptKind, content: promptDraft)
                            statusBanner = L("Saved %@.", selectedPromptKind.relativePath)
                        } catch {
                            statusBanner = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L("Restore Default")) {
                        if let doc = try? skills.restoreDefaultPrompt(selectedPromptKind) {
                            promptDraft = doc.content
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - People & Team Context Tab

    private var peopleTab: some View {
        Form {
            Section {
                Button {
                    editingPerson = AssistantPersonEntry(displayName: "", approvedVoiceCommander: true)
                } label: {
                    Label(L("Add Team Member"), systemImage: "person.badge.plus")
                }

                if skills.people.entries.isEmpty {
                    Text(L("No entries in Knowledge/People.md yet. Add members to map spoken names to Jira accounts and voice approvals."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(skills.people.entries) { person in
                        Button {
                            editingPerson = person
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(person.displayName).font(.headline)
                                    if person.approvedVoiceCommander {
                                        Text(L("Approved"))
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.18), in: Capsule())
                                            .foregroundStyle(.green)
                                    }
                                }
                                let meta = [
                                    person.jiraUsername.map { "Jira: \($0)" },
                                    person.jiraAccountID.map { "ID: \($0)" },
                                    person.aliases.isEmpty ? nil : person.aliases.joined(separator: ", ")
                                ].compactMap { $0 }.joined(separator: " · ")
                                if !meta.isEmpty {
                                    Text(meta)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(L("People & Jira Directory (Knowledge/People.md)"))
            }

            Section {
                TextField(L("Default Jira Board URL (https://...)"), text: $boardURLDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L("Default Jira Project Key (e.g. PROJ)"), text: $projectKeyDraft)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField(L("Team Context Notes"), text: $teamNotesDraft, axis: .vertical)
                    .lineLimit(3...8)

                Button(L("Save Team Context")) {
                    var doc = skills.teamContext
                    doc.defaultJiraBoardURL = boardURLDraft
                    doc.defaultJiraProjectKey = projectKeyDraft
                    doc.notes = teamNotesDraft
                    do {
                        try skills.saveTeamContext(doc)
                        statusBanner = L("Saved Knowledge/TeamContext.md.")
                    } catch {
                        statusBanner = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
            } header: {
                Text(L("Team Context (Knowledge/TeamContext.md)"))
            }
        }
    }

    // MARK: - Realtime & Board Tab

    private var realtimeBoardTab: some View {
        Form {
            Section {
                Toggle(L("Enable autonomous in-meeting voice facilitator"), isOn: $skills.autonomousMeetingVoiceEnabled)
                Picker(L("Realtime Provider"), selection: $skills.realtimeProvider) {
                    ForEach(RealtimeProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: skills.realtimeProvider) { _, kind in
                    realtimeKeyDraft = skills.realtimeAPIKey(for: kind) ?? ""
                }

                if skills.realtimeProvider != .disabled {
                    TextField(L("Realtime Model"), text: $skills.realtimeModel, prompt: Text(skills.realtimeProvider.defaultModel))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Voice"), text: $skills.realtimeVoice, prompt: Text(skills.realtimeProvider.defaultVoice))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Custom WebSocket URL (optional)"), text: $skills.realtimeEndpoint, prompt: Text(skills.realtimeProvider.defaultEndpoint))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("Realtime API Key (stored in Keychain)"), text: $realtimeKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: realtimeKeyDraft) { _, newValue in
                            skills.setRealtimeAPIKey(newValue, for: skills.realtimeProvider)
                        }
                }
            } header: {
                Text(L("Optional Realtime Voice (gpt-live / Gemini Live)"))
            } footer: {
                Text(L("Speeds up voice turns inside meetings. Rock still works automatically via your standard LLM + local TTS when off."))
            }

            Section {
                Button {
                    showingBoardSheet = true
                } label: {
                    Label(L("Open In-App Jira Board"), systemImage: "macwindow")
                }
            } header: {
                Text(L("Assistant Board"))
            }
        }
    }

    private func loadDrafts() {
        promptDraft = skills.promptText(for: selectedPromptKind)
        boardURLDraft = skills.teamContext.defaultJiraBoardURL
        projectKeyDraft = skills.teamContext.defaultJiraProjectKey
        teamNotesDraft = skills.teamContext.notes
        realtimeKeyDraft = skills.realtimeAPIKey(for: skills.realtimeProvider) ?? ""
    }
}

private struct IOSSkillEditorSheet: View {
    @State private var draft: AssistantSkill
    @State private var triggersText: String
    let onSave: (AssistantSkill) -> Void

    @Environment(\.dismiss) private var dismiss

    init(skill: AssistantSkill, onSave: @escaping (AssistantSkill) -> Void) {
        _draft = State(initialValue: skill)
        _triggersText = State(initialValue: skill.triggers.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Identity")) {
                    TextField(L("Name"), text: $draft.name)
                    TextField(L("Role summary"), text: $draft.role)
                    TextField(L("Trigger keywords (comma-separated)"), text: $triggersText)
                }
                Section(L("Behavior & Safety")) {
                    Toggle(L("Enabled"), isOn: $draft.enabled)
                    Toggle(L("Voice activation"), isOn: $draft.voiceActivation)
                    Toggle(L("Approved speakers only for outward writes"), isOn: $draft.approvedSpeakersOnly)
                    Toggle(L("Auto-greet on join"), isOn: $draft.autoGreet)
                    Toggle(L("Prefer Realtime model"), isOn: $draft.realtimePreferred)
                }
                Section(L("Allowed Tools")) {
                    ForEach(AssistantSkillToolGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(
                            get: { draft.tools.contains(group) },
                            set: { on in
                                if on {
                                    if !draft.tools.contains(group) { draft.tools.append(group) }
                                } else {
                                    draft.tools.removeAll { $0 == group }
                                }
                            }
                        ))
                    }
                }
                Section(L("Markdown Instructions")) {
                    TextEditor(text: $draft.instructions)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 220)
                }
            }
            .navigationTitle(draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        draft.triggers = triggersText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct IOSPersonEditorSheet: View {
    @State private var draft: AssistantPersonEntry
    @State private var aliasesText: String
    let onSave: (AssistantPersonEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    init(person: AssistantPersonEntry, onSave: @escaping (AssistantPersonEntry) -> Void) {
        _draft = State(initialValue: person)
        _aliasesText = State(initialValue: person.aliases.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Member Profile")) {
                    TextField(L("Display Name"), text: $draft.displayName)
                    TextField(L("Spoken aliases (comma-separated)"), text: $aliasesText)
                    TextField(L("Role"), text: Binding(
                        get: { draft.role ?? "" },
                        set: { draft.role = $0.isEmpty ? nil : $0 }
                    ))
                    Toggle(L("Approved voice commander"), isOn: $draft.approvedVoiceCommander)
                }
                Section(L("Jira Mapping")) {
                    TextField(L("Jira Username"), text: Binding(
                        get: { draft.jiraUsername ?? "" },
                        set: { draft.jiraUsername = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField(L("Jira Account ID (Cloud)"), text: Binding(
                        get: { draft.jiraAccountID ?? "" },
                        set: { draft.jiraAccountID = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField(L("Email"), text: Binding(
                        get: { draft.email ?? "" },
                        set: { draft.email = $0.isEmpty ? nil : $0 }
                    ))
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(draft.displayName.isEmpty ? L("Team Member") : draft.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        draft.aliases = aliasesText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct IOSMultiMeetingRockJoinSheet: View {
    let candidates: [JoinableMeetingCandidate]
    @ObservedObject var skills: IOSAssistantSkillsController
    let onJoin: (_ selected: [JoinableMeetingCandidate], _ skillID: String, _ enableVoice: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []
    @State private var chosenSkillID: String = "scrum-master"
    @State private var enableVoiceFacilitation = true

    var body: some View {
        NavigationStack {
            List {
                Section(L("Skill & Facilitation")) {
                    Picker(L("Assistant Skill Role"), selection: $chosenSkillID) {
                        ForEach(skills.skills.filter(\.enabled)) { skill in
                            Text(skill.name).tag(skill.id)
                        }
                    }
                    Toggle(L("Enable voice facilitator on join"), isOn: $enableVoiceFacilitation)
                }

                Section(L("Select Meetings")) {
                    if candidates.isEmpty {
                        Text(L("No upcoming or active meeting links available right now."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            let selected = selectedIDs.contains(candidate.id)
                            Button {
                                if selected { selectedIDs.remove(candidate.id) }
                                else { selectedIDs.insert(candidate.id) }
                            } label: {
                                HStack {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.title).font(.headline)
                                        if let start = candidate.start {
                                            Text(start.formatted(date: .omitted, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(L("Join Meetings with Rock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Join Selected")) {
                        let chosen = candidates.filter { selectedIDs.contains($0.id) }
                        onJoin(chosen, chosenSkillID, enableVoiceFacilitation)
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .onAppear {
                if let first = skills.selectedSkillIDs.first ?? skills.skills.first(where: \.enabled)?.id {
                    chosenSkillID = first
                }
                if let ongoing = candidates.first(where: { $0.source == .ongoingCalendar }) ?? candidates.first {
                    selectedIDs.insert(ongoing.id)
                }
            }
        }
    }
}
