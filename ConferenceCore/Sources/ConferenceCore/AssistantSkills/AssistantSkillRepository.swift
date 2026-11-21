import Foundation

/// Structured + freeform team settings stored in `Rock Assistant/Knowledge/TeamContext.md`.
public struct AssistantTeamContextDocument: Equatable, Sendable {
    public var defaultJiraBoardURL: String
    public var defaultJiraProjectKey: String
    public var defaultCalendarIdentifier: String
    public var notes: String

    public init(
        defaultJiraBoardURL: String = "",
        defaultJiraProjectKey: String = "",
        defaultCalendarIdentifier: String = "",
        notes: String = ""
    ) {
        self.defaultJiraBoardURL = defaultJiraBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultJiraProjectKey = defaultJiraProjectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultCalendarIdentifier = defaultCalendarIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes.trimmingCharacters(in: .newlines)
    }

    public static func starter() -> AssistantTeamContextDocument {
        AssistantTeamContextDocument(
            notes: """
            # Team Context

            Describe sprint conventions, standup order, definition of done, or board preferences here.
            Everything in `Rock Assistant/` is plain Markdown so you can commit it to Git or share an Obsidian vault with your team.
            """
        )
    }

    public static func decode(_ markdown: String) -> AssistantTeamContextDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let endIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return AssistantTeamContextDocument(notes: normalized)
        }
        var board = ""
        var project = ""
        var cal = ""
        for raw in lines[1..<endIdx] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2) ||
               (val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2) {
                val = String(val.dropFirst().dropLast())
            }
            switch key {
            case "default_jira_board_url": board = val
            case "default_jira_project_key": project = val
            case "default_calendar_id": cal = val
            default: break
            }
        }
        let body = Array(lines[(endIdx + 1)...]).joined(separator: "\n")
            .replacingOccurrences(of: #"^\n+"#, with: "", options: .regularExpression)
        return AssistantTeamContextDocument(
            defaultJiraBoardURL: board,
            defaultJiraProjectKey: project,
            defaultCalendarIdentifier: cal,
            notes: body
        )
    }

    public func encode() -> String {
        let quote: (String) -> String = { value in
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        var header = [
            "---",
            "default_jira_board_url: \(quote(defaultJiraBoardURL))",
            "default_jira_project_key: \(quote(defaultJiraProjectKey))",
            "default_calendar_id: \(quote(defaultCalendarIdentifier))",
            "---",
        ]
        if !notes.isEmpty {
            header.append("")
            header.append(notes)
        }
        return header.joined(separator: "\n") + "\n"
    }
}

public struct AssistantKnowledgeSearchHit: Identifiable, Codable, Equatable, Sendable {
    public var id: String { relativePath }
    public var title: String
    public var relativePath: String
    public var kind: String
    public var excerpt: String
    public var score: Double

    public init(title: String, relativePath: String, kind: String, excerpt: String, score: Double) {
        self.title = title
        self.relativePath = relativePath
        self.kind = kind
        self.excerpt = excerpt
        self.score = score
    }
}

/// Manages Obsidian-backed (or local AppSupport fallback) skills, `People.md`, and `TeamContext.md`.
public struct AssistantSkillRepository: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var skillsDirectoryURL: URL {
        rootURL.appendingPathComponent("Skills", isDirectory: true)
    }

    public var knowledgeDirectoryURL: URL {
        rootURL.appendingPathComponent("Knowledge", isDirectory: true)
    }

    public var promptsDirectoryURL: URL {
        rootURL.appendingPathComponent("Prompts", isDirectory: true)
    }

    public var peopleFileURL: URL {
        knowledgeDirectoryURL.appendingPathComponent("People.md", isDirectory: false)
    }

    public var teamContextFileURL: URL {
        knowledgeDirectoryURL.appendingPathComponent("TeamContext.md", isDirectory: false)
    }

    public func promptURL(for kind: AssistantPromptKind) -> URL {
        promptsDirectoryURL.appendingPathComponent(kind.fileName, isDirectory: false)
    }

    private var seededMarkerURL: URL {
        rootURL.appendingPathComponent(".seeded-defaults.json", isDirectory: false)
    }

    public func ensureDefaultsInstalled() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: knowledgeDirectoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: promptsDirectoryURL, withIntermediateDirectories: true)

        var seeded = loadSeededIDs()
        for skill in DefaultAssistantSkills.all {
            let fileURL = skillURL(id: skill.id)
            if fm.fileExists(atPath: fileURL.path) {
                seeded.insert(skill.id)
            } else if !seeded.contains(skill.id) {
                try writeAtomic(AssistantSkillMarkdownCodec.encode(skill), to: fileURL)
                seeded.insert(skill.id)
            }
        }
        for kind in AssistantPromptKind.allCases {
            let marker = "prompt:\(kind.rawValue)"
            let fileURL = promptURL(for: kind)
            if fm.fileExists(atPath: fileURL.path) {
                seeded.insert(marker)
            } else if !seeded.contains(marker) {
                try writeAtomic(DefaultAssistantPrompts.content(for: kind), to: fileURL)
                seeded.insert(marker)
            }
        }
        try saveSeededIDs(seeded)

        if !fm.fileExists(atPath: peopleFileURL.path) {
            try writeAtomic(AssistantPeopleMarkdownCodec.starterMarkdown(), to: peopleFileURL)
        }
        if !fm.fileExists(atPath: teamContextFileURL.path) {
            try writeAtomic(AssistantTeamContextDocument.starter().encode(), to: teamContextFileURL)
        }
    }

    public func restoreDefaultSkill(id: String) throws -> AssistantSkill? {
        guard let template = DefaultAssistantSkills.skill(id: id) else { return nil }
        try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        try writeAtomic(AssistantSkillMarkdownCodec.encode(template), to: skillURL(id: template.id))
        var seeded = loadSeededIDs()
        seeded.insert(template.id)
        try saveSeededIDs(seeded)
        return template
    }

    public func restoreAllDefaultSkills() throws {
        try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        var seeded = loadSeededIDs()
        for skill in DefaultAssistantSkills.all {
            try writeAtomic(AssistantSkillMarkdownCodec.encode(skill), to: skillURL(id: skill.id))
            seeded.insert(skill.id)
        }
        try saveSeededIDs(seeded)
    }

    public func listSkills() -> [AssistantSkill] {
        try? ensureDefaultsInstalled()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: skillsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DefaultAssistantSkills.all
        }

        var loaded: [AssistantSkill] = []
        for file in files where file.pathExtension.caseInsensitiveCompare("md") == .orderedSame {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let slug = file.deletingPathExtension().lastPathComponent
            let skill = AssistantSkillMarkdownCodec.decode(
                text,
                fallbackSlug: slug,
                relativePath: "Skills/\(file.lastPathComponent)",
                updatedAt: values.contentModificationDate
            )
            loaded.append(skill)
        }
        return loaded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func skill(id: String) -> AssistantSkill? {
        let slug = AssistantSkill.sanitizedSlug(from: id)
        guard !slug.isEmpty else { return nil }
        let file = skillURL(id: slug)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return AssistantSkillMarkdownCodec.decode(
                text,
                fallbackSlug: slug,
                relativePath: "Skills/\(file.lastPathComponent)",
                updatedAt: modified
            )
        }
        return listSkills().first { $0.id == slug }
    }

    @discardableResult
    public func saveSkill(_ skill: AssistantSkill) throws -> AssistantSkill {
        try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        var clean = skill
        clean.sourceRelativePath = "Skills/\(clean.id).md"
        clean.updatedAt = Date()
        try writeAtomic(AssistantSkillMarkdownCodec.encode(clean), to: skillURL(id: clean.id))
        return clean
    }

    public func deleteSkill(id: String) throws {
        let slug = AssistantSkill.sanitizedSlug(from: id)
        guard !slug.isEmpty else { return }
        let file = skillURL(id: slug)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        var seeded = loadSeededIDs()
        seeded.insert(slug)
        try? saveSeededIDs(seeded)
    }

    public func searchSkills(query: String, enabledOnly: Bool = false) -> [AssistantSkill] {
        let all = listSkills().filter { !enabledOnly || $0.enabled }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let folded = AssistantPersonEntry.fold(trimmed)
        return all.filter { skill in
            AssistantPersonEntry.fold(skill.id).contains(folded) ||
            AssistantPersonEntry.fold(skill.name).contains(folded) ||
            AssistantPersonEntry.fold(skill.role).contains(folded) ||
            AssistantPersonEntry.fold(skill.instructions).contains(folded) ||
            skill.triggers.contains { AssistantPersonEntry.fold($0).contains(folded) }
        }
    }

    public func loadPeople() -> AssistantPeopleDirectory {
        try? ensureDefaultsInstalled()
        guard let text = try? String(contentsOf: peopleFileURL, encoding: .utf8) else {
            return AssistantPeopleDirectory()
        }
        return AssistantPeopleMarkdownCodec.decode(text)
    }

    public func savePeople(_ directory: AssistantPeopleDirectory) throws {
        try FileManager.default.createDirectory(at: knowledgeDirectoryURL, withIntermediateDirectories: true)
        try writeAtomic(AssistantPeopleMarkdownCodec.encode(directory), to: peopleFileURL)
    }

    @discardableResult
    public func upsertPerson(_ entry: AssistantPersonEntry) throws -> AssistantPeopleDirectory {
        var directory = loadPeople()
        directory.upsert(entry)
        try savePeople(directory)
        return directory
    }

    public func loadTeamContext() -> AssistantTeamContextDocument {
        try? ensureDefaultsInstalled()
        guard let text = try? String(contentsOf: teamContextFileURL, encoding: .utf8) else {
            return .starter()
        }
        return AssistantTeamContextDocument.decode(text)
    }

    public func saveTeamContext(_ doc: AssistantTeamContextDocument) throws {
        try FileManager.default.createDirectory(at: knowledgeDirectoryURL, withIntermediateDirectories: true)
        try writeAtomic(doc.encode(), to: teamContextFileURL)
    }

    // MARK: - Core Obsidian Prompts (`Prompts/*.md`)

    public func listPrompts() -> [AssistantPromptDocument] {
        AssistantPromptKind.allCases.map(loadPrompt)
    }

    public func loadPrompt(_ kind: AssistantPromptKind) -> AssistantPromptDocument {
        try? ensureDefaultsInstalled()
        let url = promptURL(for: kind)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return AssistantPromptDocument(kind: kind, content: text, relativePath: kind.relativePath, updatedAt: modified)
        }
        return AssistantPromptDocument(
            kind: kind,
            content: DefaultAssistantPrompts.content(for: kind),
            relativePath: kind.relativePath
        )
    }

    @discardableResult
    public func savePrompt(_ kind: AssistantPromptKind, content: String) throws -> AssistantPromptDocument {
        try FileManager.default.createDirectory(at: promptsDirectoryURL, withIntermediateDirectories: true)
        let normalized = content.trimmingCharacters(in: .newlines) + "\n"
        try writeAtomic(normalized, to: promptURL(for: kind))
        var seeded = loadSeededIDs()
        seeded.insert("prompt:\(kind.rawValue)")
        try? saveSeededIDs(seeded)
        return AssistantPromptDocument(kind: kind, content: normalized, relativePath: kind.relativePath, updatedAt: Date())
    }

    @discardableResult
    public func restoreDefaultPrompt(_ kind: AssistantPromptKind) throws -> AssistantPromptDocument {
        let starter = DefaultAssistantPrompts.content(for: kind)
        return try savePrompt(kind, content: starter)
    }

    /// Resolves active skills (explicitly pinned skills + trigger-matched skills for this meeting/command)
    /// and compiles compact Obsidian-backed guidance + BasePersona for an LLM or Realtime turn.
    public func renderPromptContext(
        explicitSkillIDs: [String] = [],
        meetingTitle: String = "",
        commandText: String = "",
        includePeopleLimit: Int = 24
    ) -> (instructions: String, selectedSkills: [AssistantSkill], people: AssistantPeopleDirectory, teamContext: AssistantTeamContextDocument, basePersona: String) {
        let allSkills = listSkills().filter(\.enabled)
        let people = loadPeople()
        let team = loadTeamContext()
        let basePersona = loadPrompt(.basePersona).content.trimmingCharacters(in: .whitespacesAndNewlines)

        var selected: [AssistantSkill] = []
        var seenSkillIDs: Set<String> = []
        if !explicitSkillIDs.isEmpty {
            let wanted = explicitSkillIDs.map { AssistantSkill.sanitizedSlug(from: $0) }
            for id in wanted {
                if let skill = allSkills.first(where: { $0.id == id }), seenSkillIDs.insert(skill.id).inserted {
                    selected.append(skill)
                }
            }
        }
        if !meetingTitle.isEmpty || !commandText.isEmpty {
            let matched = allSkills.filter { $0.matches(meetingTitle: meetingTitle, commandText: commandText) }
            for skill in matched where seenSkillIDs.insert(skill.id).inserted {
                selected.append(skill)
            }
        }

        var parts: [String] = []
        if !team.defaultJiraBoardURL.isEmpty || !team.defaultJiraProjectKey.isEmpty || !team.defaultCalendarIdentifier.isEmpty || !team.notes.isEmpty {
            var block = "## Team Context (Obsidian Knowledge/TeamContext.md)\n"
            if !team.defaultJiraBoardURL.isEmpty { block += "- Default Jira Board URL: \(team.defaultJiraBoardURL)\n" }
            if !team.defaultJiraProjectKey.isEmpty { block += "- Default Jira Project Key: \(team.defaultJiraProjectKey)\n" }
            if !team.defaultCalendarIdentifier.isEmpty { block += "- Preferred Calendar ID: \(team.defaultCalendarIdentifier)\n" }
            if !team.notes.isEmpty { block += "\n\(team.notes.prefix(1_200))" }
            parts.append(block)
        }

        if !people.entries.isEmpty {
            var rows = ["## Known Team Members & Jira Mappings (`Knowledge/People.md`, showing up to \(includePeopleLimit)):"]
            for person in people.entries.prefix(includePeopleLimit) {
                let jira = person.jiraUsername ?? person.jiraAccountID ?? "unmapped"
                let aliases = person.aliases.isEmpty ? "" : " aliases=[\(person.aliases.joined(separator: ", "))]"
                let voice = person.approvedVoiceCommander ? " approved_voice=yes" : ""
                let roleText = person.role.map { " role=\($0)" } ?? ""
                rows.append("- \(person.displayName)\(aliases) -> jira=\(jira)\(roleText)\(voice)")
            }
            parts.append(rows.joined(separator: "\n"))
        }

        let catalogNames = allSkills.map { "- `\($0.id)`: \($0.name) — \($0.role)" }
        if !catalogNames.isEmpty {
            parts.append("## Available Obsidian Skills (`Skills/*.md`):\n" + catalogNames.joined(separator: "\n") +
                         "\nUse `rocknroll_get_skill` to read any skill on demand and `rocknroll_search_knowledge` / `rocknroll_search` for large vaults or historical meetings.")
        }

        for skill in selected.prefix(4) {
            parts.append("### Active Skill: \(skill.name) (`\(skill.id)`)\n" + String(skill.instructions.prefix(4_000)))
        }

        return (parts.joined(separator: "\n\n"), selected, people, team, basePersona)
    }

    /// Searches Skills, Prompts, People.md, TeamContext.md, and optional extra Obsidian vault Markdown files on demand.
    public func searchKnowledge(
        query: String,
        extraVaultRoot: URL? = nil,
        limit: Int = 8
    ) -> [AssistantKnowledgeSearchHit] {
        let needle = AssistantPersonEntry.fold(query)
        let tokens = needle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        var searchRoots: [(url: URL, base: URL, kind: String)] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension.caseInsensitiveCompare("md") == .orderedSame {
                let kind: String
                if file.path.contains("/Skills/") {
                    kind = "skill"
                } else if file.path.contains("/Prompts/") {
                    kind = "prompt"
                } else {
                    kind = "knowledge"
                }
                searchRoots.append((file, rootURL, kind))
            }
        }
        if let extraVaultRoot, extraVaultRoot.standardizedFileURL != rootURL.standardizedFileURL {
            if let enumerator = fm.enumerator(at: extraVaultRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                var visited = 0
                for case let file as URL in enumerator {
                    visited += 1
                    if visited > 1_500 { break }
                    guard let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                          vals.isSymbolicLink != true, vals.isRegularFile == true,
                          let size = vals.fileSize, size <= 262_144,
                          file.pathExtension.caseInsensitiveCompare("md") == .orderedSame else { continue }
                    if file.path.hasPrefix(rootURL.path + "/") { continue }
                    searchRoots.append((file, extraVaultRoot, "obsidian"))
                }
            }
        }

        var hits: [AssistantKnowledgeSearchHit] = []
        let rootPrefixCount = rootURL.path.hasSuffix("/") ? rootURL.path.count : rootURL.path.count + 1
        for item in searchRoots {
            guard let text = try? String(contentsOf: item.url, encoding: .utf8), !text.isEmpty else { continue }
            let foldedText = AssistantPersonEntry.fold(text)
            let basePrefix = item.base.path.hasSuffix("/") ? item.base.path.count : item.base.path.count + 1
            let relPath = item.url.path.count > basePrefix ? String(item.url.path.dropFirst(basePrefix)) : item.url.lastPathComponent
            let title = item.url.deletingPathExtension().lastPathComponent
            let foldedTitle = AssistantPersonEntry.fold(title + " " + relPath)

            var score = 0.0
            for token in tokens {
                if foldedTitle.contains(token) { score += 3.0 }
                if foldedText.contains(token) { score += 1.5 }
            }
            if foldedText.contains(needle) { score += 2.0 }
            guard score > 0 else { continue }

            let excerpt = bestExcerpt(in: text, tokens: tokens, maxLength: 360)
            let displayPath = item.url.path.hasPrefix(rootURL.path + "/")
                ? String(item.url.path.dropFirst(rootPrefixCount))
                : relPath
            hits.append(AssistantKnowledgeSearchHit(
                title: title,
                relativePath: displayPath,
                kind: item.kind,
                excerpt: excerpt,
                score: score
            ))
        }

        return hits
            .sorted { $0.score == $1.score ? $0.relativePath < $1.relativePath : $0.score > $1.score }
            .prefix(max(1, min(limit, 30)))
            .map { $0 }
    }

    private func bestExcerpt(in text: String, tokens: [String], maxLength: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let foldedLine = AssistantPersonEntry.fold(line)
            if tokens.contains(where: { foldedLine.contains($0) }) {
                let start = max(0, idx - 1)
                let end = min(lines.count - 1, idx + 3)
                let slice = lines[start...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return slice.count > maxLength ? String(slice.prefix(maxLength)) + "…" : slice
            }
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > maxLength ? String(cleaned.prefix(maxLength)) + "…" : cleaned
    }

    private func skillURL(id: String) -> URL {
        let slug = AssistantSkill.sanitizedSlug(from: id)
        return skillsDirectoryURL.appendingPathComponent("\(slug).md", isDirectory: false)
    }

    private func writeAtomic(_ text: String, to destination: URL) throws {
        guard let data = text.data(using: .utf8) else { return }
        try data.write(to: destination, options: [.atomic])
    }

    private func loadSeededIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: seededMarkerURL),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }

    private func saveSeededIDs(_ ids: Set<String>) throws {
        let data = try JSONEncoder().encode(ids.sorted())
        try data.write(to: seededMarkerURL, options: [.atomic])
    }
}
