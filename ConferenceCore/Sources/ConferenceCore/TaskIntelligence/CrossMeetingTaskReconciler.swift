import Foundation

public struct TaskReconciliationCandidateInput: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var text: String
    public var owner: String
    public var dueDay: String?
    public var dueAt: Date?
    public var done: Bool
    public var completedAt: Date?
    public var extended: TaskExtendedMetadata
    public var seriesID: String?
    public var roomIdentity: String?
    public var isOwnedByCurrentUser: Bool
    public var updatedAt: Date

    public init(
        id: UUID,
        sessionID: UUID,
        text: String,
        owner: String = "",
        dueDay: String? = nil,
        dueAt: Date? = nil,
        done: Bool = false,
        completedAt: Date? = nil,
        extended: TaskExtendedMetadata = .init(),
        seriesID: String? = nil,
        roomIdentity: String? = nil,
        isOwnedByCurrentUser: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.owner = owner
        self.dueDay = dueDay
        self.dueAt = dueAt
        self.done = done
        self.completedAt = completedAt
        self.extended = extended
        self.seriesID = seriesID
        self.roomIdentity = roomIdentity
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.updatedAt = updatedAt
    }
}

public struct CanonicalTaskUpdate: Equatable, Identifiable, Sendable {
    public var id: UUID { existingTaskID }
    public var existingTaskID: UUID
    public var existingSessionID: UUID
    public var historicalTaskID: UUID?
    public var newStatus: TaskWorkflowStatus?
    public var markDone: Bool?
    public var updatedDueDay: String?
    public var updatedDueAt: Date?
    public var contextAddition: String
    public var historyEntry: TaskMeetingContextEntry
}

public struct ReconciledExtractedTask: Identifiable, Equatable, Sendable {
    public var id: UUID { snapshot.id }
    public var snapshot: SyncedTaskSnapshot
    public var suggestedMatchTaskID: UUID?
    public var suggestedMatchScore: Double?
}

public struct CrossMeetingReconciliationResult: Equatable, Sendable {
    public var canonicalUpdates: [CanonicalTaskUpdate]
    public var newTasks: [ReconciledExtractedTask]
    public var reviewCandidates: [ReconciledExtractedTask]
    public var links: [SyncedTaskLink]
}

public struct TaskTranscriptFollowUp: Equatable, Sendable {
    public var existingTaskID: UUID
    public var newStatus: TaskWorkflowStatus?
    public var contextAddition: String
    public var evidenceQuote: String?
    public var dueDay: String?
    public var dueAt: Date?
}

public enum CrossMeetingTaskReconciler {
    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted
    private static let issueKeyRegex = try? NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9_]{1,15}-\d+)\b"#, options: [])
    private static let embeddedTaskIDRegex = try? NSRegularExpression(pattern: #"\[RnR-Task:\s*([0-9A-Fa-f-]{36})\]"#, options: [])

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "about", "need", "needs",
        "will", "shall", "must", "should", "have", "has", "had", "been", "were", "are", "was",
        "in", "on", "at", "to", "by", "of", "or", "as", "is", "it", "be", "we", "now", "new",
        "task", "todo", "action", "item", "follow", "check", "update", "make", "sure",
        "для", "или", "что", "как", "это", "при", "над", "под", "без", "про", "еще", "ещё",
        "уже", "надо", "нужно", "будет", "нужен", "нужна", "нужны", "задача", "сделать", "проверить",
        "на", "по", "за", "из", "от", "до", "ко", "не", "да"
    ]

    public static func extractIssueKeys(from text: String) -> Set<String> {
        guard text.contains("-"), let regex = issueKeyRegex else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }
        var keys: Set<String> = []
        keys.reserveCapacity(matches.count)
        for match in matches {
            if let range = Range(match.range(at: 1), in: text) {
                keys.insert(String(text[range]))
            }
        }
        return keys
    }

    public static func extractEmbeddedTaskIDs(from text: String) -> Set<UUID> {
        guard text.contains("[RnR-Task:"), let regex = embeddedTaskIDRegex else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }
        var ids: Set<UUID> = []
        ids.reserveCapacity(matches.count)
        for match in matches {
            if let range = Range(match.range(at: 1), in: text),
               let uuid = UUID(uuidString: String(text[range])) {
                ids.insert(uuid)
            }
        }
        return ids
    }

    public static func matchesScheduledDiscussion(
        _ existing: TaskReconciliationCandidateInput,
        sessionID: UUID,
        meetingTitle: String,
        endedAt: Date,
        seriesID: String? = nil,
        roomIdentity: String? = nil,
        embeddedTaskIDs: Set<UUID> = []
    ) -> Bool {
        if embeddedTaskIDs.contains(existing.id) { return true }
        return existing.extended.scheduledDiscussions.contains { discussion in
            if discussion.linkedSessionID == sessionID { return true }
            if let seriesID, !seriesID.isEmpty, discussion.calendarSeriesID == seriesID { return true }
            if let roomIdentity, !roomIdentity.isEmpty,
               let urlString = discussion.meetingURL,
               let url = URL(string: urlString),
               MeetingRoomIdentity(url)?.displayDetails == roomIdentity {
                return true
            }
            return textSimilarity(discussion.title, meetingTitle) >= 0.72 &&
                abs(discussion.startAt.timeIntervalSince(endedAt)) <= 6 * 3600
        }
    }

    public static func meaningfulTokens(_ text: String) -> [String] {
        let folded = text.workspaceFolded
        let words = folded
            .components(separatedBy: nonAlphanumerics)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
        var seen: Set<String> = []
        var result: [String] = []
        for word in words {
            let stemmed = stemToken(word)
            guard !stopwords.contains(stemmed) else { continue }
            let canonical = JiraContactMatcher.transliterateCyrillicToLatin(stemmed)
            if canonical.count >= 2, seen.insert(canonical).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    private static func stemToken(_ token: String) -> String {
        guard token.count > 4 else { return token }
        let suffixes = [
            "иями", "ями", "ами", "ого", "ему", "ому", "ыми", "ими", "ость", "ать", "ять", "ить", "еть",
            "ию", "ия", "ии", "ие", "ый", "ий", "ая", "ое", "ые", "ом", "ем", "ой", "ей", "у", "а", "я", "ы", "и",
            "ing", "tion", "ment", "ness", "ed", "es", "s"
        ]
        for suffix in suffixes {
            if token.hasSuffix(suffix), token.count - suffix.count >= 3 {
                return String(token.dropLast(suffix.count))
            }
        }
        return token
    }

    public static func containmentOverlap(_ shortOrCandidate: String, in longerSentence: String) -> Double {
        let tokensA = Set(meaningfulTokens(shortOrCandidate))
        let tokensB = Set(meaningfulTokens(longerSentence))
        return containmentOverlap(tokensA: tokensA, tokensB: tokensB)
    }

    private static func containmentOverlap(tokensA: Set<String>, tokensB: Set<String>) -> Double {
        guard tokensA.count >= 2, tokensB.count >= 2 else { return 0 }
        let shared = Double(tokensA.intersection(tokensB).count)
        guard shared >= 2 else { return 0 }
        return shared / Double(min(tokensA.count, tokensB.count))
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let clean = JiraContactMatcher.transliterateCyrillicToLatin(text)
            .components(separatedBy: nonAlphanumerics)
            .joined(separator: " ")
        let chars = Array(clean)
        guard chars.count >= 3 else { return Set(chars.map { String($0) }) }
        var set: Set<String> = []
        set.reserveCapacity(chars.count - 2)
        for i in 0...(chars.count - 3) {
            set.insert(String(chars[i..<(i + 3)]))
        }
        return set
    }

    public static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let keysL = extractIssueKeys(from: lhs)
        let keysR = extractIssueKeys(from: rhs)
        if !keysL.isEmpty && !keysL.isDisjoint(with: keysR) {
            return 1.0
        }
        let tokensL = Set(meaningfulTokens(lhs))
        let tokensR = Set(meaningfulTokens(rhs))
        return similarityScore(
            lhsText: lhs,
            rhsText: rhs,
            tokensL: tokensL,
            tokensR: tokensR,
            trigramsL: nil,
            trigramsR: nil
        )
    }

    private static func similarityScore(
        lhsText: String,
        rhsText: String,
        tokensL: Set<String>,
        tokensR: Set<String>,
        trigramsL: Set<String>?,
        trigramsR: Set<String>?
    ) -> Double {
        guard !tokensL.isEmpty && !tokensR.isEmpty else { return 0 }
        let intersection = Double(tokensL.intersection(tokensR).count)
        if intersection == 0 {
            let triL = trigramsL ?? trigrams(lhsText)
            let triR = trigramsR ?? trigrams(rhsText)
            let triOverlap = triL.isEmpty || triR.isEmpty ? 0.0 : Double(triL.intersection(triR).count * 2) / Double(triL.count + triR.count)
            return triOverlap * 0.25
        }
        let dice = (2.0 * intersection) / Double(tokensL.count + tokensR.count)
        let jaccard = intersection / Double(tokensL.union(tokensR).count)
        let triL = trigramsL ?? trigrams(lhsText)
        let triR = trigramsR ?? trigrams(rhsText)
        let triOverlap = triL.isEmpty || triR.isEmpty ? 0.0 : Double(triL.intersection(triR).count * 2) / Double(triL.count + triR.count)
        let containment = intersection / Double(min(tokensL.count, tokensR.count))
        let fullContainmentFloor = (intersection >= 3.0 && containment >= 0.99) ? 0.78 : 0.0
        return max(dice, fullContainmentFloor, dice * 0.55 + jaccard * 0.20 + triOverlap * 0.25)
    }

    public static func matchScore(
        candidate: SyncedTaskSnapshot,
        existing: TaskReconciliationCandidateInput,
        currentSeriesID: String? = nil,
        currentRoomIdentity: String? = nil,
        myAliases: [String] = []
    ) -> Double {
        let existingKeys = Set(existing.extended.externalBindings.compactMap(\.externalKey))
            .union(extractIssueKeys(from: existing.text + " " + existing.extended.contextNotes))
        let candidateKeys = Set(candidate.extended.externalBindings.compactMap(\.externalKey))
            .union(extractIssueKeys(from: candidate.text + " " + candidate.extended.contextNotes))
        return matchScore(
            candidate: candidate,
            candidateKeys: candidateKeys,
            candidateTokens: Set(meaningfulTokens(candidate.text)),
            candidateTrigrams: nil,
            existing: existing,
            existingKeys: existingKeys,
            existingTokens: Set(meaningfulTokens(existing.text)),
            existingTrigrams: nil,
            currentSeriesID: currentSeriesID,
            currentRoomIdentity: currentRoomIdentity,
            myAliases: myAliases
        )
    }

    private static func matchScore(
        candidate: SyncedTaskSnapshot,
        candidateKeys: Set<String>,
        candidateTokens: Set<String>,
        candidateTrigrams: Set<String>?,
        existing: TaskReconciliationCandidateInput,
        existingKeys: Set<String>,
        existingTokens: Set<String>,
        existingTrigrams: Set<String>?,
        currentSeriesID: String? = nil,
        currentRoomIdentity: String? = nil,
        myAliases: [String] = []
    ) -> Double {
        if !existingKeys.isEmpty && !existingKeys.isDisjoint(with: candidateKeys) {
            return 1.0
        }
        guard !candidateTokens.isEmpty && !existingTokens.isEmpty else { return 0 }
        if candidateTokens.isDisjoint(with: existingTokens) {
            // Disjoint token sets cap similarityScore at 0.25, which always fails `guard base > 0.25`.
            let triL = candidateTrigrams ?? trigrams(candidate.text)
            let triR = existingTrigrams ?? trigrams(existing.text)
            let triOverlap = triL.isEmpty || triR.isEmpty ? 0.0 : Double(triL.intersection(triR).count * 2) / Double(triL.count + triR.count)
            return triOverlap * 0.25
        }
        let base = similarityScore(
            lhsText: candidate.text,
            rhsText: existing.text,
            tokensL: candidateTokens,
            tokensR: existingTokens,
            trigramsL: candidateTrigrams,
            trigramsR: existingTrigrams
        )
        guard base > 0.25 else { return base }

        var score = base
        let ownerCompatible = JiraContactMatcher.areCompatibleOwners(candidate.owner, existing.owner, myAliases: myAliases)
        if !ownerCompatible {
            score -= 0.28
        } else if !candidate.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !existing.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 0.10
        }
        if let currentSeriesID, !currentSeriesID.isEmpty, currentSeriesID == existing.seriesID {
            score += 0.06
        } else if let currentRoomIdentity, !currentRoomIdentity.isEmpty, currentRoomIdentity == existing.roomIdentity {
            score += 0.04
        }
        return min(1.0, max(0.0, score))
    }

    public static func detectStatusSignal(in text: String) -> TaskWorkflowStatus? {
        let lower = text.workspaceFolded
        let donePhrases = [
            "done", "completed", "finished", "shipped", "deployed", "merged", "closed", "resolved", "fixed",
            "готово", "сделал", "сделала", "сделали", "закончил", "закончили", "завершил", "завершили",
            "закрыли", "закрыл", "задеплоили", "выкатили", "смержили", "починили", "выполнено"
        ]
        if containsAnyPhrase(in: lower, phrases: donePhrases) {
            return .done
        }
        let cancelledPhrases = [
            "cancelled", "canceled", "dropped", "wont do", "won't do", "no longer needed", "obsolete",
            "отменили", "отмена", "не актуально", "неактуально", "дропнули", "отказались"
        ]
        if containsAnyPhrase(in: lower, phrases: cancelledPhrases) {
            return .cancelled
        }
        let blockedPhrases = [
            "blocked", "blocker", "waiting on", "waiting for", "stuck", "cannot proceed",
            "заблокирован", "заблокировано", "блокер", "ждем", "ждём", "уперлись", "упёрлись", "стопор"
        ]
        if containsAnyPhrase(in: lower, phrases: blockedPhrases) {
            return .blocked
        }
        let reviewPhrases = [
            "in review", "code review", "on review", "ready for review", "pr opened", "pull request",
            "на ревью", "код ревью", "открыл пр", "открыл pr", "отдали на проверку", "на проверке"
        ]
        if containsAnyPhrase(in: lower, phrases: reviewPhrases) {
            return .inReview
        }
        let inProgressPhrases = [
            "in progress", "working on", "started", "picking up", "continuing",
            "в работе", "делаю", "делаем", "занимаюсь", "занимаемся", "начал", "начали", "продолжаю"
        ]
        if containsAnyPhrase(in: lower, phrases: inProgressPhrases) {
            return .inProgress
        }
        return nil
    }

    private static func containsAnyPhrase(in foldedText: String, phrases: [String]) -> Bool {
        // Avoid false positives from negations like "not done" / "не готово".
        for phrase in phrases {
            if let range = foldedText.range(of: phrase) {
                let prefixStart = foldedText.index(range.lowerBound, offsetBy: -12, limitedBy: foldedText.startIndex) ?? foldedText.startIndex
                let before = String(foldedText[prefixStart..<range.lowerBound])
                if before.hasSuffix("not ") || before.hasSuffix("не ") || before.hasSuffix("еще не ") || before.hasSuffix("ещё не ") || before.hasSuffix("still ") {
                    continue
                }
                if range.lowerBound == foldedText.startIndex || !foldedText[foldedText.index(before: range.lowerBound)].isLetter {
                    return true
                }
            }
        }
        return false
    }

    public static func analyzeTranscriptUpdates(
        meetingTitle: String,
        endedAt: Date,
        sessionID: UUID? = nil,
        seriesID: String? = nil,
        roomIdentity: String? = nil,
        events: [SyncedTranscriptEvent],
        notes: String,
        decisions: [String],
        existingTasks: [TaskReconciliationCandidateInput],
        onlyUpdateOwnedExistingTasks: Bool = false,
        myAliases: [String] = []
    ) -> [TaskTranscriptFollowUp] {
        guard !existingTasks.isEmpty else { return [] }
        let usableLines: [(speaker: String?, text: String)] =
            events.filter { ($0.kind == "transcript" || $0.kind == "chat") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ($0.speaker, $0.text) }
            + decisions.map { (nil, $0) }
            + notes.components(separatedBy: .newlines).map { (nil, $0) }

        let allText = usableLines.map(\.text).joined(separator: "\n") + "\n" + meetingTitle + "\n" + notes
        let embeddedTaskIDs = extractEmbeddedTaskIDs(from: allText)

        let permittedTasks = existingTasks.filter { task in
            guard !task.done else { return false }
            if !onlyUpdateOwnedExistingTasks { return true }
            return task.isOwnedByCurrentUser || JiraContactMatcher.isCurrentUserOwner(task.owner, myAliases: myAliases)
        }
        guard !permittedTasks.isEmpty else { return [] }

        struct PreparedFollowUpTask {
            let task: TaskReconciliationCandidateInput
            let keys: Set<String>
            let tokens: Set<String>
        }

        let preparedTasks: [PreparedFollowUpTask] = permittedTasks.map { task in
            let keys = Set(task.extended.externalBindings.compactMap(\.externalKey))
                .union(extractIssueKeys(from: task.text + " " + task.extended.contextNotes))
            let tokens = Set(meaningfulTokens(task.text))
            return PreparedFollowUpTask(task: task, keys: keys, tokens: tokens)
        }
        var trigramsCacheByTaskIndex: [Int: Set<String>] = [:]
        var tasksByKey: [String: [Int]] = [:]
        var tasksByToken: [String: [Int]] = [:]
        for (idx, item) in preparedTasks.enumerated() {
            for key in item.keys {
                tasksByKey[key, default: []].append(idx)
            }
            for token in item.tokens {
                tasksByToken[token, default: []].append(idx)
            }
        }

        var followUpsByTask: [UUID: TaskTranscriptFollowUp] = [:]
        for line in usableLines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 6 else { continue }
            let lineKeys = extractIssueKeys(from: trimmed)
            let lineTokens = Set(meaningfulTokens(trimmed))
            guard !lineKeys.isEmpty || !lineTokens.isEmpty else { continue }

            var candidateIndices: [Int] = []
            var seenIndices: Set<Int> = []
            for key in lineKeys {
                for idx in tasksByKey[key] ?? [] where seenIndices.insert(idx).inserted {
                    candidateIndices.append(idx)
                }
            }
            for token in lineTokens {
                for idx in tasksByToken[token] ?? [] where seenIndices.insert(idx).inserted {
                    candidateIndices.append(idx)
                }
            }
            guard !candidateIndices.isEmpty else { continue }
            candidateIndices.sort()

            let signal = detectStatusSignal(in: trimmed)
            var lazyLineTrigrams: Set<String>?

            for idx in candidateIndices {
                let prepared = preparedTasks[idx]
                let task = prepared.task
                let keyMatched = !prepared.keys.isEmpty && !prepared.keys.isDisjoint(with: lineKeys)
                let similarity: Double
                let containment: Double
                if keyMatched {
                    similarity = 1.0
                    containment = 1.0
                } else {
                    if lazyLineTrigrams == nil {
                        lazyLineTrigrams = trigrams(trimmed)
                    }
                    let taskTris = trigramsCacheByTaskIndex[idx] ?? {
                        let t = trigrams(task.text)
                        trigramsCacheByTaskIndex[idx] = t
                        return t
                    }()
                    similarity = similarityScore(
                        lhsText: trimmed,
                        rhsText: task.text,
                        tokensL: lineTokens,
                        tokensR: prepared.tokens,
                        trigramsL: lazyLineTrigrams,
                        trigramsR: taskTris
                    )
                    if similarity >= 0.50 && signal != nil {
                        containment = 0
                    } else if similarity >= 0.68 {
                        containment = 0
                    } else {
                        containment = containmentOverlap(tokensA: prepared.tokens, tokensB: lineTokens)
                    }
                }
                guard keyMatched
                    || (similarity >= 0.50 && signal != nil)
                    || (containment >= 0.65 && similarity >= 0.30 && signal != nil)
                    || similarity >= 0.68 else { continue }

                let quotePrefix = line.speaker.flatMap { $0.isEmpty ? nil : "\($0): " } ?? ""
                let quote = String((quotePrefix + trimmed).prefix(400))
                let contextNote = "[\(meetingTitle)] \(quote)"
                if var existingFollowUp = followUpsByTask[task.id] {
                    if let signal { existingFollowUp.newStatus = signal }
                    if !existingFollowUp.contextAddition.contains(quote) {
                        existingFollowUp.contextAddition += "\n" + contextNote
                    }
                    followUpsByTask[task.id] = existingFollowUp
                } else {
                    followUpsByTask[task.id] = TaskTranscriptFollowUp(
                        existingTaskID: task.id,
                        newStatus: signal,
                        contextAddition: contextNote,
                        evidenceQuote: quote,
                        dueDay: nil,
                        dueAt: nil
                    )
                }
            }
        }

        // Closed-loop update for tasks/epics with an explicitly scheduled/linked discussion meeting matching this session.
        if let sid = sessionID {
            for task in permittedTasks where followUpsByTask[task.id] == nil {
                guard matchesScheduledDiscussion(
                    task,
                    sessionID: sid,
                    meetingTitle: meetingTitle,
                    endedAt: endedAt,
                    seriesID: seriesID,
                    roomIdentity: roomIdentity,
                    embeddedTaskIDs: embeddedTaskIDs
                ) else { continue }

                let summaryBits = decisions.prefix(3).map { "• \($0)" }
                    + usableLines.prefix(3).map { line in
                        let prefix = line.speaker.flatMap { $0.isEmpty ? nil : "\($0): " } ?? ""
                        return "• " + prefix + line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                guard !summaryBits.isEmpty else { continue }
                let overallSignal = decisions.compactMap(detectStatusSignal(in:)).last
                    ?? usableLines.reversed().compactMap { detectStatusSignal(in: $0.text) }.first
                followUpsByTask[task.id] = TaskTranscriptFollowUp(
                    existingTaskID: task.id,
                    newStatus: overallSignal,
                    contextAddition: "[\(meetingTitle) — \(L("Linked Discussion"))]\n" + summaryBits.prefix(4).joined(separator: "\n"),
                    evidenceQuote: decisions.first,
                    dueDay: nil,
                    dueAt: nil
                )
            }
        }

        return Array(followUpsByTask.values)
    }

    public static func enrichExtractedTaskContext(
        snapshot: SyncedTaskSnapshot,
        meetingTitle: String,
        endedAt: Date,
        sessionID: UUID,
        events: [SyncedTranscriptEvent],
        decisions: [String]
    ) -> SyncedTaskSnapshot {
        var enriched = snapshot
        if enriched.extended.workflowStatus == .todo,
           let detected = detectStatusSignal(in: snapshot.text) {
            enriched.extended.workflowStatus = detected
            if detected.isTerminalDone {
                enriched.done = true
                enriched.completedAt = endedAt
            }
        }

        if enriched.extended.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let matchingLines = events
                .filter { ($0.kind == "transcript" || $0.kind == "chat") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .filter { event in textSimilarity(event.text, snapshot.text) >= 0.35 }
                .prefix(3)
                .map { event -> String in
                    let speaker = event.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prefix = (speaker?.isEmpty == false) ? "\(speaker!): " : ""
                    return "• " + prefix + event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            let matchingDecisions = decisions
                .filter { textSimilarity($0, snapshot.text) >= 0.35 }
                .prefix(2)
                .map { "• Decision: " + $0 }
            let combined = (matchingDecisions + matchingLines).joined(separator: "\n")
            if !combined.isEmpty {
                enriched.extended.appendContextNote(combined)
            }
        }

        if enriched.extended.contextHistory.isEmpty {
            let summaryNote = enriched.extended.contextNotes.isEmpty
                ? L("Created from meeting outcome")
                : String(enriched.extended.contextNotes.prefix(320))
            enriched.extended.appendHistory(TaskMeetingContextEntry(
                sessionID: sessionID,
                meetingTitle: meetingTitle,
                observedAt: endedAt,
                previousStatus: nil,
                updatedStatus: enriched.extended.workflowStatus,
                note: summaryNote,
                source: .meetingExtraction
            ))
        }
        return enriched
    }

    public static func reconcile(
        sessionID: UUID,
        meetingTitle: String,
        endedAt: Date,
        seriesID: String? = nil,
        roomIdentity: String? = nil,
        extractedTasks: [SyncedTaskSnapshot],
        existingTasks: [TaskReconciliationCandidateInput],
        transcriptFollowUps: [TaskTranscriptFollowUp] = [],
        llmMatches: [UUID: TaskTranscriptFollowUp] = [:],
        myAliases: [String] = [],
        onlyUpdateOwnedExistingTasks: Bool = false,
        rollUpToParentEpics: Bool = true
    ) -> CrossMeetingReconciliationResult {
        let otherMeetingTasks = existingTasks.filter { $0.sessionID != sessionID }
        var updatesByExistingID: [UUID: CanonicalTaskUpdate] = [:]
        var links: [SyncedTaskLink] = []
        var newTasks: [ReconciledExtractedTask] = []
        var reviewCandidates: [ReconciledExtractedTask] = []

        func canAutoMutate(_ existing: TaskReconciliationCandidateInput) -> Bool {
            guard onlyUpdateOwnedExistingTasks else { return true }
            return existing.isOwnedByCurrentUser || JiraContactMatcher.isCurrentUserOwner(existing.owner, myAliases: myAliases)
        }

        func mergeUpdate(
            existing: TaskReconciliationCandidateInput,
            historicalTaskID: UUID?,
            newStatus: TaskWorkflowStatus?,
            contextAddition: String,
            evidenceQuote: String?,
            dueDay: String?,
            dueAt: Date?
        ) {
            let currentStatus = existing.done ? .done : existing.extended.workflowStatus
            let effectiveNewStatus = newStatus ?? currentStatus
            let statusChanged = newStatus != nil && newStatus != currentStatus
            let cleanAddition = contextAddition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard statusChanged || !cleanAddition.isEmpty || dueDay != nil || dueAt != nil || historicalTaskID != nil else { return }

            let noteText = !cleanAddition.isEmpty
                ? cleanAddition
                : (statusChanged ? L("Status updated to %@", effectiveNewStatus.localizedTitle) : L("Mentioned again in meeting"))

            let historyEntry = TaskMeetingContextEntry(
                sessionID: sessionID,
                meetingTitle: meetingTitle,
                observedAt: endedAt,
                previousStatus: statusChanged ? currentStatus : nil,
                updatedStatus: statusChanged ? effectiveNewStatus : nil,
                note: noteText,
                evidenceQuote: evidenceQuote,
                source: .meetingFollowUp
            )

            if var prior = updatesByExistingID[existing.id] {
                if let newStatus {
                    prior.newStatus = newStatus
                    prior.markDone = newStatus.isTerminalDone
                }
                if !cleanAddition.isEmpty, !prior.contextAddition.contains(cleanAddition) {
                    prior.contextAddition += (prior.contextAddition.isEmpty ? "" : "\n") + cleanAddition
                }
                if let dueDay { prior.updatedDueDay = dueDay }
                if let dueAt { prior.updatedDueAt = dueAt }
                if let historicalTaskID { prior.historicalTaskID = historicalTaskID }
                updatesByExistingID[existing.id] = prior
            } else {
                updatesByExistingID[existing.id] = CanonicalTaskUpdate(
                    existingTaskID: existing.id,
                    existingSessionID: existing.sessionID,
                    historicalTaskID: historicalTaskID,
                    newStatus: statusChanged ? newStatus : nil,
                    markDone: statusChanged ? effectiveNewStatus.isTerminalDone : nil,
                    updatedDueDay: existing.dueDay == nil ? dueDay : nil,
                    updatedDueAt: existing.dueAt == nil ? dueAt : nil,
                    contextAddition: cleanAddition,
                    historyEntry: historyEntry
                )
            }
        }

        // 1. Reconcile newly extracted tasks against prior meetings' tasks.
        let otherByID = Dictionary(uniqueKeysWithValues: otherMeetingTasks.map { ($0.id, $0) })
        struct PreparedExistingTask {
            let existing: TaskReconciliationCandidateInput
            let keys: Set<String>
            let tokens: Set<String>
            let matchesDiscussion: Bool
        }
        let preparedExisting: [PreparedExistingTask] = extractedTasks.isEmpty ? [] : otherMeetingTasks.map { existing in
            let keys = Set(existing.extended.externalBindings.compactMap(\.externalKey))
                .union(extractIssueKeys(from: existing.text + " " + existing.extended.contextNotes))
            let tokens = Set(meaningfulTokens(existing.text))
            let matched = matchesScheduledDiscussion(
                existing,
                sessionID: sessionID,
                meetingTitle: meetingTitle,
                endedAt: endedAt,
                seriesID: seriesID,
                roomIdentity: roomIdentity
            )
            return PreparedExistingTask(existing: existing, keys: keys, tokens: tokens, matchesDiscussion: matched)
        }
        var existingTrigramsByID: [UUID: Set<String>] = [:]

        for candidate in extractedTasks {
            if let llmFollowUp = llmMatches[candidate.id],
               let existing = otherByID[llmFollowUp.existingTaskID],
               canAutoMutate(existing) {
                let status = llmFollowUp.newStatus ?? detectStatusSignal(in: candidate.text + " " + candidate.extended.contextNotes)
                mergeUpdate(
                    existing: existing,
                    historicalTaskID: candidate.id,
                    newStatus: status,
                    contextAddition: llmFollowUp.contextAddition.isEmpty ? candidate.extended.contextNotes : llmFollowUp.contextAddition,
                    evidenceQuote: llmFollowUp.evidenceQuote ?? candidate.text,
                    dueDay: llmFollowUp.dueDay ?? candidate.dueDay,
                    dueAt: llmFollowUp.dueAt ?? candidate.dueAt
                )
                links.append(SyncedTaskLink(
                    sessionID: sessionID,
                    historicalTaskID: candidate.id,
                    canonicalTaskID: existing.id,
                    updatedAt: endedAt
                ))
                continue
            }

            let candidateKeys = Set(candidate.extended.externalBindings.compactMap(\.externalKey))
                .union(extractIssueKeys(from: candidate.text + " " + candidate.extended.contextNotes))
            let candidateTokens = Set(meaningfulTokens(candidate.text))
            var candidateTrigrams: Set<String>?

            var bestMatch: (task: TaskReconciliationCandidateInput, score: Double)?
            for item in preparedExisting {
                let keyMatched = !item.keys.isEmpty && !item.keys.isDisjoint(with: candidateKeys)
                var score: Double
                if keyMatched {
                    score = 1.0
                } else {
                    let computed: Double
                    if !candidateTokens.isDisjoint(with: item.tokens) {
                        if candidateTrigrams == nil {
                            candidateTrigrams = trigrams(candidate.text)
                        }
                        let existingTris = existingTrigramsByID[item.existing.id] ?? {
                            let t = trigrams(item.existing.text)
                            existingTrigramsByID[item.existing.id] = t
                            return t
                        }()
                        computed = matchScore(
                            candidate: candidate,
                            candidateKeys: candidateKeys,
                            candidateTokens: candidateTokens,
                            candidateTrigrams: candidateTrigrams,
                            existing: item.existing,
                            existingKeys: item.keys,
                            existingTokens: item.tokens,
                            existingTrigrams: existingTris,
                            currentSeriesID: seriesID,
                            currentRoomIdentity: roomIdentity,
                            myAliases: myAliases
                        )
                    } else {
                        computed = 0.0
                    }
                    if item.matchesDiscussion {
                        score = max(0.90, computed)
                    } else if candidateTokens.isDisjoint(with: item.tokens) {
                        continue
                    } else {
                        score = computed
                    }
                }
                if let currentBest = bestMatch {
                    if score > currentBest.score {
                        bestMatch = (item.existing, score)
                    }
                } else {
                    bestMatch = (item.existing, score)
                }
            }

            if let best = bestMatch, best.score >= 0.72 {
                if canAutoMutate(best.task) {
                    let detectedStatus = detectStatusSignal(in: candidate.text + " " + candidate.extended.contextNotes)
                    let addition = candidate.extended.contextNotes.isEmpty ? candidate.text : candidate.extended.contextNotes
                    mergeUpdate(
                        existing: best.task,
                        historicalTaskID: candidate.id,
                        newStatus: detectedStatus ?? (candidate.done ? .done : nil),
                        contextAddition: addition,
                        evidenceQuote: candidate.text,
                        dueDay: candidate.dueDay,
                        dueAt: candidate.dueAt
                    )
                    links.append(SyncedTaskLink(
                        sessionID: sessionID,
                        historicalTaskID: candidate.id,
                        canonicalTaskID: best.task.id,
                        updatedAt: endedAt
                    ))
                } else {
                    var flagged = candidate
                    flagged.extended.appendHistory(TaskMeetingContextEntry(
                        sessionID: sessionID,
                        meetingTitle: meetingTitle,
                        observedAt: endedAt,
                        previousStatus: nil,
                        updatedStatus: candidate.extended.workflowStatus,
                        note: L("Matches teammate's task (%@): %@", best.task.owner.isEmpty ? L("Unassigned") : best.task.owner, best.task.text),
                        source: .meetingExtraction
                    ))
                    reviewCandidates.append(ReconciledExtractedTask(
                        snapshot: flagged,
                        suggestedMatchTaskID: best.task.id,
                        suggestedMatchScore: best.score
                    ))
                }
            } else if let best = bestMatch, best.score >= 0.48 {
                var flagged = candidate
                flagged.extended.appendHistory(TaskMeetingContextEntry(
                    sessionID: sessionID,
                    meetingTitle: meetingTitle,
                    observedAt: endedAt,
                    previousStatus: nil,
                    updatedStatus: candidate.extended.workflowStatus,
                    note: L("Possible match to existing task (%ld%%): %@", Int((best.score * 100).rounded()), best.task.text),
                    source: .meetingExtraction
                ))
                reviewCandidates.append(ReconciledExtractedTask(
                    snapshot: flagged,
                    suggestedMatchTaskID: best.task.id,
                    suggestedMatchScore: best.score
                ))
            } else {
                newTasks.append(ReconciledExtractedTask(snapshot: candidate))
            }
        }

        // 2. Apply transcript/discussion follow-ups for existing tasks not matched via extracted task rows.
        for followUp in transcriptFollowUps {
            guard let existing = otherByID[followUp.existingTaskID],
                  canAutoMutate(existing) else { continue }
            mergeUpdate(
                existing: existing,
                historicalTaskID: nil,
                newStatus: followUp.newStatus,
                contextAddition: followUp.contextAddition,
                evidenceQuote: followUp.evidenceQuote,
                dueDay: followUp.dueDay,
                dueAt: followUp.dueAt
            )
        }

        // 3. Roll up child task status/context progress onto parent Epics in Manager/Lead or custom modes.
        if rollUpToParentEpics && !onlyUpdateOwnedExistingTasks {
            let existingByID = Dictionary(uniqueKeysWithValues: otherMeetingTasks.map { ($0.id, $0) })
            let epicCandidates = otherMeetingTasks.filter { $0.extended.issueKind == .epic }
            if !epicCandidates.isEmpty {
                for update in Array(updatesByExistingID.values) {
                    guard let child = existingByID[update.existingTaskID],
                          let epicKey = child.extended.parentEpicKey?.uppercased(),
                          !epicKey.isEmpty else { continue }
                    guard let epic = epicCandidates.first(where: { candidate in
                        candidate.id != child.id && (
                            candidate.extended.externalBindings.contains(where: { $0.externalKey?.uppercased() == epicKey }) ||
                                extractIssueKeys(from: candidate.text).contains(epicKey)
                        )
                    }) else { continue }
                    let statusTag = update.newStatus.map { " [\($0.localizedTitle)]" } ?? ""
                    let childKey = child.extended.externalBindings.first(where: { $0.provider == .jira })?.externalKey
                    let label = childKey.map { "\($0): \(child.text)" } ?? child.text
                    mergeUpdate(
                        existing: epic,
                        historicalTaskID: nil,
                        newStatus: nil,
                        contextAddition: "[\(meetingTitle)] \(label)\(statusTag)",
                        evidenceQuote: nil,
                        dueDay: nil,
                        dueAt: nil
                    )
                }
            }
        }

        return CrossMeetingReconciliationResult(
            canonicalUpdates: Array(updatesByExistingID.values).sorted { $0.existingTaskID.uuidString < $1.existingTaskID.uuidString },
            newTasks: newTasks,
            reviewCandidates: reviewCandidates,
            links: links
        )
    }
}
