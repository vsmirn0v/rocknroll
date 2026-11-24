import Foundation

public struct MeetingMeaningfulnessInput: Equatable, Sendable {
    public var hasNotes: Bool
    public var notePreview: String?
    public var outcomeSummary: String?
    public var decisionsCount: Int
    public var tasksCount: Int
    public var openQuestionsCount: Int
    public var isGeneratingOutcome: Bool
    public var hasFailedOutcomeWithInput: Bool
    public var transcriptTexts: [String]

    public init(
        hasNotes: Bool = false,
        notePreview: String? = nil,
        outcomeSummary: String? = nil,
        decisionsCount: Int = 0,
        tasksCount: Int = 0,
        openQuestionsCount: Int = 0,
        isGeneratingOutcome: Bool = false,
        hasFailedOutcomeWithInput: Bool = false,
        transcriptTexts: [String] = []
    ) {
        self.hasNotes = hasNotes
        self.notePreview = notePreview
        self.outcomeSummary = outcomeSummary
        self.decisionsCount = decisionsCount
        self.tasksCount = tasksCount
        self.openQuestionsCount = openQuestionsCount
        self.isGeneratingOutcome = isGeneratingOutcome
        self.hasFailedOutcomeWithInput = hasFailedOutcomeWithInput
        self.transcriptTexts = transcriptTexts
    }
}

public enum MeetingContentMeaningfulness {
    private static let noDiscussionPhrases: [String] = [
        // English
        "no meaningful discussion",
        "no substantive discussion",
        "no substantial discussion",
        "no significant discussion",
        "nothing meaningful was discussed",
        "nothing substantive was discussed",
        "nothing was discussed",
        "no topics were discussed",
        "no discussion took place",
        "there was no discussion",
        "no actual discussion",
        "no meaningful content",
        "no substantive content",
        "no meaningful data",
        "no meaningful information",
        "no meaningful conversation",
        "no conversation took place",
        "no conversation was recorded",
        "no transcript",
        "empty transcript",
        "transcript is empty",
        "transcript was empty",
        "empty meeting",
        "no speech was detected",
        "no speech detected",
        "no audio was recorded",
        "no spoken content",
        // Russian
        "содержательного обсуждения не было",
        "содержательного обсуждения не велось",
        "не было содержательного обсуждения",
        "значимого обсуждения не было",
        "существенного обсуждения не было",
        "обсуждение не состоялось",
        "обсуждения не было",
        "ничего не обсуждалось",
        "никаких тем не обсуждалось",
        "темы не обсуждались",
        "нет содержательных данных",
        "нет значимой информации",
        "нет полезной информации",
        "расшифровка пуста",
        "транскрипт пуст",
        "пустая встреча",
        "речь не зафиксирована",
        "разговор не состоялся",
    ]

    private static let testCallPhrases: [String] = [
        "audio test",
        "microphone test",
        "mic test",
        "sound check",
        "connection test",
        "connectivity test",
        "test call",
        "test meeting",
        "testing the microphone",
        "testing audio",
        "testing the connection",
        "проверка связи",
        "проверка микрофона",
        "проверка звука",
        "тестовый звонок",
        "тестовая встреча",
        "встреча была тестовой",
        "звонок был тестовым",
    ]

    private static let exclusivityCues: [String] = [
        "only",
        "just",
        "brief",
        "consisted of",
        "limited to",
        "was a test",
        "appeared to be a test",
        "no other",
        "nothing else",
        "только",
        "лишь",
        "была тестовой",
        "был тестовым",
        "короткая проверка",
        "короткий тест",
    ]

    private static let fillerTokens: Set<String> = [
        "test", "testing", "hello", "hi", "hey", "ok", "okay", "yes", "no",
        "1", "2", "3", "one", "two", "three", "check", "checking",
        "mic", "microphone", "audio", "sound",
        "тест", "проверка", "привет", "алло", "раз", "два", "три",
        "ок", "да", "нет", "слышно", "микрофон", "звук",
    ]

    /// Returns whether a meeting session contains meaningful user-facing content
    /// (notes, actionable outcome items, non-empty summary, active/retryable generation,
    /// or substantive transcript/chat).
    public static func isMeaningful(_ input: MeetingMeaningfulnessInput) -> Bool {
        isMeaningful(input, lazyTranscriptTexts: { AnySequence(input.transcriptTexts) })
    }

    /// Evaluates meaningfulness while deferring transcript enumeration until
    /// metadata, notes, and outcome fields prove inconclusive.
    public static func isMeaningful(
        _ input: MeetingMeaningfulnessInput,
        lazyTranscriptTexts: () -> AnySequence<String>
    ) -> Bool {
        if input.isGeneratingOutcome || input.hasFailedOutcomeWithInput {
            return true
        }
        if let preview = input.notePreview {
            if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        } else if input.hasNotes {
            return true
        }
        if input.decisionsCount > 0 || input.tasksCount > 0 || input.openQuestionsCount > 0 {
            return true
        }
        if let rawSummary = input.outcomeSummary {
            let trimmedSummary = stripCitationMarkers(rawSummary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                return !isNonMeaningfulSummary(trimmedSummary)
            }
        }
        return hasSubstantiveTranscript(lazyTranscriptTexts())
    }

    public static func isNonMeaningfulSummary(_ summary: String) -> Bool {
        let normalized = summary
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if normalized.isEmpty {
            return true
        }
        if noDiscussionPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }
        if normalized.count <= 240,
           testCallPhrases.contains(where: { normalized.contains($0) }),
           exclusivityCues.contains(where: { normalized.contains($0) }) {
            return true
        }
        return false
    }

    public static func hasSubstantiveTranscript<S: Sequence>(_ texts: S) -> Bool where S.Element == String {
        var nonFillerCount = 0
        var nonFillerCharacters = 0
        for text in texts {
            for word in extractWords(text) where !fillerTokens.contains(word) {
                nonFillerCount += 1
                nonFillerCharacters += word.count
                if nonFillerCount >= 5 && nonFillerCharacters >= 25 {
                    return true
                }
            }
        }
        return false
    }

    private static func stripCitationMarkers(_ text: String) -> String {
        guard text.contains("[L") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "[" && index + 2 < scalars.count && scalars[index + 1] == "L" {
                var cursor = index + 2
                var digits = 0
                while cursor < scalars.count, digits < 4,
                      scalars[cursor].value >= 48, scalars[cursor].value <= 57 {
                    cursor += 1
                    digits += 1
                }
                if digits > 0, cursor < scalars.count, scalars[cursor] == "]" {
                    index = cursor + 1
                    continue
                }
            }
            result.unicodeScalars.append(scalars[index])
            index += 1
        }
        return result
    }

    private static func extractWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            words.append(String(current))
        }
        return words
    }
}
