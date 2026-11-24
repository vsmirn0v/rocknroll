import ConferenceCore
import Foundation

extension NativeDesktopMCPBackend {
    // MARK: - Task, Schedule, Artifact, Skill, People & Board MCP Handlers

    func createTask(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let rawTitle = try MCPValue.string(args["title"], key: "title")
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "title must not be empty.", details: ["field": "title", "reason": "empty"])
        }
        let meetingID = try MCPValue.optionalString(args["meeting_id"], key: "meeting_id")
        let owner = try MCPValue.optionalString(args["owner"], key: "owner")
        let dueDay = try MCPValue.optionalString(args["due_day"], key: "due_day")
        let notes = try MCPValue.optionalString(args["notes"], key: "notes")
        let syncToJira = try MCPValue.optionalBool(args["sync_to_jira"], key: "sync_to_jira") ?? false

        var sessionUUID: UUID?
        var outcomeUUID: UUID?
        if let meetingID, !meetingID.isEmpty {
            if meetingID.hasPrefix("outcome:") {
                let raw = meetingID.split(separator: ":").last.map(String.init) ?? ""
                guard let parsed = UUID(uuidString: raw) else {
                    throw MCPToolFailure("MEETING_NOT_FOUND", "The requested outcome is unavailable.")
                }
                outcomeUUID = parsed
            } else if meetingID.hasPrefix("session:") {
                let raw = meetingID.split(separator: ":").last.map(String.init) ?? ""
                guard let parsed = UUID(uuidString: raw) else {
                    throw MCPToolFailure("MEETING_NOT_FOUND", "The requested session is unavailable.")
                }
                sessionUUID = parsed
            } else if let parsed = UUID(uuidString: meetingID) {
                sessionUUID = parsed
            } else {
                throw MCPToolFailure("INVALID_ARGUMENT", "meeting_id must be a session: or outcome: identifier.",
                                     details: ["field": "meeting_id", "reason": "format"])
            }
        }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        guard await actions.approval("Create task", ["title": title, "owner": owner ?? "", "sync_to_jira": syncToJira]) else {
            return actions.finish(id, client: client, type: "task", target: title, status: "rejected", failure: "APPROVAL_DENIED")
        }

        do {
            let created = try await attention.createTaskAction(
                sessionID: sessionUUID,
                outcomeID: outcomeUUID,
                title: title,
                owner: owner,
                dueDay: dueDay,
                notes: notes,
                syncToJira: syncToJira
            )
            let taskOpaqueID = mcpTaskID(created.outcomeID, created.task)
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "entity_id": taskOpaqueID,
                "revision": created.outcomeID.uuidString,
                "task": [
                    "id": taskOpaqueID,
                    "text": created.task.text,
                    "owner": created.task.owner,
                    "due_day": created.task.dueDay ?? "",
                    "jira_synced": created.syncedJira,
                ],
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "task", target: taskOpaqueID, status: "applied", result: result)
        } catch {
            _ = actions.finish(id, client: client, type: "task", target: title, status: "failed", failure: "task_create_failed")
            throw error
        }
    }

    func scheduleMeeting(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let title = (try MCPValue.string(args["title"], key: "title")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "title must not be empty.", details: ["field": "title", "reason": "empty"])
        }
        guard let startAt = try MCPValue.date(args["start_at"], key: "start_at") else {
            throw MCPToolFailure("INVALID_ARGUMENT", "start_at must be RFC 3339 date-time.", details: ["field": "start_at", "reason": "format"])
        }
        guard let endAt = try MCPValue.date(args["end_at"], key: "end_at"), endAt > startAt else {
            throw MCPToolFailure("INVALID_ARGUMENT", "end_at must be later than start_at.", details: ["field": "end_at", "reason": "range"])
        }
        let meetingURL = try MCPValue.optionalString(args["meeting_url"], key: "meeting_url")
        let agendaNotes = try MCPValue.optionalString(args["agenda_notes"], key: "agenda_notes") ?? ""
        let calendarID = try MCPValue.optionalString(args["calendar_id"], key: "calendar_id")
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        guard await actions.approval("Schedule meeting", ["title": title, "start_at": args["start_at"] as Any, "end_at": args["end_at"] as Any]) else {
            return actions.finish(id, client: client, type: "calendar", target: title, status: "rejected", failure: "APPROVAL_DENIED")
        }

        do {
            let linked = try await attention.scheduleCalendarMeetingAction(
                title: title,
                startAt: startAt,
                endAt: endAt,
                meetingURL: meetingURL,
                agendaNotes: agendaNotes,
                calendarID: calendarID
            )
            let entityID = linked.calendarEventIdentifier ?? title
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "entity_id": entityID,
                "title": linked.title,
                "calendar": linked.calendarTitle ?? "",
                "start_at": mcpDate(linked.startAt) ?? "",
                "end_at": mcpDate(linked.endAt) ?? "",
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "calendar", target: entityID, status: "applied", result: result)
        } catch {
            _ = actions.finish(id, client: client, type: "calendar", target: title, status: "failed", failure: "calendar_schedule_failed")
            throw error
        }
    }

    func updateMeetingArtifacts(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let meetingID = try MCPValue.string(args["meeting_id"], key: "meeting_id")
        let summaryAppend = try MCPValue.optionalString(args["summary_append"], key: "summary_append")
        let replaceSummary = try MCPValue.optionalString(args["replace_summary"], key: "replace_summary")
        let decisions = args["decisions"] as? [String] ?? []
        let openQuestions = args["open_questions"] as? [String] ?? []
        let rawItems = args["action_items"] as? [MCPJSON] ?? []
        let addTasks: [(text: String, owner: String, dueDay: String?)] = rawItems.compactMap { item in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return (text, (item["owner"] as? String) ?? "", item["due_day"] as? String)
        }

        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        var sessionUUID: UUID?
        var outcomeUUID: UUID?
        if meetingID.hasPrefix("outcome:") {
            outcomeUUID = meetingID.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) }
        } else {
            sessionUUID = meetingID.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) } ?? UUID(uuidString: meetingID)
        }
        guard sessionUUID != nil || outcomeUUID != nil else {
            throw MCPToolFailure("MEETING_NOT_FOUND", "The requested meeting is unavailable.")
        }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        guard let updated = try await attention.updateMeetingArtifactsAction(
            outcomeID: outcomeUUID,
            sessionID: sessionUUID,
            summaryAppend: summaryAppend,
            replaceSummary: replaceSummary,
            addDecisions: decisions,
            addOpenQuestions: openQuestions,
            addTasks: addTasks
        ) else {
            throw MCPToolFailure("MEETING_NOT_FOUND", "No meeting or outcome was found for \(meetingID).")
        }

        let result: MCPJSON = [
            "action_id": id,
            "status": "applied",
            "observed_at": mcpNow(),
            "entity_id": mcpOutcomeID(updated.id),
            "decision_count": updated.decisions.count,
            "task_count": updated.tasks.count,
            "open_question_count": updated.openQuestions.count,
            "warnings": [],
        ]
        return actions.finish(id, client: client, type: "outcome", target: updated.id.uuidString, status: "applied", result: result)
    }

    func listSkills(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let query = try MCPValue.optionalString(args["query"], key: "query") ?? ""
        let enabledOnly = try MCPValue.optionalBool(args["enabled_only"], key: "enabled_only") ?? false
        let storage = await attention.skillStorageSummary()
        let skills = await attention.withSkillRepository { repo, _ in
            repo.searchSkills(query: query, enabledOnly: enabledOnly)
        }
        let items: [MCPJSON] = skills.map { skill in
            [
                "id": skill.id,
                "name": skill.name,
                "role": skill.role,
                "enabled": skill.enabled,
                "voice_activation": skill.voiceActivation,
                "approved_speakers_only": skill.approvedSpeakersOnly,
                "realtime_preferred": skill.realtimePreferred,
                "triggers": skill.triggers,
                "tools": skill.tools.map(\.rawValue),
                "path": skill.sourceRelativePath ?? "",
            ]
        }
        return [
            "items": items,
            "obsidian_backed": storage.isObsidianBacked,
            "storage_root": storage.folderPath,
            "observed_at": mcpNow(),
            "coverage": "complete",
            "warnings": [],
        ]
    }

    func getSkill(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let skillID = try MCPValue.string(args["skill_id"], key: "skill_id")
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let skill = await attention.withSkillRepository { repo, _ in repo.skill(id: skillID) }
        guard let skill else {
            throw MCPToolFailure("NOT_FOUND", "Skill \(skillID) was not found.")
        }
        return [
            "id": skill.id,
            "name": skill.name,
            "role": skill.role,
            "enabled": skill.enabled,
            "voice_activation": skill.voiceActivation,
            "approved_speakers_only": skill.approvedSpeakersOnly,
            "realtime_preferred": skill.realtimePreferred,
            "triggers": skill.triggers,
            "tools": skill.tools.map(\.rawValue),
            "instructions": skill.instructions,
            "path": skill.sourceRelativePath ?? "",
            "observed_at": mcpNow(),
            "coverage": "complete",
            "warnings": [],
        ]
    }

    func upsertSkill(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let skillID = try MCPValue.string(args["skill_id"], key: "skill_id")
        let name = try MCPValue.string(args["name"], key: "name")
        let instructions = try MCPValue.string(args["instructions"], key: "instructions")
        let role = try MCPValue.optionalString(args["role"], key: "role") ?? ""
        let enabled = try MCPValue.optionalBool(args["enabled"], key: "enabled") ?? true
        let voiceActivation = try MCPValue.optionalBool(args["voice_activation"], key: "voice_activation") ?? true
        let approvedOnly = try MCPValue.optionalBool(args["approved_speakers_only"], key: "approved_speakers_only") ?? true
        let realtimePreferred = try MCPValue.optionalBool(args["realtime_preferred"], key: "realtime_preferred") ?? false
        let triggers = args["triggers"] as? [String] ?? []
        let toolStrings = args["tools"] as? [String] ?? AssistantSkillToolGroup.allCases.map(\.rawValue)
        let toolGroups = toolStrings.compactMap(AssistantSkillToolGroup.init(rawValue:))

        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        guard await actions.approval("Update skill", ["skill_id": skillID, "name": name]) else {
            return actions.finish(id, client: client, type: "skill", target: skillID, status: "rejected", failure: "APPROVAL_DENIED")
        }

        let skill = AssistantSkill(
            id: skillID,
            name: name,
            role: role,
            enabled: enabled,
            voiceActivation: voiceActivation,
            triggers: triggers,
            tools: toolGroups,
            approvedSpeakersOnly: approvedOnly,
            realtimePreferred: realtimePreferred,
            instructions: instructions
        )
        let saved = try await attention.saveAssistantSkill(skill)
        let result: MCPJSON = [
            "action_id": id,
            "status": "applied",
            "observed_at": mcpNow(),
            "entity_id": saved.id,
            "path": saved.sourceRelativePath ?? "",
            "warnings": [],
        ]
        return actions.finish(id, client: client, type: "skill", target: saved.id, status: "applied", result: result)
    }

    func searchKnowledge(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        let query = (try MCPValue.string(args["query"], key: "query")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "query must not be empty.", details: ["field": "query", "reason": "empty"])
        }
        let limit = try MCPValue.integer(args["limit"], key: "limit", default: 8, maximum: 30)
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let hits = await attention.searchAssistantKnowledge(query: query, limit: limit)
        let items: [MCPJSON] = hits.map { hit in
            [
                "title": hit.title,
                "path": hit.relativePath,
                "kind": hit.kind,
                "excerpt": hit.excerpt,
                "score": hit.score,
            ]
        }
        return [
            "items": items,
            "query": query,
            "observed_at": mcpNow(),
            "coverage": "complete",
            "warnings": [],
        ]
    }

    func managePeople(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let op = try MCPValue.string(args["operation"], key: "operation")
        let query = try MCPValue.optionalString(args["query"], key: "query")
        let displayName = try MCPValue.optionalString(args["display_name"], key: "display_name")
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }

        if op == "upsert" {
            let cleanName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cleanName.isEmpty else {
                throw MCPToolFailure("INVALID_ARGUMENT", "display_name is required for upsert.",
                                     details: ["field": "display_name", "reason": "required"])
            }
            let (id, replay) = try beginAction(args, client: client)
            if let replay { return replay }

            let jiraUsername = try MCPValue.optionalString(args["jira_username"], key: "jira_username")?.trimmed
            let jiraAccountID = try MCPValue.optionalString(args["jira_account_id"], key: "jira_account_id")?.trimmed
            let forceWithoutJira = try MCPValue.optionalBool(args["force_without_jira"], key: "force_without_jira") ?? false
            let directory = await attention.loadPeopleDirectory()
            let existingMatch = directory.resolvePerson(matching: cleanName)
            let hasExistingHandle = !((existingMatch?.jiraAccountID ?? existingMatch?.jiraUsername ?? "").isEmpty)
            let hasNewHandle = !(jiraUsername ?? "").isEmpty || !(jiraAccountID ?? "").isEmpty
            let jiraConnected = await MainActor.run { (try? attention.taskSync.activeJiraConnector()) != nil }

            if !hasNewHandle && !hasExistingHandle && !forceWithoutJira && jiraConnected {
                let team = await attention.loadTeamContext()
                let proj = team.defaultJiraProjectKey.trimmed
                let candidates = (try? await attention.taskSync.searchJiraUsers(
                    query: cleanName,
                    projectKey: proj.isEmpty ? nil : proj,
                    maxResults: 8
                )) ?? []
                let result: MCPJSON = [
                    "action_id": id,
                    "status": "needs_user_confirmation",
                    "observed_at": mcpNow(),
                    "saved": false,
                    "display_name": cleanName,
                    "jira_user_candidates": candidates.map(WorkspaceTaskSyncController.jiraUserPayload),
                    "warnings": [],
                ]
                return actions.finish(id, client: client, type: "people", target: cleanName, status: "needs_user_confirmation", result: result)
            }

            let explicitApproved = try MCPValue.optionalBool(args["approved_voice_commander"], key: "approved_voice_commander")
            let entry = AssistantPersonEntry(
                displayName: cleanName,
                aliases: args["aliases"] as? [String] ?? [],
                jiraUsername: jiraUsername,
                jiraAccountID: jiraAccountID,
                email: try MCPValue.optionalString(args["email"], key: "email"),
                role: try MCPValue.optionalString(args["role"], key: "role"),
                approvedVoiceCommander: explicitApproved ?? false,
                notes: try MCPValue.optionalString(args["notes"], key: "notes")
            )
            let updated = try await attention.upsertPersonMapping(
                entry,
                allowPrivilegeChange: explicitApproved != nil
            )
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "entity_id": entry.id,
                "directory_count": updated.entries.count,
                "jira_bound": hasNewHandle || hasExistingHandle,
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "people", target: entry.id, status: "applied", result: result)
        }

        // Lookup
        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }
        let directory = await attention.loadPeopleDirectory()
        let matches: [AssistantPersonEntry]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let single = directory.resolvePerson(matching: query) {
                matches = [single]
            } else {
                let q = query.lowercased()
                matches = directory.entries.filter {
                    $0.displayName.lowercased().contains(q) ||
                    $0.aliases.contains { $0.lowercased().contains(q) } ||
                    ($0.jiraUsername?.lowercased().contains(q) == true)
                }
            }
        } else {
            matches = directory.entries
        }
        let items: [MCPJSON] = matches.map { p in
            [
                "id": p.id,
                "display_name": p.displayName,
                "aliases": p.aliases,
                "jira_username": p.jiraUsername ?? "",
                "jira_account_id": p.jiraAccountID ?? "",
                "email": p.email ?? "",
                "role": p.role ?? "",
                "approved_voice_commander": p.approvedVoiceCommander,
                "notes": p.notes ?? "",
            ]
        }
        let result: MCPJSON = [
            "action_id": id,
            "status": "applied",
            "observed_at": mcpNow(),
            "items": items,
            "warnings": [],
        ]
        return actions.finish(id, client: client, type: "people", target: query ?? "all", status: "applied", result: result)
    }

    func controlBoard(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let command = try MCPValue.string(args["command"], key: "command")
        let urlString = try MCPValue.optionalString(args["url"], key: "url")
        let meetingID = try MCPValue.optionalString(args["meeting_id"], key: "meeting_id")
        let query = try MCPValue.optionalString(args["query"], key: "query")
        let selector = try MCPValue.optionalString(args["selector"], key: "selector")
        let text = try MCPValue.optionalString(args["text"], key: "text")
        let issueKey = try MCPValue.optionalString(args["issue_key"], key: "issue_key")?.trimmed
        let targetStatus = try MCPValue.optionalString(args["status"], key: "status")?.trimmed
        let comment = try MCPValue.optionalString(args["comment"], key: "comment")
        let deltaY = args["delta_y"] as? Int
        let coordX = (args["x"] as? NSNumber)?.doubleValue
        let coordY = (args["y"] as? NSNumber)?.doubleValue
        let normalized = try MCPValue.optionalBool(args["normalized"], key: "normalized") ?? true

        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }
        let board = attention.boardController

        if command == "open_url" {
            let candidate = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !candidate.isEmpty, AssistantBoardWindowController.validateBoardURL(candidate) != nil else {
                throw MCPToolFailure("INVALID_ARGUMENT", "url must be an https:// or localhost URL.",
                                     details: ["field": "url", "reason": "format"])
            }
        }
        if command == "click_at", (coordX == nil || coordY == nil) {
            throw MCPToolFailure("INVALID_ARGUMENT", "x and y coordinates are required for click_at.",
                                 details: ["field": "x", "reason": "required"])
        }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        guard await actions.approval("Assistant board control", ["command": command, "url": urlString ?? "", "meeting_id": meetingID ?? ""]) else {
            return actions.finish(id, client: client, type: "board", target: command, status: "rejected", failure: "APPROVAL_DENIED")
        }

        switch command {
        case "open_url":
            let message = try await board.open(urlString: urlString ?? "")
            return actions.finish(id, client: client, type: "board", target: "open_url", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "share_to_meeting":
            let resolvedID = try MCPValue.string(args["meeting_id"], key: "meeting_id")
            let model = try activeMeeting(resolvedID)
            let explicitURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let urlToOpen: String?
            if !explicitURL.isEmpty {
                urlToOpen = explicitURL
            } else if board.currentURL == nil {
                let team = await attention.loadTeamContext()
                let fallback = team.defaultJiraBoardURL.trimmed
                urlToOpen = fallback.isEmpty ? nil : fallback
            } else {
                urlToOpen = nil
            }
            if let urlToOpen {
                _ = try await board.open(urlString: urlToOpen)
            }
            let message = try await board.startSharing(to: model)
            return actions.finish(id, client: client, type: "board", target: resolvedID, status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "stop_share":
            board.stopSharing()
            return actions.finish(id, client: client, type: "board", target: "stop_share", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": "Stopped board share.", "warnings": []])
        case "scroll":
            let message = try await board.scroll(deltaY: deltaY ?? 450)
            return actions.finish(id, client: client, type: "board", target: "scroll", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "filter":
            let message = try await board.filter(query: query ?? text ?? "")
            return actions.finish(id, client: client, type: "board", target: "filter", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "select_person_filter":
            let people = await attention.loadPeopleDirectory()
            let message = try await board.selectPersonFilter(query: query ?? text ?? "", people: people)
            return actions.finish(id, client: client, type: "board", target: "select_person_filter", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "clear_filters":
            let message = try await board.clearFilters()
            return actions.finish(id, client: client, type: "board", target: "clear_filters", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "move_issue":
            guard let issueKey, !issueKey.isEmpty,
                  let resolvedStatus = (targetStatus?.isEmpty == false ? targetStatus : text?.trimmed), !resolvedStatus.isEmpty else {
                throw MCPToolFailure("INVALID_ARGUMENT", "issue_key and status are required for move_issue.",
                                     details: ["field": "issue_key", "reason": "required"])
            }
            let updated = try await attention.taskSync.transitionJiraIssue(
                key: issueKey,
                targetStatus: resolvedStatus,
                comment: comment
            )
            return actions.finish(
                id,
                client: client,
                type: "board",
                target: updated.key,
                status: "applied",
                result: [
                    "action_id": id,
                    "status": "applied",
                    "observed_at": mcpNow(),
                    "issue": WorkspaceTaskSyncController.jiraIssuePayload(updated),
                    "warnings": [],
                ]
            )
        case "click":
            let message = try await board.click(selector: selector, text: text)
            return actions.finish(id, client: client, type: "board", target: "click", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "click_at":
            let message = try await board.clickAt(x: coordX ?? 0.5, y: coordY ?? 0.5, normalized: normalized)
            return actions.finish(id, client: client, type: "board", target: "click_at", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "highlight":
            let message = try await board.highlight(text: text ?? query ?? "")
            return actions.finish(id, client: client, type: "board", target: "highlight", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "message": message, "warnings": []])
        case "inspect":
            let info = try await board.inspect()
            return actions.finish(id, client: client, type: "board", target: "inspect", status: "applied",
                                  result: ["action_id": id, "status": "applied", "observed_at": mcpNow(), "board": info, "warnings": []])
        case "snapshot":
            let snap = try await board.snapshotBase64()
            return actions.finish(
                id,
                client: client,
                type: "board",
                target: "snapshot",
                status: "applied",
                result: [
                    "action_id": id,
                    "status": "applied",
                    "observed_at": mcpNow(),
                    "width": snap.width,
                    "height": snap.height,
                    "mime_type": "image/jpeg",
                    "image_base64": snap.jpegBase64,
                    "warnings": [],
                ]
            )
        default:
            throw MCPToolFailure("INVALID_ARGUMENT", "Unsupported board command.")
        }
    }

    func joinMeetings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let rawQueries = (args["queries"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawQueries.isEmpty else {
            throw MCPToolFailure("INVALID_ARGUMENT", "queries must contain at least one non-empty meeting query.",
                                 details: ["field": "queries", "reason": "empty"])
        }
        let skillID = try MCPValue.optionalString(args["skill_id"], key: "skill_id")
        let enableFacilitation = try MCPValue.optionalBool(args["enable_voice_facilitation"], key: "enable_voice_facilitation") ?? true
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        guard await actions.approval("Join meetings", ["queries": rawQueries, "skill_id": skillID ?? ""]) else {
            return actions.finish(id, client: client, type: "meeting_control", target: rawQueries.joined(separator: ", "),
                                  status: "rejected", failure: "APPROVAL_DENIED")
        }

        let outcome = await AssistantSkillToolRegistrar.joinMeetingsByQueries(
            rawQueries,
            skillID: skillID,
            enableFacilitation: enableFacilitation,
            attention: attention,
            talk: attention.talk
        )
        let result: MCPJSON = [
            "action_id": id,
            "status": outcome.joinedTitles.isEmpty ? "no_matches" : "applied",
            "observed_at": mcpNow(),
            "joined": outcome.joinedTitles,
            "unmatched": outcome.unmatched,
            "summary": outcome.summary,
            "warnings": [],
        ]
        return actions.finish(id, client: client, type: "meeting_control",
                              target: outcome.joinedTitles.first ?? rawQueries[0],
                              status: "applied", result: result)
    }

    func jiraAction(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
        _ = try validateActionID(args)
        let operation = try MCPValue.string(args["operation"], key: "operation")
        let rawJQL = try MCPValue.optionalString(args["jql"], key: "jql")
        let query = try MCPValue.optionalString(args["query"], key: "query")
        let assignee = try MCPValue.optionalString(args["assignee"], key: "assignee")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxResults = try MCPValue.integer(args["max_results"], key: "max_results", default: 15, maximum: 50)
        let issueKey = try MCPValue.optionalString(args["issue_key"], key: "issue_key")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = try MCPValue.optionalString(args["comment"], key: "comment")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetStatus = try MCPValue.optionalString(args["status"], key: "status")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = try MCPValue.optionalString(args["role"], key: "role") ?? "assignee"
        let saveToPeopleName = try MCPValue.optionalString(args["save_to_people_name"], key: "save_to_people_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try MCPValue.optionalString(args["summary"], key: "summary")?.trimmingCharacters(in: .whitespacesAndNewlines)

        if operation == "comment" {
            guard let issueKey, !issueKey.isEmpty else {
                throw MCPToolFailure("INVALID_ARGUMENT", "issue_key is required for comment.",
                                     details: ["field": "issue_key", "reason": "required"])
            }
            guard let comment, !comment.isEmpty else {
                throw MCPToolFailure("INVALID_ARGUMENT", "comment is required for comment.",
                                     details: ["field": "comment", "reason": "required"])
            }
        }
        if operation == "transition" && ((issueKey ?? "").isEmpty || (targetStatus ?? "").isEmpty) {
            throw MCPToolFailure("INVALID_ARGUMENT", "issue_key and status are required for transition.",
                                 details: ["field": "issue_key", "reason": "required"])
        }
        if operation == "assign" && (issueKey ?? "").isEmpty {
            throw MCPToolFailure("INVALID_ARGUMENT", "issue_key is required for assign.",
                                 details: ["field": "issue_key", "reason": "required"])
        }
        if operation == "create" && ((summary ?? "").isEmpty) {
            throw MCPToolFailure("INVALID_ARGUMENT", "summary is required for create.",
                                 details: ["field": "summary", "reason": "required"])
        }
        guard let attention else { throw MCPToolFailure("APP_NOT_RUNNING", "The native workspace is unavailable.") }

        let (id, replay) = try beginAction(args, client: client)
        if let replay { return replay }

        if operation == "comment" {
            guard await actions.approval("Add Jira comment", ["issue_key": issueKey ?? "", "comment": comment ?? ""]) else {
                return actions.finish(id, client: client, type: "jira", target: issueKey ?? "", status: "rejected", failure: "APPROVAL_DENIED")
            }
            try await attention.taskSync.commentOnJiraIssue(key: issueKey ?? "", comment: comment ?? "")
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "comment",
                "issue_key": issueKey ?? "",
                "commented": true,
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: issueKey ?? "", status: "applied", result: result)
        }

        if operation == "search_users" {
            let team = await attention.loadTeamContext()
            let cleanQuery = (query ?? assignee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let projectKey = team.defaultJiraProjectKey.trimmed
            let users = try await attention.taskSync.searchJiraUsers(
                query: cleanQuery,
                projectKey: projectKey.isEmpty ? nil : projectKey,
                maxResults: maxResults
            )
            let userRows: [MCPJSON] = users.map(WorkspaceTaskSyncController.jiraUserPayload)
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "search_users",
                "count": userRows.count,
                "users": userRows,
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: cleanQuery, status: "applied", result: result)
        }

        if operation == "board_users" {
            let (users, issues) = try await attention.taskSync.fetchBoardUsersAndIssues(maxResults: max(maxResults, 40))
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "board_users",
                "users": users.map(WorkspaceTaskSyncController.jiraUserPayload),
                "issues": issues.map(WorkspaceTaskSyncController.jiraIssuePayload),
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: "board_users", status: "applied", result: result)
        }

        if operation == "copy_user_from_issue" {
            let (copiedUser, sourceIssueKey) = try await attention.taskSync.copyJiraUserFromIssue(
                issueKey: issueKey,
                searchQuery: query,
                role: role
            )
            var savedToPeople = false
            if let saveToPeopleName, !saveToPeopleName.isEmpty {
                guard await actions.approval("Save Jira user to People.md", ["display_name": saveToPeopleName, "issue_key": sourceIssueKey]) else {
                    return actions.finish(id, client: client, type: "jira", target: sourceIssueKey, status: "rejected", failure: "APPROVAL_DENIED")
                }
                let people = await attention.loadPeopleDirectory()
                let existing = people.resolvePerson(matching: saveToPeopleName)
                let extraAliases = (args["aliases"] as? [String]) ?? []
                var mergedAliases = (existing?.aliases ?? []) + extraAliases
                if existing?.displayName.caseInsensitiveCompare(saveToPeopleName) != .orderedSame {
                    mergedAliases.append(saveToPeopleName)
                }
                let entry = AssistantPersonEntry(
                    id: existing?.id,
                    displayName: existing?.displayName ?? saveToPeopleName,
                    aliases: AssistantPersonEntry.deduped(mergedAliases),
                    jiraUsername: copiedUser.username ?? (copiedUser.isServerOrDC ? copiedUser.identifier : existing?.jiraUsername),
                    jiraAccountID: copiedUser.accountId ?? (!copiedUser.isServerOrDC ? copiedUser.identifier : existing?.jiraAccountID),
                    email: copiedUser.emailAddress ?? existing?.email,
                    role: existing?.role,
                    approvedVoiceCommander: existing?.approvedVoiceCommander ?? false,
                    notes: existing?.notes
                )
                _ = try await attention.upsertPersonMapping(entry, allowPrivilegeChange: false)
                savedToPeople = true
            }
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "copy_user_from_issue",
                "issue_key": sourceIssueKey,
                "copied_user": WorkspaceTaskSyncController.jiraUserPayload(copiedUser),
                "saved_to_people": savedToPeople,
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: sourceIssueKey, status: "applied", result: result)
        }

        if operation == "transition" {
            guard await actions.approval("Transition Jira issue", ["issue_key": issueKey ?? "", "status": targetStatus ?? ""]) else {
                return actions.finish(id, client: client, type: "jira", target: issueKey ?? "", status: "rejected", failure: "APPROVAL_DENIED")
            }
            let updated = try await attention.taskSync.transitionJiraIssue(
                key: issueKey ?? "",
                targetStatus: targetStatus ?? "",
                comment: comment
            )
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "transition",
                "issue": WorkspaceTaskSyncController.jiraIssuePayload(updated),
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: updated.key, status: "applied", result: result)
        }

        if operation == "assign" {
            guard await actions.approval("Assign Jira issue", ["issue_key": issueKey ?? "", "assignee": assignee ?? ""]) else {
                return actions.finish(id, client: client, type: "jira", target: issueKey ?? "", status: "rejected", failure: "APPROVAL_DENIED")
            }
            let assigneeContact: JiraUserContact?
            if let accountID = (try MCPValue.optionalString(args["jira_account_id"], key: "jira_account_id"))?.trimmed, !accountID.isEmpty {
                assigneeContact = JiraUserContact(
                    identifier: accountID,
                    username: try MCPValue.optionalString(args["jira_username"], key: "jira_username")?.trimmed,
                    accountId: accountID,
                    displayName: assignee ?? accountID,
                    isServerOrDC: false
                )
            } else if let username = (try MCPValue.optionalString(args["jira_username"], key: "jira_username"))?.trimmed, !username.isEmpty {
                assigneeContact = JiraUserContact(
                    identifier: username,
                    username: username,
                    accountId: nil,
                    displayName: assignee ?? username,
                    isServerOrDC: true
                )
            } else if let assignee, !assignee.isEmpty {
                let people = await attention.loadPeopleDirectory()
                let team = await attention.loadTeamContext()
                switch await attention.taskSync.resolveJiraAssignee(assignee, people: people, defaultProjectKey: team.defaultJiraProjectKey) {
                case .resolved(let handle, let person):
                    let isDC = !attention.taskSync.preferences.jira.isCloudHost
                    assigneeContact = JiraUserContact(
                        identifier: handle,
                        username: person?.jiraUsername ?? handle,
                        accountId: person?.jiraAccountID,
                        displayName: person?.displayName ?? assignee,
                        isServerOrDC: person?.jiraAccountID == nil && isDC
                    )
                case .unresolved(let unresolvedQuery, let candidates):
                    var result = WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(query: unresolvedQuery, candidates: candidates)
                    result["action_id"] = id
                    result["status"] = "applied"
                    result["observed_at"] = mcpNow()
                    result["operation"] = "assign"
                    result["warnings"] = []
                    return actions.finish(id, client: client, type: "jira", target: unresolvedQuery, status: "applied", result: result)
                }
            } else {
                assigneeContact = nil
            }
            let updated = try await attention.taskSync.assignJiraIssue(key: issueKey ?? "", assignee: assigneeContact)
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "assign",
                "issue": WorkspaceTaskSyncController.jiraIssuePayload(updated),
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: updated.key, status: "applied", result: result)
        }

        if operation == "create" {
            guard await actions.approval("Create Jira issue", ["summary": summary ?? ""]) else {
                return actions.finish(id, client: client, type: "jira", target: summary ?? "", status: "rejected", failure: "APPROVAL_DENIED")
            }
            let team = await attention.loadTeamContext()
            var assigneeContact: JiraUserContact?
            if let assignee, !assignee.isEmpty {
                let people = await attention.loadPeopleDirectory()
                switch await attention.taskSync.resolveJiraAssignee(assignee, people: people, defaultProjectKey: team.defaultJiraProjectKey) {
                case .resolved(let handle, let person):
                    let isDC = !attention.taskSync.preferences.jira.isCloudHost
                    assigneeContact = JiraUserContact(
                        identifier: handle,
                        username: person?.jiraUsername ?? handle,
                        accountId: person?.jiraAccountID,
                        displayName: person?.displayName ?? assignee,
                        isServerOrDC: person?.jiraAccountID == nil && isDC
                    )
                case .unresolved(let unresolvedQuery, let candidates):
                    var result = WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(query: unresolvedQuery, candidates: candidates)
                    result["action_id"] = id
                    result["status"] = "applied"
                    result["observed_at"] = mcpNow()
                    result["operation"] = "create"
                    result["warnings"] = []
                    return actions.finish(id, client: client, type: "jira", target: unresolvedQuery, status: "applied", result: result)
                }
            }
            let explicitProj = try MCPValue.optionalString(args["project_key"], key: "project_key")?.trimmed ?? ""
            let teamProj = team.defaultJiraProjectKey.trimmed
            let resolvedProject = explicitProj.isEmpty ? (teamProj.isEmpty ? nil : teamProj) : explicitProj
            let kind = (try MCPValue.optionalString(args["issue_kind"], key: "issue_kind")).flatMap(TaskIssueKind.init(rawValue:)) ?? .task
            let priority = (try MCPValue.optionalString(args["priority"], key: "priority")).flatMap(TaskPriorityLevel.init(rawValue:))
            let created = try await attention.taskSync.createJiraIssueDirect(
                summary: summary ?? "",
                description: try MCPValue.optionalString(args["description"], key: "description") ?? "",
                projectKey: resolvedProject,
                issueKind: kind,
                assignee: assigneeContact,
                priority: priority,
                parentEpicKey: try MCPValue.optionalString(args["parent_epic_key"], key: "parent_epic_key")
            )
            let result: MCPJSON = [
                "action_id": id,
                "status": "applied",
                "observed_at": mcpNow(),
                "operation": "create",
                "issue": WorkspaceTaskSyncController.jiraIssuePayload(created),
                "warnings": [],
            ]
            return actions.finish(id, client: client, type: "jira", target: created.key, status: "applied", result: result)
        }

        // search
        let activeMeeting = await MainActor.run {
            attention.meetings().first(where: { !$0.isClosed })
        }
        let jiraConfig = await attention.resolvedJiraBoardConfig(for: activeMeeting)
        let team = await attention.loadTeamContext()
        let fallbackProject = jiraConfig.projectKeys.first ?? team.defaultJiraProjectKey
        var resolvedAssigneeID: String?
        if let assignee, !assignee.isEmpty {
            let people = await attention.loadPeopleDirectory()
            switch await attention.taskSync.resolveJiraAssignee(
                assignee,
                people: people,
                defaultProjectKey: fallbackProject
            ) {
            case .resolved(let handle, _):
                resolvedAssigneeID = handle
            case .unresolved(let unresolvedQuery, let candidates):
                var result = WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                    query: unresolvedQuery,
                    candidates: candidates
                )
                result["action_id"] = id
                result["status"] = "applied"
                result["observed_at"] = mcpNow()
                result["operation"] = "search"
                result["warnings"] = []
                return actions.finish(id, client: client, type: "jira", target: unresolvedQuery, status: "applied", result: result)
            }
        }
        let baseJQL = AssistantSkillToolRegistrar.resolvedJiraJQL(
            rawJQL: rawJQL,
            query: query,
            teamProjectKey: team.defaultJiraProjectKey,
            jiraProjectKey: attention.taskSync.preferences.jira.cleanProjectKey,
            projectKeys: jiraConfig.projectKeys
        )
        let jql = resolvedAssigneeID.map {
            WorkspaceTaskSyncController.injectAssignee($0, intoJQL: baseJQL)
        } ?? baseJQL

        var finalJQL = jql
        var issues: [JiraRemoteIssue]
        do {
            issues = try await attention.taskSync.searchJiraIssues(jql: jql, maxResults: maxResults)
        } catch JiraConnectorError.badRequest(let detail) {
            if let literalAssignee = WorkspaceTaskSyncController.extractLiteralAssigneeFromJQL(jql) {
                let people = await attention.loadPeopleDirectory()
                switch await attention.taskSync.resolveJiraAssignee(
                    literalAssignee,
                    people: people,
                    defaultProjectKey: fallbackProject
                ) {
                case .resolved(let handle, _):
                    finalJQL = WorkspaceTaskSyncController.replacingLiteralAssignee(in: jql, with: handle)
                    issues = try await attention.taskSync.searchJiraIssues(jql: finalJQL, maxResults: maxResults)
                case .unresolved(let unresolvedQuery, let candidates):
                    var result = WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                        query: unresolvedQuery,
                        candidates: candidates
                    )
                    result["action_id"] = id
                    result["status"] = "applied"
                    result["observed_at"] = mcpNow()
                    result["operation"] = "search"
                    result["warnings"] = []
                    return actions.finish(id, client: client, type: "jira", target: unresolvedQuery, status: "applied", result: result)
                }
            } else {
                throw JiraConnectorError.badRequest(detail)
            }
        }
        let cleanQuery = (query ?? "").trimmed
        let boardOpen = await MainActor.run { attention.boardController.currentURL != nil }
        let hasExactMatch = !cleanQuery.isEmpty && issues.contains {
            $0.key.localizedCaseInsensitiveContains(cleanQuery)
                || $0.summary.localizedCaseInsensitiveContains(cleanQuery)
        }
        if boardOpen, (issues.isEmpty || (!cleanQuery.isEmpty && !hasExactMatch)) {
            if let (_, boardIssues) = try? await attention.taskSync.fetchBoardUsersAndIssues(maxResults: 50),
               !boardIssues.isEmpty {
                let normalizedQuery = cleanQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                let normalizedAssignee = (resolvedAssigneeID ?? assignee ?? "")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                let visibleMatches = boardIssues.filter { issue in
                    let queryOK = normalizedQuery.isEmpty
                        || issue.key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedQuery)
                        || issue.summary.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedQuery)
                    let assigneeOK = normalizedAssignee.isEmpty
                        || (issue.assigneeName ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                        || (issue.assigneeIdentifier ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                        || (issue.assigneeContact?.username ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                        || (issue.assigneeContact?.accountId ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                    return queryOK && assigneeOK
                }
                if !visibleMatches.isEmpty {
                    let existingKeys = Set(visibleMatches.map(\.key))
                    issues = visibleMatches + issues.filter { !existingKeys.contains($0.key) }
                }
            }
        }
        let rows: [MCPJSON] = Array(issues.prefix(maxResults)).map { issue in
            [
                "key": issue.key,
                "summary": issue.summary,
                "status": issue.statusName,
                "assignee": issue.assigneeName ?? "",
                "priority": issue.priority?.localizedTitle ?? "",
                "due_day": issue.dueDay ?? "",
                "browse_url": issue.browseURL ?? "",
            ]
        }
        let result: MCPJSON = [
            "action_id": id,
            "status": "applied",
            "observed_at": mcpNow(),
            "operation": "search",
            "jql": finalJQL,
            "count": rows.count,
            "issues": rows,
            "warnings": [],
        ]
        return actions.finish(id, client: client, type: "jira", target: finalJQL, status: "applied", result: result)
    }
}
