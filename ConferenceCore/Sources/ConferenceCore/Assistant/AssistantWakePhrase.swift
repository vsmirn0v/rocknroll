import Foundation

public enum AssistantInputSource: String, Codable, Sendable {
    case typed
    case voicePushToTalk
    case voiceWake
    case externalMCP

    public var isVoice: Bool {
        self == .voicePushToTalk || self == .voiceWake
    }
}

/// Parses natural Russian and English voice invocations addressed to Rock / Рок.
public struct AssistantWakePhraseMatcher: Sendable {
    public enum Match: Equatable, Sendable {
        case none
        case wakeOnly
        case command(String)
    }

    private static let leadingGreetings: Set<String> = [
        "эй", "привет", "слушай", "окей", "ок", "алло", "скажи", "пожалуйста",
        "hey", "hi", "hello", "ok", "okay", "listen", "yo"
    ]

    private static let singleWakeWords: Set<String> = [
        "рок", "рог", "рока", "рокк", "рокнролл", "рокнрол",
        "rock", "rok", "rocknroll", "rock'n'roll", "rock’n’roll"
    ]

    private static let multiWordWakeSequences: [[String]] = [
        ["рок", "н", "ролл"],
        ["рок", "н", "рол"],
        ["рок", "и", "ролл"],
        ["rock", "n", "roll"],
        ["rock", "and", "roll"]
    ]

    private static let postWakeConnectors: Set<String> = [
        "пожалуйста", "пожалуйста,", "please"
    ]

    public static func match(_ transcript: String) -> Match {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return .none }

        var index = 0
        while index < tokens.count && leadingGreetings.contains(tokens[index].normalized) {
            index += 1
        }
        guard index < tokens.count else { return .none }

        var matchedWakeEnd: Int?
        for sequence in multiWordWakeSequences {
            if index + sequence.count <= tokens.count {
                let slice = tokens[index..<(index + sequence.count)].map(\.normalized)
                if slice == sequence {
                    matchedWakeEnd = index + sequence.count
                    break
                }
            }
        }

        if matchedWakeEnd == nil {
            let candidate = tokens[index].normalized
            if (candidate == "рок" || candidate == "rock"),
               index + 2 < tokens.count,
               ["н", "n"].contains(tokens[index + 1].normalized),
               ["ролл", "рол", "roll"].contains(tokens[index + 2].normalized) {
                matchedWakeEnd = index + 3
            } else if singleWakeWords.contains(candidate) {
                matchedWakeEnd = index + 1
            }
        }

        guard let wakeEnd = matchedWakeEnd else { return .none }
        var commandStartTokenIndex = wakeEnd
        while commandStartTokenIndex < tokens.count,
              postWakeConnectors.contains(tokens[commandStartTokenIndex].normalized) {
            commandStartTokenIndex += 1
        }

        guard commandStartTokenIndex < tokens.count else {
            return .wakeOnly
        }

        let startOffset = tokens[commandStartTokenIndex].range.lowerBound
        let rawRemainder = String(trimmed[startOffset...])
        let cleanRemainder = stripLeadingSeparators(rawRemainder)
        guard !cleanRemainder.isEmpty else { return .wakeOnly }
        return .command(cleanRemainder)
    }

    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex && isSeparator(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex && !isSeparator(text[index]) {
                index = text.index(after: index)
            }
            let raw = String(text[start..<index])
            let normalized = normalizeToken(raw)
            if !normalized.isEmpty {
                result.append(Token(normalized: normalized, range: start..<index))
            }
        }
        return result
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        if ch == "-" || ch == "—" || ch == "–" { return true }
        return ch.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) && $0 != "'" && $0 != "’" }
    }

    private static func normalizeToken(_ token: String) -> String {
        let lower = token
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "’", with: "'")
        let trimmed = lower.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        return trimmed
    }

    private static func stripLeadingSeparators(_ text: String) -> String {
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isWhitespace || ch == "," || ch == ":" || ch == ";" || ch == "-" || ch == "—" || ch == "." || ch == "!" || ch == "?" {
                idx = text.index(after: idx)
            } else {
                break
            }
        }
        return String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detects when a live transcript line is likely acoustic echo of the assistant's own speech.
    public static func isLikelySelfEcho(
        candidate: String,
        lastSpoken: String,
        isLocal: Bool,
        withinEchoWindow: Bool
    ) -> Bool {
        let trimmed = lastSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return isLikelySelfEcho(
            candidate: candidate,
            recentAssistantUtterances: [trimmed],
            isLocal: isLocal,
            withinEchoWindow: withinEchoWindow
        )
    }

    /// Detects acoustic echo against the most recent assistant utterances, including short phonetic ASR garbles.
    public static func isLikelySelfEcho(
        candidate: String,
        recentAssistantUtterances: [String],
        isLocal: Bool,
        withinEchoWindow: Bool
    ) -> Bool {
        let cleanCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCandidate.isEmpty else { return false }
        let utterances = recentAssistantUtterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !utterances.isEmpty else { return false }

        let normCandidate = normalizeForEchoComparison(cleanCandidate)
        let candTokens = echoWordTokens(from: cleanCandidate)

        for utterance in utterances {
            if isLocal && (cleanCandidate == utterance || (normCandidate.count >= 8 && utterance.lowercased().contains(cleanCandidate.lowercased()))) {
                return true
            }
            let normUtterance = normalizeForEchoComparison(utterance)
            if isLocal && normCandidate.count >= 8 && normUtterance.contains(normCandidate) {
                return true
            }
        }

        guard withinEchoWindow else { return false }
        guard !candTokens.isEmpty else { return false }

        for utterance in utterances {
            let uttTokens = echoWordTokens(from: utterance)
            guard !uttTokens.isEmpty else { continue }
            let intersection = candTokens.intersection(uttTokens).count
            let overlap = Double(intersection) / Double(candTokens.count)
            if overlap >= 0.72 {
                return true
            }
        }

        // Catch short garbled local ASR tails (2-4 words, >= 7 chars) phonetically echoing a recent phrase,
        // while leaving short human commands/acknowledgments untouched.
        if isLocal && candTokens.count >= 2 && candTokens.count <= 4 && normCandidate.replacingOccurrences(of: " ", with: "").count >= 7 {
            let candWords = normCandidate.split(separator: " ").map(String.init)
            let candPhonetic = phoneticEchoSkeleton(normCandidate)
            guard candPhonetic.count >= 6 else { return false }
            for utterance in utterances {
                let normUtterance = normalizeForEchoComparison(utterance)
                let uttWords = normUtterance.split(separator: " ").map(String.init)
                guard !uttWords.isEmpty else { continue }
                let minWindow = min(uttWords.count, max(candWords.count - 1, 1))
                let maxWindow = min(uttWords.count, candWords.count + 1)
                for width in minWindow...maxWindow {
                    for start in 0...(uttWords.count - width) {
                        let slice = uttWords[start..<(start + width)].joined(separator: " ")
                        let uttPhonetic = phoneticEchoSkeleton(slice)
                        if phoneticLCSSimilarity(candPhonetic, uttPhonetic) >= 0.74 {
                            return true
                        }
                    }
                }
            }
        }

        return false
    }

    /// Removes trailing or embedded assistant echo clauses from a mixed transcript line.
    public static func stripAssistantEcho(
        from text: String,
        recentAssistantUtterances: [String],
        withinEchoWindow: Bool
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let utterances = recentAssistantUtterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !utterances.isEmpty else { return trimmed }

        if isLikelySelfEcho(
            candidate: trimmed,
            recentAssistantUtterances: utterances,
            isLocal: true,
            withinEchoWindow: withinEchoWindow
        ) {
            return ""
        }

        let clauses = splitEchoClauses(trimmed)
        guard clauses.count > 1 else { return trimmed }
        var kept: [String] = []
        for clause in clauses {
            let normClause = normalizeForEchoComparison(clause)
            guard !normClause.isEmpty else { continue }
            let isEchoClause = isLikelySelfEcho(
                candidate: clause,
                recentAssistantUtterances: utterances,
                isLocal: true,
                withinEchoWindow: true
            )
            if !isEchoClause {
                kept.append(clause)
            }
        }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeForEchoComparison(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    private static func echoWordTokens(from text: String) -> Set<String> {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        return Set(tokens)
    }

    private static func splitEchoClauses(_ text: String) -> [String] {
        var clauses: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let clean = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    clauses.append(clean)
                }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            clauses.append(trailing)
        }
        return clauses
    }

    private static func phoneticEchoSkeleton(_ normalized: String) -> String {
        var s = normalized.replacingOccurrences(of: " ", with: "")
        let replacements: [(String, String)] = [
            ("daily", "deli"),
            ("cto", "sito"),
            ("ai", "e"), ("ay", "e"), ("ei", "e"), ("ey", "e"),
            ("ph", "f"), ("sh", "s"), ("ch", "c"), ("zh", "z"),
            ("щ", "с"), ("ш", "с"), ("ч", "ц"), ("ж", "з"),
            ("ю", "u"), ("я", "a"),
            ("ц", "s"), ("c", "s"),
            ("а", "a"), ("б", "b"), ("в", "v"), ("г", "g"), ("д", "d"),
            ("е", "e"), ("з", "z"), ("и", "i"), ("й", "i"), ("к", "k"),
            ("л", "l"), ("м", "m"), ("н", "n"), ("о", "o"), ("п", "p"),
            ("р", "r"), ("с", "s"), ("т", "t"), ("у", "u"), ("ф", "f"),
            ("х", "h"), ("ы", "i"), ("э", "e"), ("y", "i")
        ]
        for (pat, rep) in replacements {
            s = s.replacingOccurrences(of: pat, with: rep)
        }
        return s
    }

    private static func phoneticLCSSimilarity(_ a: String, _ b: String) -> Double {
        let ca = Array(a), cb = Array(b)
        guard !ca.isEmpty, !cb.isEmpty else { return 0 }
        var prev = Array(repeating: 0, count: cb.count + 1)
        for i in 1...ca.count {
            var curr = Array(repeating: 0, count: cb.count + 1)
            for j in 1...cb.count {
                if ca[i - 1] == cb[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            prev = curr
        }
        let lcs = prev[cb.count]
        return Double(lcs) / Double(max(ca.count, cb.count))
    }
}

/// Maintains a short armed follow-up window after a standalone "Рок" / "Rock" wake utterance.
public struct AssistantWakeDetector: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ignored
        case armed(until: Date)
        case triggered(command: String)
    }

    public let armWindowSeconds: TimeInterval
    public private(set) var armedUntil: Date?

    public init(armWindowSeconds: TimeInterval = 5.0) {
        self.armWindowSeconds = armWindowSeconds
    }

    public func isArmed(at now: Date) -> Bool {
        guard let armedUntil else { return false }
        return now <= armedUntil
    }

    public mutating func reset() {
        armedUntil = nil
    }

    public mutating func consume(transcript: String, isFinal: Bool, now: Date) -> Outcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let until = armedUntil, now > until { armedUntil = nil }
            return .ignored
        }

        let match = AssistantWakePhraseMatcher.match(trimmed)
        if !isFinal {
            if match != .none {
                return .armed(until: now.addingTimeInterval(armWindowSeconds))
            }
            if let until = armedUntil, now <= until {
                return .armed(until: until)
            }
            return .ignored
        }

        switch match {
        case .command(let command):
            armedUntil = nil
            return .triggered(command: command)
        case .wakeOnly:
            let until = now.addingTimeInterval(armWindowSeconds)
            armedUntil = until
            return .armed(until: until)
        case .none:
            if let until = armedUntil, now <= until {
                armedUntil = nil
                return .triggered(command: trimmed)
            }
            armedUntil = nil
            return .ignored
        }
    }
}

/// Shared voice vs typed confirmation policy for Assistant actions.
public enum AssistantVoiceApprovalPolicy {
    private static let autoApprovedVoiceKinds: Set<String> = [
        "join", "mute", "setAttention", "participate", "remind", "remember", "readChat", "catchUp"
    ]
    private static let meetingSendKinds: Set<String> = [
        "sendChat", "say", "react"
    ]

    public static func shouldAutoApprove(
        actionKind: String,
        inputSource: AssistantInputSource,
        sendsWithoutAsking: Bool
    ) -> Bool {
        if inputSource == .externalMCP {
            return actionKind == "remember"
        }
        if actionKind == "remember" {
            return true
        }
        if actionKind == "leave" {
            return false
        }
        if meetingSendKinds.contains(actionKind) {
            return sendsWithoutAsking
        }
        if inputSource.isVoice {
            return autoApprovedVoiceKinds.contains(actionKind)
        }
        return false
    }
}
