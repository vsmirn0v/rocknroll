import Foundation
import XCTest
@testable import ConferenceCore

final class MeetingMeaningfulnessTests: XCTestCase {
    func testEmptyMeetingIsNotMeaningful() {
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(MeetingMeaningfulnessInput()))
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(notePreview: "   \n\t ", outcomeSummary: "   ")
        ))
    }

    func testEmptyOrTestOnlyTranscriptIsNotMeaningful() {
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(transcriptTexts: ["", "   "])
        ))
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(transcriptTexts: ["test 1 2 3", "hello? testing mic"])
        ))
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(transcriptTexts: ["проверка микрофона раз два три"])
        ))
    }

    func testSubstantiveTranscriptWithoutOutcomeIsMeaningful() {
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(transcriptTexts: [
                "Let's deploy the updated backend service on Thursday morning."
            ])
        ))
    }

    func testNoMeaningfulDiscussionSummariesAreNotMeaningful() {
        let nonMeaningfulSummaries = [
            "No meaningful discussion took place during the call.",
            "Nothing was discussed and the transcript was empty.",
            "Содержательного обсуждения не было.",
            "Ничего не обсуждалось, расшифровка пуста.",
            "Only a brief microphone test.",
            "The call consisted of a short audio test only.",
            "Это была только короткая проверка микрофона.",
        ]
        for summary in nonMeaningfulSummaries {
            XCTAssertFalse(
                MeetingContentMeaningfulness.isMeaningful(
                    MeetingMeaningfulnessInput(outcomeSummary: summary)
                ),
                "Expected non-meaningful: \(summary)"
            )
        }
    }

    func testRealEngineeringSummariesMentioningTestingRemainMeaningful() {
        let engineeringSummary = "The team reviewed the audio test plan, assigned hardware validation owners, and agreed on regression criteria."
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(outcomeSummary: engineeringSummary)
        ))
        let longSummaryWithTestAndOnly = String(repeating: "Detailed engineering architecture review. ", count: 7) + "Only the audio test suite needs an extra CI runner."
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(outcomeSummary: longSummaryWithTestAndOnly)
        ))
    }

    func testShortNormalSummariesRemainMeaningful() {
        for summary in ["Summary for One", "Morning occurrence", "Sync check [L1]"] {
            XCTAssertTrue(
                MeetingContentMeaningfulness.isMeaningful(
                    MeetingMeaningfulnessInput(outcomeSummary: summary)
                ),
                "Expected meaningful: \(summary)"
            )
        }
    }

    func testCitationOnlySummaryFallsBackToEmptyOrTranscript() {
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(outcomeSummary: "[L1] [L2]")
        ))
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(
                outcomeSummary: "[L1]",
                transcriptTexts: ["We finalized the migration rollout schedule for next Monday."]
            )
        ))
    }

    func testNotesMakeMeetingMeaningfulEvenWithoutOutcome() {
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(hasNotes: true)
        ))
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(hasNotes: true, notePreview: "- Follow up with Alice")
        ))
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(hasNotes: true, notePreview: "   \n ")
        ))
    }

    func testDecisionsTasksAndOpenQuestionsOverrideTrivialSummary() {
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(outcomeSummary: "No meaningful discussion", decisionsCount: 1)
        ))
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(outcomeSummary: "", tasksCount: 1)
        ))
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(outcomeSummary: "Empty meeting", openQuestionsCount: 1)
        ))
    }

    func testGeneratingAndFailedWithInputRemainMeaningful() {
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(isGeneratingOutcome: true)
        ))
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(hasFailedOutcomeWithInput: true)
        ))
        XCTAssertFalse(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(isGeneratingOutcome: false, hasFailedOutcomeWithInput: false)
        ))
    }

    func testWorkspaceSyncDocumentTranscriptTextsByCanonicalSession() {
        var doc = MeetingWorkspaceSyncDocument(device: "ios-1")
        let canonicalID = UUID()
        let aliasID = UUID()
        let now = Date()
        let v1 = SyncVersion(counter: 1, device: "ios-1")
        let v2 = SyncVersion(counter: 2, device: "ios-1")
        doc.upsertSession(SyncedMeetingSession(
            id: canonicalID,
            occurrenceKey: "k1",
            title: SyncValue("Weekly", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "room-1",
            startedAt: now,
            endedAt: SyncValue(now, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        ))
        doc.upsertSession(SyncedMeetingSession(
            id: aliasID,
            occurrenceKey: "k2",
            canonicalSessionID: SyncValue(canonicalID, version: v2),
            title: SyncValue("Alias", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "room-1",
            startedAt: now,
            endedAt: SyncValue(now, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        ))
        let activeChunk = SyncedTranscriptChunk(
            sessionID: aliasID,
            deviceID: "ios-1",
            chunkIndex: 0,
            sessionStartedAt: now,
            events: [
                SyncedTranscriptEvent(id: "e1", kind: "transcript", occurredAt: now, text: "  Hello team  ", deviceID: "ios-1"),
                SyncedTranscriptEvent(id: "e2", kind: "chat", occurredAt: now, text: "Link shared", deviceID: "ios-1"),
                SyncedTranscriptEvent(id: "e3", kind: "captureGap", occurredAt: now, text: "gap", deviceID: "ios-1"),
                SyncedTranscriptEvent(id: "e4", kind: "transcript", occurredAt: now, text: "   ", deviceID: "ios-1"),
            ]
        )
        let deletedChunk = SyncedTranscriptChunk(
            sessionID: canonicalID,
            deviceID: "mac-1",
            chunkIndex: 0,
            sessionStartedAt: now,
            events: [
                SyncedTranscriptEvent(id: "e5", kind: "transcript", occurredAt: now, text: "Deleted text", deviceID: "mac-1")
            ],
            isDeleted: true
        )
        doc.mergeTranscriptRecords([.chunk(activeChunk), .chunk(deletedChunk)])

        let texts = doc.transcriptTextsByCanonicalSession()
        XCTAssertEqual(texts[canonicalID], ["Hello team", "Link shared"])
        XCTAssertNil(texts[aliasID])
    }

    func testLazyMeaningfulnessSkipsTranscriptEvaluationWhenMetadataDecides() {
        let cases: [MeetingMeaningfulnessInput] = [
            MeetingMeaningfulnessInput(hasNotes: true),
            MeetingMeaningfulnessInput(notePreview: "Follow up on build"),
            MeetingMeaningfulnessInput(outcomeSummary: "Finalized the rollout schedule."),
            MeetingMeaningfulnessInput(outcomeSummary: "No meaningful discussion took place during the call."),
            MeetingMeaningfulnessInput(decisionsCount: 1),
            MeetingMeaningfulnessInput(tasksCount: 1),
            MeetingMeaningfulnessInput(openQuestionsCount: 1),
            MeetingMeaningfulnessInput(isGeneratingOutcome: true),
            MeetingMeaningfulnessInput(hasFailedOutcomeWithInput: true),
        ]

        for input in cases {
            var evaluated = false
            _ = MeetingContentMeaningfulness.isMeaningful(input) {
                evaluated = true
                return AnySequence(["Substantive spoken discussion about deployment."])
            }
            XCTAssertFalse(evaluated, "Metadata should decide meaningfulness without reading transcript: \(input)")
        }
    }

    func testLazyMeaningfulnessStopsEarlyOnLargeTranscriptSequence() {
        var yielded = 0
        let stream = AnySequence<String> {
            AnyIterator {
                guard yielded < 10_000 else { return nil }
                yielded += 1
                return "Engineering deployment discussion item number \(yielded)"
            }
        }
        let meaningful = MeetingContentMeaningfulness.isMeaningful(MeetingMeaningfulnessInput()) {
            stream
        }
        XCTAssertTrue(meaningful)
        XCTAssertLessThanOrEqual(yielded, 2, "Should stop iterating as soon as substantive threshold is reached")
    }

    func testSnapshotsMakeMeetingMeaningfulWithoutNotesOrTranscript() {
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(
            MeetingMeaningfulnessInput(hasSnapshots: true)
        ))
    }
}
