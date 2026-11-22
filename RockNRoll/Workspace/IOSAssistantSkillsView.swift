import ConferenceCore
import SwiftUI
import UIKit
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
    @State private var statusIsError = false
    @State private var pickingVaultFolder = false
    @State private var showingBoardSheet = false
    @State private var confirmDisconnectObsidian = false
    @State private var confirmRestoreAllSkills = false
    @State private var confirmRestorePrompt = false
    @State private var pendingDeleteSkill: AssistantSkill?
    @State private var pendingDeletePerson: AssistantPersonEntry?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Tab.allCases) { tab in
                        let isSelected = selectedTab == tab
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.title)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected ? Color.accentColor : Color.secondary.opacity(0.14),
                                    in: Capsule()
                                )
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            if let statusBanner {
                HStack(spacing: 8) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .red : .green)
                    Text(statusBanner)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.statusBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Dismiss alert"))
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemGroupedBackground))
            }

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
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L("Skills, Prompts & Knowledge"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("Done")) { dismissKeyboard() }
            }
        }
        .onAppear { loadDrafts() }
        .onDisappear { board.isInlineSheetActive = false }
        .onChange(of: selectedTab) { _, _ in
            statusBanner = nil
            statusIsError = false
        }
        .onChange(of: showingBoardSheet) { _, isShowing in
            board.isInlineSheetActive = isShowing
        }
        .sheet(item: $editingSkill) { draft in
            IOSSkillEditorSheet(skill: draft) { updated in
                do {
                    _ = try skills.saveSkill(updated)
                    showStatus(L("Saved skill “%@”.", updated.name))
                } catch {
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
        .sheet(item: $editingPerson) { person in
            IOSPersonEditorSheet(person: person) { updated in
                do {
                    _ = try skills.upsertPerson(updated)
                    showStatus(L("Saved %@ in People.md.", updated.displayName))
                } catch {
                    showStatus(error.localizedDescription, isError: true)
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
                    showStatus(L("Connected Obsidian folder."))
                } catch {
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
        .confirmationDialog(
            L("Use App Documents Folder"),
            isPresented: $confirmDisconnectObsidian,
            titleVisibility: .visible
        ) {
            Button(L("Use App Documents Folder"), role: .destructive) {
                skills.clearObsidianFolder()
                loadDrafts()
                showStatus(L("Switched to App Documents storage."))
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Restore Default Skills"),
            isPresented: $confirmRestoreAllSkills,
            titleVisibility: .visible
        ) {
            Button(L("Restore Default Skills"), role: .destructive) {
                do {
                    try skills.restoreDefaultSkill(id: nil)
                    loadDrafts()
                    showStatus(L("Restored default skills."))
                } catch {
                    showStatus(error.localizedDescription, isError: true)
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Restore Default"),
            isPresented: $confirmRestorePrompt,
            titleVisibility: .visible
        ) {
            Button(L("Restore Default"), role: .destructive) {
                do {
                    let doc = try skills.restoreDefaultPrompt(selectedPromptKind)
                    promptDraft = doc.content
                    showStatus(L("Restored default prompt."))
                } catch {
                    showStatus(error.localizedDescription, isError: true)
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Delete skill?"),
            isPresented: Binding(
                get: { pendingDeleteSkill != nil },
                set: { if !$0 { pendingDeleteSkill = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let skill = pendingDeleteSkill {
                Button(L("Delete"), role: .destructive) {
                    do {
                        try skills.deleteSkill(id: skill.id)
                        showStatus(L("Deleted skill “%@”.", skill.name))
                    } catch {
                        showStatus(error.localizedDescription, isError: true)
                    }
                    pendingDeleteSkill = nil
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingDeleteSkill = nil }
        }
        .confirmationDialog(
            L("Remove team member?"),
            isPresented: Binding(
                get: { pendingDeletePerson != nil },
                set: { if !$0 { pendingDeletePerson = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let person = pendingDeletePerson {
                Button(L("Remove"), role: .destructive) {
                    do {
                        try skills.removePerson(id: person.id)
                        showStatus(L("Removed %@.", person.displayName))
                    } catch {
                        showStatus(error.localizedDescription, isError: true)
                    }
                    pendingDeletePerson = nil
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingDeletePerson = nil }
        }
    }

    private func showStatus(_ message: String, isError: Bool = false) {
        statusBanner = message
        statusIsError = isError
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
                        confirmDisconnectObsidian = true
                    }
                }
                Button(L("Reload from Disk")) {
                    skills.refresh()
                    loadDrafts()
                    showStatus(L("Reloaded skills from disk."))
                }
            } header: {
                Text(L("Markdown Storage"))
            }

            Section {
                Button {
                    editingSkill = AssistantSkill(
                        id: "custom-role-\(Int.random(in: 100...999))",
                        name: L("Custom Facilitator Skill"),
                        role: L("Custom meeting role"),
                        triggers: [],
                        instructions: "# Role\n\n# Steps\n- Listen carefully\n- Keep the team aligned"
                    )
                } label: {
                    Label(L("New Skill"), systemImage: "plus.circle")
                }

                ForEach(skills.skills) { skill in
                    let isPinned = skills.selectedSkillIDs.contains(skill.id)
                    HStack {
                        Toggle(isOn: Binding(
                            get: { skill.enabled },
                            set: { newValue in
                                var copy = skill
                                copy.enabled = newValue
                                do {
                                    _ = try skills.saveSkill(copy)
                                } catch {
                                    showStatus(error.localizedDescription, isError: true)
                                }
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

                        Button {
                            if isPinned {
                                skills.selectedSkillIDs.removeAll { $0 == skill.id }
                            } else {
                                skills.selectedSkillIDs.append(skill.id)
                            }
                        } label: {
                            Image(systemName: isPinned ? "star.fill" : "star")
                                .foregroundStyle(isPinned ? .yellow : .secondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPinned ? L("Pinned for chats") : L("Pin for chats"))

                        Button(L("Edit")) {
                            editingSkill = skill
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteSkill = skill
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                    }
                }

                Button(L("Restore Default Skills")) {
                    confirmRestoreAllSkills = true
                }
            } header: {
                Text(L("Assistant Skills (Skills/*.md)"))
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
                            showStatus(L("Saved %@.", selectedPromptKind.relativePath))
                        } catch {
                            showStatus(error.localizedDescription, isError: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L("Restore Default")) {
                        confirmRestorePrompt = true
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletePerson = person
                            } label: {
                                Label(L("Delete"), systemImage: "trash")
                            }
                        }
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
                        showStatus(L("Saved Knowledge/TeamContext.md."))
                    } catch {
                        showStatus(error.localizedDescription, isError: true)
                    }
                }
                .buttonStyle(.borderedProminent)

                Text(L("Configure Jira API credentials and Reminders sync in Tasks → Sync Settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    if skills.realtimeProvider == .yandexRealtime {
                        TextField(L("Yandex Cloud Folder ID"), text: $skills.realtimeFolderID, prompt: Text("b1g..."))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField(L("Realtime Model"), text: $skills.realtimeModel, prompt: Text(skills.realtimeProvider.defaultModel))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if skills.realtimeProvider == .yandexRealtime {
                        HStack {
                            TextField(L("Voice"), text: $skills.realtimeVoice, prompt: Text(skills.realtimeProvider.defaultVoice))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Menu {
                                ForEach(YandexLiveTTSVoice.allCases) { preset in
                                    Button(preset.displayTitle) {
                                        skills.realtimeVoice = preset.rawValue
                                    }
                                }
                            } label: {
                                Label(L("Preset"), systemImage: "chevron.up.chevron.down")
                                    .font(.caption)
                            }
                        }
                        Picker(L("Voice role"), selection: $skills.realtimeVoiceRole) {
                            ForEach(YandexLiveTTSRole.allCases) { role in
                                Text(role.title).tag(role.rawValue)
                            }
                        }
                    } else {
                        TextField(L("Voice"), text: $skills.realtimeVoice, prompt: Text(skills.realtimeProvider.defaultVoice))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField(L("Custom WebSocket URL (optional)"), text: $skills.realtimeEndpoint, prompt: Text(skills.realtimeProvider.defaultEndpoint))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("Realtime API Key (stored in Keychain)"), text: $realtimeKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { saveRealtimeAPIKey() }

                    if skills.realtimeProvider == .openAIRealtime,
                       !skills.keyedRealtimeProviders.contains(.openAIRealtime),
                       !(skills.realtimeAPIKey(for: .openAIRealtime) ?? "").isEmpty {
                        Text(L("Using your OpenAI API key"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(L("Save Key")) {
                            saveRealtimeAPIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        if skills.keyedRealtimeProviders.contains(skills.realtimeProvider) {
                            Button(L("Remove"), role: .destructive) {
                                realtimeKeyDraft = ""
                                if skills.setRealtimeAPIKey("", for: skills.realtimeProvider) {
                                    showStatus(L("Removed API key from Keychain."))
                                } else {
                                    showStatus(L("Could not remove the API key from the Keychain."), isError: true)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text(L("Optional Realtime Voice (gpt-live / Gemini Live / Yandex LiveTTS)"))
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

    private func saveRealtimeAPIKey() {
        let trimmed = realtimeKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = skills.setRealtimeAPIKey(trimmed, for: skills.realtimeProvider)
        if trimmed.isEmpty {
            if ok {
                showStatus(L("Removed API key from Keychain."))
            } else {
                showStatus(L("Could not remove the API key from the Keychain."), isError: true)
            }
        } else if ok {
            showStatus(L("Saved API key to Keychain."))
        } else {
            showStatus(L("Could not save the API key to the Keychain."), isError: true)
        }
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("Done")) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
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
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
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
