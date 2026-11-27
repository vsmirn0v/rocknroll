import Foundation

/// Capabilities that an Obsidian-backed Rock Assistant skill can request and use.
public enum AssistantSkillToolGroup: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case tasks
    case jira
    case boardShare = "board_share"
    case obsidianSearch = "obsidian_search"
    case meetingSearch = "meeting_search"
    case calendarSchedule = "calendar_schedule"
    case meetingSummary = "meeting_summary"
    case meetingJoin = "meeting_join"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tasks: return L("Manage tasks")
        case .jira: return L("Jira issues & sync")
        case .boardShare: return L("Share & control board")
        case .obsidianSearch: return L("Search Obsidian knowledge")
        case .meetingSearch: return L("Search past meetings & transcripts")
        case .calendarSchedule: return L("Schedule calendar meetings")
        case .meetingSummary: return L("Update meeting summary & actions")
        case .meetingJoin: return L("Join meetings by command")
        }
    }

    public var mcpToolNames: [String] {
        switch self {
        case .tasks:
            return ["rocknroll_list_tasks", "rocknroll_create_task", "rocknroll_update_task", "rocknroll_manage_people"]
        case .jira:
            return ["rocknroll_create_task", "rocknroll_update_task", "rocknroll_manage_people"]
        case .boardShare:
            return ["rocknroll_control_board"]
        case .obsidianSearch:
            return ["rocknroll_search_knowledge", "rocknroll_list_skills", "rocknroll_get_skill"]
        case .meetingSearch:
            return ["rocknroll_list_meetings", "rocknroll_get_meeting", "rocknroll_get_transcript",
                    "rocknroll_get_outcome", "rocknroll_get_notes", "rocknroll_search"]
        case .calendarSchedule:
            return ["rocknroll_schedule_meeting", "rocknroll_list_meetings"]
        case .meetingSummary:
            return ["rocknroll_update_meeting_artifacts", "rocknroll_get_outcome"]
        case .meetingJoin:
            return ["rocknroll_control_meeting", "rocknroll_list_meetings"]
        }
    }
}

/// How an assistant role engages during a meeting.
public enum AssistantEngagementMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case off
    case mentions
    case follow
    case observe
    case advise
    case participate
    case facilitate

    public var id: String { rawValue }

    public var isSilentToRoom: Bool {
        switch self {
        case .off, .mentions, .follow, .observe, .advise:
            return true
        case .participate, .facilitate:
            return false
        }
    }

    public var requiresLiveTranscript: Bool {
        self != .off
    }

    public var supportsOutboundVoiceOrChat: Bool {
        self == .participate || self == .facilitate
    }

    public var isAdvisorFamily: Bool {
        self == .observe || self == .advise
    }

    public var title: String {
        switch self {
        case .off: return L("Off")
        case .mentions: return L("Mentions")
        case .follow: return L("Follow")
        case .observe: return L("Observe")
        case .advise: return L("Advise")
        case .participate: return L("Participate")
        case .facilitate: return L("Facilitate")
        }
    }

    public var subtitle: String {
        switch self {
        case .off: return L("No live alerts or assistant commentary.")
        case .mentions: return L("Alerts you only when you are named or urgently needed.")
        case .follow: return L("Follows the conversation and alerts you when your input matters.")
        case .observe: return L("Silently takes structured role notes with zero interruptions.")
        case .advise: return L("Silently coaches you live with probes, contradictions, and pacing.")
        case .participate: return L("Drafts or sends chat and voice replies on your behalf.")
        case .facilitate: return L("Autonomously speaks and acts as Rock Assistant in the call.")
        }
    }

    public var symbol: String {
        switch self {
        case .off: return "bell.slash"
        case .mentions: return "at"
        case .follow: return "eye"
        case .observe: return "note.text"
        case .advise: return "lightbulb"
        case .participate: return "bubble.left"
        case .facilitate: return "waveform"
        }
    }
}

/// Controls whether the neutral core `MeetingOutcome` (Summary, Decisions, Tasks, Open Questions)
/// is generated alongside a specialized role's Expert Block.
public enum CoreOutcomePolicy: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case full
    case summaryOnly = "summary_only"
    case expertOnly = "expert_only"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: return L("Full outcome & tasks")
        case .summaryOnly: return L("Summary only (no tasks)")
        case .expertOnly: return L("Role opinion only (suppress core outcome)")
        }
    }

    public var generatesCoreSummary: Bool {
        self == .full || self == .summaryOnly
    }

    public var extractsDecisionsAndTasks: Bool {
        self == .full
    }
}

/// Visibility classification for a role-generated Expert Summary Block.
public enum ExpertSummaryVisibility: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case privateOwnerOnly = "private"
    case shared

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .privateOwnerOnly: return L("Private (owner only)")
        case .shared: return L("Shareable with team")
        }
    }
}

/// An extendable assistant skill stored as Markdown + YAML frontmatter in Obsidian (or local fallback).
public struct AssistantSkill: Identifiable, Codable, Equatable, Sendable {
    public static let personalAssistantID = "personal-assistant"

    public var id: String
    public var name: String
    public var role: String
    public var enabled: Bool
    public var voiceActivation: Bool
    public var triggers: [String]
    public var tools: [AssistantSkillToolGroup]
    public var approvedSpeakersOnly: Bool
    public var realtimePreferred: Bool
    public var autoGreet: Bool
    public var defaultMode: AssistantEngagementMode
    public var coreOutcomePolicy: CoreOutcomePolicy
    public var summaryBlockTitle: String
    public var summaryVisibility: ExpertSummaryVisibility
    public var exportDestinationSlug: String?
    public var routeEntireMeeting: Bool
    public var instructions: String
    public var sourceRelativePath: String?
    public var updatedAt: Date?
    public var extraFrontmatter: [String: String]
    /// Transient runtime identifier of the vault destination that owns this skill file (`nil` = primary/local).
    public var owningDestinationID: UUID?

    public init(
        id: String,
        name: String,
        role: String = "",
        enabled: Bool = true,
        voiceActivation: Bool = true,
        triggers: [String] = [],
        tools: [AssistantSkillToolGroup] = AssistantSkillToolGroup.allCases,
        approvedSpeakersOnly: Bool = true,
        realtimePreferred: Bool = false,
        autoGreet: Bool = false,
        defaultMode: AssistantEngagementMode = .facilitate,
        coreOutcomePolicy: CoreOutcomePolicy = .full,
        summaryBlockTitle: String = "",
        summaryVisibility: ExpertSummaryVisibility = .shared,
        exportDestinationSlug: String? = nil,
        routeEntireMeeting: Bool = false,
        instructions: String,
        sourceRelativePath: String? = nil,
        updatedAt: Date? = nil,
        extraFrontmatter: [String: String] = [:],
        owningDestinationID: UUID? = nil
    ) {
        let slug = Self.sanitizedSlug(from: id.isEmpty ? name : id)
        self.id = slug.isEmpty ? "custom-skill" : slug
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.id : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.enabled = enabled
        self.voiceActivation = voiceActivation
        self.triggers = Self.normalizedList(triggers)
        self.tools = tools
        self.approvedSpeakersOnly = approvedSpeakersOnly
        self.realtimePreferred = realtimePreferred
        self.autoGreet = autoGreet
        self.defaultMode = defaultMode
        self.coreOutcomePolicy = coreOutcomePolicy
        self.summaryBlockTitle = summaryBlockTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summaryVisibility = summaryVisibility
        let cleanSlug = exportDestinationSlug?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.exportDestinationSlug = (cleanSlug?.isEmpty == false) ? cleanSlug : nil
        self.routeEntireMeeting = routeEntireMeeting
        self.instructions = instructions.trimmingCharacters(in: .newlines)
        self.sourceRelativePath = sourceRelativePath ?? "Skills/\(self.id).md"
        self.updatedAt = updatedAt
        self.extraFrontmatter = extraFrontmatter
        self.owningDestinationID = owningDestinationID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, role, enabled, voiceActivation, triggers, tools
        case approvedSpeakersOnly, realtimePreferred, autoGreet
        case defaultMode, coreOutcomePolicy, summaryBlockTitle, summaryVisibility
        case exportDestinationSlug, routeEntireMeeting
        case instructions, sourceRelativePath, updatedAt, extraFrontmatter, owningDestinationID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decode(String.self, forKey: .id)
        let rawName = try c.decode(String.self, forKey: .name)
        self.init(
            id: rawID,
            name: rawName,
            role: try c.decodeIfPresent(String.self, forKey: .role) ?? "",
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            voiceActivation: try c.decodeIfPresent(Bool.self, forKey: .voiceActivation) ?? true,
            triggers: try c.decodeIfPresent([String].self, forKey: .triggers) ?? [],
            tools: try c.decodeIfPresent([AssistantSkillToolGroup].self, forKey: .tools) ?? AssistantSkillToolGroup.allCases,
            approvedSpeakersOnly: try c.decodeIfPresent(Bool.self, forKey: .approvedSpeakersOnly) ?? true,
            realtimePreferred: try c.decodeIfPresent(Bool.self, forKey: .realtimePreferred) ?? false,
            autoGreet: try c.decodeIfPresent(Bool.self, forKey: .autoGreet) ?? false,
            defaultMode: try c.decodeIfPresent(AssistantEngagementMode.self, forKey: .defaultMode) ?? .facilitate,
            coreOutcomePolicy: try c.decodeIfPresent(CoreOutcomePolicy.self, forKey: .coreOutcomePolicy) ?? .full,
            summaryBlockTitle: try c.decodeIfPresent(String.self, forKey: .summaryBlockTitle) ?? "",
            summaryVisibility: try c.decodeIfPresent(ExpertSummaryVisibility.self, forKey: .summaryVisibility) ?? .shared,
            exportDestinationSlug: try c.decodeIfPresent(String.self, forKey: .exportDestinationSlug),
            routeEntireMeeting: try c.decodeIfPresent(Bool.self, forKey: .routeEntireMeeting) ?? false,
            instructions: try c.decodeIfPresent(String.self, forKey: .instructions) ?? "",
            sourceRelativePath: try c.decodeIfPresent(String.self, forKey: .sourceRelativePath),
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt),
            extraFrontmatter: try c.decodeIfPresent([String: String].self, forKey: .extraFrontmatter) ?? [:],
            owningDestinationID: try c.decodeIfPresent(UUID.self, forKey: .owningDestinationID)
        )
    }

    public var isPersonalAssistant: Bool {
        id == Self.personalAssistantID
    }

    public var resolvedSummaryBlockTitle: String {
        summaryBlockTitle.isEmpty ? name : summaryBlockTitle
    }

    public static func sanitizedSlug(from raw: String) -> String {
        let lowered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var previousDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                result.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash && !result.isEmpty {
                result.append("-")
                previousDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return String(result.prefix(64))
    }

    private static func normalizedList(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    public func matches(meetingTitle: String, commandText: String) -> Bool {
        guard enabled else { return false }
        let haystack = (meetingTitle + "\n" + commandText)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if haystack.contains(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            return true
        }
        if haystack.contains(id) { return true }
        return triggers.contains { trigger in
            let needle = trigger.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    /// Selects the skill matching an explicit role clause (`as ...` / `как ...`) first,
    /// falling back to general trigger matching across `commandText`.
    public static func preferredSkill(matching commandText: String, in skills: [AssistantSkill]) -> AssistantSkill? {
        let folded = commandText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ё", with: "е")
        for marker in [" в роли ", " with skill ", " with role ", " как ", " as "] {
            if let range = folded.range(of: marker) {
                let roleTail = String(folded[range.upperBound...])
                if let explicit = skills.first(where: { $0.enabled && $0.matches(meetingTitle: "", commandText: roleTail) }) {
                    return explicit
                }
            }
        }
        return skills.first(where: { $0.enabled && $0.matches(meetingTitle: "", commandText: commandText) })
    }
}

/// Deterministic YAML-frontmatter Markdown codec for Obsidian skill files.
public enum AssistantSkillMarkdownCodec {
    public static func decode(
        _ markdown: String,
        fallbackSlug: String,
        relativePath: String? = nil,
        updatedAt: Date? = nil
    ) -> AssistantSkill {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let (frontmatter, extra, body) = parseFrontmatter(normalized, knownKeys: [
            "id", "name", "role", "enabled", "voice_activation",
            "approved_speakers_only", "realtime_preferred", "auto_greet", "triggers", "tools",
            "default_mode", "core_outcome_policy", "summary_block_title", "summary_visibility",
            "export_destination_slug", "route_entire_meeting"
        ])

        let slugSource = frontmatter["id"]?.scalar ?? fallbackSlug
        let cleanSlug = AssistantSkill.sanitizedSlug(from: slugSource).isEmpty
            ? AssistantSkill.sanitizedSlug(from: fallbackSlug)
            : AssistantSkill.sanitizedSlug(from: slugSource)
        let name = frontmatter["name"]?.scalar?.trimmedNonEmpty
            ?? extractHeadingTitle(in: body)
            ?? cleanSlug
        let role = frontmatter["role"]?.scalar ?? ""
        let enabled = parseBoolScalar(frontmatter["enabled"]?.scalar, default: true)
        let voiceActivation = parseBoolScalar(frontmatter["voice_activation"]?.scalar, default: true)
        let approvedOnly = parseBoolScalar(frontmatter["approved_speakers_only"]?.scalar, default: true)
        let realtimePreferred = parseBoolScalar(frontmatter["realtime_preferred"]?.scalar, default: false)
        let autoGreet = parseBoolScalar(frontmatter["auto_greet"]?.scalar, default: false)
        let defaultMode = frontmatter["default_mode"]?.scalar.flatMap(AssistantEngagementMode.init(rawValue:)) ?? .facilitate
        let coreOutcomePolicy = frontmatter["core_outcome_policy"]?.scalar.flatMap(CoreOutcomePolicy.init(rawValue:)) ?? .full
        let summaryBlockTitle = frontmatter["summary_block_title"]?.scalar ?? ""
        let summaryVisibility = frontmatter["summary_visibility"]?.scalar.flatMap(ExpertSummaryVisibility.init(rawValue:)) ?? .shared
        let exportDestinationSlug = frontmatter["export_destination_slug"]?.scalar
        let routeEntireMeeting = parseBoolScalar(frontmatter["route_entire_meeting"]?.scalar, default: false)
        let triggers = frontmatter["triggers"]?.list ?? []
        let tools = (frontmatter["tools"]?.list ?? []).compactMap(AssistantSkillToolGroup.init(rawValue:))

        return AssistantSkill(
            id: cleanSlug,
            name: name,
            role: role,
            enabled: enabled,
            voiceActivation: voiceActivation,
            triggers: triggers,
            tools: tools.isEmpty ? (frontmatter["tools"] != nil ? [] : AssistantSkillToolGroup.allCases) : tools,
            approvedSpeakersOnly: approvedOnly,
            realtimePreferred: realtimePreferred,
            autoGreet: autoGreet,
            defaultMode: defaultMode,
            coreOutcomePolicy: coreOutcomePolicy,
            summaryBlockTitle: summaryBlockTitle,
            summaryVisibility: summaryVisibility,
            exportDestinationSlug: exportDestinationSlug,
            routeEntireMeeting: routeEntireMeeting,
            instructions: body,
            sourceRelativePath: relativePath ?? "Skills/\(cleanSlug).md",
            updatedAt: updatedAt,
            extraFrontmatter: extra
        )
    }

    public static func encode(_ skill: AssistantSkill) -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(yamlScalar(skill.id))")
        lines.append("name: \(yamlScalar(skill.name))")
        if !skill.role.isEmpty {
            lines.append("role: \(yamlScalar(skill.role))")
        }
        lines.append("enabled: \(skill.enabled ? "true" : "false")")
        lines.append("voice_activation: \(skill.voiceActivation ? "true" : "false")")
        lines.append("approved_speakers_only: \(skill.approvedSpeakersOnly ? "true" : "false")")
        lines.append("realtime_preferred: \(skill.realtimePreferred ? "true" : "false")")
        lines.append("auto_greet: \(skill.autoGreet ? "true" : "false")")
        if skill.defaultMode != .facilitate {
            lines.append("default_mode: \(yamlScalar(skill.defaultMode.rawValue))")
        }
        if skill.coreOutcomePolicy != .full {
            lines.append("core_outcome_policy: \(yamlScalar(skill.coreOutcomePolicy.rawValue))")
        }
        if !skill.summaryBlockTitle.isEmpty {
            lines.append("summary_block_title: \(yamlScalar(skill.summaryBlockTitle))")
        }
        if skill.summaryVisibility != .shared {
            lines.append("summary_visibility: \(yamlScalar(skill.summaryVisibility.rawValue))")
        }
        if let destSlug = skill.exportDestinationSlug, !destSlug.isEmpty {
            lines.append("export_destination_slug: \(yamlScalar(destSlug))")
        }
        if skill.routeEntireMeeting {
            lines.append("route_entire_meeting: true")
        }
        lines.append("triggers: [\(skill.triggers.map(yamlScalar).joined(separator: ", "))]")
        lines.append("tools: [\(skill.tools.map { yamlScalar($0.rawValue) }.joined(separator: ", "))]")
        for key in skill.extraFrontmatter.keys.sorted() {
            if let value = skill.extraFrontmatter[key] {
                lines.append("\(key): \(yamlScalar(value))")
            }
        }
        lines.append("---")
        let trimmedBody = skill.instructions.trimmingCharacters(in: .newlines)
        if trimmedBody.isEmpty {
            return lines.joined(separator: "\n") + "\n"
        }
        return lines.joined(separator: "\n") + "\n\n" + trimmedBody + "\n"
    }

    enum YAMLValue {
        case scalarValue(String)
        case listValue([String])

        var scalar: String? {
            if case .scalarValue(let s) = self { return s }
            return nil
        }
        var list: [String] {
            switch self {
            case .listValue(let items): return items
            case .scalarValue(let s):
                return s.isEmpty ? [] : [s]
            }
        }
    }

    static func parseFrontmatter(_ text: String, knownKeys: Set<String>) -> ([String: YAMLValue], [String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], [:], text)
        }
        guard let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], [:], text)
        }
        let headerLines = Array(lines[1..<endIndex])
        let bodyLines = Array(lines[(endIndex + 1)...])
        let body = bodyLines.joined(separator: "\n").replacingOccurrences(of: #"^\n+"#, with: "", options: .regularExpression)

        var values: [String: YAMLValue] = [:]
        var extra: [String: String] = [:]
        var activeListKey: String?

        for rawLine in headerLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), let listKey = activeListKey {
                let item = unquote(String(trimmed.dropFirst(2)))
                var existing = values[listKey]?.list ?? []
                if !item.isEmpty { existing.append(item) }
                values[listKey] = .listValue(existing)
                continue
            }
            activeListKey = nil
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if rawValue.isEmpty {
                activeListKey = key
                values[key] = .listValue([])
            } else if rawValue.hasPrefix("[") && rawValue.hasSuffix("]") {
                let inner = String(rawValue.dropFirst().dropLast())
                let items = parseInlineList(inner)
                values[key] = .listValue(items)
            } else {
                let cleaned = unquote(rawValue)
                if knownKeys.contains(key) {
                    values[key] = .scalarValue(cleaned)
                } else {
                    extra[key] = cleaned
                }
            }
        }
        return (values, extra, body)
    }

    private static func parseInlineList(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for ch in inner {
            if let q = quote {
                if ch == q { quote = nil }
                else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                let val = unquote(current)
                if !val.isEmpty { items.append(val) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = unquote(current)
        if !tail.isEmpty { items.append(tail) }
        return items
    }

    private static func unquote(_ s: String) -> String {
        var trimmed = s.trimmingCharacters(in: .whitespaces)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func yamlScalar(_ value: String) -> String {
        let needsQuotes = value.isEmpty ||
            value.contains(":") || value.contains("#") || value.contains("[") ||
            value.contains("]") || value.contains(",") || value.contains("\"") ||
            value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func parseBoolScalar(_ value: String?, default fallback: Bool) -> Bool {
        guard let lowered = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !lowered.isEmpty else { return fallback }
        switch lowered {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return fallback
        }
    }

    static func extractHeadingTitle(in markdown: String) -> String? {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Built-in starter Obsidian skills shipped with Rock and editable as plain Markdown files.
public enum DefaultAssistantSkills {
    public static let defaultIDs: Set<String> = Set(all.map(\.id))

    /// Universal personal assistant role underlying default `Mentions`, `Follow`, `Observe`, `Advise`, and `Participate` modes.
    public static let personalAssistant = AssistantSkill(
        id: AssistantSkill.personalAssistantID,
        name: "Personal Assistant",
        role: "Tracks meetings for you, alerts on mentions, takes quiet notes, advises privately, or participates on your behalf.",
        enabled: true,
        voiceActivation: false,
        triggers: [],
        tools: [.obsidianSearch, .meetingSearch, .tasks, .meetingSummary],
        approvedSpeakersOnly: true,
        realtimePreferred: false,
        autoGreet: false,
        defaultMode: .follow,
        coreOutcomePolicy: .full,
        summaryBlockTitle: "Personal Assistant Notes",
        summaryVisibility: .privateOwnerOnly,
        instructions: """
        # Personal Assistant

        You act as the user's private meeting assistant across live calls and post-meeting synthesis.
        - In **Observe** mode, record concise factual highlights, decisions, risks, and action-item candidates without interrupting.
        - In **Advise** mode, surface sharp follow-up questions, missed context from notes/history, and concise decision framing.
        - Always ground observations in `[L#]` transcript references and distinguish what the user said from what others proposed.
        """
    )

    public static func skill(id: String) -> AssistantSkill? {
        if id == AssistantSkill.personalAssistantID {
            return personalAssistant
        }
        return all.first { $0.id == id }
    }

    public static let all: [AssistantSkill] = [
        AssistantSkill(
            id: "scrum-master",
            name: "Scrum Master & Daily Standup",
            role: "Runs daily standups, shares the live Jira board, keeps updates crisp, and executes approved Jira/task updates.",
            enabled: true,
            voiceActivation: true,
            triggers: ["standup", "daily", "scrum", "kanban", "board", "стендап", "дейли", "скрам", "доска"],
            tools: [.boardShare, .jira, .tasks, .obsidianSearch, .meetingSearch, .meetingSummary, .meetingJoin],
            approvedSpeakersOnly: true,
            realtimePreferred: true,
            autoGreet: true,
            instructions: """
            # Scrum Master & Daily Standup

            You act as the team's Scrum Master and Meeting Facilitator inside live calls or Assistant requests.

            ## How to Run a Standup
            1. At the start of a standup, if an Effective Jira Board URL is configured and `board_is_sharing` is `false`, automatically open and share the board into the active meeting (`rocknroll_control_board` with `command: "share_to_meeting"`). Then inspect visible cards (`rocknroll_control_board` `inspect`) and board members (`rocknroll_jira_action` `board_users`, plus `rocknroll_manage_people` `lookup`) so you know who is in the call and what tasks they own.
            2. Track who has already reported vs who hasn't in the recent transcript. Before calling on a teammate for their update while the board is open/shared, **visibly select their board quick-filter** (`rocknroll_control_board` with `command: "select_person_filter"`, `query: "<person name>"`) and scroll/focus cards if needed so everyone sees their tasks on screen. When returning to general board review, call `clear_filters`.
            3. Invite each teammate sequentially (yesterday, today, blockers). Wait politely for them to finish speaking before replying; after each person finishes their update, briefly acknowledge it, ask about blockers if unmentioned, execute any requested Jira/task updates, and explicitly invite the next teammate by name. Once everyone has spoken, summarize key blockers and offer to stop sharing (`rocknroll_control_board` `stop_share`) if appropriate.
            4. When the user mentions quick filters ("квикфильтр", "фильтр по имени ..."), scrolling, clicking/opening cards, or starting/stopping board sharing ("расшарь доску", "останови показ/шаринг"), ALWAYS use `rocknroll_control_board` (`select_person_filter`, `filter`, `clear_filters`, `inspect`, `share_to_meeting`, `stop_share`, `move_issue`, `click`, `scroll`).
            5. When status changes, descriptions, assignments, or comments are agreed during the call, execute them live (`rocknroll_control_board` `move_issue` or `rocknroll_jira_action` `transition` / `assign` / `comment` / `create`) so the card updates visibly on the board. When creating or searching Jira issues, use the meeting's Effective/Board-Derived Jira Project Keys first instead of asking the user for a project key if the board is already open, and interpret ASR-garbled project keys against visible board project keys.
            6. Check `People.md` (`rocknroll_manage_people` `lookup`) to resolve spoken or meeting display names into Jira usernames/account IDs — never put an unmapped meeting name directly into JQL. If a person's Jira handle is missing, run `rocknroll_jira_action` (`search_users` or `board_users`, or `copy_user_from_issue` if they ask to copy from an assigned card), ask the speaker to confirm the matching candidate BEFORE saving `People.md`, and then run the Jira action.

            ## Voice Style & Authorization
            - Speak naturally in 1–3 crisp sentences in the meeting language; NEVER repeat the same sentence twice and NEVER read out markdown backticks or raw formatting syntax.
            - Never create duplicate local tasks: do NOT call both `rocknroll_create_task` and `rocknroll_update_meeting_artifacts(action_items:)` for the same action item, and check existing tasks before creating another one. Use `rocknroll_update_meeting_artifacts` (`summary_append`, `decisions`, `open_questions`) for meeting notes/status updates, and `rocknroll_create_task` (with `sync_to_jira: true` when Jira creation is requested or configured) for new concrete action items.
            - Only execute task creation, updates, reassignments, or Jira changes when instructed by an **approved speaker** (the local app owner is always approved) or directly confirmed in chat/voice by the owner.
            """
        ),
        AssistantSkill(
            id: "task-manager",
            name: "Task & Backlog Manager",
            role: "Creates, updates, prioritizes, assigns, and syncs action items across local tasks, Jira, Reminders, and People.md.",
            enabled: true,
            voiceActivation: true,
            triggers: ["task", "todo", "jira", "assign", "reassign", "backlog", "задача", "задачи", "назначь", "переназначь"],
            tools: [.tasks, .jira, .obsidianSearch, .meetingSearch, .calendarSchedule, .meetingSummary],
            approvedSpeakersOnly: true,
            realtimePreferred: false,
            instructions: """
            # Task & Backlog Manager

            You manage team and personal action items across meeting outcomes, Jira, and Apple Reminders.

            ## Core Responsibilities
            1. When asked to create, complete, edit, assign, or reassign a task:
               - Search existing tasks first (`rocknroll_list_tasks` or `rocknroll_search`) to avoid duplicates and obtain the current `task_id` and `expected_revision` when updating.
               - Resolve assignee names through `People.md` (`rocknroll_manage_people` with `lookup`) so meeting display names map cleanly to Jira usernames/account IDs. If not mapped in `People.md`: if the user asks to copy it from a task on the board, call `rocknroll_jira_action` (`operation: "copy_user_from_issue"`); otherwise search Jira users (`rocknroll_jira_action` `search_users` or `board_users`) and ask participants to confirm a candidate BEFORE saving to `People.md` (`upsert`).
               - For direct Jira board actions (creating an issue, moving columns/status, assigning, or commenting), call `rocknroll_jira_action` (`create`, `transition`, `assign`, `comment`), and use `rocknroll_create_task` / `rocknroll_update_task` for local meeting tasks.
            2. When a person's Jira handle, email, or nickname/alias is mentioned during a conversation, offer or save the mapping via `rocknroll_manage_people` (`upsert`) so future assignments work automatically.
            3. Keep meeting summaries accurate: after significant task changes inside a meeting, reflect decisions or updated owners via `rocknroll_update_meeting_artifacts`.
            4. If the user asks to book a follow-up working session for a task or blocker, schedule it with `rocknroll_schedule_meeting`.
            """
        ),
        AssistantSkill(
            id: "retro-and-planning",
            name: "Retrospective & Sprint Planning Facilitator",
            role: "Leads sprint planning and retrospectives grounded in past meeting summaries, transcripts, and Obsidian team notes.",
            enabled: true,
            voiceActivation: true,
            triggers: ["retro", "retrospective", "planning", "sprint", "ретро", "ретроспектива", "планирование", "спринт"],
            tools: [.tasks, .jira, .obsidianSearch, .meetingSearch, .calendarSchedule, .meetingSummary, .meetingJoin],
            approvedSpeakersOnly: true,
            realtimePreferred: true,
            instructions: """
            # Retrospective & Sprint Planning Facilitator

            You lead structured Agile Retrospectives and Sprint Planning ceremonies.

            ## Gathering Context Before Answering
            - Never assume all sprint context is already loaded: search Obsidian notes (`rocknroll_search_knowledge`) and past meetings/outcomes/transcripts (`rocknroll_list_meetings`, `rocknroll_search`, `rocknroll_get_outcome`, `rocknroll_get_transcript`) when asked about velocity, carryover work, or recurring blockers.

            ## Running the Session
            - **Retrospective**: Group discussion into Went Well, Needs Improvement, and Concrete Experiments. Push for clear owners and due dates on every improvement action.
            - **Sprint Planning**: Review open carryover tasks (`rocknroll_list_tasks`), clarify acceptance criteria, assign owners using `People.md`, and create/update sprint tasks (`rocknroll_create_task` / `rocknroll_update_task`).
            - Record all agreed sprint goals, decisions, open questions, and action items with `rocknroll_update_meeting_artifacts`.
            - Schedule follow-up check-ins or the next retrospective on the calendar when requested (`rocknroll_schedule_meeting`).
            """
        ),
        AssistantSkill(
            id: "hiring-interviewer",
            name: "Hiring Interviewer",
            role: "Silently coaches live interviews with probes and rubric pacing, then produces an evidence-cited Hiring Evaluation.",
            enabled: true,
            voiceActivation: false,
            triggers: ["interview", "candidate", "hiring", "собеседование", "кандидат", "интервью", "найм"],
            tools: [.obsidianSearch, .meetingSearch, .meetingSummary],
            approvedSpeakersOnly: true,
            realtimePreferred: false,
            autoGreet: false,
            defaultMode: .advise,
            coreOutcomePolicy: .expertOnly,
            summaryBlockTitle: "Hiring Evaluation",
            summaryVisibility: .privateOwnerOnly,
            routeEntireMeeting: true,
            instructions: """
            # Hiring Interviewer

            You act as a structured, evidence-driven hiring interview co-pilot and evaluator.

            ## Live Coaching Rules (`Observe` / `Advise`)
            - Stay **completely silent to the room** unless explicitly launched in `Facilitate` mode.
            - Distinguish `[Interviewer / Team]` statements from `[Candidate]` answers: never credit interviewer explanations to the candidate.
            - In **Observe** mode: silently log verified candidate claims, concrete examples, and potential concerns mapped to the position rubric.
            - In **Advise** mode:
              - Surface sharp **follow-up probes** when the candidate stays high-level ("we built" without personal ownership, missing failure modes, unverified scale/latency claims).
              - Flag **contradictions** with earlier statements, resume/notes context, or stated trade-offs.
              - Track **rubric pacing** so critical dimensions aren't left unassessed near the end of the slot.

            ## Post-Meeting Evaluation (`Hiring Evaluation`)
            - Ground every rating in verbatim or closely paraphrased `[L#]` transcript citations.
            - Strictly distinguish **Weak Signal** (asked and answered poorly or vaguely) from **Not Assessed** (not covered in this interview).
            - Never penalize ASR transcription glitches, accents, or bilingual technical code-switching.
            - Structure the evaluation with:
              1. **Verdict & Level Calibration** (`Strong Hire` / `Hire` / `Leaning Hire` / `Leaning No Hire` / `No Hire` + calibrated level)
              2. **Rubric Scorecard** (rating + `[L#]` evidence per dimension, or `Not Assessed`)
              3. **Key Strengths & Red Flags / Risks**
              4. **Suggested Probes for Next Round**
            """
        ),
    ]
}
