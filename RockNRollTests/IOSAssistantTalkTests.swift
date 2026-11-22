import AVFoundation
import ConferenceCore
import CoreMedia
import CoreVideo
import Network
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
        private(set) var isSharingScreen = false
        var onExternalBoardShareStopped: (() -> Void)?
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

    private func makeSolidBoardCGImage(width: Int = 1440, height: Int = 810) -> CGImage {
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
          <body style="margin:0"><div id="cols" style="width:1440px;height:810px">Sprint Columns</div></body>
        </html>
        """
        await board.loadHTMLForTesting(html)

        XCTAssertEqual(board.webView.configuration.defaultWebpagePreferences.preferredContentMode, .desktop)
        XCTAssertTrue((board.webView.customUserAgent ?? "").contains("Macintosh"))
        XCTAssertEqual(board.webView.bounds.size, CGSize(width: 1440, height: 810))

        let dims = try await board.webView.evaluateJavaScript("[window.innerWidth, window.innerHeight]") as? [NSNumber]
        XCTAssertEqual(dims?.first?.intValue, 1440)
        XCTAssertEqual(dims?.last?.intValue, 810)
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
}
