import Foundation
import XCTest
@testable import ConferenceCore

final class AssistantSpeechLedgerTests: XCTestCase {
    func testClassifyOwnServerSegmentSeparatesPureMixedAndCyrillicUtterances() {
        let ledger = AssistantSpeechLedger()
        let base = Date(timeIntervalSince1970: 1_760_000_000)

        ledger.recordCompletedUtterance(
            id: "a1",
            text: "Доброе утро, команда! Начинаем стендап.",
            startedAt: base,
            endedAt: base.addingTimeInterval(3.0)
        )

        // 1. Pure assistant echo captured as isOwn server ASR.
        let pure = ledger.classifyOwnServerSegment(
            text: "Доброе утро команда начинаем стендап",
            occurredAt: base.addingTimeInterval(3.5),
            now: base.addingTimeInterval(4.0)
        )
        XCTAssertEqual(pure, .pureAssistant(text: "Доброе утро, команда! Начинаем стендап."))

        // 2. Mixed user + assistant overlap: assistant prompt followed by user's continuation.
        let mixedPrefix = ledger.classifyOwnServerSegment(
            text: "Доброе утро команда Начинаем стендап Антон расскажи про релиз",
            occurredAt: base.addingTimeInterval(4.0),
            now: base.addingTimeInterval(4.5)
        )
        guard case .mixed(let userText1, let assistantText1) = mixedPrefix else {
            return XCTFail("Expected .mixed classification for assistant prefix + user suffix, got \(mixedPrefix)")
        }
        XCTAssertEqual(assistantText1, "Доброе утро, команда! Начинаем стендап.")
        XCTAssertTrue(userText1.contains("Антон"), "Expected remaining user text, got: \(userText1)")
        XCTAssertTrue(userText1.contains("релиз"), "Expected remaining user text, got: \(userText1)")

        // 3. Mixed English user statement + interior assistant speech.
        ledger.recordCompletedUtterance(
            id: "a2",
            text: "Checking ticket status on the board.",
            startedAt: base.addingTimeInterval(20.0),
            endedAt: base.addingTimeInterval(22.0)
        )
        let mixedInterior = ledger.classifyOwnServerSegment(
            text: "Wait a second Checking ticket status on the board and also assign it to Ivan",
            occurredAt: base.addingTimeInterval(23.0),
            now: base.addingTimeInterval(23.5)
        )
        guard case .mixed(let userText2, let assistantText2) = mixedInterior else {
            return XCTFail("Expected .mixed classification for user + interior assistant speech, got \(mixedInterior)")
        }
        XCTAssertEqual(assistantText2, "Checking ticket status on the board.")
        XCTAssertTrue(userText2.contains("Wait a second"), "Unexpected user text: \(userText2)")
        XCTAssertTrue(userText2.contains("assign it to Ivan"), "Unexpected user text: \(userText2)")

        // 4. Pure user speech outside overlap window or unrelated text.
        let pureUser = ledger.classifyOwnServerSegment(
            text: "Давайте перенесём демо на четверг.",
            occurredAt: base.addingTimeInterval(25.0),
            now: base.addingTimeInterval(25.5)
        )
        XCTAssertEqual(pureUser, .pureUser(text: "Давайте перенесём демо на четверг."))
    }

    func testTranscriptMergeEngineSeparatesAssistantFromUserAndDeduplicatesSameDeviceMicVsServerOwn() {
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_760_000_000)

        let chunk = SyncedTranscriptChunk(
            sessionID: sessionID,
            deviceID: "iphone-1",
            chunkIndex: 0,
            sessionStartedAt: start,
            events: [
                // Local hardware mic transcript (sourceTier: 1) vs server isOwn transcript (sourceTier: 3):
                SyncedTranscriptEvent(
                    id: "local-1",
                    providerMessageID: nil,
                    kind: "transcript",
                    sourceTier: 1,
                    occurredAt: start.addingTimeInterval(10),
                    speaker: "Vitalii",
                    isOwn: true,
                    speakerRole: AssistantSpeechLedger.speakerRoleUser,
                    text: "Антон, расскажи что вчера сделал",
                    deviceID: "iphone-1"
                ),
                SyncedTranscriptEvent(
                    id: "server-1",
                    providerMessageID: "srv-1",
                    kind: "transcript",
                    sourceTier: 3,
                    occurredAt: start.addingTimeInterval(10.8),
                    speaker: "Vitalii (SDB)",
                    isOwn: true,
                    speakerRole: AssistantSpeechLedger.speakerRoleUser,
                    text: "Антон, расскажи, что вчера сделал по задаче",
                    deviceID: "iphone-1"
                ),
                // Assistant spoken turn 1.5s later on the SAME device: MUST NOT merge into user!
                SyncedTranscriptEvent(
                    id: "asst-1",
                    providerMessageID: nil,
                    kind: "transcript",
                    sourceTier: 1,
                    occurredAt: start.addingTimeInterval(12.0),
                    speaker: AssistantSpeechLedger.canonicalSpeakerName,
                    isOwn: false,
                    speakerRole: AssistantSpeechLedger.speakerRoleAssistant,
                    text: "Антон, расскажи что вчера сделал по задаче",
                    deviceID: "iphone-1"
                ),
            ]
        )

        let merged = TranscriptMergeEngine.merge(chunks: [chunk])
        XCTAssertEqual(merged.count, 2, "Expected user speech (deduped) + separate assistant speech, got \(merged.count)")
        let userEvent = merged.first { !AssistantSpeechLedger.isAssistantSpeaker($0.speaker, role: $0.speakerRole) }
        let assistantEvent = merged.first { AssistantSpeechLedger.isAssistantSpeaker($0.speaker, role: $0.speakerRole) }
        XCTAssertNotNil(userEvent)
        XCTAssertNotNil(assistantEvent)
        XCTAssertEqual(userEvent?.sourceTier, 3, "Higher-tier server user transcript should win over local mic duplicate")
        XCTAssertEqual(userEvent?.speakerRole, AssistantSpeechLedger.speakerRoleUser)
        XCTAssertEqual(assistantEvent?.speaker, AssistantSpeechLedger.canonicalSpeakerName)
        XCTAssertEqual(assistantEvent?.speakerRole, AssistantSpeechLedger.speakerRoleAssistant)
    }

    func testPortableOutcomePromptExplicitlyTagsUserVsAssistant() {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let events = [
            SyncedTranscriptEvent(
                id: "u1",
                kind: "transcript",
                occurredAt: base,
                speaker: "Виталий",
                isOwn: true,
                speakerRole: AssistantSpeechLedger.speakerRoleUser,
                text: "Я закончил миграцию авторизации.",
                deviceID: "mac-1"
            ),
            SyncedTranscriptEvent(
                id: "a1",
                kind: "transcript",
                occurredAt: base.addingTimeInterval(5),
                speaker: AssistantSpeechLedger.canonicalSpeakerName,
                isOwn: false,
                speakerRole: AssistantSpeechLedger.speakerRoleAssistant,
                text: "Хорошо, уточни статус по ROCK-42.",
                deviceID: "mac-1"
            ),
            SyncedTranscriptEvent(
                id: "p1",
                kind: "transcript",
                occurredAt: base.addingTimeInterval(12),
                speaker: "Мария",
                isOwn: false,
                speakerRole: AssistantSpeechLedger.speakerRoleParticipant,
                text: "ROCK-42 на ревью.",
                deviceID: "mac-1"
            ),
        ]

        let messages = PortableOutcomePrompt.messages(
            title: "Standup",
            endedAt: base.addingTimeInterval(60),
            events: events,
            notes: "",
            language: "ru"
        )
        XCTAssertEqual(messages.count, 2)
        let system = messages[0]["content"] ?? ""
        let user = messages[1]["content"] ?? ""
        XCTAssertTrue(system.contains("(the user)"))
        XCTAssertTrue(system.contains("[assistant]"))
        XCTAssertTrue(user.contains("Виталий (the user): Я закончил миграцию авторизации."))
        XCTAssertTrue(user.contains("Rock Assistant [assistant]: Хорошо, уточни статус по ROCK-42."))
        XCTAssertTrue(user.contains("Мария: ROCK-42 на ревью."))
    }

    func testSanitizeSpokenReplyCollapsesDuplicateParagraphsAndStripsBackticks() {
        let duplicated = "С тебя начнём. Коротко: что сделал вчера, что планируешь сегодня и есть ли блокеры?\nС тебя начнём. Коротко: что сделал вчера, что планируешь сегодня и есть ли блокеры?"
        XCTAssertEqual(
            AssistantSpeechLedger.sanitizeSpokenReply(duplicated),
            "С тебя начнём. Коротко: что сделал вчера, что планируешь сегодня и есть ли блокеры?"
        )

        let backticks = "Самые близкие результаты: `SDBPROD-3328`, `SDBPROD-3326`, `SPS-2800`; если скажете точнее **название**, сузим поиск."
        XCTAssertEqual(
            AssistantSpeechLedger.sanitizeSpokenReply(backticks),
            "Самые близкие результаты: SDBPROD-3328, SDBPROD-3326, SPS-2800; если скажете точнее название, сузим поиск."
        )
    }

    func testTranscriptExportFormatterPlainTextMarkdownAndFileName() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let events = [
            SyncedTranscriptEvent(
                id: "1",
                kind: "transcript",
                occurredAt: start,
                speaker: "Vitalii",
                isOwn: true,
                speakerRole: AssistantSpeechLedger.speakerRoleUser,
                text: "Коллеги, начинаем.",
                deviceID: "ios-1"
            ),
            SyncedTranscriptEvent(
                id: "2",
                kind: "transcript",
                occurredAt: start.addingTimeInterval(30),
                speaker: AssistantSpeechLedger.canonicalSpeakerName,
                isOwn: false,
                speakerRole: AssistantSpeechLedger.speakerRoleAssistant,
                text: "Готов вести стендап.",
                deviceID: "ios-1"
            ),
            SyncedTranscriptEvent(
                id: "3",
                kind: "chat",
                occurredAt: start.addingTimeInterval(60),
                speaker: "Anna",
                isOwn: false,
                text: "Ссылка в треде",
                deviceID: "mac-1"
            ),
        ]

        let plain = TranscriptExportFormatter.formatPlainText(
            events: events,
            meetingTitle: "CTO Daily",
            startedAt: start,
            youLabel: "You",
            assistantLabel: "Rock Assistant"
        )
        XCTAssertTrue(plain.contains("CTO Daily"))
        XCTAssertTrue(plain.contains("Vitalii (You): Коллеги, начинаем."))
        XCTAssertTrue(plain.contains("Rock Assistant: Готов вести стендап."))
        XCTAssertTrue(plain.contains("Anna [Chat]: Ссылка в треде") || plain.contains("[Чат]"))

        let md = TranscriptExportFormatter.formatMarkdown(
            events: events,
            title: "CTO Daily",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            youLabel: "You",
            assistantLabel: "Rock Assistant"
        )
        XCTAssertTrue(md.hasPrefix("# CTO Daily"))
        XCTAssertTrue(md.contains("Vitalii (You):** Коллеги, начинаем."))
        XCTAssertTrue(md.contains("Rock Assistant:** Готов вести стендап."))

        let fileName = TranscriptExportFormatter.suggestedFileName(title: "CTO Daily / Sprint 12", startedAt: start, extension: "md")
        XCTAssertTrue(fileName.hasPrefix("2025-10-15-") || fileName.contains(".transcript.md"))
        XCTAssertTrue(fileName.hasSuffix(".transcript.md"))
    }
}
