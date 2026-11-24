import Foundation

/// Formats meeting transcripts consistently for clipboard copy and Markdown export
/// across iOS and macOS.
public enum TranscriptExportFormatter {
    private static let timeFormatterLock = NSLock()
    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func formatPlainText(
        events: [SyncedTranscriptEvent],
        meetingTitle: String? = nil,
        startedAt: Date? = nil,
        youLabel: String = L("You"),
        assistantLabel: String = L("Rock Assistant")
    ) -> String {
        let relevant = filteredTranscriptEvents(events)
        guard !relevant.isEmpty else { return "" }

        var lines: [String] = []
        if let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if let startedAt, startedAt != .distantPast {
                let formattedDate = timeFormatterLock.withLock { dateTimeFormatter.string(from: startedAt) }
                lines.append("\(title) (\(formattedDate))")
            } else {
                lines.append(title)
            }
            lines.append("")
        }

        for event in relevant {
            let time = formattedTimestamp(event.occurredAt)
            let author = resolvedAuthor(event: event, youLabel: youLabel, assistantLabel: assistantLabel)
            let chatTag = event.kind == "chat" ? " [\(L("Chat"))]" : ""
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("[\(time)] \(author)\(chatTag): \(text)")
        }

        return lines.joined(separator: "\n")
    }

    public static func formatMarkdown(
        events: [SyncedTranscriptEvent],
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        youLabel: String = L("You"),
        assistantLabel: String = L("Rock Assistant")
    ) -> String {
        let relevant = filteredTranscriptEvents(events)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingTitle = cleanTitle.isEmpty ? L("Meeting") : cleanTitle

        var lines: [String] = ["# \(headingTitle)", ""]
        if startedAt != .distantPast {
            let formattedStart = timeFormatterLock.withLock { dateTimeFormatter.string(from: startedAt) }
            if let endedAt, endedAt > startedAt {
                let mins = max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
                lines.append("- **\(L("Date")):** \(formattedStart) (\(L("%ld min", mins)))")
            } else {
                lines.append("- **\(L("Date")):** \(formattedStart)")
            }
            lines.append("")
        }

        lines.append("## \(L("Transcript"))")
        lines.append("")

        for event in relevant {
            let time = formattedTimestamp(event.occurredAt)
            let author = resolvedAuthor(event: event, youLabel: youLabel, assistantLabel: assistantLabel)
            let chatTag = event.kind == "chat" ? " [\(L("Chat"))]" : ""
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("**[\(time)] \(author)\(chatTag):** \(text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public static func suggestedFileName(
        title: String,
        startedAt: Date?,
        extension ext: String = "md"
    ) -> String {
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty ? "md" : ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let datePrefix: String
        if let startedAt, startedAt != .distantPast {
            datePrefix = timeFormatterLock.withLock { fileDateFormatter.string(from: startedAt) }
        } else {
            datePrefix = timeFormatterLock.withLock { fileDateFormatter.string(from: Date()) }
        }
        let slug = sanitizeSlug(title)
        return "\(datePrefix)-\(slug).transcript.\(cleanExt)"
    }

    public static func hasTranscriptContent(_ events: [SyncedTranscriptEvent]) -> Bool {
        events.contains(where: isRelevantTranscriptEvent)
    }

    private static func isRelevantTranscriptEvent(_ event: SyncedTranscriptEvent) -> Bool {
        (event.kind == "transcript" || event.kind == "chat")
            && !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func filteredTranscriptEvents(_ events: [SyncedTranscriptEvent]) -> [SyncedTranscriptEvent] {
        events.filter(isRelevantTranscriptEvent).sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id < $1.id
        }
    }

    private static func resolvedAuthor(
        event: SyncedTranscriptEvent,
        youLabel: String,
        assistantLabel: String
    ) -> String {
        if AssistantSpeechLedger.isAssistantSpeaker(event.speaker, role: event.speakerRole) {
            return assistantLabel
        }
        let label = AssistantSpeechLedger.displayAuthor(
            speaker: event.speaker,
            isOwn: event.isOwn,
            speakerRole: event.speakerRole,
            youLabel: youLabel,
            assistantLabel: assistantLabel
        )
        return label.isEmpty ? L("Participant") : label
    }

    private static func formattedTimestamp(_ date: Date) -> String {
        guard date != .distantPast else { return "--:--" }
        return timeFormatterLock.withLock { shortTimeFormatter.string(from: date) }
    }

    private static func sanitizeSlug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if collapsed.isEmpty { return "meeting" }
        return String(collapsed.prefix(48))
    }
}
