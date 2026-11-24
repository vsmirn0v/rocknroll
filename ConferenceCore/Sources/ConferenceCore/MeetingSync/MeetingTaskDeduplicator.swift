import Foundation

/// Shared deduplication and normalization helpers for meeting action items and tasks across iOS and macOS.
public enum MeetingTaskDeduplicator {
    private static let metaPrefixes: [String] = [
        "завести задачу на меня по ",
        "завести задачу по просьбе ",
        "завести задачу на ",
        "завести задачу по ",
        "завести задачу ",
        "создать задачу на меня по ",
        "создать задачу по просьбе ",
        "создать задачу на ",
        "создать задачу по ",
        "создать задачу ",
        "добавить задачу на ",
        "добавить задачу по ",
        "добавить задачу ",
        "поставить задачу на ",
        "поставить задачу по ",
        "поставить задачу ",
        "задача на меня ",
        "задача на ",
        "create a task for ",
        "create task for ",
        "create a task to ",
        "create task to ",
        "create task ",
        "add a task to ",
        "add task to ",
        "add task "
    ]

    private static let stopWords: Set<String> = [
        "по", "на", "в", "во", "и", "из", "за", "к", "ко", "о", "об", "от", "для", "с", "со",
        "у", "пожалуйста", "также", "тоже", "эту", "этот", "эта", "это", "меня", "просьбе",
        "the", "a", "an", "to", "for", "of", "on", "in", "and", "also", "please", "me", "my"
    ]

    public static func normalizedTitle(_ text: String) -> String {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
        var tokens: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens.joined(separator: " ")
    }

    public static func stripMetaTaskPrefix(_ normalized: String) -> String {
        var result = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for prefix in metaPrefixes {
                if result.hasPrefix(prefix) {
                    let remainder = String(result.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        result = remainder
                        changed = true
                        break
                    }
                }
            }
        }
        return result
    }

    public static func normalizedOwner(_ owner: String) -> String {
        let stripped = AssistantPeopleDirectory.strippedMeetingDisplayName(owner)
        let base = stripped.isEmpty ? owner : stripped
        return normalizedTitle(base)
    }

    public static func areOwnersCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedOwner(lhs)
        let b = normalizedOwner(rhs)
        if a.isEmpty || b.isEmpty { return true }
        if a == b { return true }
        let aParts = a.split(separator: " ").map(String.init)
        let bParts = b.split(separator: " ").map(String.init)
        if aParts.count == 1 || bParts.count == 1 {
            return aParts.first == bParts.first || a.contains(b) || b.contains(a)
        }
        return Set(aParts) == Set(bParts)
    }

    public static func isDuplicate(
        candidateTitle: String,
        candidateOwner: String = "",
        existingTitle: String,
        existingOwner: String = ""
    ) -> Bool {
        guard areOwnersCompatible(candidateOwner, existingOwner) else { return false }

        let candNorm = normalizedTitle(candidateTitle)
        let existNorm = normalizedTitle(existingTitle)
        guard !candNorm.isEmpty, !existNorm.isEmpty else { return false }
        if candNorm == existNorm { return true }

        // Keep tasks targeting distinct issue keys or explicit numbers separate.
        let candKeys = extractIssueKeysOrNumbers(from: candidateTitle)
        let existKeys = extractIssueKeysOrNumbers(from: existingTitle)
        if !candKeys.isEmpty && !existKeys.isEmpty && candKeys != existKeys {
            return false
        }

        let candStripped = stripMetaTaskPrefix(candNorm)
        let existStripped = stripMetaTaskPrefix(existNorm)
        if !candStripped.isEmpty && candStripped == existStripped { return true }

        let minLen = min(candStripped.count, existStripped.count)
        if minLen >= 12 && (candStripped.contains(existStripped) || existStripped.contains(candStripped)) {
            return true
        }

        let candTokens = significantTokens(from: candStripped)
        let existTokens = significantTokens(from: existStripped)
        guard candTokens.count >= 2, existTokens.count >= 2 else { return false }

        let intersection = candTokens.intersection(existTokens).count
        let unionCount = candTokens.union(existTokens).count
        guard unionCount > 0 else { return false }
        let jaccard = Double(intersection) / Double(unionCount)
        let minCover = Double(intersection) / Double(min(candTokens.count, existTokens.count))
        return jaccard >= 0.72 || (intersection >= 3 && minCover >= 0.80)
    }

    private static func significantTokens(from normalized: String) -> Set<String> {
        let raw = normalized.split(separator: " ").map(String.init)
        let filtered = raw.filter { $0.count >= 2 && !stopWords.contains($0) }.map(stemToken)
        return Set(filtered)
    }

    private static func stemToken(_ token: String) -> String {
        guard token.count >= 6 else { return token }
        let isCyrillic = token.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        guard isCyrillic else { return token }
        let twoCharEndings = ["ах", "ях", "ам", "ям", "ом", "ем", "ов", "ев", "ой", "ей", "ый", "ий", "ая", "яя", "ое", "ее", "ые", "ие"]
        for suffix in twoCharEndings where token.hasSuffix(suffix) && token.count - suffix.count >= 5 {
            return String(token.dropLast(suffix.count))
        }
        let oneCharEndings = ["а", "я", "у", "ю", "ы", "и", "е", "о"]
        for suffix in oneCharEndings where token.hasSuffix(suffix) && token.count - 1 >= 5 {
            return String(token.dropLast(1))
        }
        return token
    }

    private static func extractIssueKeysOrNumbers(from raw: String) -> Set<String> {
        var result: Set<String> = []
        let upper = raw.uppercased()
        if let keyRegex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9_]+-[0-9]+\b"#) {
            let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
            for match in keyRegex.matches(in: upper, range: range) {
                if let r = Range(match.range, in: upper) {
                    result.insert(String(upper[r]))
                }
            }
        }
        if let numRegex = try? NSRegularExpression(pattern: #"\b[0-9]+\b"#) {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            for match in numRegex.matches(in: raw, range: range) {
                if let r = Range(match.range, in: raw) {
                    result.insert(String(raw[r]))
                }
            }
        }
        return result
    }
}
