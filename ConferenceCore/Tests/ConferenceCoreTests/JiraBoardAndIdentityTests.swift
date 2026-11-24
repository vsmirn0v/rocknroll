import Foundation
import XCTest
@testable import ConferenceCore

@MainActor
private final class MockBoardWebEvaluator: JiraBoardWebEvaluating {
    var currentBoardURL: URL?
    var cookies: [HTTPCookie] = []
    var refreshedHighlightKeys: [String?] = []
    var requests: [(endpoint: String, method: String, body: String?)] = []
    var responder: (String, String, String?) -> (status: Int, body: String) = { _, _, _ in (404, "{}") }

    func callBoardAsyncJS(_ functionBody: String, arguments: [String: Any]) async throws -> String {
        let endpoint = (arguments["endpoint"] as? String) ?? ""
        let method = (arguments["method"] as? String) ?? "GET"
        let body = arguments["body"] as? String
        requests.append((endpoint, method, body))
        let result = responder(endpoint, method, body)
        let data = try JSONSerialization.data(withJSONObject: [
            "status": result.status,
            "body": result.body
        ])
        return String(decoding: data, as: UTF8.self)
    }

    func cookiesForBoard(matching origin: URL) async -> [HTTPCookie] {
        JiraBoardContextInfo.matchingCookies(cookies, for: origin)
    }

    func refreshBoardAfterJiraMutation(highlightIssueKey: String?) async {
        refreshedHighlightKeys.append(highlightIssueKey)
    }
}

final class JiraBoardAndIdentityTests: XCTestCase {
    func testJiraBoardContextInfoParsesCloudDataCenterAndCookies() throws {
        let cloudURL = try XCTUnwrap(URL(string: "https://rockteam.atlassian.net/jira/software/c/projects/ROCK/boards/42?selectedIssue=ROCK-19"))
        let cloud = try XCTUnwrap(JiraBoardContextInfo.parse(from: cloudURL))
        XCTAssertTrue(cloud.isCloud)
        XCTAssertEqual(cloud.contextPath, "")
        XCTAssertEqual(cloud.projectKey, "ROCK")
        XCTAssertEqual(cloud.rapidViewID, "42")
        XCTAssertEqual(cloud.selectedIssueKey, "ROCK-19")
        XCTAssertTrue(cloud.looksLikeJiraURL)

        let dcURL = try XCTUnwrap(URL(string: "https://jira.internal.ru/jira/secure/RapidBoard.jspa?rapidView=7&projectKey=OPS"))
        let dc = try XCTUnwrap(JiraBoardContextInfo.parse(from: dcURL))
        XCTAssertFalse(dc.isCloud)
        XCTAssertEqual(dc.contextPath, "/jira")
        XCTAssertEqual(dc.baseURL.absoluteString, "https://jira.internal.ru/jira")
        XCTAssertEqual(dc.projectKey, "OPS")
        XCTAssertEqual(dc.rapidViewID, "7")
        XCTAssertTrue(dc.looksLikeJiraURL)

        let goodCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".internal.ru",
            .path: "/jira",
            .name: "JSESSIONID",
            .value: "abc123",
            .secure: "TRUE"
        ]))
        let otherCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "other.example.com",
            .path: "/",
            .name: "SID",
            .value: "xyz"
        ]))
        let matched = JiraBoardContextInfo.matchingCookies([goodCookie, otherCookie], for: dcURL)
        XCTAssertEqual(matched.map(\.name), ["JSESSIONID"])
    }

    @MainActor
    func testBoardSessionConnectorAdoptedWithoutPATResolvesUsersCopiesFromIssueAndTransitions() async throws {
        let evaluator = MockBoardWebEvaluator()
        evaluator.currentBoardURL = URL(string: "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=15&projectKey=SDBCTO")

        evaluator.responder = { endpoint, method, _ in
            if endpoint.contains("/rest/api/2/myself") || endpoint.contains("/rest/api/3/myself") {
                return (200, """
                {"name":"v.smirnov","displayName":"Smirnov Vitalii","emailAddress":"v.smirnov@example.ru"}
                """)
            }
            if endpoint.contains("/rest/agile/1.0/board/15/issue") {
                return (200, """
                {"issues":[
                  {"id":"101","key":"SDBCTO-101","fields":{
                    "summary":"Add iCloud assistant sync",
                    "status":{"name":"In Progress"},
                    "issuetype":{"name":"Task"},
                    "assignee":{"name":"v.smirnov","displayName":"Smirnov Vitalii","emailAddress":"v.smirnov@example.ru"},
                    "reporter":{"name":"a.ivanova","displayName":"Anna Ivanova"}
                  }},
                  {"id":"102","key":"SDBCTO-102","fields":{
                    "summary":"Separate assistant speech",
                    "status":{"name":"To Do"},
                    "issuetype":{"name":"Story"},
                    "assignee":{"name":"a.petrov","displayName":"Anton Petrov"}
                  }}
                ]}
                """)
            }
            if endpoint.contains("/rest/api/2/issue/SDBCTO-101") && method == "GET" && !endpoint.contains("transitions") {
                return (200, """
                {"id":"101","key":"SDBCTO-101","fields":{
                  "summary":"Add iCloud assistant sync",
                  "status":{"name":"In Progress"},
                  "issuetype":{"name":"Task"},
                  "assignee":{"name":"v.smirnov","displayName":"Smirnov Vitalii","emailAddress":"v.smirnov@example.ru"},
                  "reporter":{"name":"a.ivanova","displayName":"Anna Ivanova"}
                }}
                """)
            }
            if endpoint.contains("/user/search") && endpoint.contains("Smirnov") {
                return (200, """
                [{"name":"v.smirnov","displayName":"Smirnov Vitalii","emailAddress":"v.smirnov@example.ru"},
                 {"name":"v.smirnov.ext","displayName":"Vitalii Smirnov (Contractor)"}]
                """)
            }
            if endpoint.contains("/transitions") && method == "GET" {
                return (200, """
                {"transitions":[
                  {"id":"11","name":"To Do","to":{"name":"To Do"}},
                  {"id":"31","name":"Done","to":{"name":"Done"}}
                ]}
                """)
            }
            if endpoint.contains("/transitions") && method == "POST" {
                return (204, "")
            }
            return (404, "{}")
        }

        var savedPrefs: [TaskSyncPreferences] = []
        let hooks = WorkspaceTaskSyncController.HostHooks(
            loadTasks: { [] },
            loadContacts: { [] },
            loadMyAliases: { [] },
            applyMutations: { _ in },
            persistPreferences: { savedPrefs.append($0) },
            readSecret: { _, _ in nil },
            writeSecret: { _, _, _ in true }
        )
        let controller = WorkspaceTaskSyncController(hooks: hooks)
        controller.preferences = TaskSyncPreferences()
        controller.boardWebEvaluator = evaluator

        await controller.adoptJiraSessionFromBoardIfAvailable(evaluator)
        XCTAssertTrue(controller.boardJiraSessionActive)
        XCTAssertEqual(controller.currentJiraUser?.username, "v.smirnov")
        XCTAssertEqual(controller.preferences.jira.baseURL, "https://tasks.sberdevices.ru/jira")
        XCTAssertEqual(controller.preferences.jira.projectKey, "SDBCTO")
        XCTAssertNoThrow(try controller.activeJiraConnector())

        // 1. Copy Jira user from existing board ticket.
        let copied = try await controller.copyJiraUserFromIssue(issueKey: "SDBCTO-101", role: "assignee")
        XCTAssertEqual(copied.issueKey, "SDBCTO-101")
        XCTAssertEqual(copied.user.username, "v.smirnov")
        XCTAssertEqual(copied.user.emailAddress, "v.smirnov@example.ru")

        // 2. Ambiguous / unconfirmed Cyrillic meeting name must return candidates for confirmation instead of guessing.
        let emptyPeople = AssistantPeopleDirectory()
        let resolution = await controller.resolveJiraAssignee("Виталий Смирнов (СДБ)", people: emptyPeople)
        guard case .unresolved(let query, let candidates) = resolution else {
            return XCTFail("Expected .unresolved candidates when People.md has no confirmed mapping, got \(resolution)")
        }
        XCTAssertEqual(query, "Виталий Смирнов (СДБ)")
        XCTAssertFalse(candidates.isEmpty, "Cyrillic transliteration should surface Smirnov Vitalii candidates")
        XCTAssertTrue(candidates.contains { $0.username == "v.smirnov" })

        // 3. Once confirmed in People.md, resolveJiraAssignee resolves deterministically.
        let confirmedPeople = AssistantPeopleDirectory(entries: [
            AssistantPersonEntry(
                displayName: "Vitalii Smirnov",
                aliases: ["Виталий Смирнов (СДБ)"],
                jiraUsername: "v.smirnov",
                approvedVoiceCommander: true
            )
        ])
        let resolved = await controller.resolveJiraAssignee("Виталий Смирнов (СДБ)", people: confirmedPeople)
        guard case .resolved(let jqlIdentifier, let person) = resolved else {
            return XCTFail("Expected .resolved once mapped in People.md, got \(resolved)")
        }
        XCTAssertEqual(jqlIdentifier, "v.smirnov")
        XCTAssertEqual(person?.displayName, "Vitalii Smirnov")

        // 4. Transition issue visibly refreshes the board.
        _ = try await controller.transitionJiraIssue(key: "SDBCTO-101", targetStatus: "Done")
        XCTAssertEqual(evaluator.refreshedHighlightKeys.last ?? nil, "SDBCTO-101")
    }

    func testAssistantCloudSyncCRDTBetweenMacAndPhonePreservesOfflineEditsAndSyncsSettings() throws {
        // Fresh device with only default settings should not push empty/default noise into CloudKit.
        var freshDoc = MeetingWorkspaceSyncDocument(device: "iphone-fresh")
        var freshBaseline: AssistantLocalSyncBaseline?
        let defaultSkills = AssistantSkillRepository.defaultSkillsListForTesting()
        let defaultPrompts = AssistantPromptKind.allCases.map {
            AssistantPromptDocument(kind: $0, content: DefaultAssistantPrompts.content(for: $0))
        }
        let freshExported = AssistantCloudSync.exportLocalState(
            .init(
                people: AssistantPeopleDirectory(),
                teamContext: .starter(),
                skills: defaultSkills,
                prompts: defaultPrompts,
                preferences: LocalAssistantPortablePreferences()
            ),
            into: &freshDoc,
            baseline: &freshBaseline
        )
        XCTAssertTrue(freshExported.isEmpty, "Unconfigured fresh install must not overwrite cloud data")

        // Device A (iPhone) edits People.md, TeamContext, creates a custom skill, customizes BasePersona, sets board URL.
        var iosDoc = MeetingWorkspaceSyncDocument(device: "iphone-1")
        var iosBaseline: AssistantLocalSyncBaseline?
        let customSkill = AssistantSkill(
            id: "release-captain",
            name: "Release Captain",
            role: "Track release readiness",
            enabled: true,
            triggers: ["релиз"],
            instructions: "Track release blockers on the board."
        )
        let iosInput = AssistantCloudSync.LocalSnapshotInput(
            people: AssistantPeopleDirectory(entries: [
                AssistantPersonEntry(displayName: "Vitalii", aliases: ["Виталий Смирнов (СДБ)"], jiraUsername: "v.smirnov", approvedVoiceCommander: true)
            ]),
            teamContext: AssistantTeamContextDocument(
                defaultJiraBoardURL: "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=15",
                defaultJiraProjectKey: "SDBCTO",
                notes: "Core release team"
            ),
            skills: defaultSkills + [customSkill],
            prompts: [
                AssistantPromptDocument(kind: .basePersona, content: "# Custom Persona\nBe extra brief."),
                AssistantPromptDocument(kind: .meetingSummary, content: DefaultAssistantPrompts.content(for: .meetingSummary)),
                AssistantPromptDocument(kind: .attentionJudge, content: DefaultAssistantPrompts.content(for: .attentionJudge)),
            ],
            preferences: LocalAssistantPortablePreferences(
                selectedSkillIDs: ["scrum-master", "release-captain"],
                autonomousMeetingVoiceEnabled: true,
                realtimeProvider: RealtimeProviderKind.openAIRealtime.rawValue,
                realtimeModel: "gpt-realtime",
                lastBoardURL: "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=15"
            )
        )
        let iosChanged = AssistantCloudSync.exportLocalState(iosInput, into: &iosDoc, baseline: &iosBaseline)
        XCTAssertEqual(iosChanged, AssistantCloudSync.allScopeKeys)

        // Device B (Mac) concurrently has an unexported local teammate Bob in People.md.
        var macDoc = MeetingWorkspaceSyncDocument(device: "mac-1")
        var macBaseline: AssistantLocalSyncBaseline?
        let macLocalInput = AssistantCloudSync.LocalSnapshotInput(
            people: AssistantPeopleDirectory(entries: [
                AssistantPersonEntry(displayName: "Bob", aliases: ["Борис"], jiraUsername: "b.ivanov")
            ]),
            teamContext: .starter(),
            skills: defaultSkills,
            prompts: defaultPrompts,
            preferences: LocalAssistantPortablePreferences()
        )
        _ = AssistantCloudSync.exportLocalState(macLocalInput, into: &macDoc, baseline: &macBaseline)

        // CloudKit sync merges library records from iPhone into Mac's document!
        _ = macDoc.mergeLibraryRecords(iosDoc.allLibraryRecords)

        let planForMac = try XCTUnwrap(AssistantCloudSync.planRemoteApplication(
            from: macDoc.contextSettings,
            currentInput: macLocalInput,
            previousBaseline: macBaseline
        ))
        XCTAssertTrue(planForMac.hasAnyChange)
        let mergedPeople = try XCTUnwrap(planForMac.updatedPeople)
        XCTAssertEqual(Set(mergedPeople.entries.map(\.displayName)), ["Bob", "Vitalii"])
        XCTAssertEqual(planForMac.updatedTeamContext?.defaultJiraProjectKey, "SDBCTO")
        XCTAssertEqual(planForMac.skillsToSave.map(\.id), ["release-captain"])
        XCTAssertEqual(planForMac.promptsToSave.map(\.kind), [.basePersona])
        XCTAssertEqual(planForMac.updatedPreferences?.autonomousMeetingVoiceEnabled, true)
        XCTAssertEqual(planForMac.updatedPreferences?.selectedSkillIDs, ["scrum-master", "release-captain"])
        XCTAssertEqual(planForMac.updatedPreferences?.lastBoardURL, "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=15")

        // Built-in skill unmodified on disk with non-nil updatedAt must NOT look customized.
        var stampedDefault = try XCTUnwrap(DefaultAssistantSkills.skill(id: "scrum-master"))
        stampedDefault.updatedAt = Date()
        stampedDefault.sourceRelativePath = "Skills/scrum-master.md"
        XCTAssertEqual(AssistantCloudSync.skillDigest(stampedDefault), AssistantCloudSync.skillDigest(try XCTUnwrap(DefaultAssistantSkills.skill(id: "scrum-master"))))
    }

    func testMeetingTaskDeduplicatorMergesIdenticalAndMetaTasksPreservingDistinctKeys() {
        XCTAssertTrue(MeetingTaskDeduplicator.isDuplicate(
            candidateTitle: "Доработка по итогам CTO Daily",
            candidateOwner: "Виталий Смирнов",
            existingTitle: "Доработка по итогам CTO Daily",
            existingOwner: "Виталий Смирнов"
        ))
        XCTAssertTrue(MeetingTaskDeduplicator.isDuplicate(
            candidateTitle: "Завести задачу на доработку по итогам CTO Daily",
            candidateOwner: "Виталий Смирнов",
            existingTitle: "Доработка по итогам CTO Daily",
            existingOwner: "Виталий Смирнов"
        ))
        XCTAssertFalse(MeetingTaskDeduplicator.isDuplicate(
            candidateTitle: "Проверить SDBCTO-12 на стенде",
            candidateOwner: "Виталий",
            existingTitle: "Проверить SDBCTO-13 на стенде",
            existingOwner: "Виталий"
        ))
        XCTAssertFalse(MeetingTaskDeduplicator.isDuplicate(
            candidateTitle: "Доработка по итогам CTO Daily",
            candidateOwner: "Виталий",
            existingTitle: "Доработка по итогам CTO Daily",
            existingOwner: "Анна"
        ))
        XCTAssertFalse(MeetingTaskDeduplicator.areOwnersCompatible("Алексей Иванов", "Алексей Петров"))
        XCTAssertTrue(MeetingTaskDeduplicator.areOwnersCompatible("Алексей", "Алексей Иванов"))
        XCTAssertTrue(MeetingTaskDeduplicator.areOwnersCompatible("Иванов Алексей", "Алексей Иванов"))
    }

    @MainActor
    func testJiraNormalizationSpokenKeyBoardDerivationAndDOMScripts() async throws {
        XCTAssertEqual(
            SyncedMeetingContextSettings.normalizedBoardURLString(from: "tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=42"),
            "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=42"
        )
        XCTAssertEqual(
            SyncedMeetingContextSettings.normalizedBoardURLString(from: "127.0.0.1:8080/boards/1"),
            "http://127.0.0.1:8080/boards/1"
        )
        XCTAssertEqual(
            SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: "SDBCTO-123, https://jira.example.com/projects/SPS/boards/5"),
            ["SDBCTO", "SPS"]
        )
        XCTAssertEqual(
            WorkspaceTaskSyncController.resolveSpokenProjectKey("Sdp ситио", candidates: ["SPS", "SDBCTO"]),
            "SDBCTO"
        )

        let evaluator = MockBoardWebEvaluator()
        evaluator.currentBoardURL = URL(string: "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=15")
        evaluator.responder = { endpoint, _, _ in
            if endpoint.contains("/rest/api/2/myself") || endpoint.contains("/rest/api/3/myself") {
                return (200, "{\"name\":\"v.smirnov\",\"displayName\":\"Vitalii Smirnov\"}")
            }
            if endpoint.contains("/rest/agile/1.0/board/15/project") {
                return (200, "{\"values\":[{\"key\":\"SDBCTO\"}]}")
            }
            if endpoint.contains("/rest/agile/1.0/board/15/issue") {
                return (200, "{\"issues\":[]}")
            }
            return (404, "{}")
        }
        let connector = JiraBoardWebSessionConnector(evaluator: evaluator)
        let derived = await connector.deriveBoardProjectKeys()
        XCTAssertTrue(derived.contains("SDBCTO"))

        let scrollScript = JiraBoardDOMScripts.scrollBoardScript(deltaY: 420)
        XCTAssertTrue(scrollScript.contains("#ghx-pool"))
        let presScript = JiraBoardDOMScripts.applyPresentationModeScript(enabled: true)
        XCTAssertTrue(presScript.contains("__rnr-board-presentation-style"))
        XCTAssertTrue(presScript.contains(".aui-page-panel"))
        XCTAssertTrue(presScript.contains("overflow-y: auto"))
        XCTAssertTrue(presScript.contains("dispatchEvent(new Event('resize'))"))
        let focusScript = JiraBoardDOMScripts.focusActiveCardsScript()
        XCTAssertTrue(focusScript.contains("scrollIntoView"))

        XCTAssertEqual(
            WorkspaceTaskSyncController.resolveSpokenProjectKey("INFRA", candidates: ["SDBCTO"]),
            "INFRA"
        )
        XCTAssertNil(
            WorkspaceTaskSyncController.resolveSpokenProjectKey("ситио", candidates: [])
        )
        XCTAssertEqual(
            WorkspaceTaskSyncController.resolvedEffectiveJiraProjectKeys(
                configured: ["TEAM"],
                globalFallback: ["GLOBAL"],
                boardDerived: ["BOARD"]
            ),
            ["TEAM"]
        )
        XCTAssertEqual(
            WorkspaceTaskSyncController.resolvedEffectiveJiraProjectKeys(
                configured: ["GLOBAL"],
                globalFallback: ["GLOBAL"],
                boardDerived: ["BOARD"]
            ),
            ["BOARD", "GLOBAL"]
        )
        XCTAssertEqual(
            WorkspaceTaskSyncController.resolvedEffectiveJiraProjectKeys(
                configured: ["GLOBAL"],
                globalFallback: ["GLOBAL"],
                boardDerived: []
            ),
            ["GLOBAL"]
        )

        let unicodeURL = SyncedMeetingContextSettings.normalizedBoardURLString(
            from: "https://jira.internal/secure/RapidBoard.jspa?rapidView=5&quickFilter=Виталий"
        )
        XCTAssertNotNil(unicodeURL)
        XCTAssertTrue(unicodeURL?.hasPrefix("https://jira.internal/secure/RapidBoard.jspa?") == true)
        XCTAssertNotNil(unicodeURL.flatMap(URL.init(string:)))

        // Stale board project keys must clear when switching to a board URL whose endpoints yield no keys.
        let syncController = WorkspaceTaskSyncController(hooks: .init(
            loadTasks: { [] },
            loadContacts: { [] },
            loadMyAliases: { [] },
            applyMutations: { _ in },
            persistPreferences: { _ in },
            readSecret: { _, _ in nil },
            writeSecret: { _, _, _ in true }
        ))
        syncController.boardWebEvaluator = evaluator
        let firstKeys = await syncController.resolveBoardDerivedProjectKeys()
        XCTAssertEqual(firstKeys, ["SDBCTO"])

        evaluator.currentBoardURL = URL(string: "https://tasks.sberdevices.ru/jira/secure/RapidBoard.jspa?rapidView=99")
        evaluator.responder = { _, _, _ in (404, "{}") }
        let clearedKeys = await syncController.resolveBoardDerivedProjectKeys()
        XCTAssertTrue(clearedKeys.isEmpty, "Switching boards must clear stale cached project keys from the previous board")
    }
}

private extension AssistantSkillRepository {
    static func defaultSkillsListForTesting() -> [AssistantSkill] {
        DefaultAssistantSkills.all
    }
}
