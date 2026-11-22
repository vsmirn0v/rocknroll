import ConferenceCore
import Foundation

/// Registers Obsidian-backed skill, knowledge, task, calendar, People.md, Jira Board,
/// and multi-meeting join tools into `AssistantAgentToolRegistry` and bridges them
/// cleanly to optional Realtime WebSocket function declarations.
@MainActor
enum AssistantSkillToolRegistrar {
    static func enrichedContext(
        base: [String: String],
        attention: AttentionCoordinator,
        explicitSkillIDs: [String] = [],
        meetingTitle: String = "",
        commandText: String = "",
        speakerName: String? = nil,
        isApprovedSpeaker: Bool = true
    ) async -> [String: String] {
        var context = base
        let preferred = explicitSkillIDs.isEmpty ? attention.store.selectedSkillIDs : explicitSkillIDs
        let rendered = await attention.withSkillRepository { repo, _ in
            repo.renderPromptContext(
                explicitSkillIDs: preferred,
                meetingTitle: meetingTitle,
                commandText: commandText
            )
        }
        var identityGuidanceParticipants: [String] = []
        if let activeMeeting = await MainActor.run(body: {
            attention.meetings().first(where: { !$0.isClosed && $0.title == meetingTitle })
                ?? attention.meetings().first(where: { !$0.isClosed })
        }) {
            identityGuidanceParticipants = [activeMeeting.displayName] + activeMeeting.participants.filter { !$0.isLocal }.map(\.name)
        }
        let guidance = DefaultAssistantPrompts.jiraIdentityResolutionGuidance(meetingParticipants: identityGuidanceParticipants)
        let combinedSkills = [rendered.instructions, guidance].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !combinedSkills.isEmpty {
            context["obsidian_skills"] = combinedSkills
        }
        if !rendered.basePersona.isEmpty {
            context["obsidian_base_persona"] = rendered.basePersona
        }
        if !rendered.teamContext.defaultJiraBoardURL.isEmpty {
            context["team_board_url"] = rendered.teamContext.defaultJiraBoardURL
        }
        context["approved_user_always"] = "true"
        if let speakerName, !speakerName.isEmpty {
            context["current_speaker"] = speakerName
            context["current_speaker_approved"] = isApprovedSpeaker ? "true" : "false"
        }
        return context
    }

    static func resolvedSkills(
        attention: AttentionCoordinator,
        explicitSkillIDs: [String] = [],
        meetingTitle: String = "",
        commandText: String = ""
    ) async -> [AssistantSkill] {
        let preferred = explicitSkillIDs.isEmpty ? attention.store.selectedSkillIDs : explicitSkillIDs
        return await attention.withSkillRepository { repo, _ in
            repo.renderPromptContext(
                explicitSkillIDs: preferred,
                meetingTitle: meetingTitle,
                commandText: commandText
            ).selectedSkills
        }
    }

    static func registerTools(
        into registry: AssistantAgentToolRegistry,
        attention: AttentionCoordinator,
        talk: AssistantTalkController,
        snapshot: AssistantNativeSnapshot,
        allowPrivilegedActions: Bool,
        allowPeopleIdentityBinding: Bool = false,
        allowedToolGroups: Set<AssistantSkillToolGroup>? = nil
    ) {
        registerReadTools(into: registry, attention: attention, allowedToolGroups: allowedToolGroups)
        if allowedToolGroups?.contains(.jira) ?? true {
            registerJiraActionTool(into: registry, attention: attention, allowComments: allowPrivilegedActions)
        }
        if allowPrivilegedActions || allowPeopleIdentityBinding {
            registerManagePeopleTool(
                into: registry,
                attention: attention,
                snapshot: snapshot,
                allowPrivilegedActions: allowPrivilegedActions,
                allowedToolGroups: allowedToolGroups
            )
        }
        guard allowPrivilegedActions else { return }
        registerWriteAndControlTools(
            into: registry,
            attention: attention,
            talk: talk,
            snapshot: snapshot,
            allowedToolGroups: allowedToolGroups
        )
    }

    nonisolated static func resolvedJiraJQL(rawJQL: String?, query: String?, teamProjectKey: String, jiraProjectKey: String) -> String {
        let explicit = rawJQL?.trimmed ?? ""
        if !explicit.isEmpty { return explicit }
        let project = teamProjectKey.trimmed.isEmpty ? jiraProjectKey : teamProjectKey.trimmed
        let cleanQuery = (query ?? "").trimmed.replacingOccurrences(of: "\"", with: "")
        var clauses: [String] = []
        if !project.isEmpty { clauses.append("project = \(project)") }
        if !cleanQuery.isEmpty { clauses.append("text ~ \"\(cleanQuery)\"") }
        return clauses.isEmpty ? "ORDER BY updated DESC" : (clauses.joined(separator: " AND ") + " ORDER BY updated DESC")
    }

    static func exportRealtimeTools(from registry: AssistantAgentToolRegistry) -> [RealtimeToolDeclaration] {
        registry.descriptors.map { descriptor in
            let schemaObj: [String: Any]
            if let inputSchema = descriptor.inputSchema?.foundationValue as? [String: Any] {
                schemaObj = inputSchema
            } else {
                var props: [String: Any] = [:]
                var required: [String] = []
                for arg in descriptor.arguments {
                    var prop: [String: Any] = ["type": jsonSchemaType(arg.type)]
                    if !arg.description.isEmpty { prop["description"] = arg.description }
                    if !arg.allowedValues.isEmpty { prop["enum"] = arg.allowedValues }
                    if arg.type == .array { prop["items"] = ["type": "string"] }
                    props[arg.name] = prop
                    if arg.required { required.append(arg.name) }
                }
                schemaObj = [
                    "type": "object",
                    "properties": props,
                    "required": required,
                ]
            }
            return RealtimeToolDeclaration(
                name: descriptor.name,
                description: descriptor.description,
                parametersJSONSchema: schemaObj
            )
        }
    }

    static func executeToolCallJSON(
        registry: AssistantAgentToolRegistry,
        name: String,
        argumentsJSON: String
    ) async -> String {
        let parsed: AssistantJSON
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            parsed = AssistantJSON.make(obj)
        } else {
            parsed = .object([:])
        }
        let call = AssistantAgentToolCall(id: UUID().uuidString, name: name, arguments: parsed)
        do {
            let validated = try registry.validate(call)
            guard let tool = registry.tool(named: name) else {
                return "{\"error\":\"Unknown tool \(name)\"}"
            }
            let result = try await tool.execute(validated, arguments: validated.arguments)
            let obj: [String: Any] = [
                "summary": result.summary,
                "is_error": result.isError,
                "data": result.json.foundationValue,
            ]
            if let encoded = try? JSONSerialization.data(withJSONObject: obj),
               let text = String(data: encoded, encoding: .utf8) {
                return text
            }
            return result.summary
        } catch {
            return "{\"error\":\(jsonStringLiteral(error.localizedDescription))}"
        }
    }

    // MARK: - Read Tools

    private static func registerReadTools(
        into registry: AssistantAgentToolRegistry,
        attention: AttentionCoordinator,
        allowedToolGroups: Set<AssistantSkillToolGroup>? = nil
    ) {
        _ = allowedToolGroups
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_list_skills",
                description: "List enabled Obsidian-backed Rock Assistant skills and triggers.",
                arguments: [
                    .init(name: "query", type: .string, required: false, description: "Optional search filter."),
                ]
            )
        ) { call, args in
            let query = args["query"]?.stringValue ?? ""
            let skills = await attention.withSkillRepository { repo, _ in
                repo.searchSkills(query: query, enabledOnly: false)
            }
            let items: [AssistantJSON] = skills.map { skill in
                .object(
                    ("id", .string(skill.id)),
                    ("name", .string(skill.name)),
                    ("role", .string(skill.role)),
                    ("enabled", .bool(skill.enabled)),
                    ("triggers", .strings(skill.triggers))
                )
            }
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(["items": .array(items)]),
                summary: L("Found %ld assistant skills.", items.count)
            )
        })

        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_get_skill",
                description: "Read the complete Markdown instructions for one Obsidian-backed assistant skill.",
                arguments: [
                    .init(name: "skill_id", type: .string, required: true, description: "Skill slug identifier."),
                ]
            )
        ) { call, args in
            guard let skillID = args["skill_id"]?.stringValue?.trimmed, !skillID.isEmpty else {
                throw AssistantAgentError.missingArgument(call.name, "skill_id")
            }
            let skill = await attention.withSkillRepository { repo, _ in repo.skill(id: skillID) }
            guard let skill else {
                return .error(call, L("Skill “%@” was not found.", skillID))
            }
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(
                    ("id", .string(skill.id)),
                    ("name", .string(skill.name)),
                    ("role", .string(skill.role)),
                    ("instructions", .string(skill.instructions))
                ),
                summary: skill.name
            )
        })

        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_search_knowledge",
                description: "Search Obsidian vault Markdown files, Knowledge/People.md, TeamContext.md, and Skills on demand.",
                arguments: [
                    .init(name: "query", type: .string, required: true, description: "Keywords to search."),
                    .init(name: "limit", type: .integer, required: false, description: "Max hits (1...20)."),
                ]
            )
        ) { call, args in
            guard let query = args["query"]?.stringValue?.trimmed, !query.isEmpty else {
                throw AssistantAgentError.missingArgument(call.name, "query")
            }
            let limit = max(1, min(args["limit"]?.intValue ?? 8, 20))
            let hits = await attention.searchAssistantKnowledge(query: query, limit: limit)
            let items: [AssistantJSON] = hits.map { hit in
                .object(
                    ("title", .string(hit.title)),
                    ("path", .string(hit.relativePath)),
                    ("kind", .string(hit.kind)),
                    ("excerpt", .string(hit.excerpt))
                )
            }
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(["items": .array(items)]),
                summary: L("Found %ld knowledge matches for “%@”.", items.count, query)
            )
        })
    }

    private static func registerJiraActionTool(
        into registry: AssistantAgentToolRegistry,
        attention: AttentionCoordinator,
        allowComments: Bool
    ) {
        let allowedOps = allowComments ? ["search", "search_users", "comment"] : ["search", "search_users"]
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_jira_action",
                description: allowComments
                    ? "Search Jira issues with JQL/text/assignee, search Jira users to bind to People.md, or post a comment directly on an existing Jira issue."
                    : "Search Jira issues read-only using JQL/text/assignee, or search Jira users to match with People.md.",
                arguments: [
                    .init(name: "operation", type: .string, required: true, allowedValues: allowedOps),
                    .init(name: "jql", type: .string, required: false),
                    .init(name: "query", type: .string, required: false),
                    .init(name: "assignee", type: .string, required: false, description: "Meeting/display name or Jira handle to resolve via People.md or Jira user search."),
                    .init(name: "max_results", type: .integer, required: false),
                    .init(name: "issue_key", type: .string, required: false),
                    .init(name: "comment", type: .string, required: false),
                ]
            )
        ) { call, args in
            let operation = args["operation"]?.stringValue ?? "search"
            switch operation {
            case "comment":
                guard allowComments else {
                    return .error(call, L("Jira comments require an approved speaker."))
                }
                guard let key = args["issue_key"]?.stringValue?.trimmed, !key.isEmpty,
                      let comment = args["comment"]?.stringValue?.trimmed, !comment.isEmpty else {
                    throw AssistantAgentError.missingArgument(call.name, "issue_key, comment")
                }
                try await attention.taskSync.commentOnJiraIssue(key: key, comment: comment)
                return .init(
                    callID: call.id,
                    toolName: call.name,
                    json: .object(("issue_key", .string(key)), ("commented", .bool(true))),
                    summary: L("Added a Jira comment on %@.", key)
                )
            case "search_users":
                let team = await attention.loadTeamContext()
                let query = (args["query"]?.stringValue ?? args["assignee"]?.stringValue ?? "").trimmed
                let maxResults = max(1, min(args["max_results"]?.intValue ?? 15, 50))
                let users = try await attention.taskSync.searchJiraUsers(
                    query: query,
                    projectKey: team.defaultJiraProjectKey.trimmed.isEmpty ? nil : team.defaultJiraProjectKey.trimmed,
                    maxResults: maxResults
                )
                let rows: [AssistantJSON] = users.map { AssistantJSON.make(WorkspaceTaskSyncController.jiraUserPayload($0)) }
                return .init(
                    callID: call.id,
                    toolName: call.name,
                    json: .object(("users", .array(rows))),
                    summary: L("Found %ld Jira users.", rows.count)
                )
            case "search":
                let team = await attention.loadTeamContext()
                let configuredProject = await MainActor.run { attention.taskSync.preferences.jira.cleanProjectKey }
                var resolvedAssigneeID: String?
                if let rawAssignee = args["assignee"]?.stringValue?.trimmed, !rawAssignee.isEmpty {
                    let people = await attention.loadPeopleDirectory()
                    switch await attention.taskSync.resolveJiraAssignee(
                        rawAssignee,
                        people: people,
                        defaultProjectKey: team.defaultJiraProjectKey
                    ) {
                    case .resolved(let jqlID, _):
                        resolvedAssigneeID = jqlID
                    case .unresolved(let unresolvedQuery, let candidates):
                        let payload = WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                            query: unresolvedQuery,
                            candidates: candidates
                        )
                        return .init(
                            callID: call.id,
                            toolName: call.name,
                            json: AssistantJSON.make(payload),
                            summary: L("Need user confirmation to match Jira user for “%@”.", unresolvedQuery)
                        )
                    }
                }
                let baseJQL = resolvedJiraJQL(
                    rawJQL: args["jql"]?.stringValue,
                    query: args["query"]?.stringValue,
                    teamProjectKey: team.defaultJiraProjectKey,
                    jiraProjectKey: configuredProject
                )
                let jql = resolvedAssigneeID.map {
                    WorkspaceTaskSyncController.injectAssignee($0, intoJQL: baseJQL)
                } ?? baseJQL
                let maxResults = max(1, min(args["max_results"]?.intValue ?? 15, 50))
                let issues: [JiraRemoteIssue]
                var finalJQL = jql
                do {
                    issues = try await attention.taskSync.searchJiraIssues(jql: jql, maxResults: maxResults)
                } catch JiraConnectorError.badRequest(let detail) {
                    if let literalAssignee = WorkspaceTaskSyncController.extractLiteralAssigneeFromJQL(jql) {
                        let people = await attention.loadPeopleDirectory()
                        switch await attention.taskSync.resolveJiraAssignee(
                            literalAssignee,
                            people: people,
                            defaultProjectKey: team.defaultJiraProjectKey
                        ) {
                        case .resolved(let handle, _):
                            finalJQL = WorkspaceTaskSyncController.replacingLiteralAssignee(in: jql, with: handle)
                            issues = try await attention.taskSync.searchJiraIssues(jql: finalJQL, maxResults: maxResults)
                        case .unresolved(let unresolvedQuery, let candidates):
                            let payload = WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                                query: unresolvedQuery,
                                candidates: candidates
                            )
                            return .init(
                                callID: call.id,
                                toolName: call.name,
                                json: AssistantJSON.make(payload),
                                summary: L("Need user confirmation to match Jira user for “%@”.", unresolvedQuery)
                            )
                        }
                    } else {
                        throw JiraConnectorError.badRequest(detail)
                    }
                }
                let rows: [AssistantJSON] = issues.map { issue in
                    .object(
                        ("key", .string(issue.key)),
                        ("summary", .string(issue.summary)),
                        ("status", .string(issue.statusName)),
                        ("assignee", .string(issue.assigneeName ?? ""))
                    )
                }
                return .init(
                    callID: call.id,
                    toolName: call.name,
                    json: .object(("jql", .string(finalJQL)), ("issues", .array(rows))),
                    summary: L("Found %ld Jira issues.", rows.count)
                )
            default:
                throw AssistantAgentError.invalidArguments(call.name, "Unsupported Jira operation \(operation)")
            }
        })
    }

    private static func registerManagePeopleTool(
        into registry: AssistantAgentToolRegistry,
        attention: AttentionCoordinator,
        snapshot: AssistantNativeSnapshot,
        allowPrivilegedActions: Bool,
        allowedToolGroups: Set<AssistantSkillToolGroup>? = nil
    ) {
        let allowsTasksOrJira = (allowedToolGroups?.contains(.tasks) ?? true)
            || (allowedToolGroups?.contains(.jira) ?? true)
        guard allowsTasksOrJira else { return }
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_manage_people",
                description: "Look up active meeting participants and member name-to-Jira mappings, or upsert aliases and Jira handles in Knowledge/People.md.",
                arguments: [
                    .init(name: "operation", type: .string, required: true, allowedValues: ["lookup", "upsert"]),
                    .init(name: "query", type: .string, required: false),
                    .init(name: "display_name", type: .string, required: false),
                    .init(name: "jira_username", type: .string, required: false),
                    .init(name: "jira_account_id", type: .string, required: false),
                    .init(name: "email", type: .string, required: false),
                    .init(name: "role", type: .string, required: false),
                    .init(name: "approved_voice_commander", type: .boolean, required: false),
                    .init(name: "aliases", type: .array, required: false),
                    .init(name: "notes", type: .string, required: false),
                ]
            )
        ) { call, args in
            let op = args["operation"]?.stringValue ?? "lookup"
            if op == "upsert" {
                guard let name = args["display_name"]?.stringValue?.trimmed, !name.isEmpty else {
                    throw AssistantAgentError.missingArgument(call.name, "display_name")
                }
                let rawAliases = args["aliases"]?.arrayValue?.compactMap(\.stringValue)
                    ?? args["aliases"]?.stringValue.map {
                        $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } ?? []
                let explicitApproved = args["approved_voice_commander"]?.boolValue
                let allowPrivilegeChange = allowPrivilegedActions && (explicitApproved != nil)
                let entry = AssistantPersonEntry(
                    displayName: name,
                    aliases: rawAliases,
                    jiraUsername: args["jira_username"]?.stringValue,
                    jiraAccountID: args["jira_account_id"]?.stringValue,
                    email: args["email"]?.stringValue,
                    role: args["role"]?.stringValue,
                    approvedVoiceCommander: allowPrivilegeChange ? (explicitApproved ?? false) : false,
                    notes: args["notes"]?.stringValue
                )
                let updated = try await attention.upsertPersonMapping(
                    entry,
                    allowPrivilegeChange: allowPrivilegeChange
                )
                return .init(
                    callID: call.id,
                    toolName: call.name,
                    json: .object(["saved": .bool(true), "count": .int(updated.entries.count), "id": .string(entry.id)]),
                    summary: L("Saved team mapping for %@ in People.md.", entry.displayName)
                )
            } else {
                let directory = await attention.loadPeopleDirectory()
                let query = args["query"]?.stringValue?.trimmed ?? ""
                let matches: [AssistantPersonEntry]
                if query.isEmpty {
                    matches = directory.entries
                } else if let best = directory.resolvePerson(matching: query) {
                    matches = [best]
                } else {
                    matches = []
                }
                let items: [AssistantJSON] = matches.map { p in
                    .object(
                        ("id", .string(p.id)),
                        ("display_name", .string(p.displayName)),
                        ("aliases", .strings(p.aliases)),
                        ("jira_username", AssistantJSON.optionalString(p.jiraUsername)),
                        ("jira_account_id", AssistantJSON.optionalString(p.jiraAccountID)),
                        ("email", AssistantJSON.optionalString(p.email)),
                        ("role", AssistantJSON.optionalString(p.role)),
                        ("approved_voice_commander", .bool(p.approvedVoiceCommander))
                    )
                }
                let activeMeeting = snapshot.contextMeetingID.flatMap { id in
                    snapshot.meetings.first(where: { $0.id == id })
                } ?? snapshot.meetings.first(where: \.active)
                let rawParticipants = activeMeeting.map { [$0.displayName] + $0.participants } ?? []
                let participantRows: [AssistantJSON] = AssistantPersonEntry.deduped(rawParticipants).map { participantName in
                    let matched = directory.resolvePerson(matching: participantName)
                    return .object(
                        ("name", .string(participantName)),
                        ("matched_id", AssistantJSON.optionalString(matched?.id)),
                        ("jira_username", AssistantJSON.optionalString(matched?.jiraUsername)),
                        ("jira_account_id", AssistantJSON.optionalString(matched?.jiraAccountID))
                    )
                }
                return .init(
                    callID: call.id,
                    toolName: call.name,
                    json: .object([
                        "items": .array(items),
                        "meeting_participants": .array(participantRows),
                    ]),
                    summary: L("Matched %ld people.", items.count)
                )
            }
        })
    }

    // MARK: - Authorized Write & Computer Use Tools

    private static func registerWriteAndControlTools(
        into registry: AssistantAgentToolRegistry,
        attention: AttentionCoordinator,
        talk: AssistantTalkController,
        snapshot: AssistantNativeSnapshot,
        allowedToolGroups: Set<AssistantSkillToolGroup>? = nil
    ) {
        func allows(_ group: AssistantSkillToolGroup) -> Bool {
            allowedToolGroups?.contains(group) ?? true
        }

        if allows(.tasks) || allows(.jira) {
            registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_create_task",
                description: "Create a task in the selected/target meeting or standalone Assistant Tasks, resolving owner aliases via People.md and optionally syncing to Jira.",
                arguments: [
                    .init(name: "title", type: .string, required: true, description: "Task description."),
                    .init(name: "owner", type: .string, required: false, description: "Owner name or spoken alias."),
                    .init(name: "meeting_id", type: .string, required: false, description: "Optional session UUID."),
                    .init(name: "due_day", type: .string, required: false, description: "Optional YYYY-MM-DD due day."),
                    .init(name: "notes", type: .string, required: false, description: "Optional context notes."),
                    .init(name: "sync_to_jira", type: .boolean, required: false, description: "Create in Jira if enabled."),
                ]
            )
        ) { call, args in
            guard let title = args["title"]?.stringValue?.trimmed, !title.isEmpty else {
                throw AssistantAgentError.missingArgument(call.name, "title")
            }
            let meetingID = args["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? snapshot.contextMeetingID
            let created = try await attention.createTaskAction(
                sessionID: meetingID,
                title: title,
                owner: args["owner"]?.stringValue,
                dueDay: args["due_day"]?.stringValue,
                notes: args["notes"]?.stringValue,
                syncToJira: args["sync_to_jira"]?.boolValue ?? false
            )
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(
                    ("task_id", .string("task:native:\(created.outcomeID.uuidString):\(created.task.id.uuidString)")),
                    ("text", .string(created.task.text)),
                    ("owner", .string(created.task.owner)),
                    ("jira_synced", .bool(created.syncedJira))
                ),
                summary: created.task.owner.isEmpty
                    ? L("Created task “%@”.", created.task.text)
                    : L("Created task “%@” for %@.", created.task.text, created.task.owner)
            )
        })

        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_update_task",
                description: "Update an existing task's text, owner/assignee (via People.md), completion state, due_day, or Jira status.",
                arguments: [
                    .init(name: "task_id", type: .string, required: true, description: "Task identifier task:native:<outcomeUUID>:<taskUUID> or task UUID."),
                    .init(name: "text", type: .string, required: false),
                    .init(name: "owner", type: .string, required: false),
                    .init(name: "done", type: .boolean, required: false),
                    .init(name: "due_day", type: .string, required: false),
                    .init(name: "jira_status", type: .string, required: false),
                    .init(name: "sync_to_jira", type: .boolean, required: false),
                ]
            )
        ) { call, args in
            guard let rawTaskID = args["task_id"]?.stringValue?.trimmed, !rawTaskID.isEmpty else {
                throw AssistantAgentError.missingArgument(call.name, "task_id")
            }
            let parts = rawTaskID.split(separator: ":").map(String.init)
            var outcomeID: UUID?
            var taskUUID: UUID?
            if parts.count == 4, parts[0] == "task", parts[1] == "native" {
                outcomeID = UUID(uuidString: parts[2])
                taskUUID = UUID(uuidString: parts[3])
            } else if let direct = UUID(uuidString: rawTaskID) {
                taskUUID = direct
                let allRows = await attention.loadWorkspaceTaskRecords()
                outcomeID = allRows.first(where: { $0.id == direct })?.outcomeID
            }
            guard let resolvedOutcome = outcomeID, let resolvedTask = taskUUID else {
                return .error(call, L("Task “%@” was not found.", rawTaskID))
            }
            var resolvedOwner = args["owner"]?.stringValue?.trimmed
            var resolvedAssigneeID: String?
            if let candidateOwner = resolvedOwner, !candidateOwner.isEmpty {
                let directory = await attention.loadPeopleDirectory()
                if let person = directory.resolvePerson(matching: candidateOwner) {
                    resolvedOwner = person.displayName
                    resolvedAssigneeID = person.jiraAccountID ?? person.jiraUsername ?? person.id
                }
            }
            let newText = args["text"]?.stringValue
            let newDone = args["done"]?.boolValue
            let dueDay = args["due_day"]?.stringValue
            let jiraStatus = args["jira_status"]?.stringValue
            let updatedCommit = try await attention.store.publishOutcomeMutation {
                try await attention.store.meetingLibrary.store.changeTask(outcomeID: resolvedOutcome, taskID: resolvedTask) { task in
                    if let newText { task.text = newText }
                    if let resolvedOwner, resolvedOwner != task.owner {
                        task.owner = resolvedOwner
                        task.assigneeID = resolvedAssigneeID
                        task.reminderAt = nil
                    } else if let resolvedAssigneeID, task.assigneeID == nil {
                        task.assigneeID = resolvedAssigneeID
                    }
                    if let newDone { task.setDone(newDone) }
                    if let dueDay {
                        let c = dueDay.trimmed
                        task.dueDay = c.isEmpty ? nil : c
                    }
                    if let jiraStatus, let mapped = TaskWorkflowStatus.fromExternalStatus(jiraStatus) {
                        task.extended.workflowStatus = mapped
                        task.setDone(mapped.isTerminalDone)
                    }
                }
            }
            guard updatedCommit != nil else {
                return .error(call, L("Task “%@” was not found.", rawTaskID))
            }
            await attention.store.meetingLibrary.refresh()
            let shouldSyncJira = await MainActor.run {
                args["sync_to_jira"]?.boolValue == true && attention.taskSync.preferences.jira.enabled
            }
            if shouldSyncJira {
                await attention.taskSync.runSync(explicitTaskIDs: [resolvedTask], automaticTrigger: true)
            }
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(["updated": .bool(true), "task_id": .string("task:native:\(resolvedOutcome.uuidString):\(resolvedTask.uuidString)")]),
                summary: L("Updated the task.")
            )
        })
        }

        if allows(.calendarSchedule) {
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_schedule_meeting",
                description: "Schedule a new meeting on Apple Calendar with start/end ISO 8601 timestamps, optional join link and agenda.",
                arguments: [
                    .init(name: "title", type: .string, required: true, description: "Meeting title."),
                    .init(name: "start_at", type: .string, required: true, description: "ISO 8601 start date-time with offset."),
                    .init(name: "end_at", type: .string, required: true, description: "ISO 8601 end date-time with offset."),
                    .init(name: "meeting_url", type: .string, required: false),
                    .init(name: "agenda_notes", type: .string, required: false),
                ]
            )
        ) { call, args in
            guard let title = args["title"]?.stringValue?.trimmed, !title.isEmpty,
                  let start = args["start_at"]?.stringValue.flatMap(AssistantTime.parse),
                  let end = args["end_at"]?.stringValue.flatMap(AssistantTime.parse),
                  end > start else {
                throw AssistantAgentError.invalidArguments(call.name, "title, start_at and later end_at are required")
            }
            let linked = try await attention.scheduleCalendarMeetingAction(
                title: title,
                startAt: start,
                endAt: end,
                meetingURL: args["meeting_url"]?.stringValue,
                agendaNotes: args["agenda_notes"]?.stringValue ?? ""
            )
            let calendarName = linked.calendarTitle?.trimmed.isEmpty == false
                ? (linked.calendarTitle ?? L("Calendar"))
                : L("Calendar")
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(
                    ("title", .string(linked.title)),
                    ("calendar", .string(calendarName)),
                    ("start_at", .date(linked.startAt)),
                    ("end_at", .date(linked.endAt))
                ),
                summary: L("Scheduled “%@” in %@.", linked.title, calendarName)
            )
        })
        }

        if allows(.meetingSummary) {
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_update_meeting_artifacts",
                description: "Update the current or target meeting summary, decisions, open questions, or action items.",
                arguments: [
                    .init(name: "meeting_id", type: .string, required: false, description: "Optional session or outcome UUID; defaults to selected active meeting."),
                    .init(name: "summary_append", type: .string, required: false),
                    .init(name: "replace_summary", type: .string, required: false),
                    .init(name: "decisions", type: .array, required: false, description: "List of decision strings."),
                    .init(name: "open_questions", type: .array, required: false, description: "List of open question strings."),
                ],
                allowsArbitraryArguments: true
            )
        ) { call, args in
            let meetingUUID = args["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? snapshot.contextMeetingID
            guard let meetingUUID else {
                return .error(call, L("Select or specify a meeting first."))
            }
            let decisions = args["decisions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let questions = args["open_questions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let rawTasks = args["action_items"]?.arrayValue ?? []
            let tasks: [(text: String, owner: String, dueDay: String?)] = rawTasks.compactMap { item in
                guard let text = item["text"]?.stringValue?.trimmed, !text.isEmpty else { return nil }
                return (text, item["owner"]?.stringValue ?? "", item["due_day"]?.stringValue)
            }
            guard let updated = try await attention.updateMeetingArtifactsAction(
                outcomeID: nil,
                sessionID: meetingUUID,
                summaryAppend: args["summary_append"]?.stringValue,
                replaceSummary: args["replace_summary"]?.stringValue,
                addDecisions: decisions,
                addOpenQuestions: questions,
                addTasks: tasks
            ) else {
                return .error(call, L("Could not update that meeting's artifacts."))
            }
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(
                    ("outcome_id", .string(updated.id.uuidString)),
                    ("decisions", .int(updated.decisions.count)),
                    ("tasks", .int(updated.tasks.count))
                ),
                summary: L("Updated summary and artifacts for “%@”.", updated.meetingTitle)
            )
        })
        }

        if allows(.obsidianSearch) || allows(.tasks) {
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_upsert_skill",
                description: "Create or update an Obsidian-backed Rock Assistant Markdown skill file.",
                arguments: [
                    .init(name: "skill_id", type: .string, required: true),
                    .init(name: "name", type: .string, required: true),
                    .init(name: "role", type: .string, required: false),
                    .init(name: "instructions", type: .string, required: true),
                    .init(name: "enabled", type: .boolean, required: false),
                ],
                allowsArbitraryArguments: true
            )
        ) { call, args in
            guard let skillID = args["skill_id"]?.stringValue?.trimmed, !skillID.isEmpty,
                  let name = args["name"]?.stringValue?.trimmed, !name.isEmpty,
                  let instructions = args["instructions"]?.stringValue?.trimmed, !instructions.isEmpty else {
                throw AssistantAgentError.missingArgument(call.name, "skill_id, name, instructions")
            }
            let skill = AssistantSkill(
                id: skillID,
                name: name,
                role: args["role"]?.stringValue ?? "",
                enabled: args["enabled"]?.boolValue ?? true,
                voiceActivation: args["voice_activation"]?.boolValue ?? true,
                triggers: args["triggers"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                tools: AssistantSkillToolGroup.allCases,
                approvedSpeakersOnly: args["approved_speakers_only"]?.boolValue ?? true,
                realtimePreferred: args["realtime_preferred"]?.boolValue ?? false,
                instructions: instructions
            )
            let saved = try await attention.saveAssistantSkill(skill)
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(["id": .string(saved.id), "path": .string(saved.sourceRelativePath ?? "")]),
                summary: L("Saved Obsidian skill “%@”.", saved.name)
            )
        })
        }

        if allows(.boardShare) {
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_control_board",
                description: "Open, inspect, capture a visual snapshot, filter, scroll, click (CSS/text or normalized canvas coordinates), highlight, or share the in-app Jira/Board browser window into an active meeting.",
                arguments: [
                    .init(name: "command", type: .string, required: true,
                          allowedValues: ["open_url", "share_to_meeting", "stop_share", "scroll", "filter", "click", "click_at", "highlight", "inspect", "snapshot"]),
                    .init(name: "url", type: .string, required: false),
                    .init(name: "meeting_id", type: .string, required: false, description: "Active session UUID; defaults to selected meeting."),
                    .init(name: "query", type: .string, required: false),
                    .init(name: "selector", type: .string, required: false),
                    .init(name: "text", type: .string, required: false),
                    .init(name: "delta_y", type: .integer, required: false),
                    .init(name: "x", type: .number, required: false, description: "Horizontal coordinate for click_at (normalized 0.0...1.0 unless normalized=false)."),
                    .init(name: "y", type: .number, required: false, description: "Vertical coordinate for click_at (normalized 0.0...1.0 unless normalized=false)."),
                    .init(name: "normalized", type: .boolean, required: false),
                ]
            )
        ) { call, args in
            guard let command = args["command"]?.stringValue else {
                throw AssistantAgentError.missingArgument(call.name, "command")
            }
            let board = attention.boardController
            switch command {
            case "open_url":
                let team = await attention.loadTeamContext()
                let urlToOpen = args["url"]?.stringValue?.trimmed.isEmpty == false
                    ? (args["url"]?.stringValue ?? "")
                    : team.defaultJiraBoardURL
                let msg = try await board.open(urlString: urlToOpen)
                return .init(callID: call.id, toolName: call.name, json: .object(["message": .string(msg)]), summary: msg)
            case "share_to_meeting":
                let targetID = args["meeting_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? snapshot.contextMeetingID
                let model = await MainActor.run {
                    targetID.flatMap { id in
                        attention.meetings().first(where: { $0.sessionID == id && !$0.isClosed })
                    }
                }
                guard let model else {
                    return .error(call, L("Join or select an active meeting before sharing the board."))
                }
                let rawURL = args["url"]?.stringValue?.trimmed ?? ""
                let urlToOpen: String?
                if !rawURL.isEmpty {
                    urlToOpen = rawURL
                } else if await MainActor.run(body: { board.currentURL == nil }) {
                    let team = await attention.loadTeamContext()
                    let fallback = team.defaultJiraBoardURL.trimmed
                    urlToOpen = fallback.isEmpty ? nil : fallback
                } else {
                    urlToOpen = nil
                }
                if let urlToOpen {
                    _ = try await board.open(urlString: urlToOpen)
                }
                let msg = try await board.startSharing(to: model)
                return .init(callID: call.id, toolName: call.name, json: .object(["sharing": .bool(true)]), summary: msg)
            case "stop_share":
                await MainActor.run {
                    board.stopSharing()
                }
                return .init(callID: call.id, toolName: call.name, json: .object(["sharing": .bool(false)]), summary: L("Stopped sharing the Assistant Board."))
            case "scroll":
                let msg = try await board.scroll(deltaY: args["delta_y"]?.intValue ?? 450)
                return .init(callID: call.id, toolName: call.name, json: .object(["message": .string(msg)]), summary: msg)
            case "filter":
                let msg = try await board.filter(query: args["query"]?.stringValue ?? args["text"]?.stringValue ?? "")
                return .init(callID: call.id, toolName: call.name, json: .object(["message": .string(msg)]), summary: msg)
            case "click":
                let msg = try await board.click(selector: args["selector"]?.stringValue, text: args["text"]?.stringValue)
                return .init(callID: call.id, toolName: call.name, json: .object(["message": .string(msg)]), summary: msg)
            case "click_at":
                guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else {
                    throw AssistantAgentError.missingArgument(call.name, "x, y")
                }
                let normalized = args["normalized"]?.boolValue ?? true
                let msg = try await board.clickAt(x: x, y: y, normalized: normalized)
                return .init(callID: call.id, toolName: call.name, json: .object(["message": .string(msg)]), summary: msg)
            case "highlight":
                let msg = try await board.highlight(text: args["text"]?.stringValue ?? args["query"]?.stringValue ?? "")
                return .init(callID: call.id, toolName: call.name, json: .object(["message": .string(msg)]), summary: msg)
            case "inspect":
                let info = try await board.inspect()
                return .init(callID: call.id, toolName: call.name, json: AssistantJSON.make(info), summary: L("Inspected the visible Assistant Board."))
            case "snapshot":
                let snap = try await board.snapshotBase64()
                return .init(
                    callID: call.id,
                    toolName: call.name,
                    json: .object(
                        ("width", .int(snap.width)),
                        ("height", .int(snap.height)),
                        ("mime_type", .string("image/jpeg")),
                        ("image_base64", .string(snap.jpegBase64))
                    ),
                    summary: L("Captured board snapshot (%ld×%ld).", snap.width, snap.height)
                )
            default:
                throw AssistantAgentError.invalidArguments(call.name, "Unsupported command \(command)")
            }
        })
        }

        if allows(.meetingJoin) {
        registry.register(AgentSkillClosureTool(
            descriptor: .init(
                name: "rocknroll_join_meetings",
                description: "Join one or more meetings by title query, optional skill role (e.g. scrum-master), and enable in-meeting voice facilitation.",
                arguments: [
                    .init(name: "queries", type: .array, required: true, description: "One or more meeting titles or keywords to match and join."),
                    .init(name: "skill_id", type: .string, required: false, description: "Optional skill slug to activate in the joined meeting(s)."),
                    .init(name: "enable_voice_facilitation", type: .boolean, required: false),
                ]
            )
        ) { call, args in
            let queries = args["queries"]?.arrayValue?.compactMap(\.stringValue).filter { !$0.trimmed.isEmpty } ?? []
            guard !queries.isEmpty else {
                throw AssistantAgentError.missingArgument(call.name, "queries")
            }
            let outcome = await Self.joinMeetingsByQueries(
                queries,
                skillID: args["skill_id"]?.stringValue,
                enableFacilitation: args["enable_voice_facilitation"]?.boolValue ?? true,
                attention: attention,
                talk: talk
            )
            return .init(
                callID: call.id,
                toolName: call.name,
                json: .object(["joined": .strings(outcome.joinedTitles), "unmatched": .strings(outcome.unmatched)]),
                summary: outcome.summary
            )
        })
        }
    }

    /// Joins 1+ calendar/room targets matching `queries` and binds the requested skill + facilitator.
    @MainActor
    static func joinMeetingsByQueries(
        _ queries: [String],
        skillID: String?,
        enableFacilitation: Bool,
        attention: AttentionCoordinator,
        talk: AssistantTalkController
    ) async -> (joinedTitles: [String], unmatched: [String], summary: String) {
        let now = attention.now()
        let candidates = attention.joinableTargets(now)
        var joinedTitles: [String] = []
        var unmatched: [String] = []
        var seenIDs: Set<UUID> = []

        for query in queries {
            let needle = query.trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard !needle.isEmpty else { continue }
            let match: JoinableMeetingCandidate?
            if ["current", "текущая", "текущую", "сейчас"].contains(needle) {
                match = CurrentMeetingTargetResolver.bestCurrentMeeting(from: candidates, now: now)
            } else {
                match = candidates.first(where: {
                    $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
                })
            }
            guard let candidate = match else {
                unmatched.append(query)
                continue
            }
            let targetID = candidate.activeSessionID ?? candidate.id
            guard seenIDs.insert(targetID).inserted else { continue }
            let ref = AssistantMeetingReference(
                id: targetID,
                title: candidate.title,
                invitation: candidate.invitation,
                active: candidate.activeSessionID != nil
            )
            if enableFacilitation, let skillID, !skillID.trimmed.isEmpty {
                attention.facilitator?.queuePendingSkill(skillID, title: ref.title, invitation: ref.invitation)
            }
            if talk.joinMeeting(ref) {
                joinedTitles.append(ref.title)
                if enableFacilitation,
                   let live = attention.meetings().first(where: {
                       !$0.isClosed && ($0.sessionID == targetID || $0.invitation == candidate.invitation)
                   }) {
                    attention.facilitator?.enable(for: live, skillID: skillID)
                }
            } else {
                unmatched.append(query)
            }
        }

        let summary: String
        if joinedTitles.isEmpty {
            summary = L("Could not find a matching meeting with a join link for: %@", queries.joined(separator: ", "))
        } else if unmatched.isEmpty {
            summary = L("Joined meetings: %@", joinedTitles.joined(separator: ", "))
        } else {
            summary = L("Joined %@; could not match: %@", joinedTitles.joined(separator: ", "), unmatched.joined(separator: ", "))
        }
        return (joinedTitles, unmatched, summary)
    }

    private static func jsonSchemaType(_ kind: AssistantValueKind) -> String {
        switch kind {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func jsonStringLiteral(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"error\""
    }
}

private struct AgentSkillClosureTool: AssistantAgentTool {
    let descriptor: AssistantAgentToolDescriptor
    let body: @Sendable (AssistantAgentToolCall, AssistantJSON) async throws -> AssistantAgentToolResult

    func validate(_ arguments: AssistantJSON) throws -> AssistantJSON { arguments }

    func execute(_ call: AssistantAgentToolCall, arguments: AssistantJSON) async throws -> AssistantAgentToolResult {
        try await body(call, arguments)
    }
}
