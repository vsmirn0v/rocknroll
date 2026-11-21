import Foundation
import XCTest
@testable import ConferenceCore

final class AssistantSkillsAndPeopleTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantSkillRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testMarkdownSkillCodecRoundTripPreservesFrontmatterAndBody() {
        let original = AssistantSkill(
            id: "sprint-planner",
            name: "Sprint Planner: Alpha",
            role: "Plan team sprints cleanly, cleanly",
            enabled: true,
            voiceActivation: false,
            triggers: ["sprint planning", "backlog grooming"],
            tools: [.tasks, .jira, .calendarSchedule, .meetingSummary],
            approvedSpeakersOnly: true,
            realtimePreferred: true,
            instructions: """
            # Sprint Planner

            Review open tasks first.
            - Prioritize P0 bugs
            - Assign Jira owners using People.md
            """,
            extraFrontmatter: ["owner": "platform-team"]
        )

        let markdown = AssistantSkillMarkdownCodec.encode(original)
        let decoded = AssistantSkillMarkdownCodec.decode(markdown, fallbackSlug: "fallback")

        XCTAssertEqual(decoded.id, "sprint-planner")
        XCTAssertEqual(decoded.name, "Sprint Planner: Alpha")
        XCTAssertEqual(decoded.role, "Plan team sprints cleanly, cleanly")
        XCTAssertTrue(decoded.enabled)
        XCTAssertFalse(decoded.voiceActivation)
        XCTAssertEqual(decoded.triggers, ["sprint planning", "backlog grooming"])
        XCTAssertEqual(decoded.tools, [.tasks, .jira, .calendarSchedule, .meetingSummary])
        XCTAssertTrue(decoded.approvedSpeakersOnly)
        XCTAssertTrue(decoded.realtimePreferred)
        XCTAssertEqual(decoded.extraFrontmatter["owner"], "platform-team")
        XCTAssertTrue(decoded.instructions.contains("Review open tasks first."))
        XCTAssertTrue(decoded.instructions.contains("- Assign Jira owners using People.md"))
    }

    func testRepositorySeedsDefaultsOnceAndRespectsUserEditsAndDeletions() throws {
        let root = try makeTempDir()
        let repo = AssistantSkillRepository(rootURL: root)
        try repo.ensureDefaultsInstalled()

        let initial = repo.listSkills()
        XCTAssertEqual(Set(initial.map(\.id)), DefaultAssistantSkills.defaultIDs)

        // Edit a shipped skill and ensure ensureDefaultsInstalled does not clobber it
        var scrum = try XCTUnwrap(repo.skill(id: "scrum-master"))
        scrum.instructions += "\n\n## Custom Team Rule\nAsk about QA readiness."
        try repo.saveSkill(scrum)
        try repo.ensureDefaultsInstalled()

        let reloadedScrum = try XCTUnwrap(repo.skill(id: "scrum-master"))
        XCTAssertTrue(reloadedScrum.instructions.contains("Ask about QA readiness."))

        // Delete a shipped skill and verify user deletion sticks until explicit restore
        try repo.deleteSkill(id: "retro-and-planning")
        try repo.ensureDefaultsInstalled()
        XCTAssertNil(repo.skill(id: "retro-and-planning"))

        _ = try repo.restoreDefaultSkill(id: "retro-and-planning")
        XCTAssertNotNil(repo.skill(id: "retro-and-planning"))
    }

    func testPeopleMarkdownCodecApprovalAndFuzzyJiraResolution() throws {
        let root = try makeTempDir()
        let repo = AssistantSkillRepository(rootURL: root)
        try repo.ensureDefaultsInstalled()

        try repo.upsertPerson(AssistantPersonEntry(
            displayName: "Alexander Ivanov",
            aliases: ["Sasha", "Саша", "@aivanov"],
            jiraUsername: "a.ivanov",
            jiraAccountID: "557058:alex-123",
            email: "alex@example.com",
            role: "iOS Lead",
            approvedVoiceCommander: true,
            notes: "Leads mobile stream | uses Cyrillic nick"
        ))
        try repo.upsertPerson(AssistantPersonEntry(
            displayName: "Maria Petrova",
            aliases: ["Masha"],
            jiraUsername: "m.petrova",
            approvedVoiceCommander: false,
            notes: "QA engineer"
        ))

        let directory = repo.loadPeople()
        XCTAssertEqual(directory.entries.count, 2)

        // Local user is ALWAYS approved regardless of People.md
        XCTAssertTrue(directory.isApprovedSpeaker("You", localUserNames: ["Vitalii"]))
        XCTAssertTrue(directory.isApprovedSpeaker("Vitalii", localUserNames: ["Vitalii"]))
        XCTAssertTrue(directory.isApprovedSpeaker("", localUserNames: ["Vitalii"]))

        // Approved teammate via alias
        XCTAssertTrue(directory.isApprovedSpeaker("Саша", localUserNames: ["Vitalii"]))
        XCTAssertTrue(directory.isApprovedSpeaker("Alexander Ivanov", localUserNames: ["Vitalii"]))

        // Unapproved teammate and unknown guest are rejected
        XCTAssertFalse(directory.isApprovedSpeaker("Maria Petrova", localUserNames: ["Vitalii"]))
        XCTAssertFalse(directory.isApprovedSpeaker("Random Guest", localUserNames: ["Vitalii"]))

        // Fuzzy resolution maps meeting display/spoken name to Jira account
        let resolvedAlex = try XCTUnwrap(directory.resolvePerson(matching: "саша"))
        XCTAssertEqual(resolvedAlex.jiraUsername, "a.ivanov")
        XCTAssertEqual(resolvedAlex.jiraAccountID, "557058:alex-123")
        XCTAssertEqual(resolvedAlex.notes, "Leads mobile stream | uses Cyrillic nick")
    }

    func testKnowledgeSearchQueriesSkillsPeopleTeamContextAndExtraVaultFiles() throws {
        let vaultRoot = try makeTempDir()
        let extraDir = vaultRoot.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: extraDir, withIntermediateDirectories: true)
        try "# Checkout Q4\n\nMigration blocker: Apple Pay token refresh.".write(
            to: extraDir.appendingPathComponent("CheckoutRoadmap.md"),
            atomically: true,
            encoding: .utf8
        )

        let assistantRoot = vaultRoot.appendingPathComponent("Rock Assistant", isDirectory: true)
        let repo = AssistantSkillRepository(rootURL: assistantRoot)
        try repo.ensureDefaultsInstalled()

        let doc = AssistantTeamContextDocument(
            defaultJiraBoardURL: "https://jira.example.com/boards/42",
            defaultJiraProjectKey: "MOB",
            defaultCalendarIdentifier: "work-cal",
            notes: "Standup starts at 10:00 MSK."
        )
        try repo.saveTeamContext(doc)
        XCTAssertEqual(repo.loadTeamContext().defaultJiraBoardURL, "https://jira.example.com/boards/42")

        let hits = repo.searchKnowledge(query: "Apple Pay token", extraVaultRoot: vaultRoot, limit: 5)
        XCTAssertEqual(hits.first?.title, "CheckoutRoadmap")
        XCTAssertEqual(hits.first?.kind, "obsidian")
        XCTAssertTrue(hits.first?.excerpt.contains("Apple Pay") == true)
    }

    func testTaskWorkflowStatusFromExternalStatus() {
        XCTAssertEqual(TaskWorkflowStatus.fromExternalStatus("To Do"), .todo)
        XCTAssertEqual(TaskWorkflowStatus.fromExternalStatus("In Progress"), .inProgress)
        XCTAssertEqual(TaskWorkflowStatus.fromExternalStatus("On Hold"), .blocked)
        XCTAssertEqual(TaskWorkflowStatus.fromExternalStatus("In Review"), .inReview)
        XCTAssertEqual(TaskWorkflowStatus.fromExternalStatus("Done"), .done)
        XCTAssertEqual(TaskWorkflowStatus.fromExternalStatus("Won't Do"), .cancelled)
        XCTAssertNil(TaskWorkflowStatus.fromExternalStatus("some_unknown_state"))
    }

    func testObsidianPromptsSeedingSaveRestoreAndCombinedSkillMatching() throws {
        let root = try makeTempDir()
        let repo = AssistantSkillRepository(rootURL: root)
        try repo.ensureDefaultsInstalled()

        let prompts = repo.listPrompts()
        XCTAssertEqual(Set(prompts.map(\.kind)), Set(AssistantPromptKind.allCases))
        XCTAssertTrue(repo.loadPrompt(.basePersona).content.contains("Rock"))

        _ = try repo.savePrompt(.basePersona, content: "# Custom Persona\nAlways speak briefly.")
        XCTAssertTrue(repo.loadPrompt(.basePersona).content.contains("Custom Persona"))

        // Auto-greet round-trip in skill Markdown
        let retro = AssistantSkill(
            id: "weekly-retro",
            name: "Weekly Retro",
            role: "Retrospective facilitator",
            triggers: ["retro", "ретро"],
            autoGreet: true,
            instructions: "Collect start/stop/continue items."
        )
        _ = try repo.saveSkill(retro)
        let reloaded = try XCTUnwrap(repo.skill(id: "weekly-retro"))
        XCTAssertTrue(reloaded.autoGreet)

        // Pinning scrum-master must not block trigger-matched skills for a meeting command.
        let ctx = repo.renderPromptContext(
            explicitSkillIDs: ["scrum-master"],
            meetingTitle: "Team Retro Sync",
            commandText: "подведи ретро"
        )
        let selectedIDs = ctx.selectedSkills.map(\.id)
        XCTAssertTrue(selectedIDs.contains("scrum-master"))
        XCTAssertTrue(selectedIDs.contains("weekly-retro"))
        XCTAssertTrue(ctx.basePersona.contains("Custom Persona"))

        _ = try repo.restoreDefaultPrompt(.basePersona)
        XCTAssertTrue(repo.loadPrompt(.basePersona).content.contains("Rock Assistant Persona"))
    }

    func testFolderWatcherDetectsExternalSkillEdit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = AssistantSkillRepository(rootURL: dir)
        try repo.ensureDefaultsInstalled()

        let fired = expectation(description: "watcher fires")
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var didFire = false
            func consume() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if didFire { return false }
                didFire = true
                return true
            }
        }
        let flag = OnceFlag()
        let watcher = AssistantSkillFolderWatcher(rootURL: dir, debounceInterval: 0.08) {
            if flag.consume() { fired.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        let customSkill = AssistantSkill(
            id: "sprint-watcher",
            name: "Sprint Watcher",
            role: "Watcher smoke test",
            instructions: "Track updates."
        )
        _ = try repo.saveSkill(customSkill)

        wait(for: [fired], timeout: 3.0)
    }

    func testRealtimeKeychainDisabledProviderGuard() {
        let keychain = WorkspaceAPIKeychain(service: "dev.vsmirn0v.test.\(UUID().uuidString)")
        XCTAssertFalse(keychain.writeRealtime("secret", provider: .disabled))
        XCTAssertNil(keychain.readRealtime(provider: .disabled))
    }

    func testJiraActionSearchAndCommentViaTaskSyncController() async throws {
        actor ConnectorStorage {
            var comments: [(key: String, comment: String)] = []
            var queries: [String] = []
            func appendQuery(_ q: String) { queries.append(q) }
            func appendComment(key: String, comment: String) { comments.append((key, comment)) }
        }
        final class MockJiraConnector: JiraTaskConnecting, @unchecked Sendable {
            let storage = ConnectorStorage()

            func verifyMyself() async throws -> JiraUserContact {
                JiraUserContact(identifier: "alex", displayName: "Alex", isServerOrDC: true)
            }
            func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
                JiraProjectMetadata(key: projectKey, name: projectKey, issueTypes: ["Task"])
            }
            func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact] { [] }
            func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue] {
                await storage.appendQuery(jql)
                return [JiraRemoteIssue(id: "1", key: "ENG-42", summary: "Fix audio route", description: "", statusName: "In Progress", workflowStatus: .inProgress)]
            }
            func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue {
                fatalError("unused")
            }
            func updateIssue(key: String, payload: JiraIssueWritePayload, targetStatus: TaskWorkflowStatus?, comment: String?) async throws -> JiraRemoteIssue {
                fatalError("unused")
            }
            func addIssueComment(key: String, comment: String) async throws {
                await storage.appendComment(key: key, comment: comment)
            }
        }

        let connector = MockJiraConnector()
        let controller = await MainActor.run {
            let hooks = WorkspaceTaskSyncController.HostHooks(
                loadTasks: { [] },
                loadContacts: { [] },
                loadMyAliases: { ["Alex"] },
                applyMutations: { _ in },
                persistPreferences: { _ in },
                makeJiraConnector: { _, _ in connector }
            )
            let sync = WorkspaceTaskSyncController(hooks: hooks)
            var prefs = sync.preferences
            prefs.jira = JiraConnectionSettings(enabled: true, baseURL: "https://jira.example.com", projectKey: "ENG")
            sync.preferences = prefs
            return sync
        }

        let found = try await controller.searchJiraIssues(jql: "project = ENG", maxResults: 10)
        XCTAssertEqual(found.map(\.key), ["ENG-42"])
        let queries = await connector.storage.queries
        XCTAssertEqual(queries, ["project = ENG"])

        try await controller.commentOnJiraIssue(key: "ENG-42", comment: "Pushed fix to staging.")
        let comments = await connector.storage.comments
        XCTAssertEqual(comments.first?.key, "ENG-42")
        XCTAssertEqual(comments.first?.comment, "Pushed fix to staging.")
    }
}
