import Foundation

public enum TranscriptMergeEngine {
    public static func merge(chunks: [SyncedTranscriptChunk]) -> [SyncedTranscriptEvent] {
        let activeChunks = chunks.filter { !$0.isDeleted }
        guard !activeChunks.isEmpty else { return [] }

        var micIntervalsByDevice: [String: [DateInterval]] = [:]
        var legIntervalsByDevice: [String: DateInterval] = [:]
        var devicesWithGaplessCoverage: Set<String> = []
        var gapIntervalsByDevice: [String: [DateInterval]] = [:]

        for chunk in activeChunks {
            if !chunk.micActiveIntervals.isEmpty {
                micIntervalsByDevice[chunk.deviceID, default: []].append(contentsOf: chunk.micActiveIntervals)
            }
            let chunkEnd = max(
                chunk.sessionStartedAt,
                chunk.sessionEndedAt ?? chunk.events.map { $0.endedAt ?? $0.occurredAt }.max() ?? chunk.sessionStartedAt
            )
            let span = DateInterval(start: chunk.sessionStartedAt, end: chunkEnd)
            if let existing = legIntervalsByDevice[chunk.deviceID] {
                legIntervalsByDevice[chunk.deviceID] = DateInterval(
                    start: min(existing.start, span.start),
                    end: max(existing.end, span.end)
                )
            } else {
                legIntervalsByDevice[chunk.deviceID] = span
            }
            let gaps = chunk.events.filter { $0.kind == "captureGap" }.map { event in
                DateInterval(start: event.occurredAt, end: max(event.occurredAt, event.endedAt ?? event.occurredAt))
            }
            gapIntervalsByDevice[chunk.deviceID, default: []].append(contentsOf: gaps)
        }
        for (deviceID, _) in legIntervalsByDevice {
            if (gapIntervalsByDevice[deviceID] ?? []).isEmpty {
                devicesWithGaplessCoverage.insert(deviceID)
            }
        }

        // 1. Exact provider ID deduplication for server captions and chat messages.
        struct ProviderKey: Hashable {
            let kind: String
            let providerMessageID: String
        }
        var byProviderKey: [ProviderKey: SyncedTranscriptEvent] = [:]
        var passthrough: [SyncedTranscriptEvent] = []

        for chunk in activeChunks {
            for event in chunk.events {
                if let msgID = event.providerMessageID, !msgID.isEmpty {
                    let key = ProviderKey(kind: event.kind, providerMessageID: msgID)
                    if let existing = byProviderKey[key] {
                        byProviderKey[key] = mergeSameProviderEvent(existing, event)
                    } else {
                        byProviderKey[key] = event
                    }
                } else {
                    passthrough.append(event)
                }
            }
        }

        let combined = Array(byProviderKey.values) + passthrough

        // 2. Suppress own-speech echoes captured on a muted/non-mic secondary device when
        // another device held the active microphone at that timestamp.
        let nonMicOwnSuppressed = combined.filter { event in
            guard event.kind == "transcript", event.isOwn, event.providerMessageID == nil else {
                return true
            }
            let localHadMic = hasMicCoverage(deviceID: event.deviceID, at: event.occurredAt, map: micIntervalsByDevice)
            if localHadMic { return true }
            let otherHadMic = micIntervalsByDevice.contains { deviceID, intervals in
                deviceID != event.deviceID &&
                    intervals.contains { $0.start.addingTimeInterval(-1.5) <= event.occurredAt &&
                        event.occurredAt <= $0.end.addingTimeInterval(1.5) }
            }
            return !otherHadMic
        }

        // 3. Fuzzy local-ASR deduplication across distinct devices.
        let ordered = nonMicOwnSuppressed.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.sourceTier != $1.sourceTier { return $0.sourceTier > $1.sourceTier }
            return $0.id < $1.id
        }

        var transcriptKept: [SyncedTranscriptEvent] = []
        var transcriptCache: [(speaker: String, tokens: Set<String>)] = []
        var nonTranscriptKept: [SyncedTranscriptEvent] = []
        var nonTranscriptIndexByKey: [String: Int] = [:]
        transcriptKept.reserveCapacity(ordered.count)
        transcriptCache.reserveCapacity(ordered.count)

        for event in ordered {
            if event.kind != "transcript" {
                let key = "\(event.kind)|\(event.id)"
                if let duplicateIndex = nonTranscriptIndexByKey[key] {
                    nonTranscriptKept[duplicateIndex] = mergeSameProviderEvent(nonTranscriptKept[duplicateIndex], event)
                } else {
                    nonTranscriptIndexByKey[key] = nonTranscriptKept.count
                    nonTranscriptKept.append(event)
                }
                continue
            }

            let eventSpeaker = normalizedSpeaker(event.speaker)
            var eventTokenSet: Set<String>?
            var matchedIndex: Int?
            for idx in stride(from: transcriptKept.count - 1, through: 0, by: -1) {
                let existing = transcriptKept[idx]
                if event.occurredAt.timeIntervalSince(existing.occurredAt) > 4.0 {
                    break
                }
                let existingIsAssistant = AssistantSpeechLedger.isAssistantSpeaker(existing.speaker, role: existing.speakerRole)
                let eventIsAssistant = AssistantSpeechLedger.isAssistantSpeaker(event.speaker, role: event.speakerRole)
                guard existingIsAssistant == eventIsAssistant else { continue }
                let sameDeviceOwnVsServer = (existing.deviceID == event.deviceID) && existing.isOwn && event.isOwn && (existing.sourceTier != event.sourceTier)
                guard existing.deviceID != event.deviceID || existing.id == event.id || sameDeviceOwnVsServer else { continue }
                if existing.id == event.id {
                    matchedIndex = idx
                    break
                }
                let cached = transcriptCache[idx]
                if !sameDeviceOwnVsServer, !cached.speaker.isEmpty && !eventSpeaker.isEmpty && cached.speaker != eventSpeaker {
                    continue
                }
                if eventTokenSet == nil {
                    eventTokenSet = Set(tokens(event.text))
                }
                guard let tokB = eventTokenSet, isFuzzyTokenMatch(cached.tokens, tokB) else { continue }
                matchedIndex = idx
                break
            }

            if let matchIndex = matchedIndex {
                let winner = pickBetterTranscript(transcriptKept[matchIndex], event)
                transcriptKept[matchIndex] = winner
                transcriptCache[matchIndex] = (
                    speaker: normalizedSpeaker(winner.speaker),
                    tokens: Set(tokens(winner.text))
                )
            } else {
                transcriptKept.append(event)
                transcriptCache.append((
                    speaker: eventSpeaker,
                    tokens: eventTokenSet ?? Set(tokens(event.text))
                ))
            }
        }

        // 4. Heal captureGap events if another device leg captured speech over that interval.
        let healedNonTranscript = nonTranscriptKept.filter { event in
            guard event.kind == "captureGap" else { return true }
            let gapStart = event.occurredAt
            let gapEnd = max(event.occurredAt, event.endedAt ?? event.occurredAt)
            let windowStart = gapStart.addingTimeInterval(-3.0)
            let windowEnd = gapEnd.addingTimeInterval(3.0)

            // Binary search for first transcript event with occurredAt >= windowStart.
            var lo = 0
            var hi = transcriptKept.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if transcriptKept[mid].occurredAt < windowStart {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            var coveredByOtherSpeech = false
            for idx in lo..<transcriptKept.count {
                let speech = transcriptKept[idx]
                if speech.occurredAt > windowEnd { break }
                if speech.deviceID != event.deviceID {
                    coveredByOtherSpeech = true
                    break
                }
            }
            if coveredByOtherSpeech { return false }
            let coveredByOtherLeg = legIntervalsByDevice.contains { deviceID, span in
                deviceID != event.deviceID &&
                    span.start <= gapStart.addingTimeInterval(2.0) &&
                    span.end >= gapEnd.addingTimeInterval(-2.0) &&
                    (devicesWithGaplessCoverage.contains(deviceID) ||
                     !(gapIntervalsByDevice[deviceID] ?? []).contains { $0.intersects(DateInterval(start: gapStart, end: gapEnd)) })
            }
            return !coveredByOtherLeg
        }

        return (transcriptKept + healedNonTranscript).sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id < $1.id
        }
    }

    private static func hasMicCoverage(
        deviceID: String,
        at date: Date,
        map: [String: [DateInterval]]
    ) -> Bool {
        guard let intervals = map[deviceID] else { return false }
        return intervals.contains {
            $0.start.addingTimeInterval(-1.5) <= date && date <= $0.end.addingTimeInterval(1.5)
        }
    }

    private static func mergeSameProviderEvent(
        _ lhs: SyncedTranscriptEvent,
        _ rhs: SyncedTranscriptEvent
    ) -> SyncedTranscriptEvent {
        let preferRHS = (rhs.sourceTier, rhs.revisions.count, rhs.text.count, rhs.deviceID) >
            (lhs.sourceTier, lhs.revisions.count, lhs.text.count, lhs.deviceID)
        var winner = preferRHS ? rhs : lhs
        winner.isBookmarked = lhs.isBookmarked || rhs.isBookmarked
        winner.speakerRole = winner.speakerRole ?? (preferRHS ? lhs.speakerRole : rhs.speakerRole)
        var seenRevisions = Set(winner.revisions.map { "\($0.observedAt.syncMilliseconds)|\($0.text)" })
        for revision in (lhs.revisions + rhs.revisions) {
            let key = "\(revision.observedAt.syncMilliseconds)|\(revision.text)"
            if seenRevisions.insert(key).inserted {
                winner.revisions.append(revision)
            }
        }
        winner.revisions.sort { $0.observedAt < $1.observedAt }
        if let latest = winner.revisions.last, winner.revisions.count > 1 {
            winner.text = latest.text
            winner.speaker = latest.author ?? winner.speaker
        }
        return winner
    }

    private static func pickBetterTranscript(
        _ lhs: SyncedTranscriptEvent,
        _ rhs: SyncedTranscriptEvent
    ) -> SyncedTranscriptEvent {
        let preferRHS = (rhs.sourceTier, rhs.text.count, rhs.deviceID) >
            (lhs.sourceTier, lhs.text.count, lhs.deviceID)
        var winner = preferRHS ? rhs : lhs
        winner.isBookmarked = lhs.isBookmarked || rhs.isBookmarked
        winner.speakerRole = winner.speakerRole ?? (preferRHS ? lhs.speakerRole : rhs.speakerRole)
        winner.occurredAt = min(lhs.occurredAt, rhs.occurredAt)
        return winner
    }

    private static func isFuzzyTokenMatch(_ setA: Set<String>, _ setB: Set<String>) -> Bool {
        guard !setA.isEmpty && !setB.isEmpty else { return false }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        let jaccard = union > 0 ? Double(intersection) / Double(union) : 0
        if jaccard >= 0.65 { return true }
        let minCount = min(setA.count, setB.count)
        let containment = minCount > 0 ? Double(intersection) / Double(minCount) : 0
        return minCount >= 3 && containment >= 0.80
    }

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func normalizedSpeaker(_ speaker: String?) -> String {
        guard let speaker else { return "" }
        let clean = speaker.workspaceFolded.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["participant", "speaker", "unknown", "участник", "неизвестный"].contains(clean) {
            return ""
        }
        return clean
    }

    private static func tokens(_ text: String) -> [String] {
        text.workspaceFolded
            .components(separatedBy: nonAlphanumerics)
            .filter { !$0.isEmpty }
    }
}
