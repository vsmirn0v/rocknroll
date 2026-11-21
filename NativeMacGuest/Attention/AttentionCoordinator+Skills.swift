import ConferenceCore
import Foundation

extension AttentionCoordinator {
    /// Resolves `<ObsidianVault>/Rock Assistant` when an Obsidian destination bookmark is configured,
    /// falling back to `store.localAssistantSkillsRootURL()` otherwise. Security-scoped access is held
    /// only for the duration of `operation`.
    func withSkillRepository<T>(_ operation: (AssistantSkillRepository, URL?) throws -> T) async rethrows -> T {
        if let destination = try? await store.meetingLibrary.store.destination(),
           let bookmark = destination.vaultBookmark {
            let resolved = ObsidianVaultAccess.resolveWithRefresh(bookmark)
            if let refreshed = resolved.refreshedBookmark, case .granted = resolved.resolution {
                var updated = destination
                updated.vaultBookmark = refreshed
                try? await store.meetingLibrary.store.saveDestination(updated)
            }
            if case .granted(let vaultURL) = resolved.resolution {
                defer { vaultURL.stopAccessingSecurityScopedResource() }
                let repo = AssistantSkillRepository(rootURL: vaultURL.appendingPathComponent("Rock Assistant", isDirectory: true))
                try? repo.ensureDefaultsInstalled()
                return try operation(repo, vaultURL)
            }
        }
        let repo = store.localSkillRepository()
        return try operation(repo, nil)
    }

    func skillStorageSummary() async -> (isObsidianBacked: Bool, folderPath: String) {
        await withSkillRepository { repo, vaultURL in
            (vaultURL != nil, repo.rootURL.path)
        }
    }

    func listAssistantSkills() async -> [AssistantSkill] {
        await withSkillRepository { repo, _ in
            repo.listSkills()
        }
    }

    func saveAssistantSkill(_ skill: AssistantSkill) async throws -> AssistantSkill {
        try await withSkillRepository { repo, _ in
            try repo.saveSkill(skill)
        }
    }

    func deleteAssistantSkill(id: String) async throws {
        try await withSkillRepository { repo, _ in
            try repo.deleteSkill(id: id)
        }
    }

    func restoreDefaultAssistantSkills(id: String? = nil) async throws {
        try await withSkillRepository { repo, _ in
            if let id {
                _ = try repo.restoreDefaultSkill(id: id)
            } else {
                try repo.restoreAllDefaultSkills()
            }
        }
    }

    func loadPeopleDirectory() async -> AssistantPeopleDirectory {
        await withSkillRepository { repo, _ in
            repo.loadPeople()
        }
    }

    func savePeopleDirectory(_ directory: AssistantPeopleDirectory) async throws {
        try await withSkillRepository { repo, _ in
            try repo.savePeople(directory)
        }
    }

    func upsertPersonMapping(_ entry: AssistantPersonEntry) async throws -> AssistantPeopleDirectory {
        let updated = try await withSkillRepository { repo, _ in
            try repo.upsertPerson(entry)
        }
        // Mirror confirmed Jira handle into WorkspaceTaskSyncController so issue creation/reassignment sees it immediately.
        let handle = entry.jiraAccountID ?? entry.jiraUsername
        if let handle, !handle.isEmpty {
            let appPerson = entry.toAppContactPerson()
            let jiraUser = JiraUserContact(
                identifier: handle,
                username: entry.jiraUsername ?? handle,
                accountId: entry.jiraAccountID,
                displayName: entry.displayName,
                emailAddress: entry.email,
                isServerOrDC: entry.jiraAccountID == nil
            )
            await taskSync.setManualContactMapping(appContact: appPerson, jiraUser: jiraUser)
        }
        return updated
    }

    func loadTeamContext() async -> AssistantTeamContextDocument {
        await withSkillRepository { repo, _ in
            repo.loadTeamContext()
        }
    }

    func saveTeamContext(_ doc: AssistantTeamContextDocument) async throws {
        try await withSkillRepository { repo, _ in
            try repo.saveTeamContext(doc)
        }
    }

    // MARK: - Core Obsidian Prompts

    func listAssistantPrompts() async -> [AssistantPromptDocument] {
        let docs = await withSkillRepository { repo, _ in
            repo.listPrompts()
        }
        for doc in docs {
            cachedPromptTexts[doc.kind] = doc.content
        }
        return docs
    }

    func loadAssistantPrompt(_ kind: AssistantPromptKind) async -> AssistantPromptDocument {
        let doc = await withSkillRepository { repo, _ in
            repo.loadPrompt(kind)
        }
        cachedPromptTexts[kind] = doc.content
        return doc
    }

    @discardableResult
    func saveAssistantPrompt(_ kind: AssistantPromptKind, content: String) async throws -> AssistantPromptDocument {
        let doc = try await withSkillRepository { repo, _ in
            try repo.savePrompt(kind, content: content)
        }
        cachedPromptTexts[kind] = doc.content
        return doc
    }

    @discardableResult
    func restoreDefaultAssistantPrompt(_ kind: AssistantPromptKind) async throws -> AssistantPromptDocument {
        let doc = try await withSkillRepository { repo, _ in
            try repo.restoreDefaultPrompt(kind)
        }
        cachedPromptTexts[kind] = doc.content
        return doc
    }

    func refreshCachedPrompts() async {
        _ = await listAssistantPrompts()
    }

    func startSkillFolderWatcher() async {
        stopSkillFolderWatcher()
        var watchRoot = store.localAssistantSkillsRootURL()
        _ = store.localSkillRepository()

        if let destination = try? await store.meetingLibrary.store.destination(),
           let bookmark = destination.vaultBookmark {
            let resolved = ObsidianVaultAccess.resolveWithRefresh(bookmark)
            if let refreshed = resolved.refreshedBookmark, case .granted = resolved.resolution {
                var updated = destination
                updated.vaultBookmark = refreshed
                try? await store.meetingLibrary.store.saveDestination(updated)
            }
            if case .granted(let vaultURL) = resolved.resolution {
                watchedSkillVaultURL = vaultURL
                let candidate = vaultURL.appendingPathComponent("Rock Assistant", isDirectory: true)
                let repo = AssistantSkillRepository(rootURL: candidate)
                try? repo.ensureDefaultsInstalled()
                watchRoot = candidate
            }
        }

        let watcher = AssistantSkillFolderWatcher(rootURL: watchRoot) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshCachedPrompts()
                self.facilitator?.invalidateSkillCache()
                self.objectWillChange.send()
            }
        }
        watcher.start()
        skillFolderWatcher = watcher
    }

    func stopSkillFolderWatcher() {
        skillFolderWatcher?.stop()
        skillFolderWatcher = nil
        if let vaultURL = watchedSkillVaultURL {
            vaultURL.stopAccessingSecurityScopedResource()
            watchedSkillVaultURL = nil
        }
    }

    func searchAssistantKnowledge(query: String, limit: Int = 8) async -> [AssistantKnowledgeSearchHit] {
        await withSkillRepository { repo, vaultURL in
            repo.searchKnowledge(query: query, extraVaultRoot: vaultURL, limit: limit)
        }
    }

    func createTaskAction(
        sessionID: UUID?,
        outcomeID: UUID? = nil,
        title: String,
        owner: String?,
        dueDay: String? = nil,
        notes: String? = nil,
        syncToJira: Bool = false
    ) async throws -> (outcomeID: UUID, task: MeetingOutcomeTask, syncedJira: Bool) {
        await store.waitForMeetingLibrary()
        await store.waitForOutcomeWrites()

        // Resolve spoken/alias owner via People.md
        var resolvedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var resolvedAssigneeID: String?
        if !resolvedOwner.isEmpty {
            let directory = await loadPeopleDirectory()
            if let person = directory.resolvePerson(matching: resolvedOwner) {
                resolvedOwner = person.displayName
                resolvedAssigneeID = person.jiraAccountID ?? person.jiraUsername ?? person.id
            }
        }

        var createdTask: MeetingOutcomeTask?
        let commit = try await store.publishOutcomeMutation {
            let created = try await store.meetingLibrary.store.createAssistantTask(
                sessionID: sessionID,
                outcomeID: outcomeID,
                title: title,
                owner: resolvedOwner,
                assigneeID: resolvedAssigneeID,
                dueDay: dueDay,
                notes: notes
            )
            createdTask = created.task
            return created.commit
        }

        guard let commit, let task = createdTask ?? commit.outcome.tasks.last else {
            throw NativeDesktopError.unavailable(L("Could not create the task."))
        }
        await store.meetingLibrary.refresh()

        var didSyncJira = false
        if syncToJira && taskSync.preferences.jira.enabled {
            await taskSync.runSync(explicitTaskIDs: [task.id], automaticTrigger: true)
            didSyncJira = true
        }
        return (commit.outcome.id, task, didSyncJira)
    }

    func updateMeetingArtifactsAction(
        outcomeID: UUID?,
        sessionID: UUID?,
        summaryAppend: String? = nil,
        replaceSummary: String? = nil,
        addDecisions: [String] = [],
        addOpenQuestions: [String] = [],
        addTasks: [(text: String, owner: String, dueDay: String?)] = []
    ) async throws -> MeetingOutcome? {
        await store.waitForMeetingLibrary()
        await store.waitForOutcomeWrites()
        let directory = await loadPeopleDirectory()
        let resolvedTasks: [(text: String, owner: String, assigneeID: String?, dueDay: String?)] = addTasks.map { item in
            let person = item.owner.isEmpty ? nil : directory.resolvePerson(matching: item.owner)
            return (
                item.text,
                person?.displayName ?? item.owner,
                person.flatMap { $0.jiraAccountID ?? $0.jiraUsername ?? $0.id },
                item.dueDay
            )
        }
        let commit = try await store.publishOutcomeMutation {
            try await store.meetingLibrary.store.updateMeetingArtifacts(
                outcomeID: outcomeID,
                sessionID: sessionID,
                summaryAppend: summaryAppend,
                replaceSummary: replaceSummary,
                addDecisions: addDecisions,
                addOpenQuestions: addOpenQuestions,
                addTasks: resolvedTasks
            )
        }
        await store.meetingLibrary.refresh()
        return commit?.outcome
    }

    func scheduleCalendarMeetingAction(
        title: String,
        startAt: Date,
        endAt: Date,
        meetingURL: String? = nil,
        agendaNotes: String = "",
        calendarID: String? = nil
    ) async throws -> TaskLinkedDiscussionMeeting {
        var resolvedCalendarID = calendarID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedCalendarID?.isEmpty != false {
            let team = await loadTeamContext()
            let fallback = team.defaultCalendarIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedCalendarID = fallback.isEmpty ? nil : fallback
        }
        let draft = TaskCalendarEventDraft(
            calendarIdentifier: resolvedCalendarID,
            title: title,
            startAt: startAt,
            endAt: endAt,
            meetingURL: meetingURL,
            agendaNotes: agendaNotes
        )
        return try await taskSync.createTaskDiscussionCalendarEvent(draft, forTaskID: UUID())
    }
}
