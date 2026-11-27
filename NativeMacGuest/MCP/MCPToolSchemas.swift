import Foundation

// MARK: - Declarative tool schemas
//
// This file is the single source of truth for what each MCP tool accepts.
// `tools/list` renders these declarations verbatim and `MCPSchemaValidator`
// enforces them before any handler runs, so the published contract and the
// enforced contract cannot drift apart. Keep `mcp/CONTRACTS.md` in sync.

final class MCPToolProperty {
    enum ValueType: String {
        case string, boolean, integer, number, object, array
    }

    let type: ValueType
    let description: String
    var minLength: Int? = nil
    var format: String? = nil
    var minimum: Int? = nil
    var maximum: Int? = nil
    var minimumNumber: Double? = nil
    var maximumNumber: Double? = nil
    var `default`: Any? = nil
    var enumValues: [String]? = nil
    var items: MCPToolProperty? = nil
    var properties: [String: MCPToolProperty]? = nil
    var required: [String] = []

    init(type: ValueType, description: String) {
        self.type = type; self.description = description
    }

    static func string(_ description: String, minLength: Int? = nil, format: String? = nil,
                       enumValues: [String]? = nil, default defaultValue: String? = nil) -> MCPToolProperty {
        let property = MCPToolProperty(type: .string, description: description)
        property.minLength = minLength; property.format = format; property.enumValues = enumValues
        if let defaultValue { property.default = defaultValue }
        return property
    }

    static func boolean(_ description: String) -> MCPToolProperty {
        MCPToolProperty(type: .boolean, description: description)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil,
                        default defaultValue: Int? = nil) -> MCPToolProperty {
        let property = MCPToolProperty(type: .integer, description: description)
        property.minimum = minimum; property.maximum = maximum
        if let defaultValue { property.default = defaultValue }
        return property
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> MCPToolProperty {
        let property = MCPToolProperty(type: .number, description: description)
        property.minimumNumber = minimum; property.maximumNumber = maximum
        return property
    }

    static func array(_ description: String, items: MCPToolProperty) -> MCPToolProperty {
        let property = MCPToolProperty(type: .array, description: description)
        property.items = items
        return property
    }

    static func object(_ description: String, properties: [String: MCPToolProperty] = [:],
                       required: [String] = []) -> MCPToolProperty {
        let property = MCPToolProperty(type: .object, description: description)
        property.properties = properties; property.required = required
        return property
    }

    /// Rendered into `tools/list`. Schemas are self-contained: no `$ref`, no network.
    var json: MCPJSON {
        var output: MCPJSON = ["type": type.rawValue, "description": description]
        if let minLength { output["minLength"] = minLength }
        if let format { output["format"] = format }
        if let minimum { output["minimum"] = minimum }
        if let maximum { output["maximum"] = maximum }
        if let minimumNumber { output["minimum"] = minimumNumber }
        if let maximumNumber { output["maximum"] = maximumNumber }
        if let `default` { output["default"] = `default` }
        if let enumValues { output["enum"] = enumValues }
        if let items { output["items"] = items.json }
        if let properties {
            output["properties"] = properties.mapValues { $0.json }
            output["required"] = required
            output["additionalProperties"] = false
        }
        return output
    }
}

struct MCPToolSchema {
    var properties: [String: MCPToolProperty] = [:]
    var required: [String] = []
    var additionalProperties = false

    var json: MCPJSON {
        [
            "type": "object",
            "properties": properties.mapValues { $0.json },
            "required": required,
            "additionalProperties": additionalProperties,
        ]
    }
}

struct MCPToolDefinition {
    let name: String
    let description: String
    let readOnly: Bool
    let scope: String
    let schema: MCPToolSchema
}

private let timeRange: [String: MCPToolProperty] = [
    "from": .string("RFC 3339 lower time bound; a time-zone offset or Z is required. When both bounds are given, from must be earlier than to.", format: "date-time"),
    "to": .string("RFC 3339 exclusive upper time bound; a time-zone offset or Z is required.", format: "date-time"),
]

private let pagination: [String: MCPToolProperty] = [
    "limit": .integer("Maximum number of items to return; values outside 1...100 are rejected. Defaults to 20.", minimum: 1, maximum: 100, default: 20),
    "cursor": .string("Opaque page cursor copied verbatim from a previous response's next_cursor. Reusing a cursor with changed filters fails with CURSOR_EXPIRED."),
]

private let actionID: MCPToolProperty = .string(
    "Client-generated UUID used as an idempotency key. Retrying with the same action_id and identical arguments replays the recorded result; reusing it with different arguments fails with ACTION_ID_REUSED.")

private let expectedRevision: MCPToolProperty = .string(
    "Opaque revision of the target observed before the call. Required unless this action_id replays an already-recorded call; see the tool description for where the current value is published.")

private let meetingIDFromList = "Opaque meeting identifier: the id of an item returned by rocknroll_list_meetings or rocknroll_search — never a meeting title."

func nativeMCPToolDefinitions() -> [MCPToolDefinition] {
    let meetingID = MCPToolProperty.string(meetingIDFromList, minLength: 1)
    let sectionsRead = MCPToolProperty.array(
        "Settings sections to include. Defaults to all three.",
        items: .string("Section name.", enumValues: ["app", "attention", "meeting"]))

    let attentionPatchKeys: [String: MCPToolProperty] = [
        "judge_enabled": .boolean("Enable the meeting judge."),
        "pause_on_battery": .boolean("Pause attention work while on battery power."),
        "draft_replies": .boolean("Draft replies to messages directed at you."),
        "local_drafts": .boolean("Prefer on-device drafting."),
        "push_to_talk": .boolean("Hold a key to talk back to a meeting."),
        "talk_back": .boolean("Allow spoken assistant replies."),
        "generate_outcomes": .boolean("Summarize meetings into outcomes with tasks."),
        "remote_outcomes": .boolean("Request outcomes from the remote meeting service."),
    ]
    let settingsPatch = MCPToolProperty.object(
        "Settings patch; omitting it applies no changes. Unknown section or field names are rejected.",
        properties: [
            "attention": .object("Attention settings; every field is a boolean.", properties: attentionPatchKeys),
        ])
    let desiredState = MCPToolProperty.object(
        "Requested device state; an empty object is allowed. Joining (room:/occurrence: targets) uses microphone=false to join muted; leave and camera apply to active sessions only.",
        properties: [
            "leave": .boolean("Leave the active session."),
            "microphone": .boolean("Desired microphone state for a session; for a join target, false joins muted."),
            "camera": .boolean("Desired camera state for a session."),
        ])

    return [
        .init(name: "rocknroll_status", description: "Report native backend, capabilities and app state.",
              readOnly: true, scope: "meetings:read",
              schema: .init()),
        .init(name: "rocknroll_list_meetings",
              description: "List and count meetings. Use kind=attended for recorded sessions, calendar for scheduled occurrences, and active for meetings open now or overlapping a date range. total_matches counts all matches before pagination.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "query": .string("Optional literal case-insensitive substring over titles and summaries. Trimmed. Omit for semantic matching of informal names against date-scoped candidates."),
                "kind": .string("Choose a record type. Omitted returns the legacy mixed catalog; specify a kind for meaningful counts.", enumValues: ["attended", "active", "favorite", "recent", "calendar", "outcome"]),
                "from": timeRange["from"]!, "to": timeRange["to"]!,
                "date_field": .string("Date used for from/to. date uses the customary date, including start for attended sessions. With active and date bounds, date matches sessions overlapping the range.", enumValues: ["date", "started_at", "ended_at"], default: "date"),
                "sort_by": .string("Sort field. date uses the record's customary date.", enumValues: ["date", "started_at", "ended_at", "title"], default: "date"),
                "sort_order": .string("Sort direction. Defaults to oldest first for date fields.", enumValues: ["asc", "desc"], default: "asc"),
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ])),
        .init(name: "rocknroll_get_meeting", description: "Get one native meeting record.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: ["meeting_id": meetingID], required: ["meeting_id"])),
        .init(name: "rocknroll_get_transcript", description: "Read an active session's transcript or a saved session's captured transcript. Historical captures can be partial.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "meeting_id": .string(meetingIDFromList + " Must identify a session (id starts with session:).", minLength: 1),
                "from": timeRange["from"]!, "to": timeRange["to"]!,
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ], required: ["meeting_id"])),
        .init(name: "rocknroll_get_outcome", description: "Get one stored historical outcome by outcome ID. Task items include the current profile’s archived flag.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "outcome_id": .string("Opaque outcome identifier: related.outcome_id of an attended item, the id of an outcome item, or the meeting_id field of a task item. Never pass a session ID here.", minLength: 1),
              ], required: ["outcome_id"])),
        .init(name: "rocknroll_get_notes", description: "Get the raw Markdown note for one meeting by a persisted or active session ID. Notes are user-authored personal records; they are attributed separately from outcomes and transcripts. Never a write: this tool changes nothing.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "meeting_id": .string("Opaque meeting identifier: an id returned by rocknroll_list_meetings or rocknroll_search. Must identify a persisted session (id starts with session:) or an outcome-backed historical session.", minLength: 1),
              ], required: ["meeting_id"])),
        .init(name: "rocknroll_list_tasks", description: "List tasks from native meeting outcomes. Tasks archived by the current profile are excluded by default.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "meeting_id": .string("Filter by outcome id (outcome:…), matching the meeting_id field of task items."),
                "done": .boolean("Filter by completion state."),
                "owner": .string("Case-insensitive substring match on the task owner."),
                "personal_only": .boolean("Only tasks assigned to the current profile by stable ID or confirmed full alias."),
                "include_archived": .boolean("Include tasks archived by the current profile; defaults to false."),
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ])),
        .init(name: "rocknroll_search", description: "Search native meetings, outcomes, tasks and transcripts.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "query": .string("Case-insensitive search text, trimmed; must be non-empty after trimming.", minLength: 1),
                "types": .array("Result types to search; defaults to all five. Unknown values are rejected.",
                                items: .string("Result type.", enumValues: ["meeting", "outcome", "task", "transcript", "note"])),
                "personal_only": .boolean("Restrict task results to the current profile's assignments."),
                "include_archived": .boolean("Include task results archived by the current profile; defaults to false."),
                "limit": pagination["limit"]!, "cursor": pagination["cursor"]!,
              ], required: ["query"])),
        .init(name: "rocknroll_get_settings", description: "Read allowlisted native settings and resolved attention configuration.",
              readOnly: true, scope: "settings:read",
              schema: .init(properties: [
                "sections": sectionsRead,
                "meeting_id": .string("Active session id; only consulted when sections includes meeting."),
              ])),
        .init(name: "rocknroll_control_meeting", description: "Request a bound native meeting control. Every call requires native approval; a session target applies device state or leaves, a room or calendar target joins it.",
              readOnly: false, scope: "meetings:control",
              schema: .init(properties: [
                "action_id": actionID,
                "meeting_id": meetingID,
                "desired_state": desiredState,
              ], required: ["action_id", "meeting_id"])),
        .init(name: "rocknroll_set_favorite", description: "Set a favorite room through the native library. expected_revision is required unless action_id replays a recorded call; the current value is published as sections.app.favorite_revision by rocknroll_get_settings.",
              readOnly: false, scope: "favorites:write",
              schema: .init(properties: [
                "action_id": actionID,
                "room_id": .string("Opaque room identifier: the id of a favorite or recent item from rocknroll_list_meetings.", minLength: 1),
                "favorite": .boolean("true stars the room, false unstars it."),
                "expected_revision": expectedRevision,
              ], required: ["action_id", "room_id", "favorite"])),
        .init(name: "rocknroll_update_task", description: "Update an allowlisted task field. expected_revision is the outcome UUID (the middle component of task_id) and is required unless action_id replays a recorded call. An empty patch applies no changes.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "task_id": .string("Opaque task identifier: the id of a task item from rocknroll_list_tasks, rocknroll_search or rocknroll_get_outcome.", minLength: 1),
                "expected_revision": expectedRevision,
                "text": .string("New task text; omit to leave unchanged."),
                "owner": .string("New owner; omit to leave unchanged."),
                "done": .boolean("New completion state; omit to leave unchanged."),
                "due_day": .string("Optional due day in YYYY-MM-DD format; pass empty string to clear."),
                "jira_status": .string("Optional workflow or Jira status such as To Do, In Progress, or Done."),
                "sync_to_jira": .boolean("When true and Jira sync is enabled, syncs this updated task to Jira."),
              ], required: ["action_id", "task_id"])),
        .init(name: "rocknroll_update_settings", description: "Update an allowlisted native setting. expected_revision is the revision field from rocknroll_get_settings and is required unless action_id replays a recorded call.",
              readOnly: false, scope: "settings:write",
              schema: .init(properties: [
                "action_id": actionID,
                "expected_revision": expectedRevision,
                "sections": settingsPatch,
              ], required: ["action_id"])),
        .init(name: "rocknroll_run_assistant", description: "Run a safe in-app assistant prompt. Actions that need native confirmation are returned as approval-required and are never executed through MCP.",
              readOnly: false, scope: "assistant:run",
              schema: .init(properties: [
                "action_id": actionID,
                "prompt": .string("Assistant instruction, trimmed; must be non-empty after trimming.", minLength: 1),
                "meeting_id": .string("Optional active session id (starts with session:) scoping the assistant to one meeting."),
                "conversation_id": .string("Recognized for compatibility but always rejected with CAPABILITY_UNAVAILABLE: this assistant exposes no external conversation IDs."),
              ], required: ["action_id", "prompt"])),
        .init(name: "rocknroll_create_task", description: "Create a task in a meeting outcome or in standalone Assistant Tasks, optionally resolving owner aliases via People.md and syncing to Jira.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "title": .string("Task description, trimmed; must be non-empty after trimming.", minLength: 1),
                "meeting_id": .string("Optional session or outcome id returned by rocknroll_list_meetings; omit for standalone Assistant Tasks."),
                "owner": .string("Optional owner display name or spoken alias resolved through Knowledge/People.md."),
                "due_day": .string("Optional due day in YYYY-MM-DD format."),
                "notes": .string("Optional task context notes."),
                "sync_to_jira": .boolean("When true and Jira is enabled, creates or syncs the task to Jira."),
              ], required: ["action_id", "title"])),
        .init(name: "rocknroll_schedule_meeting", description: "Schedule a calendar meeting via Apple Calendar with optional meeting invitation URL and agenda notes.",
              readOnly: false, scope: "meetings:control",
              schema: .init(properties: [
                "action_id": actionID,
                "title": .string("Calendar event title, trimmed; must be non-empty.", minLength: 1),
                "start_at": .string("RFC 3339 start timestamp with time-zone offset or Z.", format: "date-time"),
                "end_at": .string("RFC 3339 end timestamp with time-zone offset or Z.", format: "date-time"),
                "meeting_url": .string("Optional meeting invitation URL stored on the calendar event."),
                "agenda_notes": .string("Optional agenda notes saved in the calendar event description."),
                "calendar_id": .string("Optional writable calendar identifier; omit for default calendar."),
              ], required: ["action_id", "title", "start_at", "end_at"])),
        .init(name: "rocknroll_update_meeting_artifacts", description: "Update or append factual summary notes, decisions, open questions, and action items on a meeting outcome.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "meeting_id": .string("Opaque session or outcome identifier for the meeting to update.", minLength: 1),
                "summary_append": .string("Factual paragraph appended to the meeting summary."),
                "replace_summary": .string("Replacement summary text; omit to preserve or append to the existing summary."),
                "decisions": .array("Decisions to append to the meeting outcome.",
                                    items: .string("Decision statement.", minLength: 1)),
                "open_questions": .array("Open questions to append to the meeting outcome.",
                                         items: .string("Open question statement.", minLength: 1)),
                "action_items": .array("Structured action items to append to the meeting outcome.",
                                       items: .object("Action item entry.", properties: [
                                        "text": .string("Task description.", minLength: 1),
                                        "owner": .string("Assignee display name or alias."),
                                        "due_day": .string("Optional due day in YYYY-MM-DD format."),
                                       ], required: ["text"])),
              ], required: ["action_id", "meeting_id"])),
        .init(name: "rocknroll_list_skills", description: "List Obsidian-backed assistant skill definitions and metadata.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "query": .string("Optional filter over skill id, name, role, triggers and instructions."),
                "enabled_only": .boolean("When true, returns only enabled skills."),
              ])),
        .init(name: "rocknroll_get_skill", description: "Read one Obsidian-backed assistant skill including its full editable Markdown instructions.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "skill_id": .string("Skill slug identifier returned by rocknroll_list_skills.", minLength: 1),
              ], required: ["skill_id"])),
        .init(name: "rocknroll_upsert_skill", description: "Create or update an Obsidian-backed assistant skill Markdown file.",
              readOnly: false, scope: "settings:write",
              schema: .init(properties: [
                "action_id": actionID,
                "skill_id": .string("Skill slug identifier (e.g. scrum-master).", minLength: 1),
                "name": .string("Human-readable skill title.", minLength: 1),
                "role": .string("Short one-line description of the assistant role."),
                "enabled": .boolean("Whether the skill is active."),
                "voice_activation": .boolean("Whether voice triggers activate this skill."),
                "approved_speakers_only": .boolean("Whether outward task/board writes during meetings require approved speakers or owner."),
                "realtime_preferred": .boolean("Whether this skill prefers an optional Realtime voice model."),
                "triggers": .array("Trigger keywords matched against meeting titles or commands.",
                                   items: .string("Trigger phrase.", minLength: 1)),
                "tools": .array("Allowed skill capability groups.",
                                items: .string("Capability group.", enumValues: ["tasks", "jira", "board_share", "obsidian_search", "meeting_search", "calendar_schedule", "meeting_summary", "meeting_join"])),
                "instructions": .string("Full Markdown instructions body saved to Skills/<skill_id>.md.", minLength: 1),
              ], required: ["action_id", "skill_id", "name", "instructions"])),
        .init(name: "rocknroll_search_knowledge", description: "Search Obsidian vault Markdown notes, Knowledge/People.md, TeamContext.md, and Skills on demand.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "query": .string("Case-insensitive search text; must be non-empty after trimming.", minLength: 1),
                "limit": .integer("Maximum number of matches to return; values outside 1...30 are rejected. Defaults to 8.", minimum: 1, maximum: 30, default: 8),
              ], required: ["query"])),
        .init(name: "rocknroll_manage_people", description: "Look up or remember member name-to-Jira mappings and voice command approvals in Knowledge/People.md.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "operation": .string("Directory operation.", enumValues: ["lookup", "upsert"]),
                "query": .string("Lookup query matching display name, alias, Jira username or email."),
                "display_name": .string("Canonical member display name for upsert."),
                "aliases": .array("Spoken nicknames or meeting display names.",
                                  items: .string("Alias text.", minLength: 1)),
                "jira_username": .string("Jira Server/DC username."),
                "jira_account_id": .string("Jira Cloud accountId."),
                "email": .string("Member email address."),
                "role": .string("Team role description."),
                "approved_voice_commander": .boolean("Whether this team member can issue voice task/board instructions."),
                "force_without_jira": .boolean("Set true only to save aliases or voice permissions when the person genuinely has no Jira account."),
                "notes": .string("Optional Markdown notes kept with the member entry."),
              ], required: ["action_id", "operation"])),
        .init(name: "rocknroll_control_board", description: "Control the sandbox-safe in-app Assistant Board WKWebView window, select person filters during standups, move Jira cards, and share it directly into an active meeting.",
              readOnly: false, scope: "meetings:control",
              schema: .init(properties: [
                "action_id": actionID,
                "command": .string("Board action command.", enumValues: ["open_url", "share_to_meeting", "stop_share", "scroll", "filter", "select_person_filter", "clear_filters", "click", "click_at", "highlight", "inspect", "snapshot", "move_issue"]),
                "url": .string("HTTPS or localhost URL for open_url."),
                "meeting_id": .string("Active session identifier (session:native:...) for share_to_meeting."),
                "query": .string("Search query for filter or person name/alias for select_person_filter."),
                "selector": .string("CSS selector for click."),
                "text": .string("Visible label or issue text for click or highlight."),
                "issue_key": .string("Jira issue key for move_issue (e.g. PROJ-123)."),
                "status": .string("Target status/column name for move_issue."),
                "comment": .string("Optional Jira comment when moving an issue."),
                "delta_y": .integer("Vertical scroll delta in pixels for scroll.", minimum: -4000, maximum: 4000),
                "x": .number("Horizontal coordinate for click_at (normalized 0.0...1.0 unless normalized=false).", minimum: 0),
                "y": .number("Vertical coordinate for click_at (normalized 0.0...1.0 unless normalized=false).", minimum: 0),
                "normalized": .boolean("When true (default), x and y are normalized viewport fractions in 0.0...1.0."),
              ], required: ["action_id", "command"])),
        .init(name: "rocknroll_join_meetings", description: "Join one or more meetings by title/keyword queries, optionally bind an Obsidian skill role and enable in-meeting voice facilitation.",
              readOnly: false, scope: "meetings:control",
              schema: .init(properties: [
                "action_id": actionID,
                "queries": .array("Non-empty list of meeting title queries or keywords (or \"current\").",
                                  items: .string("Meeting title query.", minLength: 1)),
                "skill_id": .string("Optional Obsidian skill slug to bind (e.g. scrum-master)."),
                "enable_voice_facilitation": .boolean("Enable autonomous in-meeting voice facilitation after joining (defaults to true)."),
              ], required: ["action_id", "queries"])),
        .init(name: "rocknroll_jira_action", description: "Search Jira issues/board users, copy a user handle from an issue on the board, create/assign/transition issues, or post a comment.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "operation": .string("Jira operation.", enumValues: ["search", "search_users", "board_users", "copy_user_from_issue", "comment", "transition", "assign", "create"]),
                "jql": .string("Explicit JQL query for search."),
                "query": .string("Plain text search query when jql is omitted, or name/login/email query for search_users or copy_user_from_issue."),
                "assignee": .string("Meeting/display name or Jira handle to resolve via People.md or Jira user search."),
                "max_results": .integer("Maximum issues or users to return (1...50).", minimum: 1, maximum: 50, default: 15),
                "issue_key": .string("Jira issue key (e.g. PROJ-123) for comment, transition, assign, or copy_user_from_issue.", minLength: 2),
                "comment": .string("Comment body for comment or transition.", minLength: 1),
                "status": .string("Target Jira status/column name for transition (e.g. In Progress, В работе, Done)."),
                "role": .string("User role to copy from an issue: assignee (default) or reporter.", enumValues: ["assignee", "reporter"]),
                "save_to_people_name": .string("Optional People.md display name to immediately bind with the copied Jira user."),
                "aliases": .array("Optional spoken/meeting aliases when save_to_people_name is provided.", items: .string("Alias text.", minLength: 1)),
                "summary": .string("Issue summary/title when creating a Jira issue."),
                "description": .string("Issue description when creating a Jira issue."),
                "project_key": .string("Target Jira project key when creating an issue."),
                "issue_kind": .string("Issue type for create.", enumValues: ["task", "story", "bug", "epic"]),
                "priority": .string("Issue priority for create.", enumValues: ["critical", "high", "medium", "low"]),
                "parent_epic_key": .string("Optional parent Epic key for create."),
                "jira_username": .string("Explicit Jira Server/DC username for assign."),
                "jira_account_id": .string("Explicit Jira Cloud accountId for assign."),
              ], required: ["action_id", "operation"])),
        .init(name: "rocknroll_list_role_presets", description: "List specialized Markdown Role Presets under Rock Assistant/Presets/<skill_id>/.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "skill_id": .string("Optional parent Role skill slug to filter presets.", minLength: 1),
              ], required: [])),
        .init(name: "rocknroll_list_expert_opinions", description: "List persisted Primary and Secondary Expert Opinion blocks and dominant role governance for a meeting session.",
              readOnly: true, scope: "meetings:read",
              schema: .init(properties: [
                "session_id": .string("Session UUID or session: identifier.", minLength: 1),
              ], required: ["session_id"])),
        .init(name: "rocknroll_generate_expert_opinion", description: "Generate or regenerate an Expert Opinion block on a meeting using full-transcript evaluation and a Role/Preset.",
              readOnly: false, scope: "tasks:write",
              schema: .init(properties: [
                "action_id": actionID,
                "session_id": .string("Session UUID or session: identifier.", minLength: 1),
                "skill_id": .string("Target Role skill slug (e.g. hiring-interviewer).", minLength: 1),
                "preset_id": .string("Optional Role Preset slug under skill_id.", minLength: 1),
                "focus_speakers": .array("Optional speaker names to evaluate (e.g. Candidate names).", items: .string("Speaker display name.", minLength: 1)),
                "extra_context": .string("Optional ad-hoc instructions, rubric, or job description."),
                "make_primary": .boolean("Set this Role as the Dominant ★ Primary role for the meeting."),
              ], required: ["action_id", "session_id", "skill_id"])),
    ]
}

// MARK: - Pre-dispatch structural validation
//
// Runs after the scope check and before any handler, so a structurally invalid
// call produces no side effect: no action is recorded and no approval is shown.

enum MCPSchemaValidator {
    static func validate(_ arguments: MCPJSON, schema: MCPToolSchema) throws {
        for field in schema.required where arguments[field] == nil {
            throw invalid(field, "required", "\(field) is required.")
        }
        for (field, value) in arguments {
            guard let property = schema.properties[field] else {
                throw invalid(field, "unknown_field", "Unknown argument: \(field).")
            }
            try validateValue(value, property: property, field: field)
        }
        // Cross-field range check for tools that accept a time window.
        if schema.properties["from"] != nil, let fromText = arguments["from"] as? String, let toText = arguments["to"] as? String {
            let from = try MCPValue.date(fromText, key: "from")
            let to = try MCPValue.date(toText, key: "to")
            if let from, let to, from >= to {
                throw invalid("from", "range", "from must be earlier than to.")
            }
        }
    }

    private static func validateValue(_ value: Any, property: MCPToolProperty, field: String) throws {
        if value is NSNull { throw invalid(field, "null", "\(field) must not be null.") }
        switch property.type {
        case .string:
            guard let text = value as? String else { throw invalid(field, "type", "\(field) must be a string.") }
            if let minLength = property.minLength, text.count < minLength {
                throw invalid(field, "empty", "\(field) must not be empty.")
            }
            if let enums = property.enumValues, !enums.contains(text) {
                throw invalid(field, "enum", "\(field) must be one of: \(enums.joined(separator: ", ")).")
            }
        case .boolean:
            guard isBool(value) else { throw invalid(field, "type", "\(field) must be a boolean.") }
        case .integer:
            // Booleans bridge to NSNumber on Darwin and would otherwise parse as 0/1.
            guard let number = value as? Int, !isBool(value) else {
                throw invalid(field, "type", "\(field) must be an integer.")
            }
            if let minimum = property.minimum, number < minimum { throw invalid(field, "range", "\(field) must be at least \(minimum).") }
            if let maximum = property.maximum, number > maximum { throw invalid(field, "range", "\(field) must be at most \(maximum).") }
        case .number:
            guard !isBool(value), let raw = (value as? NSNumber)?.doubleValue, raw.isFinite else {
                throw invalid(field, "type", "\(field) must be a number.")
            }
            if let minimum = property.minimumNumber, raw < minimum { throw invalid(field, "range", "\(field) must be at least \(minimum).") }
            if let maximum = property.maximumNumber, raw > maximum { throw invalid(field, "range", "\(field) must be at most \(maximum).") }
        case .array:
            guard let elements = value as? [Any] else { throw invalid(field, "type", "\(field) must be an array.") }
            if let items = property.items {
                for (index, element) in elements.enumerated() {
                    try validateValue(element, property: items, field: "\(field)[\(index)]")
                }
            }
        case .object:
            guard let object = value as? MCPJSON else { throw invalid(field, "type", "\(field) must be an object.") }
            for nested in property.required where object[nested] == nil || object[nested] is NSNull {
                throw invalid("\(field).\(nested)", "required", "\(field).\(nested) is required.")
            }
            for (key, nested) in object {
                guard let nestedProperty = property.properties?[key] else {
                    throw invalid("\(field).\(key)", "unknown_field", "Unknown \(field) field: \(key).")
                }
                try validateValue(nested, property: nestedProperty, field: "\(field).\(key)")
            }
        }
    }

    /// Distinguishes real booleans from NSNumber on Darwin, where `NSNumber(value: true) as? Int` yields 1.
    private static func isBool(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        return value is Bool
    }

    private static func invalid(_ field: String, _ reason: String, _ message: String) -> MCPToolFailure {
        MCPToolFailure("INVALID_ARGUMENT", message, details: ["field": field, "reason": reason])
    }
}
