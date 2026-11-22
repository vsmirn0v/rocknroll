import Foundation

public enum OwnServerTranscriptClassification: Equatable, Sendable {
    case pureUser(text: String)
    case pureAssistant(text: String)
    case mixed(userText: String, assistantText: String)
}

/// Records utterances spoken by the assistant into an active call and separates
/// server-side `isOwn` transcripts (which mix the local microphone and injected
/// assistant TTS audio) back into distinct User vs Assistant speech.
public final class AssistantSpeechLedger: @unchecked Sendable {
    public static let canonicalSpeakerName = "Rock Assistant"
    public static let speakerRoleUser = "user"
    public static let speakerRoleAssistant = "assistant"
    public static let speakerRoleParticipant = "participant"

    public struct Utterance: Equatable, Sendable {
        public let id: String
        public let text: String
        public let startedAt: Date
        public var endedAt: Date?
        fileprivate let normalizedTokens: [String]

        fileprivate init(id: String, text: String, startedAt: Date, endedAt: Date?) {
            self.id = id
            self.text = text
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.normalizedTokens = AssistantSpeechLedger.tokenizeWithRanges(text).map(\.token)
        }
    }

    private struct TokenSpan {
        let token: String
        let range: Range<String.Index>
    }

    private let lock = NSLock()
    private var utterances: [Utterance] = []
    private let retentionSeconds: TimeInterval = 900

    public init() {}

    public func beginUtterance(id: String, text: String, startedAt: Date = Date()) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        upsert(Utterance(id: id, text: clean, startedAt: startedAt, endedAt: nil), now: startedAt)
    }

    public func endUtterance(id: String, endedAt: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = utterances.lastIndex(where: { $0.id == id }) {
            utterances[idx].endedAt = max(utterances[idx].startedAt, endedAt)
        }
    }

    public func recordCompletedUtterance(id: String, text: String, startedAt: Date, endedAt: Date) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        upsert(
            Utterance(id: id, text: clean, startedAt: startedAt, endedAt: max(startedAt, endedAt)),
            now: endedAt
        )
    }

    public func snapshotUtterances() -> [Utterance] {
        lock.lock()
        defer { lock.unlock() }
        return utterances
    }

    public func latestSpokenInfo() -> (text: String, at: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = utterances.last else { return nil }
        return (last.text, last.endedAt ?? last.startedAt)
    }

    public func isWithinActiveOrRecentSpeech(at date: Date = Date(), graceSeconds: TimeInterval = 8.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return utterances.contains { item in
            let start = item.startedAt.addingTimeInterval(-1.0)
            let end = (item.endedAt ?? date).addingTimeInterval(graceSeconds)
            return date >= start && date <= end
        }
    }

    /// Classifies a server transcript line marked `isOwn == true` by comparing it
    /// against assistant utterances active or recently spoken around `occurredAt`.
    public func classifyOwnServerSegment(
        text: String,
        occurredAt: Date?,
        now: Date = Date()
    ) -> OwnServerTranscriptClassification {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .pureUser(text: clean) }

        let candidates: [Utterance] = {
            lock.lock()
            defer { lock.unlock() }
            let referenceDate = occurredAt ?? now
            return utterances.filter { item in
                let windowStart = item.startedAt.addingTimeInterval(-4.0)
                let windowEnd = (item.endedAt ?? now).addingTimeInterval(occurredAt == nil ? 45.0 : 20.0)
                return referenceDate >= windowStart && referenceDate <= windowEnd
            }.reversed()
        }()

        guard !candidates.isEmpty else {
            return .pureUser(text: clean)
        }

        var working = clean
        var matchedAssistantTexts: [String] = []

        for utterance in candidates {
            guard !utterance.normalizedTokens.isEmpty else { continue }
            if AssistantWakePhraseMatcher.isLikelySelfEcho(
                candidate: working,
                lastSpoken: utterance.text,
                isLocal: true,
                withinEchoWindow: true
            ) {
                if matchedAssistantTexts.isEmpty {
                    return .pureAssistant(text: utterance.text)
                } else {
                    return .pureAssistant(text: matchedAssistantTexts.joined(separator: " "))
                }
            }

            if let subtraction = subtractUtterance(utterance, from: working) {
                matchedAssistantTexts.append(utterance.text)
                working = subtraction
                if working.isEmpty {
                    return .pureAssistant(text: matchedAssistantTexts.joined(separator: " "))
                }
            }
        }

        if let firstMatched = matchedAssistantTexts.first {
            let remainingTokens = Self.tokenizeWithRanges(working)
            if remainingTokens.isEmpty {
                return .pureAssistant(text: firstMatched)
            }
            return .mixed(userText: working, assistantText: matchedAssistantTexts.reversed().joined(separator: " "))
        }

        return .pureUser(text: clean)
    }

    public static func isAssistantSpeaker(_ speaker: String?, role: String?) -> Bool {
        if let role = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           role == speakerRoleAssistant {
            return true
        }
        guard let clean = speaker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !clean.isEmpty else {
            return false
        }
        return clean == "rock assistant"
            || clean == "rock'n'roll assistant"
            || clean == "ассистент rock"
            || clean == "rock (assistant)"
    }

    public static func displayAuthor(
        speaker: String?,
        isOwn: Bool,
        speakerRole: String?,
        youLabel: String = "You",
        assistantLabel: String = canonicalSpeakerName
    ) -> String {
        if isAssistantSpeaker(speaker, role: speakerRole) {
            return assistantLabel
        }
        let cleanSpeaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isOwn {
            return cleanSpeaker.isEmpty ? youLabel : "\(cleanSpeaker) (\(youLabel))"
        }
        return cleanSpeaker
    }

    // MARK: - Private Matching

    private func upsert(_ item: Utterance, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = utterances.lastIndex(where: { $0.id == item.id }) {
            utterances[idx] = item
        } else {
            utterances.append(item)
        }
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        utterances.removeAll { ($0.endedAt ?? $0.startedAt) < cutoff }
        if utterances.count > 64 {
            utterances.removeFirst(utterances.count - 64)
        }
    }

    private func subtractUtterance(_ utterance: Utterance, from text: String) -> String? {
        let textSpans = Self.tokenizeWithRanges(text)
        let uTokens = utterance.normalizedTokens
        guard !textSpans.isEmpty, uTokens.count >= 2 else { return nil }

        // Find the longest monotonic near-contiguous match of utterance tokens inside textSpans.
        var bestTextStart = 0
        var bestTextEnd = -1
        var bestMatchedCount = 0

        for startIdx in textSpans.indices {
            // Try aligning starting at each position in uTokens.
            for uStart in uTokens.indices {
                guard tokensMatchFuzzy(textSpans[startIdx].token, uTokens[uStart]) else { continue }
                var ti = startIdx
                var ui = uStart
                var matched = 0
                var lastMatchedTextIdx = startIdx

                while ti < textSpans.count && ui < uTokens.count {
                    if tokensMatchFuzzy(textSpans[ti].token, uTokens[ui]) {
                        matched += 1
                        lastMatchedTextIdx = ti
                        ti += 1
                        ui += 1
                    } else if ti + 1 < textSpans.count,
                              tokensMatchFuzzy(textSpans[ti + 1].token, uTokens[ui]) {
                        // Allow 1 inserted/misheard ASR token in server transcript.
                        ti += 1
                    } else if ui + 1 < uTokens.count,
                              tokensMatchFuzzy(textSpans[ti].token, uTokens[ui + 1]) {
                        // Allow 1 skipped token.
                        ui += 1
                    } else if ti + 1 < textSpans.count && ui + 1 < uTokens.count &&
                                tokensMatchFuzzy(textSpans[ti + 1].token, uTokens[ui + 1]) {
                        // Single substituted ASR word in place.
                        ti += 1
                        ui += 1
                    } else {
                        break
                    }
                }

                let spanLen = lastMatchedTextIdx - startIdx + 1
                let coverage = Double(matched) / Double(uTokens.count)
                let qualifies = (matched >= 4) || (uTokens.count <= 4 && coverage >= 0.65 && spanLen >= 2)
                if qualifies && matched > bestMatchedCount {
                    bestMatchedCount = matched
                    bestTextStart = startIdx
                    bestTextEnd = lastMatchedTextIdx
                }
            }
        }

        guard bestMatchedCount >= 2, bestTextEnd >= bestTextStart else { return nil }

        let cutLower = textSpans[bestTextStart].range.lowerBound
        var cutUpper = textSpans[bestTextEnd].range.upperBound
        while cutUpper < text.endIndex {
            let ch = text[cutUpper]
            if ch.isPunctuation || ch.isWhitespace {
                cutUpper = text.index(after: cutUpper)
            } else {
                break
            }
        }

        let prefix = String(text[..<cutLower]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let suffix = String(text[cutUpper...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let joined = [prefix, suffix].filter { !$0.isEmpty }.joined(separator: ". ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokensMatchFuzzy(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let maxLen = max(a.count, b.count)
        guard maxLen >= 5 else { return false }
        let minLen = min(a.count, b.count)
        guard abs(a.count - b.count) <= 2 else { return false }
        let commonPrefix = zip(a, b).prefix(while: { $0 == $1 }).count
        return commonPrefix >= max(4, minLen - 1)
    }

    private static func tokenizeWithRanges(_ text: String) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var tokenStart: String.Index?
        for idx in text.indices {
            let ch = text[idx]
            if ch.isLetter || ch.isNumber {
                if tokenStart == nil { tokenStart = idx }
            } else if let start = tokenStart {
                let raw = String(text[start..<idx])
                let folded = foldToken(raw)
                if !folded.isEmpty {
                    spans.append(TokenSpan(token: folded, range: start..<idx))
                }
                tokenStart = nil
            }
        }
        if let start = tokenStart {
            let raw = String(text[start..<text.endIndex])
            let folded = foldToken(raw)
            if !folded.isEmpty {
                spans.append(TokenSpan(token: folded, range: start..<text.endIndex))
            }
        }
        return spans
    }

    private static func foldToken(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
