import ConferenceCore
import Foundation

extension AttentionCoordinator {
    private struct ResolvedSkillRepoContext {
        var primary: AssistantSkillRepository
        var composite: CompositeAssistantSkillRepository
        var primaryVaultURL: URL?
        var securityScopedURLs: [URL]
    }

    private func resolveSkillRepositoryContext() async -> ResolvedSkillRepoContext {
        let destinations = (try? await store.meetingLibrary.store.destinations()) ?? []
        let primaryDest = destinations.first(where: \.isPrimary) ?? destinations.first

        var primaryRepo = store.localSkillRepository()
        var primaryVaultURL: URL?
        var scopedURLs: [URL] = []

        if let primaryDest, let bookmark = primaryDest.vaultBookmark {
            let resolved = ObsidianVaultAccess.resolveWithRefresh(bookmark)
            if let refreshed = resolved.refreshedBookmark, case .granted = resolved.resolution {
                var updated = primaryDest
                updated.vaultBookmark = refreshed
                try? await store.meetingLibrary.store.saveDestination(updated)
            }
            if case .granted(let vaultURL) = resolved.resolution {
                scopedURLs.append(vaultURL)
                primaryVaultURL = vaultURL
                let repo = AssistantSkillRepository(
                    rootURL: vaultURL.appendingPathComponent("Rock Assistant", isDirectory: true),
                    owningDestinationID: primaryDest.id
                )
                try? repo.ensureDefaultsInstalled()
                primaryRepo = repo
            }
        }

        var secondaryRepos: [AssistantSkillRepository] = []
        for dest in destinations where !dest.isPrimary && dest.loadsSkills {
            guard let bookmark = dest.vaultBookmark else { continue }
            let resolved = ObsidianVaultAccess.resolveWithRefresh(bookmark)
            if let refreshed = resolved.refreshedBookmark, case .granted = resolved.resolution {
                var updated = dest
                updated.vaultBookmark = refreshed
                try? await store.meetingLibrary.store.saveDestination(updated)
            }
            if case .granted(let vaultURL) = resolved.resolution {
                scopedURLs.append(vaultURL)
                let repo = AssistantSkillRepository(
                    rootURL: vaultURL.appendingPathComponent("Rock Assistant", isDirectory: true),
                    owningDestinationID: dest.id
                )
                secondaryRepos.append(repo)
            }
        }

        let composite = CompositeAssistantSkillRepository(primary: primaryRepo, secondary: secondaryRepos)
        return ResolvedSkillRepoContext(
            primary: primaryRepo,
            composite: composite,
            primaryVaultURL: primaryVaultURL,
            securityScopedURLs: scopedURLs
        )
    }

    /// Resolves `<ObsidianVault>/Rock Assistant` when an Obsidian destination bookmark is configured,
    /// falling back to `store.localAssistantSkillsRootURL()` otherwise. Security-scoped access is held
    /// only for the duration of `operation`.
    func withSkillRepository<T>(_ operation: (AssistantSkillRepository, URL?) throws -> T) async rethrows -> T {
        let context = await resolveSkillRepositoryContext()
        defer { context.securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try operation(context.primary, context.primaryVaultURL)
    }

    func withCompositeSkillRepository<T>(_ operation: (CompositeAssistantSkillRepository, URL?) throws -> T) async rethrows -> T {
        let context = await resolveSkillRepositoryContext()
        defer { context.securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try operation(context.composite, context.primaryVaultURL)
    }

    /// Async counterpart to `withSkillRepository` holding security-scoped access across `operation`.
    func withSkillRepositoryAsync<T>(_ operation: (AssistantSkillRepository, URL?) async throws -> T) async rethrows -> T {
        let context = await resolveSkillRepositoryContext()
        defer { context.securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try await operation(context.primary, context.primaryVaultURL)
    }

    func skillStorageSummary() async -> (isObsidianBacked: Bool, folderPath: String) {
        await withSkillRepository { repo, vaultURL in
            (vaultURL != nil, repo.rootURL.path)
        }
    }

    func listAssistantSkills() async -> [AssistantSkill] {
        await withCompositeSkillRepository { composite, _ in
            composite.listSkills()
        }
    }

    func listAssistantPresets(skillID: String? = nil) async -> [AssistantRolePreset] {
        await withCompositeSkillRepository { composite, _ in
            composite.listPresets(skillID: skillID)
        }
    }

    @discardableResult
    func saveAssistantPreset(_ preset: AssistantRolePreset, owningDestinationID: UUID? = nil) async throws -> AssistantRolePreset {
        let saved = try await withCompositeSkillRepository { composite, _ in
            try composite.savePreset(preset, preferredDestinationID: owningDestinationID)
        }
        notifyLocalAssistantDataChanged()
        return saved
    }

    func deleteAssistantPreset(skillID: String, id: String, owningDestinationID: UUID? = nil) async throws {
        try await withCompositeSkillRepository { composite, _ in
            try composite.deletePreset(skillID: skillID, id: id, owningDestinationID: owningDestinationID)
        }
        notifyLocalAssistantDataChanged()
    }

    private func notifyLocalAssistantDataChanged() {
        guard !isApplyingRemoteCloudSync else { return }
        onLocalAssistantDataChanged?()
    }

    func saveAssistantSkill(_ skill: AssistantSkill) async throws -> AssistantSkill {
        let saved = try await withSkillRepository { repo, _ in
            try repo.saveSkill(skill)
        }
        notifyLocalAssistantDataChanged()
        return saved
    }

    func deleteAssistantSkill(id: String) async throws {
        try await withSkillRepository { repo, _ in
            try repo.deleteSkill(id: id)
        }
        notifyLocalAssistantDataChanged()
    }

    func restoreDefaultAssistantSkills(id: String? = nil) async throws {
        try await withSkillRepository { repo, _ in
            if let id {
                _ = try repo.restoreDefaultSkill(id: id)
            } else {
                try repo.restoreAllDefaultSkills()
            }
        }
        notifyLocalAssistantDataChanged()
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
        for entry in directory.entries {
            await mirrorJiraMappingIfConfirmed(entry)
        }
        notifyLocalAssistantDataChanged()
    }

    func upsertPersonMapping(_ entry: AssistantPersonEntry, allowPrivilegeChange: Bool = true) async throws -> AssistantPeopleDirectory {
        let updated = try await withSkillRepository { repo, _ in
            try repo.upsertPerson(entry, allowPrivilegeChange: allowPrivilegeChange)
        }
        await mirrorJiraMappingIfConfirmed(entry)
        notifyLocalAssistantDataChanged()
        return updated
    }

    private func mirrorJiraMappingIfConfirmed(_ entry: AssistantPersonEntry) async {
        // Mirror confirmed Jira handle into WorkspaceTaskSyncController so issue creation/reassignment sees it immediately.
        let handle = entry.jiraAccountID ?? entry.jiraUsername
        guard let handle, !handle.isEmpty else { return }
        let appPerson = entry.toAppContactPerson()
        if let existing = taskSync.preferences.contactMappings.first(where: { $0.appContactKey == appPerson.key }),
           existing.isConfirmedByUser,
           existing.jiraIdentifier == handle {
            return
        }
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

    func loadTeamContext() async -> AssistantTeamContextDocument {
        await withSkillRepository { repo, _ in
            repo.loadTeamContext()
        }
    }

    func saveTeamContext(_ doc: AssistantTeamContextDocument) async throws {
        try await withSkillRepository { repo, _ in
            try repo.saveTeamContext(doc)
        }
        notifyLocalAssistantDataChanged()
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
        notifyLocalAssistantDataChanged()
        return doc
    }

    @discardableResult
    func restoreDefaultAssistantPrompt(_ kind: AssistantPromptKind) async throws -> AssistantPromptDocument {
        let doc = try await withSkillRepository { repo, _ in
            try repo.restoreDefaultPrompt(kind)
        }
        cachedPromptTexts[kind] = doc.content
        notifyLocalAssistantDataChanged()
        return doc
    }

    func refreshCachedPrompts() async {
        let docs = await withSkillRepository { repo, _ in
            repo.listPrompts()
        }
        for doc in docs {
            cachedPromptTexts[doc.kind] = doc.content
        }
    }

    func currentAssistantCloudInput() async -> AssistantCloudSync.LocalSnapshotInput {
        let destinations = (try? await store.meetingLibrary.store.destinations()) ?? []
        let vaultDescriptors = destinations.map { dest in
            SyncedVaultDestinationDescriptor(
                id: dest.id,
                slug: dest.resolvedSlug,
                name: dest.displayName,
                isPrimary: dest.isPrimary
            )
        }
        let repoSnapshot = await withCompositeSkillRepository { composite, _ in
            (
                people: composite.primary.loadPeople(),
                teamContext: composite.primary.loadTeamContext(),
                skills: composite.listSkills(),
                presets: composite.listPresets(),
                prompts: composite.primary.listPrompts()
            )
        }
        return AssistantCloudSync.LocalSnapshotInput(
            people: repoSnapshot.people,
            teamContext: repoSnapshot.teamContext,
            skills: repoSnapshot.skills,
            presets: repoSnapshot.presets,
            prompts: repoSnapshot.prompts,
            preferences: LocalAssistantPortablePreferences(
                selectedSkillIDs: store.selectedSkillIDs,
                autonomousMeetingVoiceEnabled: store.autonomousMeetingVoiceEnabled,
                realtimeProvider: store.realtimeProvider.rawValue,
                realtimeModel: store.realtimeModel,
                realtimeVoice: store.realtimeVoice,
                realtimeEndpoint: store.realtimeEndpoint,
                realtimeFolderID: store.realtimeFolderID,
                realtimeVoiceRole: store.realtimeVoiceRole,
                lastBoardURL: store.lastBoardURL
            ),
            vaultDestinations: vaultDescriptors
        )
    }

    func applyRemoteAssistantCloudSync(
        settings: [String: SyncedMeetingContextSettings],
        previousBaseline: AssistantLocalSyncBaseline?
    ) async -> AssistantLocalSyncBaseline? {
        let currentInput = await currentAssistantCloudInput()
        guard let plan = AssistantCloudSync.planRemoteApplication(
            from: settings,
            currentInput: currentInput,
            previousBaseline: previousBaseline
        ) else {
            return previousBaseline
        }
        if let updated = plan.updatedVaultDestinations, !updated.isEmpty, syncedVaultDestinations != updated {
            syncedVaultDestinations = updated
        } else if !currentInput.vaultDestinations.isEmpty && syncedVaultDestinations.isEmpty {
            syncedVaultDestinations = currentInput.vaultDestinations
        }
        guard plan.hasAnyChange else {
            return plan.updatedBaseline
        }

        isApplyingRemoteCloudSync = true
        defer { isApplyingRemoteCloudSync = false }

        try? await withCompositeSkillRepository { composite, _ in
            try AssistantCloudSync.applyRepositoryChanges(from: plan, to: composite.primary)
        }

        if let prefs = plan.updatedPreferences {
            if store.selectedSkillIDs != prefs.selectedSkillIDs { store.selectedSkillIDs = prefs.selectedSkillIDs }
            if store.autonomousMeetingVoiceEnabled != prefs.autonomousMeetingVoiceEnabled {
                store.autonomousMeetingVoiceEnabled = prefs.autonomousMeetingVoiceEnabled
            }
            let nextProvider = RealtimeProviderKind(rawValue: prefs.realtimeProvider) ?? .disabled
            if store.realtimeProvider != nextProvider { store.realtimeProvider = nextProvider }
            if store.realtimeModel != prefs.realtimeModel { store.realtimeModel = prefs.realtimeModel }
            if store.realtimeVoice != prefs.realtimeVoice { store.realtimeVoice = prefs.realtimeVoice }
            if store.realtimeEndpoint != prefs.realtimeEndpoint { store.realtimeEndpoint = prefs.realtimeEndpoint }
            if store.realtimeFolderID != prefs.realtimeFolderID { store.realtimeFolderID = prefs.realtimeFolderID }
            if store.realtimeVoiceRole != prefs.realtimeVoiceRole { store.realtimeVoiceRole = prefs.realtimeVoiceRole }
            if store.lastBoardURL != prefs.lastBoardURL { store.lastBoardURL = prefs.lastBoardURL }
        }

        await refreshCachedPrompts()
        facilitator?.invalidateSkillCache()
        if let updatedPeople = plan.updatedPeople {
            for entry in updatedPeople.entries {
                await mirrorJiraMappingIfConfirmed(entry)
            }
        }
        objectWillChange.send()
        return plan.updatedBaseline
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
                self.notifyLocalAssistantDataChanged()
            }
        }
        watcher.start()
        skillFolderWatcher = watcher
        await refreshCachedPrompts()
        facilitator?.invalidateSkillCache()
        objectWillChange.send()
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
        await withSkillRepositoryAsync { repo, vaultURL in
            await Task.detached(priority: .userInitiated) {
                repo.searchKnowledge(query: query, extraVaultRoot: vaultURL, limit: limit)
            }.value
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
