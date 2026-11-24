import Combine
import Foundation

@MainActor
public final class WorkspaceTaskSyncController: ObservableObject {
    public struct HostHooks {
        public var isMacPlatform: Bool
        public var deviceName: String
        public var loadTasks: @MainActor () async -> [WorkspaceTaskRecord]
        public var loadContacts: @MainActor () async -> [AppContactPerson]
        public var loadMyAliases: @MainActor () -> [String]
        public var applyMutations: @MainActor ([TaskSyncLocalMutation]) async throws -> Void
        public var persistPreferences: @MainActor (TaskSyncPreferences) async -> Void
        public var saveHandoverPacket: @MainActor (MacJiraHandoverPacket) async -> Void
        public var loadHandoverPackets: @MainActor () -> [MacJiraHandoverPacket]
        public var readSecret: (@Sendable (String, TaskIntegrationSecretKind) -> String?)?
        public var writeSecret: (@Sendable (String, String, TaskIntegrationSecretKind) -> Bool)?
        public var makeJiraConnector: (JiraConnectionSettings, TaskIntegrationKeychain) -> any JiraTaskConnecting
        public var makeRemindersConnector: () -> any AppleRemindersConnecting
        public var makeCalendarConnector: () -> any TaskCalendarEventConnecting
        public var onCalendarEventCreated: @MainActor () async -> Void

        public init(
            isMacPlatform: Bool = {
                #if os(macOS)
                return true
                #else
                return false
                #endif
            }(),
            deviceName: String = {
                #if os(macOS)
                return "Mac"
                #else
                return "iPhone"
                #endif
            }(),
            loadTasks: @escaping @MainActor () async -> [WorkspaceTaskRecord],
            loadContacts: @escaping @MainActor () async -> [AppContactPerson],
            loadMyAliases: @escaping @MainActor () -> [String],
            applyMutations: @escaping @MainActor ([TaskSyncLocalMutation]) async throws -> Void,
            persistPreferences: @escaping @MainActor (TaskSyncPreferences) async -> Void,
            saveHandoverPacket: @escaping @MainActor (MacJiraHandoverPacket) async -> Void = { _ in },
            loadHandoverPackets: @escaping @MainActor () -> [MacJiraHandoverPacket] = { [] },
            readSecret: (@Sendable (String, TaskIntegrationSecretKind) -> String?)? = nil,
            writeSecret: (@Sendable (String, String, TaskIntegrationSecretKind) -> Bool)? = nil,
            makeJiraConnector: @escaping (JiraConnectionSettings, TaskIntegrationKeychain) -> any JiraTaskConnecting = {
                JiraTaskConnector(settings: $0, keychain: $1)
            },
            makeRemindersConnector: @escaping () -> any AppleRemindersConnecting = { AppleRemindersConnector() },
            makeCalendarConnector: @escaping () -> any TaskCalendarEventConnecting = { TaskCalendarEventConnector() },
            onCalendarEventCreated: @escaping @MainActor () async -> Void = {}
        ) {
            self.isMacPlatform = isMacPlatform
            self.deviceName = deviceName
            self.loadTasks = loadTasks
            self.loadContacts = loadContacts
            self.loadMyAliases = loadMyAliases
            self.applyMutations = applyMutations
            self.persistPreferences = persistPreferences
            self.saveHandoverPacket = saveHandoverPacket
            self.loadHandoverPackets = loadHandoverPackets
            self.readSecret = readSecret
            self.writeSecret = writeSecret
            self.makeJiraConnector = makeJiraConnector
            self.makeRemindersConnector = makeRemindersConnector
            self.makeCalendarConnector = makeCalendarConnector
            self.onCalendarEventCreated = onCalendarEventCreated
        }
    }

    @Published public var preferences: TaskSyncPreferences
    @Published public var isBusy = false
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?
    @Published public var pendingPacket: TaskSyncPacket?
    @Published public var lastReport: TaskSyncExecutionReport?
    @Published public var assignableJiraUsers: [JiraUserContact] = []
    public var jiraConnectorForTesting: (any JiraTaskConnecting)?
    public weak var boardWebEvaluator: (any JiraBoardWebEvaluating)?
    @Published public private(set) var boardJiraSessionActive = false
    @Published public private(set) var derivedBoardProjectKeys: [String] = []
    private var derivedBoardCacheURL: String?
    @Published public var currentJiraUser: JiraUserContact?
    @Published public var reminderLists: [ReminderListInfo] = []
    @Published public var appContacts: [AppContactPerson] = []
    @Published public var pendingMacHandovers: [MacJiraHandoverPacket] = []
    @Published public var recentCompletedHandovers: [MacJiraHandoverPacket] = []

    public let keychain: TaskIntegrationKeychain
    private let defaultsKey = "workspace.taskSyncPreferences.v1"
    private let hooks: HostHooks
    private var isProcessingHandovers = false

    public var isMacHost: Bool { hooks.isMacPlatform }

    public init(hooks: HostHooks, keychain: TaskIntegrationKeychain = .init()) {
        self.hooks = hooks
        self.keychain = keychain
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let decoded = TaskSyncPreferences.decodeSyncJSON(raw) {
            self.preferences = decoded
            self.assignableJiraUsers = decoded.jira.cachedProjectUsers
        } else {
            self.preferences = TaskSyncPreferences()
        }
    }

    public func refreshHandoverState() {
        let all = hooks.loadHandoverPackets().sorted { $0.updatedAt > $1.updatedAt }
        pendingMacHandovers = all.filter { $0.status == .pendingMac }
        recentCompletedHandovers = Array(all.filter { $0.status != .pendingMac }.prefix(10))
    }

    public func updatePreferencesFromRemoteSync(_ remote: TaskSyncPreferences) {
        if assignableJiraUsers.isEmpty && !remote.jira.cachedProjectUsers.isEmpty {
            assignableJiraUsers = remote.jira.cachedProjectUsers
        }
        guard remote != preferences else { return }
        preferences = remote
        if !remote.jira.cachedProjectUsers.isEmpty && assignableJiraUsers.isEmpty {
            assignableJiraUsers = remote.jira.cachedProjectUsers
        }
        UserDefaults.standard.set(remote.encodeSyncJSON(), forKey: defaultsKey)
    }

    public func savePreferences(_ updated: TaskSyncPreferences) async {
        preferences = updated
        UserDefaults.standard.set(updated.encodeSyncJSON(), forKey: defaultsKey)
        await hooks.persistPreferences(updated)
    }

    public func setRoleMode(_ mode: TaskSyncRoleMode) async {
        var updated = preferences
        updated.roleMode = mode
        switch mode {
        case .personalOwner:
            updated.scopeMode = .myTasksOnly
        case .managerLead:
            updated.scopeMode = .allTasks
        case .custom:
            break
        }
        await savePreferences(updated)
    }

    public func refreshAppContacts() async {
        appContacts = await hooks.loadContacts()
        if assignableJiraUsers.isEmpty && !preferences.jira.cachedProjectUsers.isEmpty {
            assignableJiraUsers = preferences.jira.cachedProjectUsers
        }
    }

    public func jiraHostKey(for settings: JiraConnectionSettings? = nil) -> String {
        (settings ?? preferences.jira).normalizedBaseURL?.host?.lowercased() ?? "default"
    }

    public func saveJiraSecret(_ secret: String, kind: TaskIntegrationSecretKind, settings: JiraConnectionSettings? = nil) {
        let host = jiraHostKey(for: settings)
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            _ = keychain.delete(hostKey: host, kind: kind)
            if let writeSecret = hooks.writeSecret {
                _ = writeSecret("", host, kind)
            }
            return
        }
        if let writeSecret = hooks.writeSecret {
            _ = writeSecret(clean, host, kind)
        } else {
            _ = keychain.write(clean, hostKey: host, kind: kind)
        }
    }

    public func readJiraSecret(kind: TaskIntegrationSecretKind, settings: JiraConnectionSettings? = nil) -> String? {
        readJiraSecret(host: jiraHostKey(for: settings), kind: kind)
    }

    private func readJiraSecret(host: String, kind: TaskIntegrationSecretKind) -> String? {
        if let readSecret = hooks.readSecret {
            return readSecret(host, kind)
        }
        return keychain.read(hostKey: host, kind: kind)
    }

    public func hasJiraSecret(for settings: JiraConnectionSettings? = nil) -> Bool {
        let host = jiraHostKey(for: settings)
        let target = settings ?? preferences.jira
        switch target.authMode {
        case .personalAccessToken:
            return !(readJiraSecret(host: host, kind: .jiraPersonalAccessToken)?.isEmpty ?? true)
        case .webSession:
            return !(readJiraSecret(host: host, kind: .jiraSessionCookies)?.isEmpty ?? true)
        case .basicAuth:
            return !target.usernameOrEmail.isEmpty && !(readJiraSecret(host: host, kind: .jiraBasicSecret)?.isEmpty ?? true)
        }
    }

    public func testJiraConnectionAndRefreshContacts(using customSettings: JiraConnectionSettings? = nil) async -> Bool {
        let targetSettings = customSettings ?? preferences.jira
        isBusy = true
        errorMessage = nil
        statusMessage = L("Connecting to Jira…")
        defer { isBusy = false }

        let connector = hooks.makeJiraConnector(targetSettings, keychain)
        do {
            let me = try await connector.verifyMyself()
            currentJiraUser = me
            let projectKey = targetSettings.cleanProjectKey
            var details = L("Signed in as %@", me.displayName)
            if !projectKey.isEmpty {
                if let meta = try? await connector.fetchProjectMetadata(projectKey: projectKey) {
                    details += " · \(meta.key) (\(meta.name))"
                }
                let users = (try? await connector.fetchAssignableUsers(projectKey: projectKey, query: "")) ?? []
                assignableJiraUsers = users
            }
            let contacts = await hooks.loadContacts()
            appContacts = contacts
            if !assignableJiraUsers.isEmpty {
                let (merged, _) = JiraContactMatcher.reconcileMappings(
                    appContacts: contacts,
                    jiraUsers: assignableJiraUsers,
                    existing: preferences.contactMappings
                )
                var updated = preferences
                updated.contactMappings = merged
                if hooks.isMacPlatform {
                    updated.jira.cachedProjectUsers = Array(assignableJiraUsers.prefix(150))
                }
                await savePreferences(updated)
            }
            statusMessage = details
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func fetchWritableEventCalendars() async throws -> [WritableEventCalendarInfo] {
        try await hooks.makeCalendarConnector().requestAccessAndFetchCalendars()
    }

    public func fetchUpcomingCalendarEvents(daysAhead: Int = 21) async throws -> [UpcomingCalendarEventSummary] {
        try await hooks.makeCalendarConnector().fetchUpcomingEvents(daysAhead: daysAhead)
    }

    public func createTaskDiscussionCalendarEvent(
        _ draft: TaskCalendarEventDraft,
        forTaskID taskID: UUID
    ) async throws -> TaskLinkedDiscussionMeeting {
        let linked = try await hooks.makeCalendarConnector().createDiscussionEvent(draft, forTaskID: taskID)
        await hooks.onCalendarEventCreated()
        return linked
    }

    public func autoMatchContacts() async {
        appContacts = await hooks.loadContacts()
        if preferences.jira.enabled && assignableJiraUsers.isEmpty && hasJiraSecret() {
            let connector = hooks.makeJiraConnector(preferences.jira, keychain)
            if let users = try? await connector.fetchAssignableUsers(projectKey: preferences.jira.cleanProjectKey, query: "") {
                assignableJiraUsers = users
            }
        }
        let (merged, _) = JiraContactMatcher.reconcileMappings(
            appContacts: appContacts,
            jiraUsers: assignableJiraUsers,
            existing: preferences.contactMappings
        )
        var updated = preferences
        updated.contactMappings = merged
        await savePreferences(updated)
    }

    public func setManualContactMapping(appContact: AppContactPerson, jiraUser: JiraUserContact?) async {
        var updated = preferences
        updated.contactMappings.removeAll { $0.appContactKey == appContact.key }
        if let jiraUser {
            updated.contactMappings.append(ContactIdentityMapping(
                appContact: appContact,
                jiraUser: jiraUser,
                confirmed: true,
                confidence: 1.0
            ))
        }
        await savePreferences(updated)
    }

    public func refreshReminderLists() async {
        let connector = hooks.makeRemindersConnector()
        do {
            let lists = try await connector.fetchLists()
            reminderLists = lists
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func ensureDefaultReminderList(named title: String) async {
        let connector = hooks.makeRemindersConnector()
        do {
            let ensured = try await connector.ensureList(named: title, preferredID: preferences.reminders.listIdentifier)
            reminderLists = try await connector.fetchLists()
            var updated = preferences
            updated.reminders.listIdentifier = ensured.id
            updated.reminders.listTitle = ensured.title
            await savePreferences(updated)
            statusMessage = L("Reminders list ready: %@", ensured.title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs either interactive preview packet preparation or direct auto-apply depending on preferences (or explicit override).
    public func runSync(
        explicitTaskIDs: Set<UUID>? = nil,
        directionOverride: TaskSyncDirection? = nil,
        providerFilter: ExternalTaskProviderKind? = nil,
        automaticTrigger: Bool = false
    ) async {
        guard preferences.anyProviderEnabled else {
            if !automaticTrigger {
                errorMessage = L("Enable Jira or Apple Reminders in Task Sync settings first.")
            }
            return
        }
        isBusy = true
        errorMessage = nil
        statusMessage = L("Building sync packet…")
        defer { isBusy = false }

        do {
            let packet = try await buildSyncPacket(
                explicitTaskIDs: explicitTaskIDs,
                directionOverride: directionOverride,
                providerFilter: providerFilter
            )

            // On iPhone when import-only from Jira is requested while corporate Jira is routed via Mac:
            if !hooks.isMacPlatform,
               directionOverride == .importOnly,
               preferences.jira.enabled,
               (providerFilter == nil || providerFilter == .jira),
               packet.relayJiraViaMac {
                let jql = preferences.jira.importJQL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !jql.isEmpty {
                    let handover = MacJiraHandoverPacket(
                        originDeviceName: hooks.deviceName,
                        kind: .importFromJira,
                        status: .pendingMac,
                        approvedByUser: true,
                        operations: [],
                        importJQL: jql,
                        summaryMessage: L("Requested Jira import from %@", hooks.deviceName)
                    )
                    await hooks.saveHandoverPacket(handover)
                    refreshHandoverState()
                    if packet.operations.isEmpty {
                        statusMessage = L("Handed over Jira import request to your Mac.")
                        pendingPacket = nil
                        return
                    }
                }
            }

            if packet.operations.isEmpty {
                statusMessage = L("All tasks in scope are already up to date.")
                pendingPacket = nil
                return
            }

            if !packet.discoveredMappings.isEmpty && packet.discoveredMappings != preferences.contactMappings {
                var updated = preferences
                updated.contactMappings = packet.discoveredMappings
                await savePreferences(updated)
            }

            if preferences.approvalMode == .autoApply {
                statusMessage = L("Applying %ld sync updates…", packet.selectedCount)
                try await applyPacket(packet)
            } else {
                pendingPacket = packet
                statusMessage = nil
            }
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func buildSyncPacket(
        explicitTaskIDs: Set<UUID>? = nil,
        directionOverride: TaskSyncDirection? = nil,
        providerFilter: ExternalTaskProviderKind? = nil
    ) async throws -> TaskSyncPacket {
        let tasks = await hooks.loadTasks()
        let contacts = await hooks.loadContacts()
        appContacts = contacts
        let aliases = hooks.loadMyAliases()

        var jiraIssues: [JiraRemoteIssue] = []
        var jiraUsers: [JiraUserContact] = assignableJiraUsers.isEmpty
            ? preferences.jira.cachedProjectUsers
            : assignableJiraUsers
        var relayJiraViaMac = false
        var warnings: [String] = []

        if preferences.jira.enabled && (providerFilter == nil || providerFilter == .jira) {
            let canHandOver = !hooks.isMacPlatform && preferences.jira.executionRoute != .directOnly
            if !hooks.isMacPlatform && preferences.jira.executionRoute == .alwaysViaMac {
                relayJiraViaMac = true
                warnings.append(L("Corporate Jira route is set to Mac handover. Approved Jira operations will run on your Mac."))
            } else {
                let connector = hooks.makeJiraConnector(preferences.jira, keychain)
                let projectKey = preferences.jira.cleanProjectKey
                do {
                    if jiraUsers.isEmpty && !projectKey.isEmpty {
                        let fetchedUsers = try await connector.fetchAssignableUsers(projectKey: projectKey, query: "")
                        jiraUsers = fetchedUsers
                        assignableJiraUsers = fetchedUsers
                        if hooks.isMacPlatform && !fetchedUsers.isEmpty && fetchedUsers != preferences.jira.cachedProjectUsers {
                            var updated = preferences
                            updated.jira.cachedProjectUsers = Array(fetchedUsers.prefix(150))
                            await savePreferences(updated)
                        }
                    }
                    let jql = preferences.jira.importJQL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !jql.isEmpty {
                        jiraIssues = try await connector.searchIssues(jql: jql, maxResults: 100)
                    }
                } catch {
                    if canHandOver && MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                        relayJiraViaMac = true
                        warnings.append(L("Jira is unreachable from iPhone (%@). Approved changes will be handed over to your Mac.", error.localizedDescription))
                    } else {
                        throw error
                    }
                }
            }
        }

        var reminders: [ReminderItemSnapshot] = []
        if preferences.reminders.enabled && (providerFilter == nil || providerFilter == .appleReminders) {
            let connector = hooks.makeRemindersConnector()
            reminders = try await connector.fetchReminders(
                inListID: preferences.reminders.listIdentifier,
                includeCompleted: !preferences.reminders.importIncompleteReminders
            )
        }

        var packet = TaskSyncPlanner.buildPacket(
            localTasks: tasks,
            jiraIssues: jiraIssues,
            jiraUsers: jiraUsers,
            reminders: reminders,
            preferences: preferences,
            myAliases: aliases,
            explicitTaskIDs: explicitTaskIDs,
            directionOverride: directionOverride,
            providerFilter: providerFilter
        )
        packet.relayJiraViaMac = relayJiraViaMac
        if !warnings.isEmpty {
            packet.warnings = warnings + packet.warnings
        }
        return packet
    }

    public func applyPacket(_ packet: TaskSyncPacket) async throws {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let tasks = await hooks.loadTasks()
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        let selectedJiraOps = packet.operations.filter { $0.isSelected && $0.provider == .jira }
        let reminderOnlyPacket = TaskSyncPacket(
            id: packet.id,
            createdAt: packet.createdAt,
            operations: packet.operations.filter { $0.provider != .jira },
            assignableJiraUsers: packet.assignableJiraUsers,
            warnings: packet.warnings,
            discoveredMappings: packet.discoveredMappings
        )

        var handoverJiraInsteadOfDirect = !hooks.isMacPlatform && !selectedJiraOps.isEmpty && (
            packet.relayJiraViaMac || preferences.jira.executionRoute == .alwaysViaMac
        )

        if !handoverJiraInsteadOfDirect,
           !hooks.isMacPlatform,
           !selectedJiraOps.isEmpty,
           preferences.jira.executionRoute == .directWithMacFallback {
            if !hasJiraSecret() {
                handoverJiraInsteadOfDirect = true
            } else {
                do {
                    _ = try await hooks.makeJiraConnector(preferences.jira, keychain).verifyMyself()
                } catch where MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                    handoverJiraInsteadOfDirect = true
                }
            }
        }

        var handedOverCount = 0
        if handoverJiraInsteadOfDirect && !selectedJiraOps.isEmpty {
            let handover = MacJiraHandoverPacket(
                originDeviceName: hooks.deviceName,
                kind: .applyOperations,
                status: .pendingMac,
                approvedByUser: true,
                operations: selectedJiraOps,
                importJQL: nil,
                summaryMessage: L("%ld Jira changes queued from %@", selectedJiraOps.count, hooks.deviceName)
            )
            await hooks.saveHandoverPacket(handover)
            refreshHandoverState()
            handedOverCount = selectedJiraOps.count
        }

        let effectivePacket = handedOverCount > 0 ? reminderOnlyPacket : packet
        let jira = (handedOverCount == 0 && preferences.jira.enabled) ? hooks.makeJiraConnector(preferences.jira, keychain) : nil
        let reminders = preferences.reminders.enabled ? hooks.makeRemindersConnector() : nil

        let (mutations, report) = await TaskSyncExecutor.execute(
            packet: effectivePacket,
            localTasksByID: tasksByID,
            preferences: preferences,
            jira: jira,
            reminders: reminders
        )
        if !mutations.isEmpty {
            try await hooks.applyMutations(mutations)
        }
        lastReport = report
        pendingPacket = nil

        if !report.failedMessages.isEmpty {
            errorMessage = report.failedMessages.joined(separator: "\n")
        }
        if handedOverCount > 0 && report.appliedCount > 0 {
            statusMessage = L("Applied %ld Reminders updates; handed over %ld Jira actions to Mac.", report.appliedCount, handedOverCount)
        } else if handedOverCount > 0 {
            statusMessage = L("Handed over %ld Jira actions to your Mac via iCloud.", handedOverCount)
        } else {
            statusMessage = L(
                "Synced %ld items (%ld created, %ld updated, %ld imported).",
                report.appliedCount, report.createdCount, report.updatedCount, report.importedCount
            )
        }
    }

    /// Runs on Mac when pending handover packets arrive from iPhone via iCloud Workspace Sync.
    public func processPendingHandoversFromIOS() async {
        guard hooks.isMacPlatform, !isProcessingHandovers else { return }
        refreshHandoverState()
        let pending = pendingMacHandovers
        guard !pending.isEmpty else { return }

        guard preferences.jira.enabled else {
            statusMessage = L("%ld Jira sync packets from iPhone waiting (enable Jira on Mac).", pending.count)
            return
        }
        guard hasJiraSecret() else {
            statusMessage = L("%ld Jira sync packets from iPhone waiting for Jira sign-in on Mac.", pending.count)
            return
        }

        isProcessingHandovers = true
        isBusy = true
        defer {
            isProcessingHandovers = false
            isBusy = false
            refreshHandoverState()
        }

        let connector = hooks.makeJiraConnector(preferences.jira, keychain)
        do {
            _ = try await connector.verifyMyself()
        } catch {
            if MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                for var item in pending {
                    item.updatedAt = Date()
                    item.lastErrorMessage = L("Waiting for corporate Jira reachability on Mac (%@)", error.localizedDescription)
                    await hooks.saveHandoverPacket(item)
                }
                statusMessage = L("Waiting for corporate Jira / VPN on Mac (%ld pending from iPhone).", pending.count)
            } else {
                errorMessage = error.localizedDescription
            }
            return
        }

        let localTasks = await hooks.loadTasks()
        var tasksByID = Dictionary(uniqueKeysWithValues: localTasks.map { ($0.id, $0) })

        for var handover in pending {
            do {
                if handover.kind == .importFromJira {
                    let jql = (handover.importJQL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        ? handover.importJQL!
                        : preferences.jira.importJQL
                    let issues = try await connector.searchIssues(jql: jql, maxResults: 100)
                    let packet = TaskSyncPlanner.buildPacket(
                        localTasks: localTasks,
                        jiraIssues: issues,
                        jiraUsers: assignableJiraUsers,
                        reminders: [],
                        preferences: preferences,
                        myAliases: hooks.loadMyAliases(),
                        directionOverride: .importOnly,
                        providerFilter: .jira
                    )
                    if handover.approvedByUser || preferences.approvalMode == .autoApply {
                        let (mutations, report) = await TaskSyncExecutor.execute(
                            packet: packet,
                            localTasksByID: tasksByID,
                            preferences: preferences,
                            jira: connector,
                            reminders: nil
                        )
                        if !mutations.isEmpty {
                            try await hooks.applyMutations(mutations)
                        }
                        handover.status = report.failedMessages.isEmpty ? .completedOnMac : .failedOnMac
                        handover.updatedAt = Date()
                        handover.summaryMessage = L("Imported %ld Jira issues on Mac.", report.importedCount + report.updatedCount)
                        handover.lastErrorMessage = report.failedMessages.isEmpty ? nil : report.failedMessages.joined(separator: "; ")
                    } else {
                        pendingPacket = packet
                        handover.status = .completedOnMac
                        handover.updatedAt = Date()
                        handover.summaryMessage = L("Prepared %ld Jira updates for review on Mac.", packet.operations.count)
                    }
                    await hooks.saveHandoverPacket(handover)
                } else {
                    if !handover.approvedByUser && preferences.approvalMode == .reviewBeforeApply {
                        pendingPacket = TaskSyncPacket(operations: handover.operations, assignableJiraUsers: assignableJiraUsers)
                        handover.status = .completedOnMac
                        handover.updatedAt = Date()
                        handover.summaryMessage = L("Opened %ld operations for review on Mac.", handover.operations.count)
                        await hooks.saveHandoverPacket(handover)
                        continue
                    }

                    var resolvedOps: [TaskSyncOperation] = []
                    for var op in handover.operations {
                        if let lid = op.localTaskID, tasksByID[lid] == nil {
                            tasksByID[lid] = WorkspaceTaskRecord(
                                id: lid,
                                sessionID: TaskExtendedMetadata.externalImportsSessionID,
                                outcomeID: TaskExtendedMetadata.externalImportsOutcomeID,
                                meetingTitle: L("Synced from %@", handover.originDeviceName),
                                text: op.title,
                                owner: op.ownerDisplay,
                                dueDay: op.dueDay,
                                dueAt: op.dueAt,
                                done: op.targetWorkflowStatus.isTerminalDone,
                                extended: TaskExtendedMetadata(
                                    workflowStatus: op.targetWorkflowStatus,
                                    priority: op.priority,
                                    issueKind: op.issueKind,
                                    parentEpicKey: op.parentEpicKey
                                )
                            )
                        }
                        // Prevent duplicate Jira issue creation if the text already references a remote key.
                        if op.kind == .createExternal,
                           let explicitKey = CrossMeetingTaskReconciler.extractIssueKeys(from: op.title).first {
                            let existingIssue: JiraRemoteIssue?
                            if let fullConnector = connector as? JiraTaskConnector {
                                existingIssue = try? await fullConnector.fetchIssue(key: explicitKey)
                            } else {
                                existingIssue = (try? await connector.searchIssues(jql: "key = \(explicitKey)", maxResults: 1))?.first
                            }
                            if let existingIssue {
                                op.kind = .linkExistingExternal
                                op.externalID = existingIssue.id
                                op.externalKey = existingIssue.key
                                op.remoteIssueSnapshot = existingIssue
                            }
                        }
                        resolvedOps.append(op)
                    }

                    let execPacket = TaskSyncPacket(operations: resolvedOps, assignableJiraUsers: assignableJiraUsers)
                    let (mutations, report) = await TaskSyncExecutor.execute(
                        packet: execPacket,
                        localTasksByID: tasksByID,
                        preferences: preferences,
                        jira: connector,
                        reminders: nil
                    )
                    let annotatedMutations = mutations.map { mutation -> TaskSyncLocalMutation in
                        var copy = mutation
                        copy.historyEntry.note += " (\(L("via Mac handover")))"
                        return copy
                    }
                    if !annotatedMutations.isEmpty {
                        try await hooks.applyMutations(annotatedMutations)
                    }
                    handover.status = report.failedMessages.isEmpty ? .completedOnMac : .failedOnMac
                    handover.updatedAt = Date()
                    handover.summaryMessage = L(
                        "Synced %ld Jira items via Mac (%ld created, %ld updated).",
                        report.appliedCount, report.createdCount, report.updatedCount
                    )
                    handover.lastErrorMessage = report.failedMessages.isEmpty ? nil : report.failedMessages.joined(separator: "; ")
                    await hooks.saveHandoverPacket(handover)
                }
            } catch {
                if MacJiraHandoverPacket.shouldHandOverJiraError(error) {
                    handover.updatedAt = Date()
                    handover.lastErrorMessage = L("Waiting for corporate Jira on Mac: %@", error.localizedDescription)
                } else {
                    handover.status = .failedOnMac
                    handover.updatedAt = Date()
                    handover.lastErrorMessage = error.localizedDescription
                }
                await hooks.saveHandoverPacket(handover)
            }
        }
        statusMessage = L("Processed %ld Jira handover(s) from iPhone.", pending.count)
    }

    // MARK: - Direct Assistant Jira Queries, User Search & Comments

    public enum JiraAssigneeResolution: Equatable, Sendable {
        case resolved(jqlIdentifier: String, person: AssistantPersonEntry?)
        case unresolved(query: String, candidates: [JiraUserContact])
    }

    nonisolated public static func extractLiteralAssigneeFromJQL(_ jql: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\bassignee\s*(?:=|!=)\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let nsRange = NSRange(jql.startIndex..<jql.endIndex, in: jql)
        guard let match = regex.firstMatch(in: jql, range: nsRange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: jql) else {
            return nil
        }
        let literal = String(jql[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !literal.isEmpty, literal.lowercased() != "currentuser()" else { return nil }
        return literal
    }

    nonisolated public static func escapedJQLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated public static func injectAssignee(_ assigneeIdentifier: String, intoJQL jql: String) -> String {
        let escaped = escapedJQLString(assigneeIdentifier)
        let clause = "assignee = \"\(escaped)\""
        let trimmed = jql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\(clause) ORDER BY updated DESC" }
        if let orderRange = trimmed.range(of: #"\bORDER\s+BY\b"#, options: [.regularExpression, .caseInsensitive]) {
            let filterPart = String(trimmed[..<orderRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let orderPart = String(trimmed[orderRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if filterPart.isEmpty {
                return "\(clause) \(orderPart)"
            }
            return "(\(filterPart)) AND \(clause) \(orderPart)"
        }
        return "(\(trimmed)) AND \(clause)"
    }

    nonisolated public static func replacingLiteralAssignee(in jql: String, with assigneeIdentifier: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\bassignee\s*(?:=|!=)\s*)["'][^"']+["']"#,
            options: [.caseInsensitive]
        ) else {
            return jql
        }
        let escaped = NSRegularExpression.escapedTemplate(for: escapedJQLString(assigneeIdentifier))
        let range = NSRange(jql.startIndex..<jql.endIndex, in: jql)
        return regex.stringByReplacingMatches(in: jql, range: range, withTemplate: "$1\"\(escaped)\"")
    }

    nonisolated public static func jiraUserPayload(_ user: JiraUserContact) -> [String: Any] {
        [
            "identifier": user.identifier,
            "username": user.username ?? "",
            "account_id": user.accountId ?? "",
            "display_name": user.displayName,
            "email": user.emailAddress ?? "",
            "is_server_or_dc": user.isServerOrDC,
        ]
    }

    nonisolated public static func jiraIssuePayload(_ issue: JiraRemoteIssue) -> [String: Any] {
        [
            "key": issue.key,
            "summary": issue.summary,
            "status": issue.statusName,
            "issue_type": issue.issueTypeName,
            "assignee": issue.assigneeName ?? "",
            "assignee_id": issue.assigneeIdentifier ?? "",
            "browse_url": issue.browseURL ?? "",
        ]
    }

    nonisolated public static func unresolvedJiraAssigneePayload(
        query: String,
        candidates: [JiraUserContact]
    ) -> [String: Any] {
        [
            "needs_user_confirmation": true,
            "unmapped_meeting_user": query,
            "jira_user_candidates": candidates.map(jiraUserPayload),
            "instruction": "Ask the participant whether one of these Jira users matches their meeting name, or ask for their Jira username/email. Once confirmed, call rocknroll_manage_people(operation='upsert', display_name=..., aliases=[meeting_display_name], jira_username=..., jira_account_id=..., email=...) and retry the Jira query."
        ]
    }

    public func activeJiraConnector() throws -> any JiraTaskConnecting {
        if let testConnector = jiraConnectorForTesting {
            return testConnector
        }
        if let evaluator = boardWebEvaluator,
           let boardURL = evaluator.currentBoardURL,
           let info = JiraBoardContextInfo.parse(from: boardURL),
           (boardJiraSessionActive || info.looksLikeJiraURL) {
            if !preferences.jira.enabled
                || preferences.jira.normalizedBaseURL == nil
                || !hasJiraSecret()
                || (preferences.jira.authMode == .webSession
                    && preferences.jira.normalizedBaseURL?.host?.lowercased() == info.baseURL.host?.lowercased()) {
                return JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
            }
        }
        if preferences.jira.enabled && preferences.jira.normalizedBaseURL != nil {
            if hasJiraSecret() {
                return hooks.makeJiraConnector(preferences.jira, keychain)
            }
            if let evaluator = boardWebEvaluator, evaluator.currentBoardURL != nil {
                return JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
            }
            return hooks.makeJiraConnector(preferences.jira, keychain)
        }
        if let evaluator = boardWebEvaluator, evaluator.currentBoardURL != nil {
            return JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
        }
        throw JiraConnectorError.badRequest(L("Sign in to Jira on the Assistant Board or in Tasks → Sync Settings first."))
    }

    public func adoptJiraSessionFromBoardIfAvailable(_ evaluator: any JiraBoardWebEvaluating) async {
        boardWebEvaluator = evaluator
        guard let url = evaluator.currentBoardURL,
              let info = JiraBoardContextInfo.parse(from: url),
              info.looksLikeJiraURL else {
            boardJiraSessionActive = false
            return
        }

        let webConnector = JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
        let derivedFromBoard = await resolveBoardDerivedProjectKeys(forceRefresh: true)
        guard let me = try? await webConnector.verifyMyself() else {
            boardJiraSessionActive = false
            return
        }
        boardJiraSessionActive = true
        currentJiraUser = me

        var adoptSettings = preferences.jira
        adoptSettings.baseURL = info.baseURL.absoluteString
        let cookies = await evaluator.cookiesForBoard(matching: info.baseURL)
        let cookieHeader = cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if !cookieHeader.isEmpty {
            saveJiraSecret(cookieHeader, kind: .jiraSessionCookies, settings: adoptSettings)
        }

        let effectiveBoardProject = (info.projectKey?.cleanedNilIfEmpty) ?? derivedFromBoard.first
        let sameHost = preferences.jira.normalizedBaseURL?.host?.lowercased() == info.baseURL.host?.lowercased()
        if !preferences.jira.enabled || preferences.jira.normalizedBaseURL == nil {
            var updated = preferences
            updated.jira.enabled = true
            updated.jira.baseURL = info.baseURL.absoluteString
            updated.jira.authMode = .webSession
            if updated.jira.cleanProjectKey.isEmpty, let proj = effectiveBoardProject, !proj.isEmpty {
                updated.jira.projectKey = proj
            }
            if updated.jira.usernameOrEmail.isEmpty,
               let hint = (me.emailAddress?.cleanedNilIfEmpty ?? me.username?.cleanedNilIfEmpty) {
                updated.jira.usernameOrEmail = hint
            }
            await savePreferences(updated)
        } else if sameHost,
                  preferences.jira.cleanProjectKey.isEmpty,
                  let proj = effectiveBoardProject,
                  !proj.isEmpty {
            var updated = preferences
            updated.jira.projectKey = proj
            await savePreferences(updated)
        }

        if assignableJiraUsers.isEmpty,
           let boardIssues = try? await webConnector.fetchActiveBoardIssues(maxResults: 40) {
            var usersByID: [String: JiraUserContact] = [me.identifier.lowercased(): me]
            for issue in boardIssues {
                if let assignee = issue.assigneeContact {
                    usersByID[assignee.identifier.lowercased()] = assignee
                }
                if let reporter = issue.reporterContact {
                    usersByID[reporter.identifier.lowercased()] = reporter
                }
            }
            let collected = Array(usersByID.values)
            if !collected.isEmpty {
                assignableJiraUsers = collected
            }
        }
    }

    public func searchJiraUsers(
        query: String,
        projectKey: String? = nil,
        maxResults: Int = 15
    ) async throws -> [JiraUserContact] {
        let connector = try activeJiraConnector()
        let project = projectKey?.cleanedNilIfEmpty ?? preferences.jira.cleanProjectKey.cleanedNilIfEmpty
        var collected = (try? await connector.searchUsers(query: query, projectKey: project, maxResults: maxResults)) ?? []

        // Augment with active board assignees/reporters and current user so corporate DC/Cloud instances
        // that restrict /user/search still return teammates visible on the open board.
        var boardIssues: [JiraRemoteIssue] = []
        if let webConnector = connector as? JiraBoardWebSessionConnector {
            boardIssues = (try? await webConnector.fetchActiveBoardIssues(maxResults: 60)) ?? []
        } else if let evaluator = boardWebEvaluator, evaluator.currentBoardURL != nil {
            let webConnector = JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
            boardIssues = (try? await webConnector.fetchActiveBoardIssues(maxResults: 60)) ?? []
        }

        if !boardIssues.isEmpty {
            var extras: [JiraUserContact] = []
            if let me = currentJiraUser { extras.append(me) }
            for issue in boardIssues {
                if let assignee = issue.assigneeContact { extras.append(assignee) }
                if let reporter = issue.reporterContact { extras.append(reporter) }
            }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = AssistantPeopleDirectory.strippedMeetingDisplayName(needle)
            let searchNeedle = stripped.isEmpty ? needle : stripped
            let matchedExtras = extras.filter { user in
                guard !searchNeedle.isEmpty else { return true }
                return JiraContactMatcher.matchScore(
                    name: searchNeedle,
                    candidateNames: [user.displayName, user.username ?? "", user.identifier],
                    candidateEmail: user.emailAddress,
                    candidateUsername: user.username
                ) >= 0.45
            }
            var seen = Set(collected.map { $0.identifier.lowercased() })
            for user in matchedExtras where seen.insert(user.identifier.lowercased()).inserted {
                collected.append(user)
            }
        }

        if collected.isEmpty,
           let direct = try? await connector.searchUsers(query: query, projectKey: project, maxResults: maxResults) {
            collected = direct
        }
        return Array(collected.prefix(max(1, maxResults)))
    }

    public func resolveJiraAssignee(
        _ rawAssignee: String,
        people: AssistantPeopleDirectory,
        defaultProjectKey: String = ""
    ) async -> JiraAssigneeResolution {
        let clean = rawAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = AssistantPeopleDirectory.strippedMeetingDisplayName(clean)
        let query = stripped.isEmpty ? clean : stripped
        guard !query.isEmpty else {
            return .unresolved(query: rawAssignee, candidates: [])
        }
        if clean.lowercased() == "currentuser()" {
            return .resolved(jqlIdentifier: clean, person: nil)
        }

        if let person = people.resolvePerson(matching: clean) ?? people.resolvePerson(matching: query) {
            let handle = preferences.jira.isCloudHost
                ? (person.jiraAccountID?.cleanedNilIfEmpty ?? person.jiraUsername?.cleanedNilIfEmpty)
                : (person.jiraUsername?.cleanedNilIfEmpty ?? person.jiraAccountID?.cleanedNilIfEmpty)
            if let handle {
                return .resolved(jqlIdentifier: handle, person: person)
            }
        }

        let needle = query.hasPrefix("@") ? String(query.dropFirst()) : query
        for mapping in preferences.contactMappings where mapping.isConfirmedByUser {
            let score = JiraContactMatcher.matchScore(
                name: needle,
                candidateNames: [
                    mapping.appDisplayName,
                    mapping.jiraDisplayName,
                    mapping.jiraUsername ?? "",
                    mapping.jiraIdentifier
                ],
                candidateEmail: mapping.jiraEmail,
                candidateUsername: mapping.jiraUsername
            )
            if score >= 0.85 {
                let handle = preferences.jira.isCloudHost
                    ? (mapping.jiraAccountId?.cleanedNilIfEmpty ?? mapping.jiraIdentifier)
                    : (mapping.jiraUsername?.cleanedNilIfEmpty ?? mapping.jiraIdentifier)
                return .resolved(jqlIdentifier: handle, person: nil)
            }
        }

        let project = defaultProjectKey.cleanedNilIfEmpty ?? preferences.jira.cleanProjectKey.cleanedNilIfEmpty
        var liveCandidates: [JiraUserContact] = []
        if (try? activeJiraConnector()) != nil {
            liveCandidates = (try? await searchJiraUsers(query: query, projectKey: project, maxResults: 8)) ?? []
        }

        if liveCandidates.isEmpty {
            let cached = assignableJiraUsers.isEmpty ? preferences.jira.cachedProjectUsers : assignableJiraUsers
            liveCandidates = cached
                .map { user -> (JiraUserContact, Double) in
                    let score = JiraContactMatcher.matchScore(
                        name: needle,
                        candidateNames: [user.displayName, user.username ?? "", user.identifier],
                        candidateEmail: user.emailAddress,
                        candidateUsername: user.username
                    )
                    return (user, score)
                }
                .filter { $0.1 >= 0.50 }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }

        if let exact = liveCandidates.first(where: {
            $0.identifier.caseInsensitiveCompare(needle) == .orderedSame
                || ($0.username?.caseInsensitiveCompare(needle) == .orderedSame)
                || ($0.accountId?.caseInsensitiveCompare(needle) == .orderedSame)
        }) {
            return .resolved(jqlIdentifier: exact.identifier, person: nil)
        }

        return .unresolved(query: clean, candidates: Array(liveCandidates.prefix(8)))
    }

    public func searchJiraIssues(jql: String, maxResults: Int = 20) async throws -> [JiraRemoteIssue] {
        let connector = try activeJiraConnector()
        return try await connector.searchIssues(jql: jql, maxResults: maxResults)
    }

    public func commentOnJiraIssue(key: String, comment: String) async throws {
        let connector = try activeJiraConnector()
        try await connector.addIssueComment(key: key, comment: comment)
        await boardWebEvaluator?.refreshBoardAfterJiraMutation(highlightIssueKey: key)
    }

    public func fetchBoardUsersAndIssues(maxResults: Int = 50) async throws -> (users: [JiraUserContact], issues: [JiraRemoteIssue]) {
        let connector = try activeJiraConnector()
        let issues: [JiraRemoteIssue]
        if let webConnector = connector as? JiraBoardWebSessionConnector {
            issues = try await webConnector.fetchActiveBoardIssues(maxResults: maxResults)
        } else if let evaluator = boardWebEvaluator, evaluator.currentBoardURL != nil {
            let webConnector = JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
            issues = try await webConnector.fetchActiveBoardIssues(maxResults: maxResults)
        } else {
            let project = preferences.jira.cleanProjectKey
            let jql = project.isEmpty
                ? "updated >= -30d ORDER BY updated DESC"
                : "project = \"\(Self.escapedJQLString(project))\" ORDER BY updated DESC"
            issues = try await connector.searchIssues(jql: jql, maxResults: maxResults)
        }

        var usersByID: [String: JiraUserContact] = [:]
        var orderedIDs: [String] = []
        func appendUser(_ user: JiraUserContact?) {
            guard let user else { return }
            let key = user.identifier.lowercased()
            if usersByID[key] == nil {
                orderedIDs.append(key)
            }
            usersByID[key] = user
        }
        appendUser(currentJiraUser)
        for issue in issues {
            appendUser(issue.assigneeContact)
            appendUser(issue.reporterContact)
        }
        return (orderedIDs.compactMap { usersByID[$0] }, issues)
    }

    public func copyJiraUserFromIssue(
        issueKey: String? = nil,
        searchQuery: String? = nil,
        role: String = "assignee"
    ) async throws -> (user: JiraUserContact, issueKey: String) {
        let connector = try activeJiraConnector()
        let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let resolvedIssue: JiraRemoteIssue
        if let rawKey = issueKey?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty {
            resolvedIssue = try await connector.fetchIssueDetails(key: rawKey)
        } else {
            let (_, boardIssues) = try await fetchBoardUsersAndIssues(maxResults: 60)
            let needle = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !needle.isEmpty,
               let boardMatch = boardIssues.first(where: { issue in
                   issue.key.localizedCaseInsensitiveContains(needle)
                       || issue.summary.localizedCaseInsensitiveContains(needle)
                       || (issue.assigneeName?.localizedCaseInsensitiveContains(needle) == true)
               }) {
                resolvedIssue = try await connector.fetchIssueDetails(key: boardMatch.key)
            } else if !needle.isEmpty {
                let escaped = Self.escapedJQLString(needle)
                let searched = try await connector.searchIssues(
                    jql: "text ~ \"\(escaped)\" ORDER BY updated DESC",
                    maxResults: 10
                )
                guard let first = searched.first else {
                    throw JiraConnectorError.notFound(L("No Jira issue matched %@.", needle))
                }
                resolvedIssue = try await connector.fetchIssueDetails(key: first.key)
            } else {
                let resolvedMe: JiraUserContact?
                if let current = currentJiraUser {
                    resolvedMe = current
                } else {
                    resolvedMe = try? await connector.verifyMyself()
                }
                if let me = resolvedMe,
                   let mineOnBoard = boardIssues.first(where: { issue in
                       guard let assignee = issue.assigneeContact else { return false }
                       return assignee.identifier.caseInsensitiveCompare(me.identifier) == .orderedSame
                           || (assignee.username != nil && assignee.username == me.username)
                   }) {
                    resolvedIssue = try await connector.fetchIssueDetails(key: mineOnBoard.key)
                } else if let firstBoardIssue = boardIssues.first(where: { $0.assigneeContact != nil }) {
                    resolvedIssue = try await connector.fetchIssueDetails(key: firstBoardIssue.key)
                } else {
                    throw JiraConnectorError.badRequest(L("Specify a Jira issue key or search text to copy a user from."))
                }
            }
        }

        let picked = cleanRole == "reporter"
            ? (resolvedIssue.reporterContact ?? resolvedIssue.assigneeContact)
            : (resolvedIssue.assigneeContact ?? resolvedIssue.reporterContact)
        guard var user = picked else {
            throw JiraConnectorError.badRequest(L("Issue %@ has no assignee or reporter set.", resolvedIssue.key))
        }
        if user.emailAddress == nil || (user.accountId == nil && user.username == nil),
           let enriched = (try? await connector.searchUsers(query: user.identifier, projectKey: nil, maxResults: 3))?.first(where: {
               $0.identifier.caseInsensitiveCompare(user.identifier) == .orderedSame
                   || ($0.username != nil && $0.username == user.username)
                   || ($0.accountId != nil && $0.accountId == user.accountId)
           }) {
            user = enriched
        }
        return (user, resolvedIssue.key)
    }

    public func transitionJiraIssue(
        key: String,
        targetStatus: String,
        comment: String? = nil
    ) async throws -> JiraRemoteIssue {
        let connector = try activeJiraConnector()
        let updated = try await connector.transitionIssue(key: key, targetStatusText: targetStatus, comment: comment)
        await boardWebEvaluator?.refreshBoardAfterJiraMutation(highlightIssueKey: updated.key)
        return updated
    }

    public func assignJiraIssue(
        key: String,
        assignee: JiraUserContact?
    ) async throws -> JiraRemoteIssue {
        let connector = try activeJiraConnector()
        let updated = try await connector.assignIssue(key: key, assignee: assignee)
        await boardWebEvaluator?.refreshBoardAfterJiraMutation(highlightIssueKey: updated.key)
        return updated
    }

    public func resolveBoardDerivedProjectKeys(forceRefresh: Bool = false) async -> [String] {
        guard let evaluator = boardWebEvaluator, let url = evaluator.currentBoardURL else {
            return derivedBoardProjectKeys
        }
        let cacheKey = url.absoluteString
        let previousURL = derivedBoardCacheURL
        if !forceRefresh, previousURL == cacheKey, !derivedBoardProjectKeys.isEmpty {
            return derivedBoardProjectKeys
        }
        let webConnector = JiraBoardWebSessionConnector(evaluator: evaluator, fallbackSettings: preferences.jira)
        let keys = await webConnector.deriveBoardProjectKeys()
        if !keys.isEmpty {
            derivedBoardCacheURL = cacheKey
            derivedBoardProjectKeys = keys
        } else if previousURL != cacheKey {
            derivedBoardCacheURL = nil
            derivedBoardProjectKeys = []
        }
        return derivedBoardProjectKeys
    }

    /// Resolves effective Jira project keys prioritizing an explicit per-meeting override over board-derived keys,
    /// then falling back to configured/global defaults.
    nonisolated public static func resolvedEffectiveJiraProjectKeys(
        configured: [String],
        globalFallback: [String],
        boardDerived: [String]
    ) -> [String] {
        let cleanConfigured = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: configured)
        let cleanGlobal = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: globalFallback)
        let cleanBoard = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: boardDerived)
        let hasPerMeetingOverride = !cleanConfigured.isEmpty && cleanConfigured != cleanGlobal
        if hasPerMeetingOverride {
            return cleanConfigured
        }
        if !cleanBoard.isEmpty {
            return cleanBoard + cleanConfigured.filter { !cleanBoard.contains($0) }
        }
        return cleanConfigured
    }

    public func createJiraIssueDirect(
        summary: String,
        description: String = "",
        projectKey: String? = nil,
        issueKind: TaskIssueKind = .task,
        assignee: JiraUserContact? = nil,
        priority: TaskPriorityLevel? = nil,
        parentEpicKey: String? = nil
    ) async throws -> JiraRemoteIssue {
        let connector = try activeJiraConnector()
        let boardContextProject: String? = {
            guard let url = boardWebEvaluator?.currentBoardURL else { return nil }
            return JiraBoardContextInfo.parse(from: url)?.projectKey
        }()
        let explicitKey = projectKey?.cleanedNilIfEmpty
        let configuredKey = preferences.jira.cleanProjectKey.cleanedNilIfEmpty
        var derivedProject: String? = boardContextProject
        if explicitKey == nil && configuredKey == nil && derivedProject == nil {
            derivedProject = await resolveBoardDerivedProjectKeys().first
        }
        let resolvedProject = explicitKey
            ?? configuredKey
            ?? derivedProject
        guard let resolvedProject, !resolvedProject.isEmpty else {
            throw JiraConnectorError.badRequest(L("Jira project key is required."))
        }
        let payload = JiraIssueWritePayload(
            projectKey: resolvedProject,
            issueType: preferences.jira.defaultIssueType.cleanedNilIfEmpty ?? "Task",
            issueKind: issueKind,
            parentEpicKey: parentEpicKey,
            summary: summary,
            description: description,
            priority: priority,
            assignee: assignee
        )
        let created = try await connector.createIssue(payload)
        await boardWebEvaluator?.refreshBoardAfterJiraMutation(highlightIssueKey: created.key)
        return created
    }

    /// Resolves spoken or ASR-garbled project keys (e.g. "Sdp ситио", "SDB CTO") against known candidates.
    nonisolated public static func resolveSpokenProjectKey(_ raw: String, candidates: [String]) -> String? {
        let cleanCandidates = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: candidates)
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let direct = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: rawTrimmed)
        if let exact = direct.first(where: { cleanCandidates.contains($0) }) {
            return exact
        }
        let stripped = rawTrimmed
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        let filler: Set<String> = ["ключ", "проект", "проекта", "джира", "жира", "jira", "project", "key", "задача", "в", "на"]
        let words = stripped
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
        guard !words.isEmpty else { return nil }
        let joinedDirect = words.joined().uppercased()
        if let exact = cleanCandidates.first(where: { $0 == joinedDirect }) {
            return exact
        }

        func explicitASCIIKeyIfValid() -> String? {
            guard !rawTrimmed.isEmpty,
                  rawTrimmed.unicodeScalars.allSatisfy(\.isASCII),
                  direct.count == 1 else {
                return nil
            }
            let explicit = direct[0]
            guard explicit.range(of: #"^[A-Z][A-Z0-9_]{1,}$"#, options: .regularExpression) != nil else {
                return nil
            }
            if words.count == 1 || rawTrimmed.contains("://") || rawTrimmed.contains("-") {
                return explicit
            }
            return nil
        }

        guard !cleanCandidates.isEmpty else {
            return explicitASCIIKeyIfValid()
        }

        func spokenToLatin(_ token: String) -> String {
            var s = token
            let multiMap: [(String, String)] = [
                ("ситио", "cto"), ("сити", "ct"), ("джи", "j"), ("эйч", "h"),
                ("сдб", "sdb"), ("спс", "sps"), ("кти", "ct"),
                ("ш", "sh"), ("щ", "sh"), ("ч", "ch"), ("ж", "zh"), ("ю", "yu"), ("я", "ya")
            ]
            for (pat, rep) in multiMap {
                s = s.replacingOccurrences(of: pat, with: rep)
            }
            let charMap: [Character: String] = [
                "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "з": "z",
                "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
                "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h",
                "ц": "c"
            ]
            var out = ""
            for ch in s {
                if let mapped = charMap[ch] {
                    out += mapped
                } else if ch.isASCII && ch.isLetter || ch.isNumber {
                    out.append(ch)
                }
            }
            return out.uppercased()
        }

        let phoneticForms: [String] = [
            words.map(spokenToLatin).joined(),
            spokenToLatin(words.joined())
        ].filter { !$0.isEmpty }

        func similarity(_ a: String, _ b: String) -> Double {
            let ca = Array(a), cb = Array(b)
            if ca.isEmpty || cb.isEmpty { return 0 }
            if a == b { return 1.0 }
            var dp = Array(repeating: Array(repeating: 0, count: cb.count + 1), count: ca.count + 1)
            for i in 0...ca.count { dp[i][0] = i }
            for j in 0...cb.count { dp[0][j] = j }
            for i in 1...ca.count {
                for j in 1...cb.count {
                    let cost = ca[i - 1] == cb[j - 1] ? 0 : 1
                    dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
                }
            }
            let dist = dp[ca.count][cb.count]
            let maxLen = max(ca.count, cb.count)
            return max(0.0, 1.0 - Double(dist) / Double(maxLen))
        }

        var best: (key: String, score: Double)?
        for cand in cleanCandidates {
            let score = phoneticForms.map { similarity($0, cand) }.max() ?? 0
            if best == nil || score > best!.score {
                best = (cand, score)
            }
        }
        if let best, best.score >= 0.55 {
            return best.key
        }
        return explicitASCIIKeyIfValid()
    }
}
