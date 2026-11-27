import ConferenceCore
import Foundation

struct MeetingMarkdownSections: OptionSet, Codable, Sendable {
    let rawValue: Int

    static let notes = Self(rawValue: 1 << 0)
    static let summary = Self(rawValue: 1 << 1)
    static let decisions = Self(rawValue: 1 << 2)
    static let tasks = Self(rawValue: 1 << 3)
    static let questions = Self(rawValue: 1 << 4)
    static let transcript = Self(rawValue: 1 << 5)
    static let snapshots = Self(rawValue: 1 << 6)
    static let expertOpinions = Self(rawValue: 1 << 7)
    // Transcripts are opt-in for both new and existing destinations.
    static let all: Self = [.notes, .summary, .decisions, .tasks, .questions, .snapshots, .expertOpinions]

    func applying(_ overrides: MeetingAutoExportOverrides) -> Self {
        var result = self
        func apply(_ flag: Bool?, to member: Self) {
            guard let flag else { return }
            if flag { result.insert(member) }
            else { result.remove(member) }
        }
        apply(overrides.includeTranscript, to: .transcript)
        apply(overrides.includeNotes, to: .notes)
        apply(overrides.includeSummary, to: .summary)
        apply(overrides.includeDecisions, to: .decisions)
        apply(overrides.includeTasks, to: .tasks)
        apply(overrides.includeQuestions, to: .questions)
        return result
    }
}

/// Fixed Markdown templates. Raw local notes are never normalized: the template wraps
/// them but cannot drop or rewrite unsupported syntax. Explicit states for empty and
/// pending outcomes; schema version and revisions travel with every export.
enum MeetingMarkdownTemplate {
    static let schemaVersion = 1

    /// Flat YAML encoding without a dependency; strings use JSON-compatible quoting.
    static func yamlValue(_ value: String) -> String {
        // JSON strings are valid YAML double-quoted scalars. Always quote to
        // preserve text such as booleans, dates and titles containing colons.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(value), let encoded = String(data: bytes, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    static func frontmatter(session: MeetingSessionRecord, note: MeetingNoteRecord?,
                            outcome: MeetingOutcome?, outcomeState: MeetingOutcomePersistenceState,
                            exportRevision: Int,
                            dominantRole: DominantRoleBinding? = nil,
                            expertBlocksCount: Int = 0) -> String {
        var lines = ["---",
            "schema_version: \(schemaVersion)",
            "meeting_id: \"\(session.id.uuidString)\"",
            "title: \(yamlValue(session.title))",
            "time_zone: \(yamlValue(session.timeZoneID))",
            "export_revision: \(exportRevision)",
            "note_revision: \(note?.revision ?? 0)",
            "outcome_state: \(outcomeState.rawValue)"]
        if let dominantRole {
            lines.append("dominant_role: \(yamlValue(dominantRole.skillID))")
            if let presetID = dominantRole.presetID, !presetID.isEmpty {
                lines.append("dominant_preset: \(yamlValue(presetID))")
            }
            lines.append("core_outcome_policy: \(dominantRole.coreOutcomePolicy.rawValue)")
        }
        if expertBlocksCount > 0 {
            lines.append("expert_opinions_count: \(expertBlocksCount)")
        }
        if let start = session.recordedStart {
            lines.append("started_at: \(ISO8601DateFormatter().string(from: start))")
        }
        if let ended = session.knownEnd {
            lines.append("ended_at: \(ISO8601DateFormatter().string(from: ended))")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// The managed body: raw note verbatim, then outcome sections with explicit
    /// empty/pending states. Section headings are stable for both locales.
    static func managedContent(session: MeetingSessionRecord, note: MeetingNoteRecord?,
                               outcome: MeetingOutcome?, outcomeState: MeetingOutcomePersistenceState,
                               sections: MeetingMarkdownSections = .all, headingLevel: Int = 1,
                               boldTitle: Bool = false,
                               snapshots: [MeetingSnapshotRecord] = [],
                               useWikiLinksForSnapshots: Bool = true,
                               expertBlocks: [SyncedMeetingExpertBlock] = [],
                               dominantRole: DominantRoleBinding? = nil,
                               coreOutcomePolicy: CoreOutcomePolicy = .full) -> String {
        let heading = String(repeating: "#", count: headingLevel)
        var parts = [boldTitle ? "**" + session.title + "**" : heading + " " + session.title]
        if sections.contains(.snapshots), !snapshots.isEmpty {
            parts += ["", MeetingSnapshotMarkdown.obsidianSection(
                snapshots: snapshots,
                attachmentsFolder: "Attachments",
                headingLevel: headingLevel + 1,
                useWikiLinks: useWikiLinksForSnapshots
            )]
        }
        if sections.contains(.notes) {
            parts += ["", heading + "# Notes"]
            if let note, !note.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(MarkdownStructureScanner.closingTrailingFence(in: note.markdown))
            } else {
                parts.append("_No notes for this meeting._")
            }
        }
        let visibleExpertBlocks = expertBlocks
            .filter { !$0.isDeleted.value }
            .sorted { left, right in
                let leftPrimary = isPrimaryExpertBlock(left, dominantRole: dominantRole)
                let rightPrimary = isPrimaryExpertBlock(right, dominantRole: dominantRole)
                if leftPrimary != rightPrimary { return leftPrimary }
                return left.createdAt < right.createdAt
            }
        let outcomeSectionMask: MeetingMarkdownSections = switch coreOutcomePolicy {
        case .full: [.summary, .decisions, .tasks, .questions]
        case .summaryOnly: [.summary]
        case .expertOnly: []
        }
        let requestedOutcomeSections = sections.intersection(outcomeSectionMask)
        let shouldSuppressEmptyOutcome = (coreOutcomePolicy == .expertOnly && !visibleExpertBlocks.isEmpty)
        if !requestedOutcomeSections.isEmpty && !shouldSuppressEmptyOutcome {
            parts += ["", heading + "# Outcome"]
            switch outcomeState {
            case .notStarted:
                parts.append("_No outcome for this meeting._")
            case .pending:
                parts.append("_The meeting outcome is being prepared…_")
            case .failed:
                parts.append("_The meeting outcome could not be generated. Retry it in Rock’N’Roll for Mac._")
            case .draft, .ready:
                if let outcome {
                    if requestedOutcomeSections.contains(.summary) {
                        parts.append(outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "_No summary._" : MarkdownStructureScanner.closingTrailingFence(in: outcome.summary))
                    }
                    if requestedOutcomeSections.contains(.decisions), !outcome.decisions.isEmpty {
                        parts += ["", heading + "## Decisions", outcome.decisions.map { "- " + $0 }.joined(separator: "\n")]
                    }
                    if requestedOutcomeSections.contains(.tasks), !outcome.tasks.isEmpty {
                        parts += ["", heading + "## Tasks", outcome.tasks.map { task in
                            "- [" + (task.done ? "x" : " ") + "] " + task.text +
                                (task.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " — " + task.owner)
                        }.joined(separator: "\n")]
                    }
                    if requestedOutcomeSections.contains(.questions), !outcome.openQuestions.isEmpty {
                        parts += ["", heading + "## Open questions", outcome.openQuestions.map { "- " + $0 }.joined(separator: "\n")]
                    }
                } else {
                    parts.append("_No outcome for this meeting._")
                }
            }
        }
        if sections.contains(.expertOpinions), !visibleExpertBlocks.isEmpty {
            for block in visibleExpertBlocks {
                let isPrimary = isPrimaryExpertBlock(block, dominantRole: dominantRole)
                let badge = isPrimary ? "★ " : ""
                parts += ["", heading + "# " + badge + block.title.value]
                var meta: [String] = []
                meta.append("Role: \(block.skillID)")
                if let presetName = block.contextSnapshot.value.presetName, !presetName.isEmpty {
                    meta.append("Preset: \(presetName)")
                } else if let presetID = block.presetID, !presetID.isEmpty {
                    meta.append("Preset: \(presetID)")
                }
                let focusSpeakers = block.contextSnapshot.value.focusSpeakers
                if !focusSpeakers.isEmpty {
                    meta.append("Focus: \(focusSpeakers.joined(separator: ", "))")
                }
                if let verdict = block.headlineVerdict.value?.trimmingCharacters(in: .whitespacesAndNewlines), !verdict.isEmpty {
                    meta.append("Verdict: \(verdict)")
                }
                if !meta.isEmpty {
                    parts.append("> " + meta.joined(separator: " | "))
                }
                let body = block.markdownBody.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    parts.append("")
                    parts.append(MarkdownStructureScanner.closingTrailingFence(in: body))
                }
            }
        }
        return MarkdownStructureScanner.closingTrailingFence(in: parts.joined(separator: "\n"))
    }

    private static func isPrimaryExpertBlock(_ block: SyncedMeetingExpertBlock, dominantRole: DominantRoleBinding?) -> Bool {
        guard let dominantRole else { return false }
        if let blockID = dominantRole.expertBlockID { return blockID == block.id }
        return dominantRole.skillID == block.skillID && dominantRole.presetID == block.presetID
    }

    static func transcriptBody(events: [SyncedTranscriptEvent], startedAt: Date?) -> String? {
        let speech = events.filter { $0.kind == "transcript" }.sorted {
            ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id)
        }
        guard let origin = startedAt ?? speech.first?.occurredAt else { return nil }
        let paragraphs = speech.compactMap { event -> String? in
            let line = transcriptText(event.text)
            guard !line.isEmpty else { return nil }
            let elapsed = Int(max(0, event.occurredAt.timeIntervalSince(origin)))
            let time = String(format: "%02ld:%02ld:%02ld", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
            let isAssistant = AssistantSpeechLedger.isAssistantSpeaker(event.speaker, role: event.speakerRole)
            let formattedSpeaker: String
            if isAssistant {
                formattedSpeaker = "Rock Assistant (Assistant)"
            } else {
                let rawSpeaker = transcriptText(event.speaker ?? "")
                if event.isOwn {
                    formattedSpeaker = rawSpeaker.isEmpty ? "You" : "\(rawSpeaker) (You)"
                } else {
                    formattedSpeaker = rawSpeaker
                }
            }
            let label = formattedSpeaker.isEmpty ? time : "\(time) \(formattedSpeaker)"
            return "**\(label)** — \(line)"
        }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
    }

    static func transcriptText(_ text: String) -> String {
        // Transcript text is literal, including HTML, links and marker-like content.
        let punctuation = CharacterSet(charactersIn: "\\`*_[]<>~|&")
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.unicodeScalars.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }
            .joined()
    }

    /// Sanitized, collision-resistant file name for a meeting. The name derives from
    /// the title plus a stable session prefix; title changes never move the file once
    /// a binding exists.
    static func meetingFileName(title: String, sessionID: UUID) -> String {
        let cleaned = title.components(separatedBy: CharacterSet.alphanumerics.inverted.union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }.joined(separator: " ")
        let base = cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(60))
        return "\(base) \(String(sessionID.uuidString.prefix(8))).md"
    }
}
