import ConferenceCore
import Foundation
import SwiftUI

/// Owns iOS Obsidian-backed assistant skills (`Skills/*.md`), core prompt files
/// (`Prompts/BasePersona.md`, `MeetingSummary.md`, `AttentionJudge.md`), `Knowledge/People.md`,
/// `Knowledge/TeamContext.md`, live filesystem watching, and optional Realtime credentials.
@MainActor
final class IOSAssistantSkillsController: ObservableObject {
    @Published private(set) var skills: [AssistantSkill] = []
    @Published private(set) var prompts: [AssistantPromptDocument] = []
    @Published private(set) var people = AssistantPeopleDirectory()
    @Published private(set) var teamContext = AssistantTeamContextDocument()
    @Published private(set) var isObsidianBacked = false
    @Published private(set) var folderPath = ""
    @Published var storageError: String?

    @Published var realtimeProvider: RealtimeProviderKind {
        didSet { preferences.set(realtimeProvider.rawValue, forKey: Keys.realtimeProvider) }
    }
    @Published var realtimeModel: String {
        didSet { preferences.set(realtimeModel, forKey: Keys.realtimeModel) }
    }
    @Published var realtimeVoice: String {
        didSet { preferences.set(realtimeVoice, forKey: Keys.realtimeVoice) }
    }
    @Published var realtimeEndpoint: String {
        didSet { preferences.set(realtimeEndpoint, forKey: Keys.realtimeEndpoint) }
    }
    @Published var realtimeFolderID: String {
        didSet {
            guard oldValue != realtimeFolderID else { return }
            preferences.set(realtimeFolderID, forKey: YandexRealtimePreferences.folderIDKey)
            if !suppressCredentialBroadcast {
                NotificationCenter.default.post(
                    name: YandexRealtimePreferences.credentialsChangedNotification,
                    object: self,
                    userInfo: ["isStandard": preferences === UserDefaults.standard]
                )
            }
        }
    }
    @Published var realtimeVoiceRole: String {
        didSet { preferences.set(realtimeVoiceRole, forKey: YandexRealtimePreferences.voiceRoleKey) }
    }
    @Published var selectedSkillIDs: [String] {
        didSet { preferences.set(selectedSkillIDs, forKey: Keys.selectedSkillIDs) }
    }
    @Published var autonomousMeetingVoiceEnabled: Bool {
        didSet { preferences.set(autonomousMeetingVoiceEnabled, forKey: Keys.autonomousMeetingVoice) }
    }
    @Published private(set) var keyedRealtimeProviders: Set<RealtimeProviderKind> = []

    private enum Keys {
        static let vaultBookmark = "ios.assistant.obsidianVaultBookmark.v1"
        static let realtimeProvider = "ios.assistant.realtime.provider.v1"
        static let realtimeModel = "ios.assistant.realtime.model.v1"
        static let realtimeVoice = "ios.assistant.realtime.voice.v1"
        static let realtimeEndpoint = "ios.assistant.realtime.endpoint.v1"
        static let selectedSkillIDs = "ios.assistant.selectedSkillIDs.v1"
        static let autonomousMeetingVoice = "ios.assistant.autonomousMeetingVoice.v1"
    }

    private weak var workspace: IOSWorkspaceCoordinator?
    private let preferences: UserDefaults
    private let keychain: WorkspaceAPIKeychain
    private let customRootURL: URL?
    private var folderWatcher: AssistantSkillFolderWatcher?
    private var watchedVaultURL: URL?
    private var hasLoadedOnce = false
    private var suppressCredentialBroadcast = false
    private var credentialObserver: NSObjectProtocol?

    init(
        workspace: IOSWorkspaceCoordinator?,
        preferences: UserDefaults = .standard,
        keychain: WorkspaceAPIKeychain? = nil,
        customRootURL: URL? = nil
    ) {
        self.workspace = workspace
        self.preferences = preferences
        self.keychain = keychain ?? workspace?.keychain ?? WorkspaceAPIKeychain()
        self.customRootURL = customRootURL

        self.realtimeProvider = preferences.string(forKey: Keys.realtimeProvider)
            .flatMap(RealtimeProviderKind.init(rawValue:)) ?? .disabled
        self.realtimeModel = preferences.string(forKey: Keys.realtimeModel) ?? ""
        self.realtimeVoice = preferences.string(forKey: Keys.realtimeVoice) ?? ""
        self.realtimeEndpoint = preferences.string(forKey: Keys.realtimeEndpoint) ?? ""
        self.realtimeFolderID = preferences.string(forKey: YandexRealtimePreferences.folderIDKey) ?? ""
        self.realtimeVoiceRole = preferences.string(forKey: YandexRealtimePreferences.voiceRoleKey) ?? ""
        self.selectedSkillIDs = preferences.stringArray(forKey: Keys.selectedSkillIDs) ?? ["scrum-master"]
        self.autonomousMeetingVoiceEnabled = preferences.object(forKey: Keys.autonomousMeetingVoice) as? Bool ?? true

        refreshRealtimeKeyIndicators()
        refresh()
        startWatcher()
        credentialObserver = NotificationCenter.default.addObserver(
            forName: YandexRealtimePreferences.credentialsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let posterIsStandard = (note.userInfo?["isStandard"] as? Bool) ?? false
            let posterObject = note.object as AnyObject?
            Task { @MainActor [weak self] in
                guard let self, posterObject !== self else { return }
                guard self.preferences === UserDefaults.standard && posterIsStandard else { return }
                self.suppressCredentialBroadcast = true
                defer { self.suppressCredentialBroadcast = false }
                let updatedFolder = self.preferences.string(forKey: YandexRealtimePreferences.folderIDKey) ?? ""
                if self.realtimeFolderID != updatedFolder {
                    self.realtimeFolderID = updatedFolder
                }
                self.refreshRealtimeKeyIndicators()
            }
        }
    }

    deinit {
        folderWatcher?.stop()
        watchedVaultURL?.stopAccessingSecurityScopedResource()
        if let credentialObserver {
            NotificationCenter.default.removeObserver(credentialObserver)
        }
    }

    // MARK: - Storage Resolution & Watcher

    static func defaultLocalRootURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Rock Assistant", isDirectory: true)
    }

    private func resolveRepositoryContext() -> (repo: AssistantSkillRepository, vaultURL: URL?, stopAccess: Bool) {
        if let customRootURL {
            let repo = AssistantSkillRepository(rootURL: customRootURL)
            try? repo.ensureDefaultsInstalled()
            return (repo, nil, false)
        }
        if let bookmark = preferences.data(forKey: Keys.vaultBookmark) {
            var stale = false
            if let vaultURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let accessed = vaultURL.startAccessingSecurityScopedResource()
                if stale, let refreshed = try? vaultURL.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    preferences.set(refreshed, forKey: Keys.vaultBookmark)
                }
                let root = vaultURL.appendingPathComponent("Rock Assistant", isDirectory: true)
                let repo = AssistantSkillRepository(rootURL: root)
                try? repo.ensureDefaultsInstalled()
                return (repo, vaultURL, accessed)
            }
        }
        let repo = AssistantSkillRepository(rootURL: Self.defaultLocalRootURL())
        try? repo.ensureDefaultsInstalled()
        return (repo, nil, false)
    }

    func withRepository<T>(_ operation: (AssistantSkillRepository, URL?) throws -> T) rethrows -> T {
        let context = resolveRepositoryContext()
        defer {
            if context.stopAccess {
                context.vaultURL?.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(context.repo, context.vaultURL)
    }

    func setObsidianFolder(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        preferences.set(bookmark, forKey: Keys.vaultBookmark)
        storageError = nil
        refresh()
        startWatcher()
    }

    func clearObsidianFolder() {
        preferences.removeObject(forKey: Keys.vaultBookmark)
        storageError = nil
        refresh()
        startWatcher()
    }

    func refresh() {
        withRepository { repo, vaultURL in
            self.skills = repo.listSkills()
            self.prompts = repo.listPrompts()
            self.people = repo.loadPeople()
            self.teamContext = repo.loadTeamContext()
            self.isObsidianBacked = vaultURL != nil
            self.folderPath = repo.rootURL.path
            self.hasLoadedOnce = true
        }
    }

    func startWatcher() {
        stopWatcher()
        var watchRoot = customRootURL ?? Self.defaultLocalRootURL()
        if customRootURL == nil, let bookmark = preferences.data(forKey: Keys.vaultBookmark) {
            var stale = false
            if let vaultURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), vaultURL.startAccessingSecurityScopedResource() {
                watchedVaultURL = vaultURL
                let candidate = vaultURL.appendingPathComponent("Rock Assistant", isDirectory: true)
                let repo = AssistantSkillRepository(rootURL: candidate)
                try? repo.ensureDefaultsInstalled()
                watchRoot = candidate
            }
        } else {
            let repo = AssistantSkillRepository(rootURL: watchRoot)
            try? repo.ensureDefaultsInstalled()
        }

        let watcher = AssistantSkillFolderWatcher(rootURL: watchRoot) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        watcher.start()
        folderWatcher = watcher
    }

    func stopWatcher() {
        folderWatcher?.stop()
        folderWatcher = nil
        if let vaultURL = watchedVaultURL {
            vaultURL.stopAccessingSecurityScopedResource()
            watchedVaultURL = nil
        }
    }

    // MARK: - Skills, Core Prompts & People CRUD

    @discardableResult
    func saveSkill(_ skill: AssistantSkill) throws -> AssistantSkill {
        let saved = try withRepository { repo, _ in
            try repo.saveSkill(skill)
        }
        refresh()
        return saved
    }

    func deleteSkill(id: String) throws {
        try withRepository { repo, _ in
            try repo.deleteSkill(id: id)
        }
        selectedSkillIDs.removeAll { $0 == id }
        refresh()
    }

    func restoreDefaultSkill(id: String? = nil) throws {
        try withRepository { repo, _ in
            if let id {
                _ = try repo.restoreDefaultSkill(id: id)
            } else {
                try repo.restoreAllDefaultSkills()
            }
        }
        refresh()
    }

    @discardableResult
    func savePrompt(_ kind: AssistantPromptKind, content: String) throws -> AssistantPromptDocument {
        let saved = try withRepository { repo, _ in
            try repo.savePrompt(kind, content: content)
        }
        refresh()
        return saved
    }

    @discardableResult
    func restoreDefaultPrompt(_ kind: AssistantPromptKind) throws -> AssistantPromptDocument {
        let restored = try withRepository { repo, _ in
            try repo.restoreDefaultPrompt(kind)
        }
        refresh()
        return restored
    }

    func promptText(for kind: AssistantPromptKind) -> String {
        if let cached = prompts.first(where: { $0.kind == kind }) {
            return cached.content
        }
        return withRepository { repo, _ in
            repo.loadPrompt(kind).content
        }
    }

    @discardableResult
    func upsertPerson(_ entry: AssistantPersonEntry) throws -> AssistantPeopleDirectory {
        let updated = try withRepository { repo, _ in
            try repo.upsertPerson(entry)
        }
        refresh()
        let handle = entry.jiraAccountID ?? entry.jiraUsername
        if let handle, !handle.isEmpty, let workspace {
            let appPerson = entry.toAppContactPerson()
            let jiraUser = JiraUserContact(
                identifier: handle,
                username: entry.jiraUsername ?? handle,
                accountId: entry.jiraAccountID,
                displayName: entry.displayName,
                emailAddress: entry.email,
                isServerOrDC: entry.jiraAccountID == nil
            )
            Task { @MainActor in
                await workspace.taskSync.setManualContactMapping(appContact: appPerson, jiraUser: jiraUser)
            }
        }
        return updated
    }

    func savePeople(_ directory: AssistantPeopleDirectory) throws {
        try withRepository { repo, _ in
            try repo.savePeople(directory)
        }
        refresh()
    }

    @discardableResult
    func removePerson(id: String) throws -> AssistantPeopleDirectory {
        let updated = try withRepository { repo, _ in
            try repo.removePerson(id: id)
        }
        refresh()
        return updated
    }

    func saveTeamContext(_ doc: AssistantTeamContextDocument) throws {
        try withRepository { repo, _ in
            try repo.saveTeamContext(doc)
        }
        refresh()
    }

    func searchKnowledge(query: String, limit: Int = 8) -> [AssistantKnowledgeSearchHit] {
        withRepository { repo, vaultURL in
            repo.searchKnowledge(query: query, extraVaultRoot: vaultURL, limit: limit)
        }
    }

    func searchKnowledgeAsync(query: String, limit: Int = 8) async -> [AssistantKnowledgeSearchHit] {
        let context = resolveRepositoryContext()
        defer {
            if context.stopAccess {
                context.vaultURL?.stopAccessingSecurityScopedResource()
            }
        }
        let repo = context.repo
        let vaultURL = context.vaultURL
        return await Task.detached(priority: .userInitiated) {
            repo.searchKnowledge(query: query, extraVaultRoot: vaultURL, limit: limit)
        }.value
    }

    func renderPromptContext(
        explicitSkillIDs: [String] = [],
        meetingTitle: String = "",
        commandText: String = ""
    ) -> (instructions: String, selectedSkills: [AssistantSkill], people: AssistantPeopleDirectory, teamContext: AssistantTeamContextDocument, basePersona: String) {
        let preferred = explicitSkillIDs.isEmpty ? selectedSkillIDs : explicitSkillIDs
        if hasLoadedOnce {
            let basePersona = prompts.first(where: { $0.kind == .basePersona })?.content ?? ""
            return AssistantSkillRepository.renderPromptContext(
                skills: skills,
                people: people,
                teamContext: teamContext,
                basePersona: basePersona,
                explicitSkillIDs: preferred,
                meetingTitle: meetingTitle,
                commandText: commandText
            )
        }
        return withRepository { repo, _ in
            repo.renderPromptContext(
                explicitSkillIDs: preferred,
                meetingTitle: meetingTitle,
                commandText: commandText
            )
        }
    }

    // MARK: - Realtime API Keys

    func realtimeAPIKey(for kind: RealtimeProviderKind? = nil) -> String? {
        let target = kind ?? realtimeProvider
        guard target != .disabled else { return nil }
        if let specific = keychain.readRealtime(provider: target)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !specific.isEmpty {
            return specific
        }
        if target == .openAIRealtime,
           let openAIKey = keychain.read(kind: .openAI)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !openAIKey.isEmpty {
            return openAIKey
        }
        return nil
    }

    @discardableResult
    func setRealtimeAPIKey(_ value: String, for kind: RealtimeProviderKind? = nil) -> Bool {
        let target = kind ?? realtimeProvider
        guard target != .disabled else { return false }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = clean.isEmpty
            ? keychain.deleteRealtime(provider: target)
            : keychain.writeRealtime(clean, provider: target)
        refreshRealtimeKeyIndicators()
        if saved && target == .yandexRealtime && !suppressCredentialBroadcast {
            NotificationCenter.default.post(
                name: YandexRealtimePreferences.credentialsChangedNotification,
                object: self,
                userInfo: ["isStandard": preferences === UserDefaults.standard]
            )
        }
        return saved
    }

    func refreshRealtimeKeyIndicators() {
        var present: Set<RealtimeProviderKind> = []
        for kind in RealtimeProviderKind.allCases where kind != .disabled {
            if let existing = keychain.readRealtime(provider: kind),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                present.insert(kind)
            }
        }
        keyedRealtimeProviders = present
    }

    // MARK: - Workspace Actions with People.md Resolution

    func resolvedOwnerName(_ rawOwner: String?) -> String {
        let clean = (rawOwner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        if let person = people.resolvePerson(matching: clean) {
            return person.displayName
        }
        return clean
    }

    func createTaskWithPeopleResolution(
        sessionID: UUID?,
        title: String,
        owner: String?,
        dueDay: String? = nil,
        syncToJira: Bool = false
    ) async -> (resolvedTitle: String, resolvedOwner: String, jiraSynced: Bool)? {
        guard let workspace else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let ownerName = resolvedOwnerName(owner)
        let targetSessionID = sessionID
            ?? workspace.historySessions.first?.id
            ?? TaskExtendedMetadata.externalImportsSessionID
        await workspace.addTask(
            sessionID: targetSessionID,
            text: cleanTitle,
            owner: ownerName,
            dueDay: dueDay,
            reminderAt: nil
        )
        var syncedJira = false
        if syncToJira && workspace.taskSync.preferences.jira.enabled,
           let created = workspace.tasks.first(where: { $0.sessionID == targetSessionID && $0.text == cleanTitle }) {
            await workspace.taskSync.runSync(explicitTaskIDs: [created.id], automaticTrigger: true)
            syncedJira = true
        }
        return (cleanTitle, ownerName, syncedJira)
    }

    func updateTaskWithPeopleResolution(
        taskID: String? = nil,
        query: String? = nil,
        done: Bool? = nil,
        newTitle: String? = nil,
        owner: String? = nil,
        dueDay: String? = nil,
        syncToJira: Bool = false
    ) async -> (id: UUID, title: String, done: Bool, owner: String)? {
        guard let workspace else { return nil }
        var matched: IOSMeetingTaskItem?
        if let rawID = taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
           let uuid = UUID(uuidString: rawID) {
            matched = workspace.tasks.first(where: { $0.id == uuid })
        }
        if matched == nil,
           let q = query?.trimmingCharacters(in: .whitespacesAndNewlines),
           !q.isEmpty {
            let needle = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let openFirst = workspace.tasks.filter { !$0.done } + workspace.tasks.filter(\.done)
            matched = openFirst.first(where: {
                $0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
            })
        }
        guard var task = matched else { return nil }

        let now = Date()
        if let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let owner, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.owner = resolvedOwnerName(owner)
        }
        if let dueDay {
            let cleanDue = dueDay.trimmingCharacters(in: .whitespacesAndNewlines)
            task.dueDay = cleanDue.isEmpty ? nil : cleanDue
        }
        if let done {
            task.done = done
            task.completedAt = done ? now : nil
            if done { task.reminderAt = nil }
            task.extended.applyDoneFlag(done)
        }
        task.updatedAt = now

        guard await workspace.updateTask(task) else { return nil }
        if syncToJira && workspace.taskSync.preferences.jira.enabled {
            await workspace.taskSync.runSync(explicitTaskIDs: [task.id], automaticTrigger: true)
        }
        return (task.id, task.text, task.done, task.owner)
    }

    func updateMeetingArtifacts(
        sessionID: UUID?,
        summaryAppend: String? = nil,
        replaceSummary: String? = nil,
        decisions: [String] = [],
        openQuestions: [String] = [],
        actionItems: [(text: String, owner: String, dueDay: String?)] = []
    ) async -> Bool {
        guard let workspace else { return false }
        let sid = sessionID ?? workspace.historySessions.first?.id
        guard let sid else { return false }

        let existing = workspace.outcomesBySession[sid]
        var summary = existing?.summary ?? ""
        if let replaceSummary, !replaceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = replaceSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let summaryAppend, !summaryAppend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let chunk = summaryAppend.trimmingCharacters(in: .whitespacesAndNewlines)
            summary = summary.isEmpty ? chunk : (summary + "\n" + chunk)
        }

        var mergedDecisions = existing?.decisions ?? []
        for item in decisions {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !mergedDecisions.contains(clean) {
                mergedDecisions.append(clean)
            }
        }
        var mergedQuestions = existing?.openQuestions ?? []
        for q in openQuestions {
            let clean = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !mergedQuestions.contains(clean) {
                mergedQuestions.append(clean)
            }
        }

        await workspace.saveEditedOutcome(
            sessionID: sid,
            summary: summary,
            decisions: mergedDecisions,
            openQuestions: mergedQuestions
        )
        for item in actionItems {
            let clean = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            await workspace.addTask(
                sessionID: sid,
                text: clean,
                owner: resolvedOwnerName(item.owner),
                dueDay: item.dueDay,
                reminderAt: nil
            )
        }
        return true
    }

    func scheduleCalendarMeeting(
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: String? = nil,
        agendaNotes: String = ""
    ) async throws -> TaskLinkedDiscussionMeeting? {
        guard let workspace else { return nil }
        let cleanCal = teamContext.defaultCalendarIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = TaskCalendarEventDraft(
            calendarIdentifier: cleanCal.isEmpty ? nil : cleanCal,
            title: title,
            startAt: startAt,
            endAt: endAt,
            meetingURL: meetingURL,
            agendaNotes: agendaNotes
        )
        return try await workspace.taskSync.createTaskDiscussionCalendarEvent(draft, forTaskID: UUID())
    }

    func resolvedJiraJQL(rawJQL: String?, query: String?) -> String {
        let explicit = (rawJQL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let teamProject = teamContext.defaultJiraProjectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let jiraProject = workspace?.taskSync.preferences.jira.cleanProjectKey ?? ""
        let project = teamProject.isEmpty ? jiraProject : teamProject
        let cleanQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        var clauses: [String] = []
        if !project.isEmpty { clauses.append("project = \(project)") }
        if !cleanQuery.isEmpty { clauses.append("text ~ \"\(cleanQuery)\"") }
        return clauses.isEmpty ? "ORDER BY updated DESC" : (clauses.joined(separator: " AND ") + " ORDER BY updated DESC")
    }

    func searchJiraIssues(jql: String?, query: String?, maxResults: Int = 15) async throws -> [JiraRemoteIssue] {
        guard let workspace else { return [] }
        let resolved = resolvedJiraJQL(rawJQL: jql, query: query)
        return try await workspace.taskSync.searchJiraIssues(jql: resolved, maxResults: max(1, min(maxResults, 50)))
    }

    func commentOnJiraIssue(key: String, comment: String) async throws {
        guard let workspace else { return }
        try await workspace.taskSync.commentOnJiraIssue(key: key, comment: comment)
    }
}
