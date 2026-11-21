import AppKit
import ConferenceCore
import SwiftUI

/// In-app editor for Obsidian-backed Assistant Skills (`Skills/*.md`),
/// `Knowledge/People.md` (meeting name ↔ Jira mappings + voice approvals),
/// `Knowledge/TeamContext.md`, and live Assistant Board standup facilitation.
struct AssistantSkillsView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var store: AttentionStore
    @ObservedObject private var facilitator: AutonomousMeetingFacilitator
    @ObservedObject private var board: AssistantBoardWindowController

    enum SectionTab: String, CaseIterable, Identifiable {
        case skills, prompts, people, board
        var id: String { rawValue }
        var title: String {
            switch self {
            case .skills: return L("Skills & Prompts")
            case .prompts: return L("Core Prompts")
            case .people: return L("Team & Jira")
            case .board: return L("Board & Facilitation")
            }
        }
    }

    @State private var tab: SectionTab = .skills
    @State private var isObsidianBacked = false
    @State private var storagePath = ""
    @State private var skills: [AssistantSkill] = []
    @State private var selectedSkillID: String?
    @State private var draftSkill = AssistantSkill(id: "", name: "", instructions: "")
    @State private var draftTriggersText = ""

    @State private var prompts: [AssistantPromptDocument] = []
    @State private var selectedPromptKind: AssistantPromptKind = .basePersona
    @State private var draftPromptContent = ""

    @State private var people = AssistantPeopleDirectory()
    @State private var selectedPersonID: String?
    @State private var personName = ""
    @State private var personAliases = ""
    @State private var personJiraUsername = ""
    @State private var personJiraAccountID = ""
    @State private var personEmail = ""
    @State private var personRole = ""
    @State private var personApprovedVoice = true
    @State private var personNotes = ""

    @State private var teamContext = AssistantTeamContextDocument()
    @State private var statusMessage: String?

    init(attention: AttentionCoordinator) {
        self.attention = attention
        self._store = ObservedObject(wrappedValue: attention.store)
        self._facilitator = ObservedObject(wrappedValue: attention.facilitator ?? AutonomousMeetingFacilitator(attention: attention))
        self._board = ObservedObject(wrappedValue: attention.boardController)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            storageHeader
            Picker(L("Skills workspace section"), selection: $tab) {
                ForEach(SectionTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .nativeSettingAnchor("settings.skills", nativeControlFocus: true)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch tab {
            case .skills:
                skillsTab
            case .prompts:
                promptsTab
            case .people:
                peopleTab
            case .board:
                boardAndFacilitationTab
            }
        }
        .task { await reloadAll() }
    }

    private var storageHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: isObsidianBacked ? "folder.badge.gearshape" : "internaldrive")
                .foregroundStyle(isObsidianBacked ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isObsidianBacked ? L("Synced with Obsidian vault (Git-ready Markdown)") : L("Stored on this Mac (connect Obsidian in Settings → Integrations to share)"))
                    .font(.callout.weight(.medium))
                if !storagePath.isEmpty {
                    Text(storagePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(L("Reload")) {
                Task { await reloadAll() }
            }
            .controlSize(.small)
            if !storagePath.isEmpty {
                Button(L("Reveal in Finder")) {
                    let url = URL(fileURLWithPath: storagePath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Skills Tab

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Assistant skills (`Skills/*.md`)")).font(.headline)
                Spacer()
                Button(L("+ New Skill")) { createNewSkill() }
                    .controlSize(.small)
                Button(L("Restore Defaults")) {
                    Task {
                        try? await attention.restoreDefaultAssistantSkills()
                        await reloadAll()
                        statusMessage = L("Default assistant skills restored.")
                    }
                }
                .controlSize(.small)
            }

            if !skills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(skills) { item in
                            Button {
                                selectSkill(item)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(item.enabled ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 7, height: 7)
                                    Text(item.name)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedSkillID == item.id
                                        ? Color.accentColor.opacity(0.2)
                                        : Color(nsColor: .controlBackgroundColor),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        TextField(L("Skill name"), text: $draftSkill.name)
                        TextField(L("Slug ID"), text: $draftSkill.id)
                            .frame(width: 170)
                        Toggle(L("Enabled"), isOn: $draftSkill.enabled)
                    }
                    TextField(L("Role summary"), text: $draftSkill.role)
                    TextField(L("Voice / meeting triggers (comma-separated)"), text: $draftTriggersText)
                    HStack(spacing: 16) {
                        Toggle(L("Voice activation"), isOn: $draftSkill.voiceActivation)
                        Toggle(L("Approved speakers only"), isOn: $draftSkill.approvedSpeakersOnly)
                        Toggle(L("Prefer Realtime model"), isOn: $draftSkill.realtimePreferred)
                        Toggle(L("Auto-greet when joining"), isOn: $draftSkill.autoGreet)
                    }
                    .font(.caption)

                    if !draftSkill.id.isEmpty {
                        Toggle(L("Pin globally for all chats"), isOn: Binding(
                            get: { store.selectedSkillIDs.contains(draftSkill.id) },
                            set: { pinned in
                                if pinned {
                                    if !store.selectedSkillIDs.contains(draftSkill.id) {
                                        store.selectedSkillIDs.append(draftSkill.id)
                                    }
                                } else {
                                    store.selectedSkillIDs.removeAll { $0 == draftSkill.id }
                                }
                            }
                        ))
                        .font(.caption)
                    }

                    Text(L("Allowed capabilities")).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), alignment: .leading)], spacing: 4) {
                        ForEach(AssistantSkillToolGroup.allCases) { group in
                            Toggle(group.title, isOn: Binding(
                                get: { draftSkill.tools.contains(group) },
                                set: { enabled in
                                    if enabled {
                                        if !draftSkill.tools.contains(group) { draftSkill.tools.append(group) }
                                    } else {
                                        draftSkill.tools.removeAll { $0 == group }
                                    }
                                }
                            ))
                            .font(.caption)
                        }
                    }

                    Text(L("Markdown instructions (saved verbatim in Obsidian)")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draftSkill.instructions)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

                    HStack {
                        Button(L("Save Skill")) {
                            Task {
                                var updated = draftSkill
                                updated.id = AssistantSkill.sanitizedSlug(from: updated.id.isEmpty ? updated.name : updated.id)
                                updated.triggers = draftTriggersText
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                                if let saved = try? await attention.saveAssistantSkill(updated) {
                                    selectedSkillID = saved.id
                                    draftSkill = saved
                                    await reloadAll()
                                    statusMessage = L("Saved skill “%@” to Markdown.", saved.name)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftSkill.name.trimmed.isEmpty)

                        if DefaultAssistantSkills.defaultIDs.contains(draftSkill.id) {
                            Button(L("Reset Template")) {
                                Task {
                                    try? await attention.restoreDefaultAssistantSkills(id: draftSkill.id)
                                    await reloadAll()
                                    statusMessage = L("Reset default template for “%@”.", draftSkill.name)
                                }
                            }
                        }

                        Spacer()
                        if !draftSkill.id.isEmpty {
                            Button(L("Delete"), role: .destructive) {
                                let targetID = draftSkill.id
                                Task {
                                    try? await attention.deleteAssistantSkill(id: targetID)
                                    selectedSkillID = nil
                                    await reloadAll()
                                    statusMessage = L("Removed skill “%@”.", targetID)
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Core Obsidian Prompts Tab

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Core LLM system instructions stored in Obsidian (`Prompts/*.md`). Edit them here or share via Git."))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AssistantPromptKind.allCases) { kind in
                        Button {
                            selectedPromptKind = kind
                            draftPromptContent = prompts.first(where: { $0.kind == kind })?.content
                                ?? DefaultAssistantPrompts.content(for: kind)
                        } label: {
                            Text(kind.title)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedPromptKind == kind
                                        ? Color.accentColor.opacity(0.2)
                                        : Color(nsColor: .controlBackgroundColor),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedPromptKind.title).font(.headline)
                    Text(selectedPromptKind.subtitle).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draftPromptContent)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 200)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

                    HStack {
                        Button(L("Save Prompt")) {
                            let kind = selectedPromptKind
                            let body = draftPromptContent
                            Task {
                                if let saved = try? await attention.saveAssistantPrompt(kind, content: body) {
                                    draftPromptContent = saved.content
                                    await reloadAll()
                                    statusMessage = L("Saved %@ in Obsidian.", kind.relativePath)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftPromptContent.trimmed.isEmpty)

                        Button(L("Restore Default")) {
                            let kind = selectedPromptKind
                            Task {
                                if let restored = try? await attention.restoreDefaultAssistantPrompt(kind) {
                                    draftPromptContent = restored.content
                                    await reloadAll()
                                    statusMessage = L("Restored default %@.", kind.relativePath)
                                }
                            }
                        }
                        Spacer()
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - People & Jira Tab

    private var peopleTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L("You (the local user) are always approved for voice commands. Add teammates in People.md to map meeting names to Jira accounts and grant voice task permissions."),
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .nativeSettingAnchor("settings.people-directory", nativeControlFocus: true)

            HStack {
                Text(L("Known members (`Knowledge/People.md`)")).font(.headline)
                Spacer()
                Button(L("+ Add Member")) { clearPersonDraft() }
                    .controlSize(.small)
            }

            if !people.entries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(people.entries) { entry in
                            Button {
                                loadPersonDraft(entry)
                            } label: {
                                HStack(spacing: 4) {
                                    if entry.approvedVoiceCommander {
                                        Image(systemName: "mic.badge.checkmark")
                                            .foregroundStyle(.green)
                                            .font(.caption2)
                                    }
                                    Text(entry.displayName)
                                    if let jira = entry.jiraUsername ?? entry.jiraAccountID {
                                        Text("· @\(jira)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedPersonID == entry.id
                                        ? Color.accentColor.opacity(0.2)
                                        : Color(nsColor: .controlBackgroundColor),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField(L("Display name"), text: $personName)
                        TextField(L("Role (e.g. iOS Lead)"), text: $personRole)
                    }
                    TextField(L("Spoken aliases & nicks (comma-separated)"), text: $personAliases)
                    HStack(spacing: 10) {
                        TextField(L("Jira username"), text: $personJiraUsername)
                        TextField(L("Jira account ID"), text: $personJiraAccountID)
                        TextField(L("Email"), text: $personEmail)
                    }
                    TextField(L("Notes"), text: $personNotes)
                    Toggle(L("Approved to instruct Rock by voice during facilitated meetings"), isOn: $personApprovedVoice)
                    HStack {
                        Button(L("Save to People.md")) {
                            Task {
                                let entry = AssistantPersonEntry(
                                    id: selectedPersonID,
                                    displayName: personName,
                                    aliases: personAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                                    jiraUsername: personJiraUsername,
                                    jiraAccountID: personJiraAccountID,
                                    email: personEmail,
                                    role: personRole,
                                    approvedVoiceCommander: personApprovedVoice,
                                    notes: personNotes
                                )
                                if let updated = try? await attention.upsertPersonMapping(entry) {
                                    people = updated
                                    selectedPersonID = entry.id
                                    statusMessage = L("Saved %@ in Knowledge/People.md.", entry.displayName)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(personName.trimmed.isEmpty)

                        Spacer()
                        if let selectedPersonID {
                            Button(L("Remove"), role: .destructive) {
                                Task {
                                    var updated = people
                                    updated.remove(id: selectedPersonID)
                                    try? await attention.savePeopleDirectory(updated)
                                    people = updated
                                    clearPersonDraft()
                                    statusMessage = L("Removed member from People.md.")
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Board & Facilitation Tab

    private var boardAndFacilitationTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox(L("Jira Board & Computer Use (`TeamContext.md`)")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("Default Jira Board URL"), text: $teamContext.defaultJiraBoardURL, prompt: Text("https://jira.example.com/boards/42"))
                        .nativeSettingAnchor("settings.assistant-board", nativeControlFocus: true)
                    TextField(L("Default Jira project key"), text: $teamContext.defaultJiraProjectKey, prompt: Text("PROJ"))
                    Text(L("Rock uses an isolated in-app browser window with your existing session to display, scroll, filter, and share your board during standups without Accessibility permission."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L("Save Team Context")) {
                            Task {
                                try? await attention.saveTeamContext(teamContext)
                                statusMessage = L("Saved TeamContext.md.")
                            }
                        }
                        Button(L("Open Assistant Board")) {
                            Task {
                                if !teamContext.defaultJiraBoardURL.trimmed.isEmpty {
                                    _ = try? await board.open(urlString: teamContext.defaultJiraBoardURL)
                                } else {
                                    board.showWindow()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(6)
            }

            GroupBox(L("Autonomous In-Meeting Voice Facilitation")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L("Enable voice facilitation when joining meetings by command"), isOn: $store.autonomousMeetingVoiceEnabled)
                    let live = attention.meetings().filter { !$0.isClosed }
                    if live.isEmpty {
                        Text(L("Join a meeting or ask Rock by voice (e.g. “Rock, join Daily Standup as Scrum Master”)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(live, id: \.sessionID) { model in
                            let isActive = facilitator.activeSessionSkills[model.sessionID] != nil
                            let boundSkill = facilitator.activeSessionSkills[model.sessionID] ?? (skills.first?.id ?? "scrum-master")
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.title).font(.callout.weight(.medium))
                                    if let msg = facilitator.lastStatusBySession[model.sessionID] {
                                        Text(msg).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Menu {
                                    ForEach(skills.filter(\.enabled)) { skill in
                                        Button(skill.name) {
                                            facilitator.enable(for: model, skillID: skill.id)
                                        }
                                    }
                                } label: {
                                    Text(skills.first(where: { $0.id == boundSkill })?.name ?? boundSkill)
                                }
                                .frame(width: 170)

                                Button(isActive ? L("Stop Voice Facilitator") : L("Start Voice Facilitator")) {
                                    if isActive {
                                        facilitator.disable(for: model.sessionID)
                                    } else {
                                        facilitator.enable(for: model, skillID: boundSkill)
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button(board.sharingMeetingID == model.sessionID ? L("Stop Board Share") : L("Share Board")) {
                                    Task {
                                        if board.sharingMeetingID == model.sessionID {
                                            board.stopSharing()
                                        } else {
                                            if board.currentURL == nil && !teamContext.defaultJiraBoardURL.trimmed.isEmpty {
                                                _ = try? await board.open(urlString: teamContext.defaultJiraBoardURL)
                                            }
                                            _ = try? await board.startSharing(to: model)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Helpers

    private func reloadAll() async {
        let storage = await attention.skillStorageSummary()
        isObsidianBacked = storage.isObsidianBacked
        storagePath = storage.folderPath

        let loadedSkills = await attention.listAssistantSkills()
        skills = loadedSkills
        if let selected = selectedSkillID,
           let match = loadedSkills.first(where: { $0.id == selected }) {
            selectSkill(match)
        } else if let first = loadedSkills.first {
            selectSkill(first)
        }

        people = await attention.loadPeopleDirectory()
        teamContext = await attention.loadTeamContext()
        let loadedPrompts = await attention.listAssistantPrompts()
        prompts = loadedPrompts
        draftPromptContent = loadedPrompts.first(where: { $0.kind == selectedPromptKind })?.content
            ?? DefaultAssistantPrompts.content(for: selectedPromptKind)
    }

    private func selectSkill(_ skill: AssistantSkill) {
        selectedSkillID = skill.id
        draftSkill = skill
        draftTriggersText = skill.triggers.joined(separator: ", ")
    }

    private func createNewSkill() {
        selectedSkillID = nil
        draftSkill = AssistantSkill(
            id: "custom-role",
            name: "Custom Assistant Skill",
            role: "Specialized workflow stored in Obsidian.",
            enabled: true,
            voiceActivation: true,
            triggers: ["custom"],
            tools: AssistantSkillToolGroup.allCases,
            approvedSpeakersOnly: true,
            realtimePreferred: false,
            instructions: """
            # Custom Assistant Skill

            Describe how Rock should handle this meeting or workflow.
            """
        )
        draftTriggersText = "custom"
    }

    private func loadPersonDraft(_ entry: AssistantPersonEntry) {
        selectedPersonID = entry.id
        personName = entry.displayName
        personAliases = entry.aliases.joined(separator: ", ")
        personJiraUsername = entry.jiraUsername ?? ""
        personJiraAccountID = entry.jiraAccountID ?? ""
        personEmail = entry.email ?? ""
        personRole = entry.role ?? ""
        personApprovedVoice = entry.approvedVoiceCommander
        personNotes = entry.notes ?? ""
    }

    private func clearPersonDraft() {
        selectedPersonID = nil
        personName = ""
        personAliases = ""
        personJiraUsername = ""
        personJiraAccountID = ""
        personEmail = ""
        personRole = ""
        personApprovedVoice = true
        personNotes = ""
    }
}

/// Compact toolbar menu inside a live meeting window to control voice facilitation,
/// active skill role, proactive kickoff, and in-meeting Assistant Board screen sharing.
struct NativeMeetingAssistantMenu: View {
    @ObservedObject var meeting: NativeDesktopMeetingModel
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var facilitator: AutonomousMeetingFacilitator
    @ObservedObject private var board: AssistantBoardWindowController
    @State private var skills: [AssistantSkill] = []

    init(meeting: NativeDesktopMeetingModel, attention: AttentionCoordinator) {
        self.meeting = meeting
        self.attention = attention
        self._facilitator = ObservedObject(wrappedValue: attention.facilitator ?? AutonomousMeetingFacilitator(attention: attention))
        self._board = ObservedObject(wrappedValue: attention.boardController)
    }

    private var isFacilitatorActive: Bool {
        facilitator.activeSessionSkills[meeting.sessionID] != nil
    }

    private var activeSkillID: String {
        facilitator.activeSessionSkills[meeting.sessionID] ?? skills.first?.id ?? "scrum-master"
    }

    var body: some View {
        Menu {
            Button(isFacilitatorActive ? L("Stop Voice Facilitator") : L("Start Voice Facilitator")) {
                if isFacilitatorActive {
                    facilitator.disable(for: meeting.sessionID)
                } else {
                    facilitator.enable(for: meeting, skillID: activeSkillID)
                }
            }
            if isFacilitatorActive {
                Button(L("Kick off skill now")) {
                    Task { await facilitator.kickOffSkill(for: meeting, skillID: activeSkillID) }
                }
            }
            Menu(L("Skill Role")) {
                ForEach(skills.filter(\.enabled)) { skill in
                    Button {
                        facilitator.enable(for: meeting, skillID: skill.id)
                    } label: {
                        if skill.id == activeSkillID && isFacilitatorActive {
                            Label(skill.name, systemImage: "checkmark")
                        } else {
                            Text(skill.name)
                        }
                    }
                }
            }
            Divider()
            Button(L("Open Assistant Board")) {
                Task {
                    let team = await attention.loadTeamContext()
                    if board.currentURL == nil && !team.defaultJiraBoardURL.trimmed.isEmpty {
                        _ = try? await board.open(urlString: team.defaultJiraBoardURL)
                    } else {
                        board.showWindow()
                    }
                }
            }
            Button(board.sharingMeetingID == meeting.sessionID ? L("Stop Board Share") : L("Share Board to Meeting")) {
                Task {
                    if board.sharingMeetingID == meeting.sessionID {
                        board.stopSharing()
                    } else {
                        let team = await attention.loadTeamContext()
                        if board.currentURL == nil && !team.defaultJiraBoardURL.trimmed.isEmpty {
                            _ = try? await board.open(urlString: team.defaultJiraBoardURL)
                        }
                        _ = try? await board.startSharing(to: meeting)
                    }
                }
            }
        } label: {
            Label(
                L("Rock Assistant"),
                systemImage: isFacilitatorActive ? "sparkles.rectangle.stack.fill" : "sparkles"
            )
        }
        .help(L("Facilitate this meeting with Rock skills & Jira Board"))
        .task { skills = await attention.listAssistantSkills() }
    }
}

/// Multi-meeting join + skill binding sheet presented from Home.
struct MultiMeetingRockJoinSheet: View {
    @ObservedObject var attention: AttentionCoordinator
    @Binding var isPresented: Bool

    @State private var candidates: [JoinableMeetingCandidate] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var skills: [AssistantSkill] = []
    @State private var selectedSkillID: String = "scrum-master"
    @State private var enableVoice = true
    @State private var statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Join Meetings with Rock")).font(.title2.bold())
            Text(L("Pick one or more meetings and an Obsidian skill role so Rock joins and assists by voice."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if candidates.isEmpty {
                Text(L("No meetings with join links found right now.")).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(candidates) { candidate in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(candidate.id) },
                            set: { on in
                                if on { selectedIDs.insert(candidate.id) } else { selectedIDs.remove(candidate.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).font(.body.weight(.medium))
                                if let start = candidate.start {
                                    Text(start.formatted(date: .omitted, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 240)
            }

            if !skills.isEmpty {
                Picker(L("Skill Role"), selection: $selectedSkillID) {
                    ForEach(skills.filter(\.enabled)) { skill in
                        Text(skill.name).tag(skill.id)
                    }
                }
            }

            Toggle(L("Enable autonomous in-meeting voice facilitation"), isOn: $enableVoice)

            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(L("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Join Selected")) {
                    let chosenTitles = candidates.filter { selectedIDs.contains($0.id) }.map(\.title)
                    Task {
                        let res = await AssistantSkillToolRegistrar.joinMeetingsByQueries(
                            chosenTitles,
                            skillID: selectedSkillID,
                            enableFacilitation: enableVoice,
                            attention: attention,
                            talk: attention.talk
                        )
                        statusText = res.summary
                        if !res.joinedTitles.isEmpty {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .task {
            let targets = attention.joinableTargets(attention.now())
            candidates = targets
            if let first = CurrentMeetingTargetResolver.bestCurrentMeeting(from: targets, now: attention.now()) {
                selectedIDs = [first.id]
            }
            let loaded = await attention.listAssistantSkills()
            skills = loaded
            if let firstSkill = loaded.first(where: \.enabled) {
                selectedSkillID = firstSkill.id
            }
        }
    }
}
