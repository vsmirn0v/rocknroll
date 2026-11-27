import Foundation

/// A reusable per-role context & rubric preset stored as Markdown + YAML frontmatter under
/// `Rock Assistant/Presets/<skill-id>/<preset-slug>.md` (for example, individual hiring positions
/// under `hiring-interviewer`).
public struct AssistantRolePreset: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var skillID: String
    public var name: String
    public var enabled: Bool
    public var defaultMode: AssistantEngagementMode?
    public var coreOutcomePolicy: CoreOutcomePolicy?
    public var exportDestinationSlug: String?
    public var routeEntireMeeting: Bool?
    public var focusSpeakerRole: String
    public var rubricDimensions: [String]
    public var instructions: String
    public var sourceRelativePath: String?
    public var updatedAt: Date?
    public var extraFrontmatter: [String: String]
    /// Transient runtime identifier of the vault destination that owns this preset file.
    public var owningDestinationID: UUID?

    public var compositeKey: String { "\(skillID)/\(id)" }

    public init(
        id: String,
        skillID: String,
        name: String,
        enabled: Bool = true,
        defaultMode: AssistantEngagementMode? = nil,
        coreOutcomePolicy: CoreOutcomePolicy? = nil,
        exportDestinationSlug: String? = nil,
        routeEntireMeeting: Bool? = nil,
        focusSpeakerRole: String = "",
        rubricDimensions: [String] = [],
        instructions: String,
        sourceRelativePath: String? = nil,
        updatedAt: Date? = nil,
        extraFrontmatter: [String: String] = [:],
        owningDestinationID: UUID? = nil
    ) {
        let cleanSkill = AssistantSkill.sanitizedSlug(from: skillID)
        self.skillID = cleanSkill.isEmpty ? "custom-skill" : cleanSkill
        let slug = AssistantSkill.sanitizedSlug(from: id.isEmpty ? name : id)
        self.id = slug.isEmpty ? "default-preset" : slug
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanName.isEmpty ? self.id : cleanName
        self.enabled = enabled
        self.defaultMode = defaultMode
        self.coreOutcomePolicy = coreOutcomePolicy
        let cleanDest = exportDestinationSlug?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.exportDestinationSlug = (cleanDest?.isEmpty == false) ? cleanDest : nil
        self.routeEntireMeeting = routeEntireMeeting
        self.focusSpeakerRole = focusSpeakerRole.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rubricDimensions = Self.normalizedList(rubricDimensions)
        self.instructions = instructions.trimmingCharacters(in: .newlines)
        self.sourceRelativePath = sourceRelativePath ?? "Presets/\(self.skillID)/\(self.id).md"
        self.updatedAt = updatedAt
        self.extraFrontmatter = extraFrontmatter
        self.owningDestinationID = owningDestinationID
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
}

public enum AssistantRolePresetMarkdownCodec {
    public static func decode(
        _ markdown: String,
        fallbackSkillID: String,
        fallbackSlug: String,
        relativePath: String? = nil,
        updatedAt: Date? = nil
    ) -> AssistantRolePreset {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let (frontmatter, extra, body) = AssistantSkillMarkdownCodec.parseFrontmatter(
            normalized,
            knownKeys: [
                "id", "skill_id", "name", "enabled", "default_mode",
                "core_outcome_policy", "export_destination_id", "export_destination_slug",
                "route_entire_meeting", "focus_speaker_role", "rubric_dimensions"
            ]
        )

        let skillSource = frontmatter["skill_id"]?.scalar ?? fallbackSkillID
        let cleanSkill = AssistantSkill.sanitizedSlug(from: skillSource).isEmpty
            ? AssistantSkill.sanitizedSlug(from: fallbackSkillID)
            : AssistantSkill.sanitizedSlug(from: skillSource)

        let slugSource = frontmatter["id"]?.scalar ?? fallbackSlug
        let cleanSlug = AssistantSkill.sanitizedSlug(from: slugSource).isEmpty
            ? AssistantSkill.sanitizedSlug(from: fallbackSlug)
            : AssistantSkill.sanitizedSlug(from: slugSource)

        let name = frontmatter["name"]?.scalar?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
            ?? AssistantSkillMarkdownCodec.extractHeadingTitle(in: body)
            ?? cleanSlug
        let enabled = AssistantSkillMarkdownCodec.parseBoolScalar(frontmatter["enabled"]?.scalar, default: true)
        let defaultMode = frontmatter["default_mode"]?.scalar.flatMap(AssistantEngagementMode.init(rawValue:))
        let policy = frontmatter["core_outcome_policy"]?.scalar.flatMap(CoreOutcomePolicy.init(rawValue:))
        let destSlug = frontmatter["export_destination_slug"]?.scalar ?? frontmatter["export_destination_id"]?.scalar
        let routeEntire: Bool? = frontmatter["route_entire_meeting"]?.scalar.map {
            AssistantSkillMarkdownCodec.parseBoolScalar($0, default: false)
        }
        let focusRole = frontmatter["focus_speaker_role"]?.scalar ?? ""
        let rubric = frontmatter["rubric_dimensions"]?.list ?? []

        return AssistantRolePreset(
            id: cleanSlug,
            skillID: cleanSkill,
            name: name,
            enabled: enabled,
            defaultMode: defaultMode,
            coreOutcomePolicy: policy,
            exportDestinationSlug: destSlug,
            routeEntireMeeting: routeEntire,
            focusSpeakerRole: focusRole,
            rubricDimensions: rubric,
            instructions: body,
            sourceRelativePath: relativePath ?? "Presets/\(cleanSkill)/\(cleanSlug).md",
            updatedAt: updatedAt,
            extraFrontmatter: extra
        )
    }

    public static func encode(_ preset: AssistantRolePreset) -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(AssistantSkillMarkdownCodec.yamlScalar(preset.id))")
        lines.append("skill_id: \(AssistantSkillMarkdownCodec.yamlScalar(preset.skillID))")
        lines.append("name: \(AssistantSkillMarkdownCodec.yamlScalar(preset.name))")
        lines.append("enabled: \(preset.enabled ? "true" : "false")")
        if let defaultMode = preset.defaultMode {
            lines.append("default_mode: \(AssistantSkillMarkdownCodec.yamlScalar(defaultMode.rawValue))")
        }
        if let policy = preset.coreOutcomePolicy {
            lines.append("core_outcome_policy: \(AssistantSkillMarkdownCodec.yamlScalar(policy.rawValue))")
        }
        if let destSlug = preset.exportDestinationSlug, !destSlug.isEmpty {
            lines.append("export_destination_slug: \(AssistantSkillMarkdownCodec.yamlScalar(destSlug))")
        }
        if let routeEntire = preset.routeEntireMeeting {
            lines.append("route_entire_meeting: \(routeEntire ? "true" : "false")")
        }
        if !preset.focusSpeakerRole.isEmpty {
            lines.append("focus_speaker_role: \(AssistantSkillMarkdownCodec.yamlScalar(preset.focusSpeakerRole))")
        }
        if !preset.rubricDimensions.isEmpty {
            lines.append("rubric_dimensions: [\(preset.rubricDimensions.map(AssistantSkillMarkdownCodec.yamlScalar).joined(separator: ", "))]")
        }
        for key in preset.extraFrontmatter.keys.sorted() {
            if let value = preset.extraFrontmatter[key] {
                lines.append("\(key): \(AssistantSkillMarkdownCodec.yamlScalar(value))")
            }
        }
        lines.append("---")
        let trimmedBody = preset.instructions.trimmingCharacters(in: .newlines)
        if trimmedBody.isEmpty {
            return lines.joined(separator: "\n") + "\n"
        }
        return lines.joined(separator: "\n") + "\n\n" + trimmedBody + "\n"
    }

    public static func starterTemplate(skillID: String, presetName: String) -> AssistantRolePreset {
        if skillID == "hiring-interviewer" {
            return AssistantRolePreset(
                id: presetName,
                skillID: skillID,
                name: presetName,
                enabled: true,
                defaultMode: .advise,
                coreOutcomePolicy: .expertOnly,
                routeEntireMeeting: true,
                focusSpeakerRole: "Candidate",
                rubricDimensions: [
                    "Technical Depth & Fundamentals",
                    "System Design & Trade-offs",
                    "Debugging, Quality & Ownership",
                    "Communication & Collaboration"
                ],
                instructions: """
                ## Position & Seniority Bar
                Describe the target level, domain expectations, and key responsibilities for \(presetName).

                ## Must-Ask Areas & Red Flags
                - Verify concrete first-hand ownership ("I designed/debugged" vs. vague "we").
                - Watch for inability to explain failure modes or production trade-offs.

                ## Custom Summary Focus
                Highlight level calibration, concrete evidence per rubric dimension, and follow-up probes for the next stage.
                """
            )
        }
        return AssistantRolePreset(
            id: presetName,
            skillID: skillID,
            name: presetName,
            enabled: true,
            instructions: """
            ## Context & Goals
            Custom context and evaluation focus for \(presetName).
            """
        )
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
