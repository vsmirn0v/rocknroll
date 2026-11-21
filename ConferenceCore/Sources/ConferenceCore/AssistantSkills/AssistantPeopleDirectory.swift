import Foundation

/// Canonical member identity bridging meeting speaker names, Obsidian aliases,
/// voice-command authorization, and Jira assignee fields.
public struct AssistantPersonEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var aliases: [String]
    public var jiraUsername: String?
    public var jiraAccountID: String?
    public var email: String?
    public var role: String?
    public var approvedVoiceCommander: Bool
    public var notes: String?

    public init(
        id: String? = nil,
        displayName: String,
        aliases: [String] = [],
        jiraUsername: String? = nil,
        jiraAccountID: String? = nil,
        email: String? = nil,
        role: String? = nil,
        approvedVoiceCommander: Bool = false,
        notes: String? = nil
    ) {
        let cleanedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateID = (id?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? JiraContactMatcher.normalizedKey(cleanedName.isEmpty ? (jiraUsername ?? UUID().uuidString) : cleanedName)
        self.id = candidateID.isEmpty ? UUID().uuidString.lowercased() : candidateID
        self.displayName = cleanedName.isEmpty ? self.id : cleanedName
        self.aliases = Self.deduped(aliases)
        self.jiraUsername = jiraUsername?.cleanedNilIfEmpty
        self.jiraAccountID = jiraAccountID?.cleanedNilIfEmpty
        self.email = email?.cleanedNilIfEmpty
        self.role = role?.cleanedNilIfEmpty
        self.approvedVoiceCommander = approvedVoiceCommander
        self.notes = notes?.cleanedNilIfEmpty
    }

    public func toAppContactPerson(isCurrentUser: Bool = false) -> AppContactPerson {
        AppContactPerson(
            key: id,
            displayName: displayName,
            aliases: aliases,
            isCurrentUser: isCurrentUser,
            email: email
        )
    }

    public func matchesNameOrAlias(_ query: String) -> Bool {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return false }
        let candidates = [id, displayName, jiraUsername, jiraAccountID, email].compactMap { $0 } + aliases
        return candidates.contains { Self.fold($0) == needle }
    }

    public func matchScore(for query: String) -> Double {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return 0 }
        let stripped = needle.hasPrefix("@") ? String(needle.dropFirst()) : needle

        let exactFields = [displayName, id, jiraUsername, jiraAccountID, email].compactMap { $0 }
        for field in exactFields {
            let folded = Self.fold(field)
            if folded == needle || folded == stripped { return 1.0 }
        }
        for alias in aliases {
            let folded = Self.fold(alias)
            if folded == needle || folded == stripped { return 0.96 }
        }
        let allTerms = exactFields + aliases
        for term in allTerms {
            let folded = Self.fold(term)
            if folded.contains(stripped) || stripped.contains(folded) {
                return 0.72
            }
        }
        let queryTokens = Set(stripped.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !queryTokens.isEmpty else { return 0 }
        for term in allTerms {
            let termTokens = Set(Self.fold(term).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            if !queryTokens.intersection(termTokens).isEmpty {
                return 0.55
            }
        }
        return 0
    }

    static func fold(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func deduped(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let key = fold(clean)
            if seen.insert(key).inserted {
                result.append(clean)
            }
        }
        return result
    }
}

/// Obsidian-friendly directory backed by `Knowledge/People.md`.
public struct AssistantPeopleDirectory: Equatable, Sendable {
    public var entries: [AssistantPersonEntry]
    public var freeformNotes: String

    public init(entries: [AssistantPersonEntry] = [], freeformNotes: String = "") {
        self.entries = entries
        self.freeformNotes = freeformNotes
    }

    private static let selfMarkers: Set<String> = ["you", "me", "self", "вы", "я"]

    /// Checks whether a speaker is permitted to issue task/Jira/board instructions.
    /// The local user is ALWAYS approved regardless of People.md contents.
    public func isApprovedSpeaker(_ speakerName: String, localUserNames: [String]) -> Bool {
        let needle = AssistantPersonEntry.fold(speakerName)
        if needle.isEmpty || Self.selfMarkers.contains(needle) {
            return true
        }
        let normalizedLocal = Set(localUserNames.map(AssistantPersonEntry.fold).filter { !$0.isEmpty })
        if normalizedLocal.contains(needle) {
            return true
        }
        // Handle "Display Name (You)" suffixes
        for localName in normalizedLocal where needle.contains(localName) || localName.contains(needle) {
            return true
        }
        if let matched = entries.first(where: { $0.matchesNameOrAlias(speakerName) }) {
            return matched.approvedVoiceCommander
        }
        return false
    }

    public func resolvePerson(matching query: String) -> AssistantPersonEntry? {
        var best: (entry: AssistantPersonEntry, score: Double)?
        for entry in entries {
            let score = entry.matchScore(for: query)
            guard score >= 0.5 else { continue }
            if best == nil || score > best!.score {
                best = (entry, score)
            }
        }
        return best?.entry
    }

    public mutating func upsert(_ incoming: AssistantPersonEntry) {
        if let index = entries.firstIndex(where: {
            $0.id == incoming.id || $0.matchesNameOrAlias(incoming.displayName)
        }) {
            var existing = entries[index]
            if !incoming.displayName.isEmpty {
                existing.displayName = incoming.displayName
            }
            existing.aliases = AssistantPersonEntry.deduped(existing.aliases + incoming.aliases)
            if let jiraUsername = incoming.jiraUsername { existing.jiraUsername = jiraUsername }
            if let jiraAccountID = incoming.jiraAccountID { existing.jiraAccountID = jiraAccountID }
            if let email = incoming.email { existing.email = email }
            if let role = incoming.role { existing.role = role }
            existing.approvedVoiceCommander = incoming.approvedVoiceCommander
            if let notes = incoming.notes { existing.notes = notes }
            entries[index] = existing
        } else {
            entries.append(incoming)
        }
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }
}

/// Reads and writes `Knowledge/People.md` as a Git-friendly Markdown table with optional user notes below.
public enum AssistantPeopleMarkdownCodec {
    private static let tableHeader =
        "| ID | Name | Aliases | Jira Username | Jira Account ID | Email | Role | Approved Voice | Notes |"
    private static let tableDivider =
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"

    public static func starterMarkdown() -> String {
        encode(AssistantPeopleDirectory(
            entries: [],
            freeformNotes: """
            ## Voice & Jira Identity Notes
            - You (the local Rock user) are **always** approved to issue voice instructions cleanly from anywhere in the app or inside meetings.
            - Add teammates above or tell Rock in chat/voice (for example: *"Remember that Sasha in standups is @a.ivanov in Jira and is approved for tasks"*).
            """
        ))
    }

    public static func decode(_ markdown: String) -> AssistantPeopleDirectory {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var entries: [AssistantPersonEntry] = []
        var notesLines: [String] = []
        var insideManagedHeader = true

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                insideManagedHeader = false
                let cells = splitRow(trimmed)
                // Skip header / divider rows
                if cells.count >= 2 && (cells[0] == "ID" || cells[0].allSatisfy { $0 == "-" || $0 == ":" }) {
                    continue
                }
                guard cells.count >= 8 else { continue }
                let id = cells[0]
                let name = cells[1]
                let aliases = cells[2]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let jiraUsername = cells[3].cleanedNilIfEmpty
                let jiraAccountID = cells[4].cleanedNilIfEmpty
                let email = cells[5].cleanedNilIfEmpty
                let role = cells[6].cleanedNilIfEmpty
                let approved = ["true", "yes", "1", "✓"].contains(cells[7].lowercased())
                let notes = cells.count > 8 ? cells[8].cleanedNilIfEmpty : nil
                guard !name.isEmpty || jiraUsername != nil else { continue }
                entries.append(AssistantPersonEntry(
                    id: id.isEmpty ? nil : id,
                    displayName: name.isEmpty ? (jiraUsername ?? id) : name,
                    aliases: aliases,
                    jiraUsername: jiraUsername,
                    jiraAccountID: jiraAccountID,
                    email: email,
                    role: role,
                    approvedVoiceCommander: approved,
                    notes: notes
                ))
            } else {
                if insideManagedHeader && (
                    trimmed == "# Team & Jira Directory" ||
                    trimmed.hasPrefix("> ") ||
                    trimmed.isEmpty
                ) {
                    continue
                }
                insideManagedHeader = false
                notesLines.append(rawLine)
            }
        }

        let extraNotes = notesLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantPeopleDirectory(entries: entries, freeformNotes: extraNotes)
    }

    public static func encode(_ directory: AssistantPeopleDirectory) -> String {
        var lines: [String] = [
            "# Team & Jira Directory",
            "",
            "> Shared in Obsidian so teammates can version-control meeting display names, aliases, Jira usernames/account IDs, and approved voice commanders. The local user is always approved.",
            "",
            tableHeader,
            tableDivider,
        ]
        for entry in directory.entries.sorted(by: {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }) {
            let cells = [
                entry.id,
                entry.displayName,
                entry.aliases.joined(separator: ", "),
                entry.jiraUsername ?? "",
                entry.jiraAccountID ?? "",
                entry.email ?? "",
                entry.role ?? "",
                entry.approvedVoiceCommander ? "yes" : "no",
                entry.notes ?? "",
            ].map(escapeCell)
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        let cleanedNotes = directory.freeformNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedNotes.isEmpty {
            lines.append("")
            lines.append(cleanedNotes)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escapeCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitRow(_ row: String) -> [String] {
        var inner = row.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in inner {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

private extension String {
    var cleanedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
