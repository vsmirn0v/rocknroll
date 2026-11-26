import AVFoundation
import ConferenceCore
import CoreMedia
import CoreVideo
import Network
import SwiftUI
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class IOSAssistantTalkTests: XCTestCase {
    private final class SuiteBox {
        let name: String
        let defaults: UserDefaults

        init() {
            name = "ios.assistant.talk.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private func makeSessionItem(id: UUID = UUID(), title: String, startedAt: Date) -> IOSMeetingSessionItem {
        IOSMeetingSessionItem(
            id: id,
            occurrenceKey: "occ-\(id.uuidString)",
            title: title,
            hasTitleOverride: false,
            invitation: URL(string: "https://meet.example.com/\(id.uuidString)"),
            roomIdentity: "meet.example.com",
            calendarSeriesID: nil,
            externalSeriesID: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1800),
            timeZoneID: "UTC",
            state: "ended",
            legs: [:],
            outcomeClaim: nil,
            obsidianReceipt: nil,
            manualObsidianSaveAt: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
    }

    func testWakeWordMonthlyMeetingCountAutoAnswers() async {
        let suite = SuiteBox()
        let voiceStore = IOSVoiceStore(preferences: suite.defaults)
        voiceStore.autoAuditionVoiceReplies = false

        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true

        let fixedNow = Date(timeIntervalSince1970: 1_760_500_000) // Oct 2025
        let cal = Calendar(identifier: .gregorian)
        let lastMonth = cal.date(byAdding: .month, value: -1, to: fixedNow)!

        let talk = IOSAssistantTalkController(speech: speech, voiceStore: voiceStore)
        talk.now = { fixedNow }
        talk.sessionsProvider = { [self] in
            [
                makeSessionItem(title: "Product Sync", startedAt: fixedNow.addingTimeInterval(-86_400)),
                makeSessionItem(title: "Design Review", startedAt: fixedNow.addingTimeInterval(-172_800)),
                makeSessionItem(title: "Last Month Kickoff", startedAt: lastMonth),
            ]
        }

        speech.onWakeCommand = { command in
            await talk.run(command, source: .voiceWake)
        }

        let outcome = await speech.processTranscriptForTesting("рок, сколько было встреч в этом месяце?", isFinal: true, now: fixedNow)
        XCTAssertEqual(outcome, .triggered(command: "сколько было встреч в этом месяце?"))
        XCTAssertNil(talk.pendingApproval)
        let answer = talk.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(answer.contains("2"), "Expected 2 meetings this month, got: \(answer)")
        XCTAssertTrue(answer.contains("Product Sync"))
        XCTAssertFalse(answer.contains("Last Month Kickoff"))
    }

    func testWakeJoinCurrentMeetingAutoExecutesWhileTypedAsks() async {
        let suite = SuiteBox()
        let voiceStore = IOSVoiceStore(preferences: suite.defaults)
        voiceStore.autoAuditionVoiceReplies = false

        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        let fixedNow = Date(timeIntervalSince1970: 1_760_500_000)
        let ongoingInvite = URL(string: "https://meet.example.com/current-standup")!
        let candidate = JoinableMeetingCandidate(
            id: CurrentMeetingTargetResolver.stableID(namespace: "calendar", key: "standup"),
            title: "Current Standup",
            invitation: ongoingInvite,
            source: .ongoingCalendar,
            start: fixedNow.addingTimeInterval(-300),
            end: fixedNow.addingTimeInterval(1500)
        )

        var joinedCandidates: [JoinableMeetingCandidate] = []
        let talk = IOSAssistantTalkController(speech: speech, voiceStore: voiceStore)
        talk.now = { fixedNow }
        talk.joinableTargets = { _ in [candidate] }
        talk.onJoinCandidate = { item in
            joinedCandidates.append(item)
            return true
        }
        speech.onWakeCommand = { command in
            await talk.run(command, source: .voiceWake)
        }

        // Typed join requires explicit confirmation
        await talk.run("join current meeting", source: .typed)
        XCTAssertEqual(talk.pendingApproval?.kind, .join)
        XCTAssertTrue(joinedCandidates.isEmpty)
        talk.cancelPendingApproval()
        XCTAssertNil(talk.pendingApproval)

        // Voice wake join executes immediately
        _ = await speech.processTranscriptForTesting("рок, подключи меня к текущей встрече", isFinal: true, now: fixedNow)
        XCTAssertNil(talk.pendingApproval)
        XCTAssertEqual(joinedCandidates.map(\.invitation), [ongoingInvite])
    }

    func testVoiceConfirmationPolicyForMuteParticipateChatAndLeave() async {
        let suite = SuiteBox()
        let voiceStore = IOSVoiceStore(preferences: suite.defaults)
        voiceStore.autoAuditionVoiceReplies = false
        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        let assistant = IOSAssistantCoordinator(workspace: nil, preferences: suite.defaults, resolveBridge: { _ in nil })

        let meetingID = UUID()
        assistant.setParticipationOptions(for: meetingID, askBeforeSending: true, output: .chat, goal: "")

        var mutedCalled = false
        var participateObjective: String?
        var sentChat: [String] = []
        var leaveCalled = false

        let talk = IOSAssistantTalkController(assistant: assistant, speech: speech, voiceStore: voiceStore)
        talk.activeMeetingsProvider = {
            [(id: meetingID, title: "Engineering Sync", isUnmuted: true, canSendChat: true, sessionID: nil)]
        }
        talk.onMuteMeeting = { _ in
            mutedCalled = true
            return "Muted"
        }
        talk.onRequestParticipation = { _, goal in
            participateObjective = goal
        }
        talk.onSendChat = { _, text in
            sentChat.append(text)
        }
        talk.onLeaveMeeting = { _ in
            leaveCalled = true
            return true
        }

        // 1. Voice mute & participate execute immediately without approval
        await talk.run("выключи микрофон", source: .voiceWake)
        XCTAssertTrue(mutedCalled)
        XCTAssertNil(talk.pendingApproval)

        await talk.run("перейди в режим участия с контекстом согласовать релиз", source: .voiceWake)
        XCTAssertEqual(participateObjective, "согласовать релиз")
        XCTAssertNil(talk.pendingApproval)

        // 2. Voice chat asks before sending when askBeforeSending == true
        await talk.run("отправь в чат Буду через 5 минут", source: .voiceWake)
        XCTAssertEqual(talk.pendingApproval?.kind, .sendChat)
        XCTAssertTrue(sentChat.isEmpty)
        talk.confirmPendingApproval()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sentChat, ["Буду через 5 минут"])

        // 3. Voice leave always requires confirmation
        await talk.run("покинь встречу", source: .voiceWake)
        XCTAssertEqual(talk.pendingApproval?.kind, .leave)
        XCTAssertFalse(leaveCalled)
        talk.cancelPendingApproval()
        XCTAssertFalse(leaveCalled)
    }

    func testDictationPopulatesAndCancelsCleanly() async {
        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        speech.transcribeOverride = { _ in "Обсудить бюджет Q4" }

        var capturedFinal = ""
        speech.startDictation(
            onPartial: { _ in },
            onFinal: { text in capturedFinal = text }
        )
        XCTAssertEqual(speech.mode, .dictating)

        // Simulate 0.5 s audio burst (~8000 samples) + silence hangover (~12000 zeros) -> VAD emits segment
        let speechBurst = (0..<8_000).map { i in Float(sin(Double(i) * 0.1) * 0.25) }
        let silenceTail = [Float](repeating: 0, count: 16_000)
        await speech.processSampleChunkForTesting(speechBurst + silenceTail)
        XCTAssertEqual(capturedFinal, "Обсудить бюджет Q4")
        XCTAssertEqual(speech.mode, .idle)

        // Manual cancel leaves previous state intact
        speech.startDictation(onPartial: { _ in }, onFinal: { _ in XCTFail("Cancelled dictation must not commit") })
        speech.stopDictation(commit: false)
        XCTAssertEqual(speech.mode, .idle)
    }

    func testVoiceStorePresetPersistenceAndFallbackSynthesis() async throws {
        let suite = SuiteBox()
        let store = IOSVoiceStore(preferences: suite.defaults)
        store.wakeWordEnabled = false
        store.assistantAuditionVoice = .voxPreset(.warmFemale)
        store.autoAuditionVoiceReplies = false
        store.autoAuditionTypedReplies = true

        let reloaded = IOSVoiceStore(preferences: suite.defaults)
        XCTAssertFalse(reloaded.wakeWordEnabled)
        XCTAssertEqual(reloaded.assistantAuditionVoice, .voxPreset(.warmFemale))
        XCTAssertFalse(reloaded.autoAuditionVoiceReplies)
        XCTAssertTrue(reloaded.autoAuditionTypedReplies)

        // Without VoxCPM2 model downloaded on simulator, audition cleanly falls back to iPhone system voice
        do {
            let buffer = try await reloaded.synthesizeAssistantResponse("Проверка голоса ассистента")
            XCTAssertGreaterThan(buffer.frameLength, 0)
        } catch {
            // In bare CI simulator environments without system TTS voices installed, allow system error rather than voxModelNotInstalled
            XCTAssertNotEqual(error as? IOSVoiceSynthesisError, .voxModelNotInstalled)
        }
    }

    func testIOSSkillsControllerSeedsDefaultsAndResolvesPeopleAndPrompts() throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-skills-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let controller = IOSAssistantSkillsController(
            workspace: nil,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.test.\(UUID().uuidString)"),
            customRootURL: tempRoot
        )
        defer { controller.stopWatcher() }

        XCTAssertFalse(controller.skills.isEmpty)
        XCTAssertTrue(controller.skills.contains(where: { $0.id == "scrum-master" }))
        XCTAssertTrue(controller.promptText(for: .basePersona).contains("Rock"))

        _ = try controller.savePrompt(.meetingSummary, content: "# Custom Summary Prompt")
        XCTAssertEqual(
            controller.promptText(for: .meetingSummary).trimmingCharacters(in: .whitespacesAndNewlines),
            "# Custom Summary Prompt"
        )

        _ = try controller.upsertPerson(AssistantPersonEntry(
            displayName: "Anna Petrova",
            aliases: ["Аня", "Anna"],
            jiraUsername: "apetrova",
            jiraAccountID: "acc-99",
            approvedVoiceCommander: true
        ))
        XCTAssertEqual(controller.resolvedOwnerName("Аня"), "Anna Petrova")
        XCTAssertTrue(controller.people.isApprovedSpeaker("Anna", localUserNames: []))
        XCTAssertFalse(controller.people.isApprovedSpeaker("Random Guest", localUserNames: []))
    }

    func testIOSMultiMeetingVoiceJoinWithSkillBinding() async {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-multijoin-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let skills = IOSAssistantSkillsController(
            workspace: nil,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.multijoin.\(UUID().uuidString)"),
            customRootURL: tempRoot
        )
        defer { skills.stopWatcher() }

        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: nil,
            board: nil,
            resolveBridge: { _ in nil }
        )

        let now = Date()
        let daily = JoinableMeetingCandidate(
            id: UUID(),
            title: "Daily Standup",
            invitation: URL(string: "https://meet.example.com/daily")!,
            source: .ongoingCalendar,
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(1800)
        )
        let retro = JoinableMeetingCandidate(
            id: UUID(),
            title: "Sprint Retro",
            invitation: URL(string: "https://meet.example.com/retro")!,
            source: .upcomingCalendar,
            start: now.addingTimeInterval(300),
            end: now.addingTimeInterval(3600)
        )

        var joined: [String] = []
        let talk = IOSAssistantTalkController()
        talk.skills = skills
        talk.facilitator = facilitator
        talk.joinableTargets = { _ in [daily, retro] }
        talk.onJoinCandidate = { candidate in
            joined.append(candidate.title)
            return true
        }

        await talk.run("Рок, подключи меня к Daily Standup и Sprint Retro как Scrum Master", source: .voiceWake)
        XCTAssertEqual(joined, ["Daily Standup", "Sprint Retro"])
        XCTAssertEqual(
            facilitator.pendingSkillByTitleOrURL["https://meet.example.com/daily"],
            "scrum-master"
        )
        XCTAssertEqual(
            facilitator.pendingSkillByTitleOrURL["https://meet.example.com/retro"],
            "scrum-master"
        )
    }

    func testIOSFacilitatorAuthorizationAndEchoSuppression() throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-auth-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let skills = IOSAssistantSkillsController(
            workspace: nil,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.auth.\(UUID().uuidString)"),
            customRootURL: tempRoot
        )
        defer { skills.stopWatcher() }

        _ = try skills.upsertPerson(AssistantPersonEntry(
            displayName: "Lead Dev",
            aliases: ["Lead"],
            approvedVoiceCommander: true
        ))
        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: nil,
            board: nil,
            resolveBridge: { _ in nil }
        )
        let scrumSkill = skills.skills.first(where: { $0.id == "scrum-master" })
        XCTAssertTrue(facilitator.isSpeakerAuthorized(speakerName: "Anyone", isLocalSpeaker: true, skill: scrumSkill, localNames: []))
        XCTAssertTrue(facilitator.isSpeakerAuthorized(speakerName: "Lead", isLocalSpeaker: false, skill: scrumSkill, localNames: []))
        XCTAssertFalse(facilitator.isSpeakerAuthorized(speakerName: "Stranger", isLocalSpeaker: false, skill: scrumSkill, localNames: []))
        XCTAssertTrue(AssistantWakePhraseMatcher.isLikelySelfEcho(
            candidate: "Ready to kick off standup now",
            lastSpoken: "Hi team, ready to kick off standup now.",
            isLocal: false,
            withinEchoWindow: true
        ))
    }

    // MARK: - Facilitator Lifecycle, Audio Tap, Function Calling & Realtime Tools

    private final class MockRealtimeTransport: RealtimeVoiceTransport, @unchecked Sendable {
        actor Storage {
            var connectCount = 0
            var disconnectCount = 0
            var lastConfig: RealtimeSessionConfig?
            var sentTexts: [String] = []
            var audioChunks: [Data] = []
            var toolResults: [(callID: String, name: String, json: String)] = []

            func recordConnect(_ config: RealtimeSessionConfig) {
                connectCount += 1
                lastConfig = config
            }
            func recordAudio(_ data: Data) { audioChunks.append(data) }
            func recordText(_ text: String) { sentTexts.append(text) }
            func recordToolResult(_ callID: String, _ name: String, _ json: String) {
                toolResults.append((callID, name, json))
            }
            func recordDisconnect() { disconnectCount += 1 }
        }

        let events: AsyncStream<RealtimeVoiceEvent>
        private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
        let storage = Storage()
        var onTextTurn: ((String, AsyncStream<RealtimeVoiceEvent>.Continuation) -> Void)?

        init() {
            var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
            self.events = AsyncStream { cont = $0 }
            self.continuation = cont
        }

        func connect(config: RealtimeSessionConfig) async throws {
            await storage.recordConnect(config)
            continuation.yield(.connected)
        }

        func sendAudioPCM16(_ data: Data) async throws {
            await storage.recordAudio(data)
        }

        func sendTextTurn(_ text: String) async throws {
            await storage.recordText(text)
            onTextTurn?(text, continuation)
        }

        func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {
            await storage.recordToolResult(callID, name, jsonOutput)
        }

        func updateInstructions(_ instructions: String) async throws {}

        func emitEventForTesting(_ event: RealtimeVoiceEvent) {
            continuation.yield(event)
        }

        func disconnect() async {
            await storage.recordDisconnect()
            continuation.finish()
        }
    }

    private final class MockLLMURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

        static func makeSession(handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
            Self.handler = handler
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockLLMURLProtocol.self]
            return URLSession(configuration: config)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.handler?(request) ?? (500, Data())
                let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private actor DisabledCalendarReader: CalendarReading {
        func access() -> CalendarAccess { .denied }
        func requestAccess() -> Bool { false }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
            .init(calendars: [], meetings: [])
        }
    }

    private actor NoopOutcomeWriter: PortableOutcomeWriting {
        func generateOutcome(
            title: String, endedAt: Date, events: [SyncedTranscriptEvent],
            notes: String, language: String, configuration: PortableOutcomeConfiguration
        ) async throws -> PortableOutcomeResult {
            .init(summary: "", decisions: [], tasks: [], openQuestions: [])
        }
    }

    @MainActor
    private final class NoopZoneTransport<Record: SyncZoneRecord>: CloudZoneTransporting {
        func connect() async throws -> CloudZoneSession { .init(account: "acc", generation: "g1") }
        func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record> {
            .init(records: [], token: nil)
        }
        func save(_ values: [Record], session: CloudZoneSession) async throws -> [Record] { values }
        func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws {}
        func clear(session: CloudZoneSession) async throws {}
    }

    private func makeTestWorkspace(tempRoot: URL, prefs: UserDefaults) async throws -> (workspace: IOSWorkspaceCoordinator, store: IOSWorkspaceStore) {
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: .ephemeral))
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: DisabledCalendarReader(),
            detector: detector,
            preferences: prefs,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders
        )
        let store = IOSWorkspaceStore(root: tempRoot.appendingPathComponent("ws-db", isDirectory: true))
        try await store.prepare()
        let archiveStore = TranscriptArchiveStore(root: tempRoot.appendingPathComponent("archive", isDirectory: true), preferences: prefs)
        let ws = IOSWorkspaceCoordinator(
            store: store,
            calendar: calendar,
            syncPreferences: RoomSyncCoordinator(
                history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
                name: "Vitalii",
                preferences: prefs,
                storage: RoomSyncCoordinatorTests.Storage(),
                transport: RoomSyncCoordinatorTests.Cloud()
            ),
            preferences: prefs,
            outcomeWriter: NoopOutcomeWriter(),
            archiveStore: archiveStore,
            libraryTransport: AnyCloudZoneTransport(NoopZoneTransport<MeetingLibrarySyncRecord>()),
            transcriptTransport: AnyCloudZoneTransport(NoopZoneTransport<MeetingTranscriptSyncRecord>()),
            scheduleTransport: AnyCloudZoneTransport(NoopZoneTransport<MeetingScheduleSyncRecord>()),
            isNetworkOnline: { false },
            macGraceOverrideSeconds: 0.05,
            scheduleTaskNotification: { _ in },
            cancelTaskNotification: { _ in }
        )
        ws.start()
        return (ws, store)
    }

    func testIOSFacilitatorLifecycleConnectAutoGreetAudioTapAndSessionEndedTeardown() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-lifecycle-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let skills = IOSAssistantSkillsController(
            workspace: nil,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.lifecycle.\(UUID().uuidString)"),
            customRootURL: tempRoot
        )
        defer { skills.stopWatcher() }
        skills.realtimeProvider = .openAIRealtime
        XCTAssertTrue(skills.setRealtimeAPIKey("test-realtime-key", for: .openAIRealtime))
        if var scrum = skills.skills.first(where: { $0.id == "scrum-master" }) {
            scrum.autoGreet = true
            try skills.saveSkill(scrum)
        }

        let cid = UUID()
        var ensuredTranscription = false
        var releasedTranscription = false
        var spokenReplies: [String] = []
        var capturedTap: (@Sendable (String, Data) -> Void)?

        let bridge = IOSAssistantSessionBridge(
            controllerID: cid,
            title: "Daily Standup",
            roomKey: "https://meet.example.com/standup",
            localDisplayName: "Vitalii",
            participantNames: ["Anna"],
            canSendChat: true,
            isMicUnmuted: true,
            isForeground: true,
            ensureTranscription: {},
            ensureFacilitatorTranscription: { ensuredTranscription = true },
            releaseFacilitatorTranscription: { releasedTranscription = true },
            setRealtimeAudioTap: { tap in capturedTap = tap },
            sendChat: { _ in },
            speakVoice: { spokenReplies.append($0) }
        )

        let transport = MockRealtimeTransport()
        transport.onTextTurn = { _, cont in
            cont.yield(.assistantTranscriptDone("Good morning team! Let's start standup."))
            cont.yield(.audioDone)
        }

        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: nil,
            board: nil,
            resolveBridge: { $0 == cid ? bridge : nil }
        )
        facilitator.customRealtimeTransportFactory = { transport }

        facilitator.queuePendingSkill("scrum-master", title: "Daily Standup", invitation: URL(string: "https://meet.example.com/standup"))
        facilitator.sessionConnected(controllerID: cid)

        for _ in 0..<60 where spokenReplies.isEmpty || !facilitator.realtimeActive {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(ensuredTranscription, "Facilitator must start transcription even when Assistant mode is off")
        XCTAssertEqual(facilitator.activeSessionSkills[cid], "scrum-master")
        XCTAssertTrue(facilitator.realtimeActive)
        XCTAssertEqual(spokenReplies.first, "Good morning team! Let's start standup.")
        XCTAssertNotNil(capturedTap, "Live PCM16 tap should be attached when Realtime connects")

        // Local mic PCM16 right after speaking is suppressed by echo cooldown, while remote audio streams live
        let samplePCM = RealtimeVoiceAudio.floatSamplesToPCM16Data([0.1, -0.1, 0.25, -0.25])
        capturedTap?("local", samplePCM)
        try await Task.sleep(for: .milliseconds(50))
        let suppressedLocalAudio = await transport.storage.audioChunks
        XCTAssertTrue(suppressedLocalAudio.isEmpty, "Local mic audio inside post-reply cooldown should be suppressed")

        capturedTap?("remote-anna", samplePCM)
        for _ in 0..<40 where await transport.storage.audioChunks.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let receivedAudio = await transport.storage.audioChunks
        XCTAssertFalse(receivedAudio.isEmpty)

        // End the meeting session and confirm WebSocket and state are torn down
        facilitator.sessionEnded(controllerID: cid)
        for _ in 0..<40 where await transport.storage.disconnectCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(facilitator.activeSessionSkills[cid])
        XCTAssertFalse(facilitator.realtimeActive)
        let disconnects = await transport.storage.disconnectCount
        XCTAssertGreaterThanOrEqual(disconnects, 1)
        XCTAssertFalse(releasedTranscription) // sessionEnded cleans up directly; disable() releases refcount
    }

    func testIOSSkillAutoMatchPriorityOverDefaultSelectionAndRemovePerson() throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-skill-prio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let skills = IOSAssistantSkillsController(
            workspace: nil,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.prio.\(UUID().uuidString)"),
            customRootURL: tempRoot
        )
        defer { skills.stopWatcher() }
        skills.selectedSkillIDs = ["scrum-master"]

        let retroID = UUID()
        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: nil,
            board: nil,
            resolveBridge: { _ in nil }
        )
        facilitator.enable(controllerID: retroID, title: "Sprint Retro", skillID: nil)
        XCTAssertEqual(facilitator.activeSessionSkills[retroID], "retro-and-planning")

        facilitator.enable(controllerID: retroID, title: "Sprint Retro", skillID: "task-manager")
        XCTAssertEqual(facilitator.activeSessionSkills[retroID], "task-manager")

        _ = try skills.upsertPerson(AssistantPersonEntry(id: "p-del", displayName: "Dmitry", jiraUsername: "dmitry"))
        XCTAssertEqual(skills.people.entries.count, 1)
        try skills.removePerson(id: "p-del")
        XCTAssertTrue(skills.people.entries.isEmpty)
    }

    func testIOSStandardLLMFunctionCallingUpdatesTaskArtifactsAndRespectsApproval() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-std-tools-\(UUID().uuidString)", isDirectory: true)

        let (workspace, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)

        let cid = UUID()
        let sid = workspace.beginSession(
            controllerID: cid,
            requestedWorkspaceID: nil,
            title: "Sprint Planning",
            invitation: URL(string: "https://meet.example.com/plan")!,
            roomIdentity: "meet.example.com/plan",
            calendarMeeting: nil,
            engine: .guest
        )
        await workspace.addTask(sessionID: sid, text: "Prepare release notes", owner: "Vitalii", dueDay: nil, reminderAt: nil)

        workspace.outcomeConfig = PortableOutcomeConfiguration(
            providerKind: .custom,
            baseURL: "https://mock.local/v1",
            model: "test-model"
        )
        workspace.setRemoteAIConsent(true)

        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.stdtools.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        _ = try skills.upsertPerson(AssistantPersonEntry(
            displayName: "Anna Petrova",
            aliases: ["Аня"],
            jiraUsername: "apetrova",
            approvedVoiceCommander: true
        ))

        var turnStep = 0
        let mockSession = MockLLMURLProtocol.makeSession { _ in
            turnStep += 1
            if turnStep == 1 {
                let payload: [String: Any] = [
                    "choices": [[
                        "message": [
                            "role": "assistant",
                            "tool_calls": [
                                [
                                    "id": "tc-1",
                                    "type": "function",
                                    "function": [
                                        "name": "rocknroll_update_task",
                                        "arguments": "{\"query\":\"Prepare release notes\",\"done\":true,\"owner\":\"Аня\"}"
                                    ]
                                ],
                                [
                                    "id": "tc-2",
                                    "type": "function",
                                    "function": [
                                        "name": "rocknroll_update_meeting_artifacts",
                                        "arguments": "{\"summary_append\":\"Agreed on Friday release.\",\"decisions\":[\"Ship v2.1\"],\"action_items\":[{\"text\":\"Verify staging builds\",\"owner\":\"Аня\"}]}"
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
                return (200, try JSONSerialization.data(withJSONObject: payload))
            }
            let finalPayload: [String: Any] = [
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "content": "Updated the release notes task and added the action item for Anna."
                    ]
                ]]
            ]
            return (200, try JSONSerialization.data(withJSONObject: finalPayload))
        }

        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: workspace,
            board: nil,
            resolveBridge: { _ in nil }
        )
        facilitator.llmURLSession = mockSession

        // Approved speaker: standard turn executes tool calls and mutates workspace tasks + outcomes
        let reply = await facilitator.executeStandardTurn(
            controllerID: cid,
            title: "Sprint Planning",
            skillID: "retro-and-planning",
            speakerName: "Anna Petrova",
            allowWrites: true,
            commandText: "Mark release notes done and assign staging check to Anya"
        )
        XCTAssertTrue(reply.contains("Updated the release notes task"))

        let updatedTask = try XCTUnwrap(workspace.tasks.first(where: { $0.text == "Prepare release notes" }))
        XCTAssertTrue(updatedTask.done)
        XCTAssertEqual(updatedTask.owner, "Anna Petrova")

        let addedAction = try XCTUnwrap(workspace.tasks.first(where: { $0.text == "Verify staging builds" }))
        XCTAssertEqual(addedAction.owner, "Anna Petrova")
        XCTAssertEqual(workspace.outcomesBySession[sid]?.decisions, ["Ship v2.1"])

        // Unapproved speaker: executeSharedTool rejects write mutation
        let blocked = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_update_task",
            argumentsJSON: "{\"query\":\"Verify staging builds\",\"done\":true}",
            sessionID: sid,
            allowWrites: false,
            allowedGroups: [.tasks],
            skills: skills,
            workspace: workspace,
            board: nil
        )
        XCTAssertTrue(blocked.contains("not allowed"))
        XCTAssertFalse(workspace.tasks.first(where: { $0.text == "Verify staging builds" })?.done ?? true)
        await store.close()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testIOSDirectVoiceRealtimeTurnExecutesRegisteredTools() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-direct-rt-\(UUID().uuidString)", isDirectory: true)

        let (workspace, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)

        let cid = UUID()
        let sid = workspace.beginSession(
            controllerID: cid,
            requestedWorkspaceID: nil,
            title: "Weekly Sync",
            invitation: URL(string: "https://meet.example.com/weekly")!,
            roomIdentity: "meet.example.com/weekly",
            calendarMeeting: nil,
            engine: .guest
        )
        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.directrt.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }
        skills.realtimeProvider = .openAIRealtime
        XCTAssertTrue(skills.setRealtimeAPIKey("rt-secret", for: .openAIRealtime))

        let transport = MockRealtimeTransport()
        transport.onTextTurn = { _, cont in
            cont.yield(.toolCall(
                callID: "call-42",
                name: "rocknroll_create_task",
                argumentsJSON: "{\"title\":\"Publish iOS changelog\"}"
            ))
            cont.yield(.assistantTranscriptDone("Created task Publish iOS changelog."))
            cont.yield(.audioDone)
        }

        let talk = IOSAssistantTalkController()
        talk.workspace = workspace
        talk.skills = skills
        talk.targetControllerID = cid
        talk.activeMeetingsProvider = { [(id: cid, title: "Weekly Sync", isUnmuted: false, canSendChat: false, sessionID: sid)] }
        talk.customRealtimeTransportFactory = { transport }
        await talk.run("Помоги задокументировать чейнджлог", source: .voiceWake)

        let toolResults = await transport.storage.toolResults
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.name, "rocknroll_create_task")
        XCTAssertTrue(workspace.tasks.contains(where: { $0.text == "Publish iOS changelog" }))
        XCTAssertEqual(talk.lastVoiceAnswer, "Created task Publish iOS changelog.")
        await store.close()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Desktop Jira Board Rendering & Direct Sharing

    @MainActor
    private final class MockBoardShareSession: IOSBoardShareSession {
        let id: UUID
        let title: String
        var canShareBoard = true
        var isBoardShareSessionAlive = true
        private(set) var isSharingScreen = false
        var onExternalBoardShareStopped: (() -> Void)?
        var onBoardShareInterrupted: (() -> Void)?
        private(set) var startedSamples: [CMSampleBuffer] = []
        private(set) var pushedSamples: [CMSampleBuffer] = []
        private(set) var stopCount = 0

        init(id: UUID = UUID(), title: String = "Sprint Planning") {
            self.id = id
            self.title = title
        }

        func startBoardSharing(initialSample: CMSampleBuffer) async throws {
            isSharingScreen = true
            startedSamples.append(initialSample)
        }

        func pushBoardShareFrame(_ sample: CMSampleBuffer) {
            pushedSamples.append(sample)
        }

        func stopBoardSharing() async {
            isSharingScreen = false
            stopCount += 1
        }
    }

    private final class LoopbackHTTPBoardServer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "ios.board.loopback")
        private var listener: NWListener?
        private let html: String

        init(html: String) {
            self.html = html
        }

        func start() async throws -> UInt16 {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            return try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if !resumed, let port = listener.port?.rawValue {
                            resumed = true
                            continuation.resume(returning: port)
                        }
                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: error)
                        }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.serve(conn)
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener?.cancel()
            listener = nil
        }

        private func serve(_ conn: NWConnection) {
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, _, error in
                guard let self, error == nil else {
                    conn.cancel()
                    return
                }
                let body = Data(self.html.utf8)
                let response =
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: text/html; charset=utf-8\r\n" +
                    "Content-Length: \(body.count)\r\n" +
                    "Connection: close\r\n\r\n"
                var payload = Data(response.utf8)
                payload.append(body)
                conn.send(content: payload, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    private func makeSolidBoardCGImage(width: Int = 1280, height: Int = 720) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        ctx.setFillColor(red: 0.12, green: 0.35, blue: 0.72, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testIOSAssistantBoardUsesDesktopViewportAndUserAgent() async throws {
        let board = IOSAssistantBoardController()
        let html = """
        <!doctype html>
        <html>
          <head><title>Jira Desktop Board</title></head>
          <body style="margin:0"><div id="cols" style="width:1280px;height:720px">Sprint Columns</div></body>
        </html>
        """
        await board.loadHTMLForTesting(html)

        XCTAssertEqual(board.webView.configuration.defaultWebpagePreferences.preferredContentMode, .desktop)
        XCTAssertTrue((board.webView.customUserAgent ?? "").contains("Macintosh"))
        XCTAssertEqual(board.webView.bounds.size, CGSize(width: 1280, height: 720))

        let dims = try await board.webView.evaluateJavaScript("[window.innerWidth, window.innerHeight]") as? [NSNumber]
        XCTAssertEqual(dims?.first?.intValue, 1280)
        XCTAssertEqual(dims?.last?.intValue, 720)
    }

    func testIOSAssistantBoardShares1080pDesktopFramesAndHandlesStop() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-board-share-\(UUID().uuidString)", isDirectory: true)
        let (workspace, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)
        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.boardshare.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        let mockSession = MockBoardShareSession(title: "Sprint Planning")
        let board = IOSAssistantBoardController()
        board.resolveShareTarget = { requested in
            (requested == nil || requested == mockSession.id) ? mockSession : nil
        }
        let testImage = makeSolidBoardCGImage()
        board.snapshotOverrideForTesting = { testImage }
        await board.loadHTMLForTesting("<!doctype html><html><body><div>ROCK-101</div></body></html>")

        let shareJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_control_board",
            argumentsJSON: "{\"command\":\"share_to_meeting\"}",
            sessionID: nil,
            controllerID: mockSession.id,
            allowWrites: true,
            allowedGroups: [.boardShare],
            skills: skills,
            workspace: workspace,
            board: board
        )
        let shareObj = try JSONSerialization.jsonObject(with: Data(shareJSON.utf8)) as? [String: Any]
        XCTAssertEqual(shareObj?["sharing"] as? Bool, true)
        XCTAssertTrue(board.isSharing)
        XCTAssertEqual(board.sharingSessionID, mockSession.id)
        XCTAssertEqual(board.sharingMeetingTitle, "Sprint Planning")
        XCTAssertEqual(mockSession.startedSamples.count, 1)

        let firstPixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(mockSession.startedSamples[0]))
        XCTAssertEqual(CVPixelBufferGetWidth(firstPixels), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(firstPixels), 1080)

        board.markBoardDirty()
        for _ in 0..<25 where mockSession.pushedSamples.isEmpty {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(mockSession.pushedSamples.isEmpty)
        let pushedPixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(mockSession.pushedSamples[0]))
        XCTAssertEqual(CVPixelBufferGetWidth(pushedPixels), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(pushedPixels), 1080)

        // External stop from the active call clears board sharing state without loop
        mockSession.onExternalBoardShareStopped?()
        XCTAssertFalse(board.isSharing)
        XCTAssertNil(board.sharingSessionID)

        // Re-share and verify explicit stop_share tool stops the session cleanly
        _ = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_control_board",
            argumentsJSON: "{\"command\":\"share_to_meeting\"}",
            sessionID: nil,
            controllerID: mockSession.id,
            allowWrites: true,
            allowedGroups: [.boardShare],
            skills: skills,
            workspace: workspace,
            board: board
        )
        XCTAssertTrue(board.isSharing)

        let stopJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_control_board",
            argumentsJSON: "{\"command\":\"stop_share\"}",
            sessionID: nil,
            controllerID: mockSession.id,
            allowWrites: true,
            allowedGroups: [.boardShare],
            skills: skills,
            workspace: workspace,
            board: board
        )
        let stopObj = try JSONSerialization.jsonObject(with: Data(stopJSON.utf8)) as? [String: Any]
        XCTAssertEqual(stopObj?["sharing"] as? Bool, false)
        XCTAssertFalse(board.isSharing)
        for _ in 0..<20 where mockSession.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(mockSession.stopCount, 1)

        await store.close()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testIOSFacilitatorDeterministicVoiceSharesJiraBoard() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-voice-board-share-\(UUID().uuidString)", isDirectory: true)
        let (workspace, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)
        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.voiceboard.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        let server = LoopbackHTTPBoardServer(
            html: "<!doctype html><html><head><title>Standup Board</title></head><body><div>ROCK-42</div></body></html>"
        )
        let port = try await server.start()
        defer { server.stop() }
        let boardURL = "http://127.0.0.1:\(port)/boards/42"
        var teamDoc = skills.teamContext
        teamDoc.defaultJiraBoardURL = boardURL
        try skills.saveTeamContext(teamDoc)

        let mockSession = MockBoardShareSession(title: "Daily Standup")
        let board = IOSAssistantBoardController()
        board.defaultBoardURLProvider = { skills.teamContext.defaultJiraBoardURL }
        board.resolveShareTarget = { requested in
            (requested == nil || requested == mockSession.id) ? mockSession : nil
        }
        let testImage = makeSolidBoardCGImage()
        board.snapshotOverrideForTesting = { testImage }

        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: workspace,
            board: board,
            resolveBridge: { _ in nil }
        )

        let replyRU = await facilitator.executeStandardTurn(
            controllerID: mockSession.id,
            title: "Daily Standup",
            skillID: "scrum-master",
            speakerName: "Vitalii",
            allowWrites: true,
            commandText: "Расшарь доску Jira"
        )
        XCTAssertTrue(replyRU.contains("Daily Standup"))
        XCTAssertTrue(board.isSharing)
        XCTAssertEqual(board.currentURL?.absoluteString, boardURL)
        XCTAssertEqual(mockSession.startedSamples.count, 1)

        // Stop and test English deterministic phrase
        let stopReply = await facilitator.executeStandardTurn(
            controllerID: mockSession.id,
            title: "Daily Standup",
            skillID: "scrum-master",
            speakerName: "Vitalii",
            allowWrites: true,
            commandText: "Stop sharing the Jira board"
        )
        XCTAssertTrue(stopReply.contains("Stopped"))
        XCTAssertFalse(board.isSharing)

        let replyEN = await facilitator.executeStandardTurn(
            controllerID: mockSession.id,
            title: "Daily Standup",
            skillID: "scrum-master",
            speakerName: "Vitalii",
            allowWrites: true,
            commandText: "Share the Jira board"
        )
        XCTAssertTrue(replyEN.contains("Daily Standup"))
        XCTAssertTrue(board.isSharing)

        board.stopSharing()
        await store.close()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testIOSAutonomousFacilitatorDefaultsOffForManualDailyJoin() throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-daily-default-off-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let skills = IOSAssistantSkillsController(
            workspace: nil,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.dailyoff.\(UUID().uuidString)"),
            customRootURL: tempRoot
        )
        defer { skills.stopWatcher() }
        XCTAssertFalse(skills.autonomousMeetingVoiceEnabled)

        let manualID = UUID()
        let queuedID = UUID()
        let bridgeFor: (UUID) -> IOSAssistantSessionBridge = { id in
            IOSAssistantSessionBridge(
                controllerID: id,
                title: "CTO Daily",
                roomKey: "https://meet.example.com/cto-daily-\(id.uuidString)",
                localDisplayName: "Vitalii",
                participantNames: [],
                canSendChat: true,
                isMicUnmuted: false,
                isForeground: true,
                ensureTranscription: {},
                sendChat: { _ in },
                speakVoice: { _ in }
            )
        }

        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: nil,
            board: nil,
            resolveBridge: { bridgeFor($0) }
        )

        // Manual join to "CTO Daily" with default settings must NOT auto-engage scrum-master.
        facilitator.sessionConnected(controllerID: manualID)
        facilitator.sessionTitleUpdated(controllerID: manualID, title: "CTO Daily")
        XCTAssertNil(facilitator.activeSessionSkills[manualID])

        // Queued voice-join skill MUST still attach when the meeting connects.
        facilitator.queuePendingSkill("scrum-master", title: "CTO Daily", invitation: URL(string: "https://meet.example.com/cto-daily-\(queuedID.uuidString)"))
        facilitator.sessionConnected(controllerID: queuedID)
        XCTAssertEqual(facilitator.activeSessionSkills[queuedID], "scrum-master")

        // Enabling autonomous facilitator restores title-based matching for new meetings.
        let optInID = UUID()
        skills.autonomousMeetingVoiceEnabled = true
        facilitator.sessionConnected(controllerID: optInID)
        XCTAssertEqual(facilitator.activeSessionSkills[optInID], "scrum-master")
    }

    func testIOSYandexRealtimeTurnExecutesToolAndPassesFolderIDAndSampleRates() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-yandex-rt-\(UUID().uuidString)", isDirectory: true)
        let (workspace, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)

        let cid = UUID()
        let sid = workspace.beginSession(
            controllerID: cid,
            requestedWorkspaceID: nil,
            title: "Yandex Sync",
            invitation: URL(string: "https://meet.example.com/yandex-sync")!,
            roomIdentity: "meet.example.com/yandex-sync",
            calendarMeeting: nil,
            engine: .guest
        )
        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.yandexrt.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }
        skills.realtimeProvider = .yandexRealtime
        skills.realtimeFolderID = "b1g-ios-folder"
        skills.realtimeVoice = "vera"
        skills.realtimeVoiceRole = "support"
        XCTAssertTrue(skills.setRealtimeAPIKey("AQVN-ios-key", for: .yandexRealtime))

        let transport = MockRealtimeTransport()
        transport.onTextTurn = { _, cont in
            let pcm = RealtimeVoiceAudio.floatSamplesToPCM16Data([0.1, -0.1, 0.2, -0.2])
            cont.yield(.toolCall(
                callID: "yc-call-1",
                name: "rocknroll_create_task",
                argumentsJSON: "{\"title\":\"Verify Yandex LiveTTS\"}"
            ))
            cont.yield(.audioPCM16(pcm, sampleRate: 44_100))
            cont.yield(.assistantTranscriptDone("Готово, добавил задачу Verify Yandex LiveTTS."))
            cont.yield(.audioDone)
        }

        let talk = IOSAssistantTalkController()
        talk.workspace = workspace
        talk.skills = skills
        talk.targetControllerID = cid
        talk.activeMeetingsProvider = { [(id: cid, title: "Yandex Sync", isUnmuted: false, canSendChat: false, sessionID: sid)] }
        talk.customRealtimeTransportFactory = { transport }
        await talk.run("Помоги задокументировать чейнджлог Yandex LiveTTS", source: .voiceWake)

        let connectedConfig = await transport.storage.lastConfig
        XCTAssertEqual(connectedConfig?.provider, .yandexRealtime)
        XCTAssertEqual(connectedConfig?.folderID, "b1g-ios-folder")
        XCTAssertEqual(connectedConfig?.model, "speech-realtime-max-tts-live")
        XCTAssertEqual(connectedConfig?.voice, "vera")
        XCTAssertEqual(connectedConfig?.voiceRole, "support")
        XCTAssertEqual(connectedConfig?.inputSampleRate, 24_000)
        XCTAssertEqual(connectedConfig?.outputSampleRate, 44_100)

        let toolResults = await transport.storage.toolResults
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.name, "rocknroll_create_task")
        XCTAssertTrue(workspace.tasks.contains(where: { $0.text == "Verify Yandex LiveTTS" }))
        XCTAssertEqual(talk.lastVoiceAnswer, "Готово, добавил задачу Verify Yandex LiveTTS.")

        await store.close()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testIOSPerMeetingAutoFacilitatorSettingEngagesOnlyForConfiguredMeetingWhenGlobalOff() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-per-meeting-fac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let (workspace, store) = try await makeTestWorkspace(
            tempRoot: tempRoot.appendingPathComponent("ws", isDirectory: true),
            prefs: suite.defaults
        )

        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.permeeting.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }
        XCTAssertFalse(skills.autonomousMeetingVoiceEnabled)

        // Configure per-series auto-join + Scrum Master on one daily, plus a room-level override vs series override.
        await workspace.saveContextSettings(
            scopeKey: "series:cto-daily-ext",
            scopeKind: .calendarSeries,
            title: "CTO Daily",
            sameRoomTransition: nil,
            about: nil,
            matters: nil,
            never: nil,
            people: nil,
            autoJoin: true,
            updateAutoJoin: true,
            autoFacilitatorSkillID: "scrum-master",
            updateAutoFacilitatorSkillID: true
        )
        await workspace.saveContextSettings(
            scopeKey: "room:https://meet.example.com/shared-room",
            scopeKind: .room,
            title: "Shared Room",
            sameRoomTransition: nil,
            about: nil,
            matters: nil,
            never: nil,
            people: nil,
            autoJoin: false,
            updateAutoJoin: true,
            autoFacilitatorSkillID: nil,
            updateAutoFacilitatorSkillID: true
        )

        XCTAssertEqual(
            workspace.autoJoinOverride(
                seriesIDs: ["cto-daily-ext"],
                roomKeys: ["https://meet.example.com/shared-room"]
            ),
            true,
            "Calendar series setting must override room setting for auto-join"
        )
        XCTAssertEqual(
            workspace.autoJoinOverride(
                seriesIDs: ["other-series"],
                roomKeys: ["https://meet.example.com/shared-room"]
            ),
            false
        )
        XCTAssertNil(
            workspace.autoJoinOverride(
                seriesIDs: ["other-series"],
                roomKeys: ["https://meet.example.com/unconfigured"]
            )
        )

        let ctoDailyID = UUID()
        let otherDailyID = UUID()
        let bridges: [UUID: IOSAssistantSessionBridge] = [
            ctoDailyID: IOSAssistantSessionBridge(
                controllerID: ctoDailyID,
                title: "CTO Daily",
                roomKey: "https://meet.example.com/shared-room",
                calendarSeriesKey: "cto-daily-ext",
                localDisplayName: "Vitalii",
                participantNames: [],
                canSendChat: true,
                isMicUnmuted: false,
                isForeground: true,
                ensureTranscription: {},
                sendChat: { _ in },
                speakVoice: { _ in }
            ),
            otherDailyID: IOSAssistantSessionBridge(
                controllerID: otherDailyID,
                title: "Team Daily",
                roomKey: "https://meet.example.com/other-room",
                calendarSeriesKey: "other-series",
                localDisplayName: "Vitalii",
                participantNames: [],
                canSendChat: true,
                isMicUnmuted: false,
                isForeground: true,
                ensureTranscription: {},
                sendChat: { _ in },
                speakVoice: { _ in }
            ),
        ]
        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: workspace,
            board: nil,
            resolveBridge: { bridges[$0] }
        )

        // Unconfigured meeting ("Team Daily") must NOT auto-engage scrum-master.
        facilitator.sessionConnected(controllerID: otherDailyID)
        facilitator.sessionTitleUpdated(controllerID: otherDailyID, title: "Team Daily")
        XCTAssertNil(facilitator.activeSessionSkills[otherDailyID])

        // Opted-in series ("CTO Daily") MUST auto-engage scrum-master even when global autonomousMeetingVoiceEnabled is false.
        facilitator.sessionConnected(controllerID: ctoDailyID)
        XCTAssertEqual(facilitator.activeSessionSkills[ctoDailyID], "scrum-master")

        // Stopping manually must keep it disabled on later title updates in the same session.
        facilitator.disable(controllerID: ctoDailyID)
        facilitator.sessionTitleUpdated(controllerID: ctoDailyID, title: "CTO Daily")
        XCTAssertNil(facilitator.activeSessionSkills[ctoDailyID])

        await store.close()
    }

    func testIOSScrumMasterJiraUserSearchPeopleBindingRealtimeDecollisionAndBoardResilience() async throws {
        actor JiraSpy {
            var queriedJQLs: [String] = []
            func recordJQL(_ jql: String) { queriedJQLs.append(jql) }
        }
        final class MockIOSJiraConnector: JiraTaskConnecting, @unchecked Sendable {
            let spy = JiraSpy()
            func verifyMyself() async throws -> JiraUserContact {
                JiraUserContact(identifier: "scrum.bot", username: "scrum.bot", displayName: "Scrum Bot", isServerOrDC: true)
            }
            func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
                fatalError("unused")
            }
            func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact] { [] }
            func searchUsers(query: String, projectKey: String?, maxResults: Int) async throws -> [JiraUserContact] {
                [JiraUserContact(
                    identifier: "v.smirnov",
                    username: "v.smirnov",
                    displayName: "Vitaliy Smirnov",
                    emailAddress: "v.smirnov@sberdevices.ru",
                    isServerOrDC: true
                )]
            }
            func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue] {
                await spy.recordJQL(jql)
                if jql.contains("Виталий") {
                    throw JiraConnectorError.badRequest("The value 'Виталий Смирнов (СДБ)' does not exist for the field 'assignee'.")
                }
                return [JiraRemoteIssue(
                    id: "42",
                    key: "SDBCTO-42",
                    summary: "Fix board sharing",
                    description: "",
                    statusName: "In Progress",
                    workflowStatus: .inProgress,
                    assigneeName: "Vitaliy Smirnov",
                    assigneeIdentifier: "v.smirnov"
                )]
            }
            func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue { fatalError("unused") }
            func updateIssue(key: String, payload: JiraIssueWritePayload, targetStatus: TaskWorkflowStatus?, comment: String?) async throws -> JiraRemoteIssue { fatalError("unused") }
        }

        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-scrum-jira-people-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let (workspace, store) = try await makeTestWorkspace(
            tempRoot: tempRoot.appendingPathComponent("ws", isDirectory: true),
            prefs: suite.defaults
        )

        let jira = MockIOSJiraConnector()
        workspace.taskSync.jiraConnectorForTesting = jira
        workspace.taskSync.assignableJiraUsers = []
        var syncPrefs = TaskSyncPreferences()
        syncPrefs.jira = JiraConnectionSettings(
            enabled: true,
            baseURL: "https://tasks.sberdevices.ru",
            projectKey: "SDBCTO",
            authMode: .personalAccessToken
        )
        workspace.taskSync.preferences = syncPrefs
        defer {
            workspace.taskSync.jiraConnectorForTesting = nil
            workspace.taskSync.preferences = TaskSyncPreferences()
        }

        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.scrumjira.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        // 1. Direct Jira user search
        let userSearchJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_jira_action",
            argumentsJSON: #"{"operation":"search_users","query":"Виталий Смирнов (СДБ)"}"#,
            sessionID: nil,
            allowWrites: false,
            allowedGroups: [.jira],
            skills: skills,
            workspace: workspace,
            board: nil
        )
        let userSearchObj = try JSONSerialization.jsonObject(with: Data(userSearchJSON.utf8)) as? [String: Any]
        let foundUsers = userSearchObj?["users"] as? [[String: Any]]
        XCTAssertEqual(foundUsers?.first?["username"] as? String, "v.smirnov")

        // 2. Unmapped assignee returns needs_user_confirmation + jira_user_candidates
        let unresolvedJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_jira_action",
            argumentsJSON: #"{"operation":"search","assignee":"Виталий Смирнов (СДБ)"}"#,
            sessionID: nil,
            allowWrites: false,
            allowedGroups: [.jira],
            skills: skills,
            workspace: workspace,
            board: nil
        )
        let unresolvedObj = try JSONSerialization.jsonObject(with: Data(unresolvedJSON.utf8)) as? [String: Any]
        XCTAssertEqual(unresolvedObj?["needs_user_confirmation"] as? Bool, true)
        let candidates = unresolvedObj?["jira_user_candidates"] as? [[String: Any]]
        XCTAssertEqual(candidates?.first?["identifier"] as? String, "v.smirnov")

        // 3. Unapproved speaker can bind meeting alias to People.md without privilege escalation
        let upsertJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_manage_people",
            argumentsJSON: #"{"operation":"upsert","display_name":"Vitaliy Smirnov","aliases":["Виталий Смирнов (СДБ)"],"jira_username":"v.smirnov","approved_voice_commander":true}"#,
            sessionID: nil,
            allowWrites: false,
            allowedGroups: [.tasks, .jira],
            skills: skills,
            workspace: workspace,
            board: nil
        )
        let upsertObj = try JSONSerialization.jsonObject(with: Data(upsertJSON.utf8)) as? [String: Any]
        XCTAssertEqual(upsertObj?["saved"] as? Bool, true)
        XCTAssertEqual(skills.people.resolvePerson(matching: "Виталий Смирнов (СДБ)")?.approvedVoiceCommander, false)

        // 4. Retry Jira issue search now resolves to v.smirnov
        let resolvedSearchJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_jira_action",
            argumentsJSON: #"{"operation":"search","assignee":"Виталий Смирнов (СДБ)"}"#,
            sessionID: nil,
            allowWrites: false,
            allowedGroups: [.jira],
            skills: skills,
            workspace: workspace,
            board: nil
        )
        let resolvedObj = try JSONSerialization.jsonObject(with: Data(resolvedSearchJSON.utf8)) as? [String: Any]
        XCTAssertTrue((resolvedObj?["jql"] as? String)?.contains(#"assignee = "v.smirnov""#) == true)
        let issues = resolvedObj?["issues"] as? [[String: Any]]
        XCTAssertEqual(issues?.first?["key"] as? String, "SDBCTO-42")

        // 5. Board share stays active across transient reconnect while session remains alive
        let mockSession = MockBoardShareSession(title: "CTO Daily")
        let board = IOSAssistantBoardController()
        board.resolveShareTarget = { requested in
            (requested == nil || requested == mockSession.id) ? mockSession : nil
        }
        let testImage = makeSolidBoardCGImage()
        board.snapshotOverrideForTesting = { testImage }
        await board.loadHTMLForTesting("<!doctype html><html><body><div>SDBCTO-42</div></body></html>")
        _ = try await board.startSharing(targetID: mockSession.id)
        XCTAssertTrue(board.isSharing)

        mockSession.canShareBoard = false
        mockSession.isBoardShareSessionAlive = true
        board.markBoardDirty()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(board.isSharing, "Transient reconnect with canShareBoard == false must not stop board sharing")
        XCTAssertEqual(mockSession.stopCount, 0)

        mockSession.isBoardShareSessionAlive = false
        board.markBoardDirty()
        for _ in 0..<80 where board.isSharing {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(board.isSharing)

        // 6. Realtime handleVoiceTurn avoids duplicate sendText during recent audio tap & survives non-fatal .error
        if var scrum = skills.skills.first(where: { $0.id == "scrum-master" }) {
            scrum.autoGreet = false
            try skills.saveSkill(scrum)
        }
        skills.realtimeProvider = .openAIRealtime
        XCTAssertTrue(skills.setRealtimeAPIKey("test-rt-key", for: .openAIRealtime))

        let rtCID = UUID()
        var capturedTap: (@Sendable (String, Data) -> Void)?
        let rtBridge = IOSAssistantSessionBridge(
            controllerID: rtCID,
            title: "CTO Daily",
            roomKey: "https://meet.example.com/cto-daily",
            localDisplayName: "Vitaliy",
            participantNames: ["Anna"],
            canSendChat: true,
            isMicUnmuted: true,
            isForeground: true,
            ensureTranscription: {},
            ensureFacilitatorTranscription: {},
            releaseFacilitatorTranscription: {},
            setRealtimeAudioTap: { capturedTap = $0 },
            sendChat: { _ in },
            speakVoice: { _ in }
        )
        let transport = MockRealtimeTransport()
        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: workspace,
            board: board,
            resolveBridge: { $0 == rtCID ? rtBridge : nil }
        )
        facilitator.customRealtimeTransportFactory = { transport }
        facilitator.enable(controllerID: rtCID, title: "CTO Daily", skillID: "scrum-master")

        for _ in 0..<80 where !facilitator.realtimeActive || capturedTap == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(facilitator.realtimeActive)
        XCTAssertNotNil(capturedTap)

        let samplePCM = RealtimeVoiceAudio.floatSamplesToPCM16Data([0.2, -0.2, 0.15, -0.15])
        capturedTap?("remote-anna", samplePCM)
        try await Task.sleep(for: .milliseconds(120))
        await facilitator.handleVoiceTurn(
            controllerID: rtCID,
            title: "CTO Daily",
            skillID: "scrum-master",
            speakerName: "Anna",
            isLocalSpeaker: false,
            commandText: "Какие задачи на Виталии?"
        )
        let sentTexts = await transport.storage.sentTexts
        XCTAssertTrue(sentTexts.isEmpty, "handleVoiceTurn must skip sendText when Realtime server_vad already received audio")

        transport.emitEventForTesting(.error("Conversation already has an active response"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(facilitator.realtimeActive, "Non-fatal Realtime .error must preserve active session")

        facilitator.sessionEnded(controllerID: rtCID)
        for _ in 0..<40 where facilitator.realtimeActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.close()
    }

    func testIOSScrumMasterRollingTranscriptBusyQueueBoardShareAutoRecoveryAndScopedJira() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-scrum-fixes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let (workspace, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)
        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.scrumfixes.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        // 1. Multi-project JQL scoping & per-meeting Jira config vs app default inheritance.
        XCTAssertEqual(
            skills.resolvedJiraJQL(rawJQL: nil, query: "поддержке", projectKeys: ["SDBPROD", "SPS"]),
            "project in (\"SDBPROD\", \"SPS\") AND text ~ \"поддержке\" ORDER BY updated DESC"
        )
        let customRoomID = UUID()
        let customSID = workspace.beginSession(
            controllerID: customRoomID,
            requestedWorkspaceID: nil,
            title: "CTO Daily",
            invitation: URL(string: "https://meet.example.com/cto-daily")!,
            roomIdentity: "meet.example.com/cto-daily",
            calendarMeeting: nil,
            engine: .guest
        )
        await workspace.saveContextSettings(
            scopeKey: "room:meet.example.com/cto-daily",
            scopeKind: .room,
            title: "CTO Daily",
            sameRoomTransition: nil,
            about: nil,
            matters: nil,
            never: nil,
            people: nil,
            jiraBoardURL: "https://jira.example.com/secure/RapidBoard.jspa?rapidView=99",
            updateJiraBoardURL: true,
            jiraProjectKeys: ["SDBCTO", "SPS"],
            updateJiraProjectKeys: true
        )
        let scoped = workspace.resolvedJiraBoardConfig(
            for: customSID,
            defaultBoardURL: "https://jira.example.com/default",
            defaultProjectKey: "DEF",
            lastBoardURL: "",
            jiraSettings: .init()
        )
        XCTAssertEqual(scoped.boardURL?.absoluteString, "https://jira.example.com/secure/RapidBoard.jspa?rapidView=99")
        XCTAssertEqual(scoped.projectKeys, ["SDBCTO", "SPS"])

        let inherited = workspace.resolvedJiraBoardConfig(
            for: nil,
            defaultBoardURL: "https://jira.example.com/default",
            defaultProjectKey: "DEF",
            lastBoardURL: "",
            jiraSettings: .init()
        )
        XCTAssertEqual(inherited.boardURL?.absoluteString, "https://jira.example.com/default")
        XCTAssertEqual(inherited.projectKeys, ["DEF"])

        var jiraPrefFallback = JiraConnectionSettings()
        jiraPrefFallback.baseURL = "https://jira-host.example.com"
        let dashboardFallback = workspace.resolvedJiraBoardConfig(
            for: nil,
            defaultBoardURL: "",
            defaultProjectKey: "",
            lastBoardURL: "",
            jiraSettings: jiraPrefFallback
        )
        XCTAssertEqual(dashboardFallback.boardURL?.absoluteString, "https://jira-host.example.com")

        // 2. Board share auto-recovery after unexpected interruption while session stays alive,
        // plus deterministic quick filter & clear filter commands.
        let mockSession = MockBoardShareSession(title: "CTO Daily")
        let board = IOSAssistantBoardController()
        board.resolveShareTarget = { requested in
            (requested == nil || requested == mockSession.id) ? mockSession : nil
        }
        let testImage = makeSolidBoardCGImage()
        board.snapshotOverrideForTesting = { testImage }
        await board.loadHTMLForTesting("<!doctype html><html><body><button>Виталий</button><button>Clear all filters</button></body></html>")

        _ = try await board.startSharing(targetID: mockSession.id)
        XCTAssertTrue(board.isSharing)
        XCTAssertEqual(mockSession.startedSamples.count, 1)

        mockSession.canShareBoard = false
        mockSession.isBoardShareSessionAlive = true
        mockSession.onBoardShareInterrupted?()
        XCTAssertTrue(board.isRecoveringShare)
        XCTAssertFalse(board.isSharing)

        mockSession.canShareBoard = true
        for _ in 0..<40 where !board.isSharing {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(board.isSharing, "Board share must automatically restart once peer share capability recovers")
        XCTAssertFalse(board.isRecoveringShare)
        XCTAssertGreaterThanOrEqual(mockSession.startedSamples.count, 2)

        // Healthy connected session: remote screen-share takeover stops board share WITHOUT auto-recovery.
        _ = try await board.startSharing(targetID: mockSession.id)
        XCTAssertTrue(board.isSharing)
        mockSession.onExternalBoardShareStopped?()
        XCTAssertFalse(board.isSharing)
        XCTAssertFalse(board.isRecoveringShare, "Healthy remote share takeover must not enter recovery mode")

        let truncatedQuery = IOSAutonomousMeetingFacilitator.extractPersonFilterQuery(
            from: "Там у тебя квикфильт Виталий",
            lower: "там у тебя квикфильт виталий"
        )
        XCTAssertEqual(truncatedQuery, "Виталий")
        let conjunctionQuery = IOSAutonomousMeetingFacilitator.extractPersonFilterQuery(
            from: "На доске фильтр по имени Виталий и ты увидишь",
            lower: "на доске фильтр по имени виталий и ты увидишь"
        )
        XCTAssertEqual(conjunctionQuery, "Виталий")

        let filterReply = await IOSAutonomousMeetingFacilitator.handleDeterministicBoardCommand(
            "На доске квикфильтр Виталий",
            board: board,
            defaultBoardURL: scoped.boardURL?.absoluteString ?? "",
            targetID: mockSession.id,
            people: skills.people
        )
        XCTAssertNotNil(filterReply)
        board.stopSharing()

        // 3. Busy-turn transcript queue drain & duplicate coordinator suppression when facilitator is active.
        if var scrum = skills.skills.first(where: { $0.id == "scrum-master" }) {
            scrum.autoGreet = false
            try skills.saveSkill(scrum)
        }
        skills.realtimeProvider = .openAIRealtime
        XCTAssertTrue(skills.setRealtimeAPIKey("test-rt-key", for: .openAIRealtime))

        let cid = UUID()
        let bridge = IOSAssistantSessionBridge(
            controllerID: cid,
            title: "CTO Daily",
            roomKey: "https://meet.example.com/cto-daily",
            localDisplayName: "Vitalii",
            participantNames: ["Anna"],
            canSendChat: true,
            isMicUnmuted: true,
            isForeground: true,
            ensureTranscription: {},
            ensureFacilitatorTranscription: {},
            releaseFacilitatorTranscription: {},
            sendChat: { _ in },
            speakVoice: { _ in }
        )

        let transport = MockRealtimeTransport()
        transport.onTextTurn = { text, cont in
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                cont.yield(.assistantTranscriptDone("Ответ на: \(text)"))
                cont.yield(.audioDone)
            }
        }
        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: workspace,
            board: board,
            resolveBridge: { $0 == cid ? bridge : nil }
        )
        facilitator.wakeCoalesceDelay = .zero
        facilitator.followUpCoalesceDelay = .zero
        facilitator.customRealtimeTransportFactory = { transport }
        facilitator.enable(controllerID: cid, title: "CTO Daily", skillID: "scrum-master", suppressAutoGreet: true)

        for _ in 0..<80 where !facilitator.realtimeActive {
            try await Task.sleep(for: .milliseconds(25))
        }

        struct NoEvalWhenFacilitatorActive: IOSAssistantEvaluating {
            func evaluate(_ request: IOSAssistantEvaluationRequest) async throws -> IOSAssistantVerdict {
                XCTFail("IOSAssistantCoordinator must not evaluate duplicates while facilitator owns session")
                return .quiet
            }
        }
        let coordinator = IOSAssistantCoordinator(
            workspace: workspace,
            preferences: suite.defaults,
            evaluator: NoEvalWhenFacilitatorActive(),
            modelAvailable: { true },
            evaluationCooldown: 0,
            mentionCooldown: 0,
            resolveBridge: { $0 == cid ? bridge : nil }
        )
        coordinator.setMode(.participating, for: cid)
        coordinator.isFacilitatorActive = { id in facilitator.activeSessionSkills[id] != nil }
        coordinator.onTranscriptEvents = { id, title, invitation, events, localNames in
            facilitator.observeEvents(
                controllerID: id,
                title: title,
                invitationURL: invitation,
                events: events,
                localNames: localNames
            )
        }

        let t0 = Date()
        coordinator.observeEvents([
            SyncedTranscriptEvent(
                id: "ev-1",
                kind: "transcript",
                occurredAt: t0,
                speaker: "Vitalii",
                isOwn: true,
                speakerRole: AssistantSpeechLedger.speakerRoleUser,
                text: "Рок, найди задачу по поддержке",
                deviceID: "ios-1"
            )
        ], for: cid)

        for _ in 0..<60 where await transport.storage.sentTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Send second utterance WHILE turn 1 is still in flight (~140ms): must queue and drain after audioDone!
        coordinator.observeEvents([
            SyncedTranscriptEvent(
                id: "ev-2",
                kind: "transcript",
                occurredAt: t0.addingTimeInterval(0.03),
                speaker: "Vitalii",
                isOwn: true,
                speakerRole: AssistantSpeechLedger.speakerRoleUser,
                text: "Рок, и фильтр на Виталия",
                deviceID: "ios-1"
            )
        ], for: cid)

        for _ in 0..<120 where await transport.storage.sentTexts.count < 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let sent = await transport.storage.sentTexts
        XCTAssertEqual(sent.count, 2, "Utterance spoken while busy must not be dropped")
        XCTAssertTrue(sent[0].contains("поддержке"))
        XCTAssertTrue(sent[1].contains("фильтр на Виталия"))

        facilitator.sessionEnded(controllerID: cid)
        for _ in 0..<40 where facilitator.realtimeActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.close()
    }

    func testIOSMultiParticipantImperfectDailyStandupEdgeCases() async throws {
        final class MockJiraConnectorForStandup: JiraTaskConnecting, @unchecked Sendable {
            private let lock = NSLock()
            private var created: [JiraIssueWritePayload] = []

            func recordedPayloads() -> [JiraIssueWritePayload] {
                lock.lock()
                defer { lock.unlock() }
                return created
            }

            func verifyMyself() async throws -> JiraUserContact {
                JiraUserContact(identifier: "v.smirnov", username: "v.smirnov", displayName: "Vitalii", isServerOrDC: true)
            }

            func fetchProjectMetadata(projectKey: String) async throws -> JiraProjectMetadata {
                let data = Data("{\"key\":\"\(projectKey)\",\"name\":\"\(projectKey)\",\"issueTypes\":[\"Task\"]}".utf8)
                return try JSONDecoder().decode(JiraProjectMetadata.self, from: data)
            }

            func fetchAssignableUsers(projectKey: String, query: String) async throws -> [JiraUserContact] { [] }
            func searchIssues(jql: String, maxResults: Int) async throws -> [JiraRemoteIssue] { [] }

            func createIssue(_ payload: JiraIssueWritePayload) async throws -> JiraRemoteIssue {
                lock.lock()
                created.append(payload)
                let num = 200 + created.count
                lock.unlock()
                return JiraRemoteIssue(
                    id: "\(num)",
                    key: "\(payload.projectKey)-\(num)",
                    summary: payload.summary,
                    description: payload.description,
                    statusName: "To Do",
                    workflowStatus: .todo,
                    issueTypeName: "Task",
                    issueKind: .task
                )
            }

            func updateIssue(
                key: String,
                payload: JiraIssueWritePayload,
                targetStatus: TaskWorkflowStatus?,
                comment: String?
            ) async throws -> JiraRemoteIssue {
                JiraRemoteIssue(
                    id: key,
                    key: key,
                    summary: payload.summary,
                    description: payload.description,
                    statusName: "In Progress",
                    workflowStatus: .inProgress
                )
            }
        }

        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-imperfect-standup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let (workspace, store) = try await makeTestWorkspace(
            tempRoot: tempRoot.appendingPathComponent("ws", isDirectory: true),
            prefs: suite.defaults
        )

        let jiraConnector = MockJiraConnectorForStandup()
        workspace.taskSync.jiraConnectorForTesting = jiraConnector
        defer { workspace.taskSync.jiraConnectorForTesting = nil }
        var taskPrefs = TaskSyncPreferences()
        taskPrefs.jira = JiraConnectionSettings(
            enabled: true,
            baseURL: "https://tasks.sberdevices.ru/jira",
            projectKey: "",
            authMode: .personalAccessToken
        )
        workspace.taskSync.preferences = taskPrefs

        let skills = IOSAssistantSkillsController(
            workspace: workspace,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.standup.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        // Save 2 approved participants (Vitalii local lead + Anna teammate); Guest Bob is unapproved.
        try skills.upsertPerson(AssistantPersonEntry(
            id: "vitalii",
            displayName: "Виталий Смирнов",
            aliases: ["Виталий", "Vitalii"],
            jiraUsername: "v.smirnov",
            approvedVoiceCommander: true
        ))
        try skills.upsertPerson(AssistantPersonEntry(
            id: "anna",
            displayName: "Анна Иванова",
            aliases: ["Анна", "Аня", "Anna"],
            jiraUsername: "a.ivanova",
            approvedVoiceCommander: true
        ))

        let cid = UUID()
        let inviteURL = URL(string: "https://meet.example.com/cto-daily-\(cid.uuidString)")!
        let sid = workspace.beginSession(
            controllerID: cid,
            requestedWorkspaceID: nil,
            title: "CTO Daily",
            invitation: inviteURL,
            roomIdentity: "meet.example.com/cto-daily",
            calendarMeeting: nil,
            engine: .guest
        )

        // Real WKWebView RapidBoard HTML (with NO ?projectKey= param!) containing #ghx-pool and SDBCTO-101 card.
        let board = IOSAssistantBoardController()
        board.taskSync = workspace.taskSync
        let boardHTML = """
        <!doctype html>
        <html>
          <head><title>CTO Daily Board</title></head>
          <body style="margin:0">
            <div id="ghx-header" style="height:120px">Header</div>
            <div id="ghx-pool" style="height:240px;overflow-y:auto;">
              <div style="height:1000px">
                <div class="ghx-issue" data-issue-key="SDBCTO-101">Поддержка 1</div>
              </div>
            </div>
          </body>
        </html>
        """
        let server = LoopbackHTTPBoardServer(html: boardHTML)
        let port = try await server.start()
        defer { server.stop() }
        let boardURL = "http://127.0.0.1:\(port)/secure/RapidBoard.jspa?rapidView=42"
        _ = try await board.open(urlString: boardURL, presentSheet: false)

        // Verify Presentation Mode CSS + #ghx-pool real scrolling + DOM project key derivation (SDBCTO)
        await board.setPresentationMode(true)
        let hasStyle = try await board.webView.evaluateJavaScript("!!document.getElementById('__rnr-board-presentation-style')") as? Bool
        XCTAssertEqual(hasStyle, true)

        _ = try await board.scroll(deltaY: 320)
        let poolScrollTop = try await board.webView.evaluateJavaScript("document.getElementById('ghx-pool').scrollTop") as? NSNumber
        XCTAssertGreaterThan(poolScrollTop?.doubleValue ?? 0, 0)

        let derivedKeys = await workspace.taskSync.resolveBoardDerivedProjectKeys(forceRefresh: true)
        XCTAssertEqual(derivedKeys, ["SDBCTO"])

        // 1. Task deduplication across rocknroll_create_task + rocknroll_update_meeting_artifacts
        let create1 = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_create_task",
            argumentsJSON: "{\"title\":\"Доработка по итогам CTO Daily\",\"owner\":\"Виталий\"}",
            sessionID: sid,
            controllerID: cid,
            allowWrites: true,
            allowedGroups: [.tasks, .meetingSummary, .jira, .boardShare],
            skills: skills,
            workspace: workspace,
            board: board
        )
        let create2 = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_create_task",
            argumentsJSON: "{\"title\":\"Завести задачу на доработку по итогам CTO Daily\",\"owner\":\"Виталий\"}",
            sessionID: sid,
            controllerID: cid,
            allowWrites: true,
            allowedGroups: [.tasks, .meetingSummary, .jira, .boardShare],
            skills: skills,
            workspace: workspace,
            board: board
        )
        let artResult = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_update_meeting_artifacts",
            argumentsJSON: "{\"summary_append\":\"Обсудили статус\", \"action_items\":[{\"text\":\"Доработка по итогам CTO Daily\",\"owner\":\"Виталий Смирнов\"}]}",
            sessionID: sid,
            controllerID: cid,
            allowWrites: true,
            allowedGroups: [.tasks, .meetingSummary, .jira, .boardShare],
            skills: skills,
            workspace: workspace,
            board: board
        )
        XCTAssertTrue(create1.contains("\"created\":true"))
        XCTAssertTrue(create2.contains("\"already_existed\":true"))
        XCTAssertTrue(artResult.contains("\"action_items_deduplicated\":1"))
        let ctoTasks = workspace.tasks.filter { $0.sessionID == sid && !$0.done }
        XCTAssertEqual(ctoTasks.count, 1, "Duplicate/meta tasks must merge cleanly into 1 open task")

        // 2. Spoken project key resolution ("Sdp ситио" -> "SDBCTO") using derived board key
        let jiraCreateJSON = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_jira_action",
            argumentsJSON: "{\"operation\":\"create\",\"project_key\":\"Sdp ситио\",\"summary\":\"Fix RapidBoard scroll\"}",
            sessionID: sid,
            controllerID: cid,
            allowWrites: true,
            allowedGroups: [.jira, .tasks],
            skills: skills,
            workspace: workspace,
            board: board
        )
        XCTAssertTrue(jiraCreateJSON.contains("SDBCTO-201"), "Got: \(jiraCreateJSON)")
        XCTAssertEqual(jiraConnector.recordedPayloads().last?.projectKey, "SDBCTO")

        // Unapproved guest write block
        let guestCreateBlocked = await IOSAutonomousMeetingFacilitator.executeSharedTool(
            name: "rocknroll_jira_action",
            argumentsJSON: "{\"operation\":\"create\",\"summary\":\"Unauthorized ticket\"}",
            sessionID: sid,
            controllerID: cid,
            allowWrites: false,
            allowedGroups: [.jira, .tasks],
            skills: skills,
            workspace: workspace,
            board: board
        )
        XCTAssertTrue(guestCreateBlocked.contains("\"error\""))

        // 3. Partial ASR deferral + silence wait + barge-in cancellation + post-leave silence
        var connectedFlag = true
        var humanSpeakingFlag = false
        var bargeInCancelCount = 0
        var spokenReplies: [String] = []
        let bridge = IOSAssistantSessionBridge(
            controllerID: cid,
            title: "CTO Daily",
            roomKey: inviteURL.absoluteString,
            localDisplayName: "Виталий Смирнов",
            participantNames: ["Анна Иванова", "Guest Bob"],
            canSendChat: true,
            isMicUnmuted: true,
            isForeground: true,
            isMeetingSoundEnabled: true,
            canDeliverAutomaticReplies: true,
            ensureTranscription: {},
            isConnected: { connectedFlag },
            isHumanSpeaking: { humanSpeakingFlag },
            cancelVoiceReplyForBargeIn: { bargeInCancelCount += 1 },
            sendChat: { _ in },
            speakVoice: { text in
                spokenReplies.append(text)
                try? await Task.sleep(for: .milliseconds(200))
            }
        )

        let transport = MockRealtimeTransport()
        transport.onTextTurn = { text, cont in
            Task {
                try? await Task.sleep(for: .milliseconds(25))
                cont.yield(.assistantTranscriptDone("Начинаем CTO Daily! Принято: \(text)"))
                cont.yield(.audioDone)
            }
        }
        skills.realtimeProvider = .openAIRealtime
        XCTAssertTrue(skills.setRealtimeAPIKey("test-standup-key", for: .openAIRealtime))
        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: workspace,
            board: board,
            resolveBridge: { $0 == cid ? bridge : nil }
        )
        facilitator.wakeCoalesceDelay = .milliseconds(20)
        facilitator.followUpCoalesceDelay = .milliseconds(40)
        facilitator.silencePollInterval = .milliseconds(25)
        facilitator.maxSilenceWaitDuration = .milliseconds(350)
        facilitator.customRealtimeTransportFactory = { transport }
        facilitator.enable(controllerID: cid, title: "CTO Daily", skillID: "scrum-master", suppressAutoGreet: true)
        for _ in 0..<80 where !facilitator.realtimeActive {
            try await Task.sleep(for: .milliseconds(20))
        }

        let coordinator = IOSAssistantCoordinator(
            workspace: workspace,
            preferences: suite.defaults,
            modelAvailable: { false },
            evaluationCooldown: 0,
            mentionCooldown: 0,
            resolveBridge: { $0 == cid ? bridge : nil }
        )
        coordinator.onTranscriptPartialActivity = { id, partialIDs in
            facilitator.updatePartialActivity(controllerID: id, partialEventIDs: partialIDs)
        }
        coordinator.onTranscriptEvents = { id, title, url, events, localNames in
            facilitator.observeEvents(controllerID: id, title: title, invitationURL: url, events: events, localNames: localNames)
        }
        coordinator.isFacilitatorActive = { id in facilitator.activeSessionSkills[id] != nil }

        // While Anna has a partial ASR segment in flight, turn must NOT fire early
        let t0 = Date()
        coordinator.observeEvents([
            SyncedTranscriptEvent(id: "p1", kind: "transcript", occurredAt: t0, speaker: "Анна Иванова", isOwn: false, text: "Рок", deviceID: "mac-1")
        ], for: cid, partialEventIDs: ["p1"])
        try await Task.sleep(for: .milliseconds(80))
        let sentBeforeFinalize = await transport.storage.sentTexts.count
        XCTAssertEqual(sentBeforeFinalize, 0, "Partial ASR in flight must defer turn execution")

        // Finalize Anna's utterance
        coordinator.observeEvents([
            SyncedTranscriptEvent(id: "p1", kind: "transcript", occurredAt: t0, speaker: "Анна Иванова", isOwn: false, text: "Рок, переходи ко мне", deviceID: "mac-1")
        ], for: cid, partialEventIDs: [])
        for _ in 0..<60 where spokenReplies.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(spokenReplies.count, 1)

        // Phonetic garble self-echo shortly after speaking must be ignored
        coordinator.observeEvents([
            SyncedTranscriptEvent(id: "e1", kind: "transcript", occurredAt: t0.addingTimeInterval(0.1), speaker: "Виталий Смирнов", isOwn: true, text: "цито Дели", deviceID: "ios-1")
        ], for: cid, partialEventIDs: [])
        try await Task.sleep(for: .milliseconds(90))
        let countAfterEcho = await transport.storage.sentTexts.count
        XCTAssertEqual(countAfterEcho, 1, "Phonetic echo right after assistant TTS must not re-trigger")

        // Mixed echo + genuine wake command strips echo prefix and preserves command
        let mixedCleaned = AssistantWakePhraseMatcher.stripAssistantEcho(
            from: "Начинаем CTO Daily! Рок, отфильтруй по Анне",
            recentAssistantUtterances: spokenReplies,
            withinEchoWindow: true
        )
        XCTAssertTrue(mixedCleaned.contains("Рок, отфильтруй по Анне"))

        // Human interrupts while assistant starts speaking -> triggers cancelVoiceReplyForBargeIn
        let longSpeakTask = Task {
            await facilitator.speakIntoMeeting("Начинаю длинный пересказ всех задач за прошлый квартал...", controllerID: cid)
        }
        try await Task.sleep(for: .milliseconds(40))
        humanSpeakingFlag = true
        coordinator.observeEvents([
            SyncedTranscriptEvent(id: "b1", kind: "transcript", occurredAt: t0.addingTimeInterval(0.3), speaker: "Виталий Смирнов", isOwn: true, text: "Подожди секунду", deviceID: "ios-1")
        ], for: cid, partialEventIDs: ["b1"])
        XCTAssertGreaterThanOrEqual(bargeInCancelCount, 1, "Human speech during TTS must trigger barge-in cancel")
        _ = await longSpeakTask.value
        humanSpeakingFlag = false

        // Post-leave / disconnect: never speaks or falls back to local audition
        connectedFlag = false
        let repliesBeforeLeave = spokenReplies.count
        await facilitator.speakIntoMeeting("Не должно озвучиваться после выхода", controllerID: cid)
        XCTAssertEqual(spokenReplies.count, repliesBeforeLeave)

        facilitator.sessionEnded(controllerID: cid)
        for _ in 0..<40 where facilitator.realtimeActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.close()
    }

    func testIOSPerMeetingJiraSettingsAndTeamContextPersistAcrossReloadWithoutRevertRace() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-jira-persist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let roomURL = URL(string: "https://meet.example.com/cto-persist")!
        let (ws1, store1) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)
        let sid = ws1.beginSession(
            controllerID: UUID(),
            requestedWorkspaceID: nil,
            title: "CTO Daily",
            invitation: roomURL,
            roomIdentity: "meet.example.com/cto-persist",
            calendarMeeting: nil,
            engine: .guest
        )

        await ws1.saveContextSettings(
            scopeKey: "room:" + roomURL.absoluteString,
            scopeKind: .room,
            title: "CTO Daily",
            sameRoomTransition: nil,
            about: "Daily sync",
            matters: nil,
            never: nil,
            people: nil,
            jiraBoardURL: "jira.internal.ru/secure/RapidBoard.jspa?rapidView=77",
            updateJiraBoardURL: true,
            jiraProjectKeys: ["SDBCTO-42, SPS"],
            updateJiraProjectKeys: true
        )

        let savedConfig = ws1.resolvedJiraBoardConfig(
            for: sid,
            defaultBoardURL: "",
            defaultProjectKey: "",
            jiraSettings: .init()
        )
        XCTAssertEqual(savedConfig.boardURL?.absoluteString, "https://jira.internal.ru/secure/RapidBoard.jspa?rapidView=77")
        XCTAssertEqual(savedConfig.projectKeys, ["SDBCTO", "SPS"])

        // Test TeamContext normalization + no revert race across syncAssistantStateToCloudNow + reloadFromStore
        let skills = IOSAssistantSkillsController(
            workspace: ws1,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.jirapersist.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }
        ws1.assistantSyncInputProvider = { [weak skills] in
            skills?.currentCloudSyncInput() ?? .init(
                people: .init(), teamContext: .init(), skills: [], prompts: [], preferences: .init()
            )
        }
        ws1.onAssistantSettingsSynced = { [weak skills] settings, baseline in
            skills?.applyRemoteCloudSync(settings: settings, previousBaseline: baseline)
        }

        var doc = skills.teamContext
        doc.defaultJiraBoardURL = "boards.internal.ru/boards/5"
        doc.defaultJiraProjectKey = "SDBCTO-9"
        try skills.saveTeamContext(doc)
        ws1.syncAssistantStateToCloudNow()
        await ws1.reloadFromStore()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(skills.teamContext.defaultJiraBoardURL, "https://boards.internal.ru/boards/5")
        XCTAssertEqual(skills.teamContext.defaultJiraProjectKey, "SDBCTO")

        await ws1.flushNotesNow()
        await store1.close()

        // Re-open workspace on the same disk store & replica and confirm per-meeting Jira config survives restart
        let (ws2, store2) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)
        try await ws2.reloadFromStore()
        try await Task.sleep(for: .milliseconds(50))
        let reloadedConfig = ws2.resolvedJiraBoardConfig(
            for: sid,
            defaultBoardURL: "",
            defaultProjectKey: "",
            jiraSettings: .init()
        )
        XCTAssertEqual(reloadedConfig.boardURL?.absoluteString, "https://jira.internal.ru/secure/RapidBoard.jspa?rapidView=77")
        XCTAssertEqual(reloadedConfig.projectKeys, ["SDBCTO", "SPS"])
        await store2.close()
    }

    func testIOSFacilitatorRoleDisplayNameAndRecommendationAndToggleState() async throws {
        let suite = SuiteBox()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-fac-role-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let (ws, store) = try await makeTestWorkspace(tempRoot: tempRoot, prefs: suite.defaults)
        let skills = IOSAssistantSkillsController(
            workspace: ws,
            preferences: suite.defaults,
            keychain: WorkspaceAPIKeychain(service: "dev.vsmirn0v.ios.facrole.\(UUID().uuidString)"),
            customRootURL: tempRoot.appendingPathComponent("skills", isDirectory: true)
        )
        defer { skills.stopWatcher() }

        let facilitator = IOSAutonomousMeetingFacilitator(
            skills: skills,
            workspace: ws,
            board: nil,
            resolveBridge: { _ in nil }
        )
        let assistant = IOSAssistantCoordinator(
            workspace: ws,
            preferences: suite.defaults,
            modelAvailable: { false },
            resolveBridge: { _ in nil }
        )

        XCTAssertEqual(facilitator.recommendedSkillID(for: "Daily Standup"), "scrum-master")
        XCTAssertNil(facilitator.recommendedSkillID(for: "Quarterly Architecture Sync"))
        XCTAssertEqual(facilitator.skillDisplayName(for: "task-manager"), "Task & Backlog Manager")
        XCTAssertEqual(facilitator.skillDisplayName(for: "unknown-slug"), "unknown-slug")

        let cid = UUID()
        let host = UIHostingController(
            rootView: IOSAssistantModeSheet(
                controllerID: cid,
                meetingTitle: "Daily Standup",
                canSendChat: true,
                assistant: assistant,
                skills: skills,
                facilitator: facilitator
            )
        )
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()

        XCTAssertNil(facilitator.activeSessionSkills[cid])
        facilitator.enable(controllerID: cid, title: "Daily Standup", skillID: "task-manager", suppressAutoGreet: true)
        XCTAssertEqual(facilitator.activeSessionSkills[cid], "task-manager")
        XCTAssertEqual(facilitator.skillDisplayName(for: "task-manager"), "Task & Backlog Manager")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        facilitator.disable(controllerID: cid)
        XCTAssertNil(facilitator.activeSessionSkills[cid])
        XCTAssertNil(facilitator.lastStatusBySession[cid])
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        await store.close()
    }

    func testPushToTalkStopBeforeStartTaskCompletesCancelsPendingCapture() async throws {
        let suite = SuiteBox()
        let speech = IOSAssistantSpeechCoordinator()
        speech.isTestingEnvironment = true
        let talk = IOSAssistantTalkController(speech: speech, voiceStore: IOSVoiceStore(preferences: suite.defaults))

        talk.startPushToTalk()
        talk.stopPushToTalk()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(talk.listening, "Cancelling before async capture startup finishes must not leave listening stuck true")
        XCTAssertEqual(speech.mode, .idle)
    }
}
