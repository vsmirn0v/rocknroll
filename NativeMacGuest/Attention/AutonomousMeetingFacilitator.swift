import AVFoundation
import ConferenceCore
import Foundation

/// Runs autonomous in-meeting voice facilitation using Obsidian-backed skills,
/// `People.md` speaker approval (owner is always approved), per-session optional
/// `OpenAI Realtime` / `Gemini Live` WebSocket acceleration with live audio streaming,
/// and automatic local STT -> LLM -> TTS fallback.
@MainActor
final class AutonomousMeetingFacilitator: ObservableObject {
    @Published private(set) var activeSessionSkills: [UUID: String] = [:]
    @Published private(set) var pendingSkillByTitleOrURL: [String: String] = [:]
    @Published private(set) var lastStatusBySession: [UUID: String] = [:]
    @Published private(set) var lastSpokenAnswerBySession: [UUID: String] = [:]
    @Published private(set) var realtimeActive = false

    private final class SessionRealtimeState {
        let router = RealtimeVoiceRouter()
        var connected = false
        var audioChunks: [Data] = []
        var transcriptBuffer = ""
        var lastTurnAllowWrites = false
        var lastApprovedTranscriptAt: Date?
        var lastRemoteAudioAt: Date?
        var activeSkillID: String
        var approvedSpeakersOnly = true
        var turnTimeoutTask: Task<Void, Never>?

        init(activeSkillID: String) {
            self.activeSkillID = activeSkillID
        }
    }

    private weak var attention: AttentionCoordinator?
    private var processedLineIDsBySession: [UUID: Set<String>] = [:]
    private var busySessions: Set<UUID> = []
    private var manuallyDisabledSessions: Set<UUID> = []
    private var lastSpokeAtBySession: [UUID: Date] = [:]
    private var lastVoiceDeliveryEndedAtBySession: [UUID: Date] = [:]
    private var realtimeSessions: [UUID: SessionRealtimeState] = [:]
    private var cachedSkills: [AssistantSkill] = []
    private var lastSkillRefreshAt = Date.distantPast

    init(attention: AttentionCoordinator) {
        self.attention = attention
    }

    func invalidateSkillCache() {
        lastSkillRefreshAt = .distantPast
        Task { @MainActor [weak self] in
            await self?.refreshSkillsCache()
        }
    }

    func queuePendingSkill(_ skillID: String, title: String?, invitation: URL?) {
        let slug = AssistantSkill.sanitizedSlug(from: skillID)
        guard !slug.isEmpty else { return }
        if let title, !title.trimmed.isEmpty {
            pendingSkillByTitleOrURL[title.trimmed.lowercased()] = slug
        }
        if let invitation {
            pendingSkillByTitleOrURL[invitation.absoluteString.lowercased()] = slug
        }
    }

    private func resolveSkillID(explicitSkillID: String?, meetingTitle: String) -> String {
        if let explicit = explicitSkillID.map(AssistantSkill.sanitizedSlug(from:)), !explicit.isEmpty {
            return explicit
        }
        if let autoMatched = cachedSkills.first(where: {
            $0.enabled && $0.matches(meetingTitle: meetingTitle, commandText: "")
        })?.id {
            return autoMatched
        }
        return attention?.store.selectedSkillIDs.first ?? "scrum-master"
    }

    func enable(for model: NativeDesktopMeetingModel, skillID: String? = nil) {
        manuallyDisabledSessions.remove(model.sessionID)
        var chosen = resolveSkillID(explicitSkillID: skillID, meetingTitle: model.title)
        activeSessionSkills[model.sessionID] = chosen
        // Skip pre-existing lines at activation time so Rock responds to new spoken instructions.
        processedLineIDsBySession[model.sessionID] = Set(model.transcript.map(\.id))
        let initialTitle = cachedSkills.first(where: { $0.id == chosen })?.name ?? chosen
        lastStatusBySession[model.sessionID] = L("Autonomous voice facilitator active (%@)", initialTitle)
        Task { @MainActor [weak self, weak model] in
            guard let self, let model, !model.isClosed else { return }
            await self.refreshSkillsCache()
            if skillID == nil {
                chosen = self.resolveSkillID(explicitSkillID: nil, meetingTitle: model.title)
                self.activeSessionSkills[model.sessionID] = chosen
            }
            let skill = self.cachedSkills.first(where: { $0.id == chosen })
            self.lastStatusBySession[model.sessionID] = L("Autonomous voice facilitator active (%@)", skill?.name ?? chosen)
            await self.maybeConnectRealtime(for: model, skill: skill, skillID: chosen)
            if skill?.autoGreet == true {
                await self.kickOffSkill(for: model, skillID: chosen)
            }
        }
    }

    func disable(for sessionID: UUID) {
        manuallyDisabledSessions.insert(sessionID)
        activeSessionSkills.removeValue(forKey: sessionID)
        processedLineIDsBySession.removeValue(forKey: sessionID)
        lastStatusBySession.removeValue(forKey: sessionID)
        lastSpokeAtBySession.removeValue(forKey: sessionID)
        busySessions.remove(sessionID)
        if let model = attention?.meetings().first(where: { $0.sessionID == sessionID }) {
            model.onRealtimeAudioPCM16 = nil
        }
        if let state = realtimeSessions.removeValue(forKey: sessionID) {
            state.turnTimeoutTask?.cancel()
            Task { await state.router.stop() }
        }
        syncRealtimeActiveFlag()
    }

    /// Proactively introduces the bound skill into the meeting (e.g. starting a Daily Standup).
    func kickOffSkill(for model: NativeDesktopMeetingModel, skillID: String? = nil) async {
        guard let attention, !model.isClosed else { return }
        let activeID = skillID ?? activeSessionSkills[model.sessionID] ?? "scrum-master"
        await refreshSkillsCache()
        let skill = cachedSkills.first(where: { $0.id == activeID })
        let prompt = L("Briefly greet the meeting and kick off your role (%@) in 1–2 crisp sentences.", skill?.name ?? activeID)
        await handleVoiceTurn(
            model: model,
            skillID: activeID,
            speakerName: attention.store.profile.name.trimmed.isEmpty ? L("You") : attention.store.profile.name.trimmed,
            isLocalSpeaker: true,
            commandText: prompt
        )
    }

    func processTick(models: [NativeDesktopMeetingModel]) {
        refreshSkillsCacheIfNeeded()

        // 1. Attach queued skills to newly connected meetings (voice join / MCP join).
        for model in models where !model.isClosed && model.connected && activeSessionSkills[model.sessionID] == nil {
            if let queued = pendingSkillByTitleOrURL.removeValue(forKey: model.invitation.absoluteString.lowercased())
                ?? pendingSkillByTitleOrURL.removeValue(forKey: model.title.trimmed.lowercased()) {
                enable(for: model, skillID: queued)
            } else if attention?.store.autonomousMeetingVoiceEnabled == true,
                      !manuallyDisabledSessions.contains(model.sessionID),
                      let matched = cachedSkills.first(where: {
                          $0.enabled && $0.voiceActivation && $0.matches(meetingTitle: model.title, commandText: "")
                      }) {
                enable(for: model, skillID: matched.id)
            }
        }

        // 2. Prune closed meetings.
        let liveIDs = Set(models.filter { !$0.isClosed }.map(\.sessionID))
        for sessionID in Array(activeSessionSkills.keys) where !liveIDs.contains(sessionID) {
            disable(for: sessionID)
            manuallyDisabledSessions.remove(sessionID)
        }
        manuallyDisabledSessions = manuallyDisabledSessions.intersection(liveIDs)

        let now = Date()
        for model in models where !model.isClosed && model.connected {
            guard let skillID = activeSessionSkills[model.sessionID],
                  !busySessions.contains(model.sessionID) else { continue }
            var seen = processedLineIDsBySession[model.sessionID] ?? []
            let unseen = model.transcript.filter { !seen.contains($0.id) }
            guard !unseen.isEmpty else { continue }
            for line in unseen { seen.insert(line.id) }
            processedLineIDsBySession[model.sessionID] = seen

            let inFollowUpWindow = lastSpokeAtBySession[model.sessionID].map { now.timeIntervalSince($0) <= 20 } ?? false
            let inEchoWindow = lastVoiceDeliveryEndedAtBySession[model.sessionID].map { now.timeIntervalSince($0) <= 6 } ?? false
            let lastSpoken = lastSpokenAnswerBySession[model.sessionID]?.trimmed ?? ""

            var matchedLine = unseen.first { _ in false }
            var matchedCommand = ""
            for line in unseen.reversed() {
                let text = line.text.trimmed
                guard !text.isEmpty else { continue }
                if Self.isLikelySelfEcho(candidate: text, lastSpoken: lastSpoken, isLocal: line.isOwn, withinEchoWindow: inEchoWindow) {
                    continue
                }
                if case .command(let cmd) = AssistantWakePhraseMatcher.match(text),
                   !cmd.trimmed.isEmpty {
                    matchedLine = line
                    matchedCommand = cmd.trimmed
                    break
                }
                // Within a 20s active follow-up window, accept direct follow-up utterances from approved/local speakers.
                if inFollowUpWindow && text.count >= 4 {
                    matchedLine = line
                    matchedCommand = text
                    break
                }
            }
            guard let triggerLine = matchedLine, !matchedCommand.isEmpty else { continue }

            busySessions.insert(model.sessionID)
            let commandText = matchedCommand
            Task { @MainActor [weak self, weak model] in
                guard let self, let model else { return }
                await self.handleVoiceTurn(
                    model: model,
                    skillID: skillID,
                    speakerName: triggerLine.participantName,
                    isLocalSpeaker: triggerLine.isOwn,
                    commandText: commandText
                )
            }
        }
    }

    // MARK: - Turn Execution

    private func handleVoiceTurn(
        model: NativeDesktopMeetingModel,
        skillID: String,
        speakerName: String,
        isLocalSpeaker: Bool,
        commandText: String
    ) async {
        guard let attention else {
            busySessions.remove(model.sessionID)
            return
        }
        let localNames = attention.store.profile.aliases + model.participants.filter(\.isLocal).map(\.name)
        let directory = await attention.loadPeopleDirectory()
        let approved = isLocalSpeaker || directory.isApprovedSpeaker(speakerName, localUserNames: localNames)

        let skill = await attention.withSkillRepository { repo, _ in repo.skill(id: skillID) }
        let allowWrites = approved || (skill?.approvedSpeakersOnly == false)
        let allowedGroups: Set<AssistantSkillToolGroup>? = skill.map { Set($0.tools) }

        // If this was a non-wake follow-up from an unapproved speaker, ignore quietly rather than interrupting.
        if !approved, case .none = AssistantWakePhraseMatcher.match(commandText) {
            if let lastSpoke = lastSpokeAtBySession[model.sessionID], Date().timeIntervalSince(lastSpoke) <= 20, !isLocalSpeaker {
                // Only proceed without wake phrase in follow-up window if speaker is approved (or skill allows everyone).
                if skill?.approvedSpeakersOnly != false {
                    busySessions.remove(model.sessionID)
                    return
                }
            }
        }

        // Try Realtime WebSocket acceleration first if connected for this session;
        // falls back immediately to standard agent + local VoiceSynthesis otherwise.
        if let rtState = realtimeSessions[model.sessionID],
           await rtState.router.isRealtimeConnected {
            rtState.lastTurnAllowWrites = allowWrites
            rtState.lastApprovedTranscriptAt = allowWrites ? Date() : nil
            rtState.activeSkillID = skillID
            rtState.approvedSpeakersOnly = skill?.approvedSpeakersOnly ?? true
            rtState.audioChunks.removeAll()
            rtState.transcriptBuffer = ""
            let prefixedPrompt = "[\(speakerName) (approved=\(allowWrites)) in “\(model.title)”]: \(commandText)"
            if await rtState.router.sendText(prefixedPrompt) {
                lastStatusBySession[model.sessionID] = L("Realtime model handling request…")
                rtState.turnTimeoutTask?.cancel()
                let sid = model.sessionID
                rtState.turnTimeoutTask = Task { @MainActor [weak self, weak rtState] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, let rtState, !Task.isCancelled else { return }
                    self.busySessions.remove(sid)
                    if !rtState.transcriptBuffer.trimmed.isEmpty {
                        await self.speakIntoMeeting(rtState.transcriptBuffer.trimmed, model: model)
                        rtState.transcriptBuffer = ""
                    }
                }
                return
            }
        }

        defer { busySessions.remove(model.sessionID) }

        // Standard pipeline fallback (works with local models, cloud chat completions, and Vox/macOS TTS)
        let talk = attention.talk
        talk.targetMeetingID = model.sessionID
        let snapshot = talk.makeAgentSnapshot()
        let hooks = AssistantNativeToolProvider.Hooks(
            executeAction: { [weak talk] action in
                guard allowWrites, let talk else { throw AssistantAgentError.unsupported }
                return try await talk.executeFacilitatorNativeAction(action)
            },
            readNote: { [weak attention] id in await attention?.store.meetingLibrary.note(sessionID: id) }
        )
        let registry = AssistantNativeToolProvider.registry(snapshot: snapshot, hooks: hooks)
        if let external = attention.externalToolProvider {
            await registry.registerMeetingMCPTools(external, includeAdditionalReads: true)
        }
        AssistantSkillToolRegistrar.registerTools(
            into: registry,
            attention: attention,
            talk: talk,
            snapshot: snapshot,
            allowPrivilegedActions: allowWrites,
            allowedToolGroups: allowedGroups
        )
        let context = await AssistantSkillToolRegistrar.enrichedContext(
            base: AssistantNativeToolProvider.context(snapshot: snapshot),
            attention: attention,
            explicitSkillIDs: [skillID],
            meetingTitle: model.title,
            commandText: commandText,
            speakerName: speakerName,
            isApprovedSpeaker: allowWrites
        )

        let environment = AssistantAgentEnvironment(
            registry: registry,
            model: attention.store.provider.agentModel(key: attention.store.apiKey(for: attention.store.provider)),
            context: context,
            approvalPolicy: { _, action in
                if !allowWrites { return .ask }
                if action.kind == .remember { return .allow }
                return AssistantVoiceApprovalPolicy.shouldAutoApprove(
                    actionKind: action.kind.rawValue,
                    inputSource: .voiceWake,
                    sendsWithoutAsking: false
                ) ? .allow : .ask
            },
            actionCoordinator: attention.actionCoordinator,
            approvalTitle: { call, action in AssistantTalkController.agentApprovalTitle(call, action) },
            approvalDetail: { _, action in action.text }
        )

        let runtime = AssistantRuntime()
        let framedPrompt = "\(speakerName) says: \(commandText)\n" +
            (allowWrites
                ? "(Approved speaker. Answer concisely for voice playback in 1-3 sentences after running any needed tools.)"
                : "(Read-only guest speaker. Do not create/update tasks, schedule meetings, or control the board unless an approved member confirms. Answer concisely for voice playback.)")
        let outcome = await runtime.submit(framedPrompt, environment: environment)

        let spokenText: String?
        switch outcome {
        case .success(.completed(let text, _, _)):
            spokenText = text
        case .success(.needsUserInput(let question)):
            spokenText = question
        case .success(.approvalRequired(let approval)):
            lastStatusBySession[model.sessionID] = L("Approval required: %@", approval.title)
            spokenText = nil
        case .failure:
            spokenText = nil
        }

        if let spokenText, !spokenText.trimmed.isEmpty {
            await speakIntoMeeting(spokenText, model: model)
        }
    }

    private func maybeConnectRealtime(for model: NativeDesktopMeetingModel, skill: AssistantSkill?, skillID: String) async {
        guard let attention else { return }
        let kind = attention.store.realtimeProvider
        guard kind != .disabled,
              let apiKey = attention.store.realtimeAPIKey(for: kind),
              !apiKey.isEmpty else {
            syncRealtimeActiveFlag()
            return
        }

        if let old = realtimeSessions.removeValue(forKey: model.sessionID) {
            old.turnTimeoutTask?.cancel()
            await old.router.stop()
        }

        let talk = attention.talk
        let snapshot = talk.makeAgentSnapshot()
        let hooks = AssistantNativeToolProvider.Hooks(
            executeAction: { _ in throw AssistantAgentError.unsupported },
            readNote: { [weak attention] id in await attention?.store.meetingLibrary.note(sessionID: id) }
        )
        let allowedGroups: Set<AssistantSkillToolGroup>? = skill.map { Set($0.tools) }
        let registry = AssistantNativeToolProvider.registry(snapshot: snapshot, hooks: hooks)
        if let external = attention.externalToolProvider {
            await registry.registerMeetingMCPTools(external, includeAdditionalReads: true)
        }
        AssistantSkillToolRegistrar.registerTools(
            into: registry,
            attention: attention,
            talk: talk,
            snapshot: snapshot,
            allowPrivilegedActions: true,
            allowedToolGroups: allowedGroups
        )
        let promptCtx = await AssistantSkillToolRegistrar.enrichedContext(
            base: AssistantNativeToolProvider.context(snapshot: snapshot),
            attention: attention,
            explicitSkillIDs: [skillID],
            meetingTitle: model.title,
            commandText: "",
            speakerName: nil,
            isApprovedSpeaker: true
        )
        let basePersona = promptCtx["obsidian_base_persona"] ?? ""
        let skillsText = promptCtx["obsidian_skills"] ?? "Facilitate the meeting concisely in the user's language."
        let instructions = [basePersona, skillsText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let tools = AssistantSkillToolRegistrar.exportRealtimeTools(from: registry)
        let config = RealtimeSessionConfig(
            provider: kind,
            apiKey: apiKey,
            model: attention.store.realtimeModel,
            voice: attention.store.realtimeVoice,
            endpointOverride: attention.store.realtimeEndpoint,
            systemInstructions: instructions,
            tools: tools
        )

        let state = SessionRealtimeState(activeSkillID: skillID)
        state.approvedSpeakersOnly = skill?.approvedSpeakersOnly ?? true
        realtimeSessions[model.sessionID] = state
        let sessionID = model.sessionID
        await state.router.start(
            config: config,
            executeTool: { [weak self] name, argsJSON in
                guard let self else { return "{}" }
                return await self.executeRealtimeTool(sessionID: sessionID, name: name, argumentsJSON: argsJSON)
            },
            onEvent: { [weak self, weak model, weak state] event in
                guard let self, let state else { return }
                await self.handleRealtimeEvent(event, state: state, model: model)
            }
        )
        state.connected = await state.router.isRealtimeConnected
        if state.connected {
            attachAudioTap(to: model, state: state)
        }
        syncRealtimeActiveFlag()
    }

    private func attachAudioTap(to model: NativeDesktopMeetingModel, state: SessionRealtimeState) {
        let router = state.router
        let sessionID = model.sessionID
        model.onRealtimeAudioPCM16 = { [weak self, weak model, weak state] _, trackID, pcm in
            Task { @MainActor [weak self, weak model, weak state] in
                if trackID == MeetingTranscriber.localTrackID {
                    if model?.isVoiceReplyInFlight == true || self?.isInAudioEchoCooldown(sessionID: sessionID) == true {
                        return
                    }
                    if let state {
                        let recentRemote = state.lastRemoteAudioAt.map { Date().timeIntervalSince($0) <= 3.0 } ?? false
                        if !recentRemote {
                            state.lastTurnAllowWrites = true
                        }
                    }
                } else if let state {
                    state.lastRemoteAudioAt = Date()
                    if state.approvedSpeakersOnly {
                        let recentApprovedTranscript = state.lastApprovedTranscriptAt.map {
                            Date().timeIntervalSince($0) <= 8.0
                        } ?? false
                        if !recentApprovedTranscript {
                            state.lastTurnAllowWrites = false
                        }
                    } else {
                        state.lastTurnAllowWrites = true
                    }
                }
                _ = await router.sendAudioPCM16(pcm)
            }
        }
    }

    private func isInAudioEchoCooldown(sessionID: UUID) -> Bool {
        guard let ended = lastVoiceDeliveryEndedAtBySession[sessionID] else { return false }
        return Date().timeIntervalSince(ended) < 1.5
    }

    private func executeRealtimeTool(sessionID: UUID, name: String, argumentsJSON: String) async -> String {
        guard let attention else { return "{\"error\":\"Workspace unavailable\"}" }
        guard let state = realtimeSessions[sessionID] else {
            return "{\"error\":\"Session closed\"}"
        }
        // Strictly enforce People.md approval and skill capability scopes for Realtime tool calls.
        let allowWrites = state.lastTurnAllowWrites
        let skill = await attention.withSkillRepository { repo, _ in repo.skill(id: state.activeSkillID) }
        let allowedGroups: Set<AssistantSkillToolGroup>? = skill.map { Set($0.tools) }

        let talk = attention.talk
        let snapshot = talk.makeAgentSnapshot()
        let hooks = AssistantNativeToolProvider.Hooks(
            executeAction: { [weak talk] action in
                guard allowWrites, let talk else { throw AssistantAgentError.unsupported }
                return try await talk.executeFacilitatorNativeAction(action)
            },
            readNote: { [weak attention] id in await attention?.store.meetingLibrary.note(sessionID: id) }
        )
        let registry = AssistantNativeToolProvider.registry(snapshot: snapshot, hooks: hooks)
        if let external = attention.externalToolProvider {
            await registry.registerMeetingMCPTools(external, includeAdditionalReads: true)
        }
        AssistantSkillToolRegistrar.registerTools(
            into: registry,
            attention: attention,
            talk: talk,
            snapshot: snapshot,
            allowPrivilegedActions: allowWrites,
            allowedToolGroups: allowedGroups
        )
        return await AssistantSkillToolRegistrar.executeToolCallJSON(
            registry: registry,
            name: name,
            argumentsJSON: argumentsJSON
        )
    }

    private func handleRealtimeEvent(_ event: RealtimeVoiceEvent, state: SessionRealtimeState, model: NativeDesktopMeetingModel?) async {
        switch event {
        case .connected:
            state.connected = true
            syncRealtimeActiveFlag()
        case .audioPCM16(let pcm, _):
            state.audioChunks.append(pcm)
        case .assistantTranscriptDelta(let delta):
            state.transcriptBuffer += delta
        case .assistantTranscriptDone(let text):
            state.transcriptBuffer = text
        case .audioDone:
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            if let sessionID = model?.sessionID {
                busySessions.remove(sessionID)
            }
            let combined = state.audioChunks.reduce(into: Data()) { $0.append($1) }
            state.audioChunks.removeAll()
            let text = state.transcriptBuffer.trimmed
            state.transcriptBuffer = ""
            if let model, !model.isClosed {
                if let buffer = Self.pcm16ToAudioBuffer(data: combined, sampleRate: 24_000) {
                    await deliverSpokenBuffer(buffer, fallbackText: text, model: model)
                } else if !text.isEmpty {
                    await speakIntoMeeting(text, model: model)
                }
            }
        case .error(let msg):
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            if let sessionID = model?.sessionID {
                busySessions.remove(sessionID)
                lastStatusBySession[sessionID] = L("Realtime fallback active (%@)", msg)
            }
            state.connected = false
            syncRealtimeActiveFlag()
        case .disconnected:
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            if let sessionID = model?.sessionID {
                busySessions.remove(sessionID)
            }
            state.connected = false
            syncRealtimeActiveFlag()
        default:
            break
        }
    }

    func speakIntoMeeting(_ text: String, model: NativeDesktopMeetingModel) async {
        guard let attention, !model.isClosed else { return }
        lastSpokeAtBySession[model.sessionID] = Date()
        lastSpokenAnswerBySession[model.sessionID] = text
        do {
            let buffer = try await attention.store.voiceConfiguration.synthesize(text)
            await deliverSpokenBuffer(buffer, fallbackText: text, model: model)
        } catch {
            lastStatusBySession[model.sessionID] = error.localizedDescription
        }
    }

    private func deliverSpokenBuffer(_ buffer: AVAudioPCMBuffer, fallbackText: String, model: NativeDesktopMeetingModel) async {
        guard let attention, !model.isClosed else { return }
        lastSpokeAtBySession[model.sessionID] = Date()
        if !fallbackText.isEmpty {
            lastSpokenAnswerBySession[model.sessionID] = fallbackText
        }
        defer {
            lastVoiceDeliveryEndedAtBySession[model.sessionID] = Date()
        }
        if model.supportsVoiceReply && model.snapshot.playoutOn {
            if !model.ownsMicrophone, let arbiter = model.microphoneArbiter {
                _ = await arbiter(model)
            }
            do {
                try await attention.deliverVoice(model, buffer)
                lastStatusBySession[model.sessionID] = L("Spoken into “%@”.", model.title)
                return
            } catch {
                // Fall through to local preview playback if WebRTC send fails.
            }
        }
        if (try? VoicePreviewPlayer.shared.play(buffer)) == nil, !fallbackText.isEmpty {
            _ = try? await VoiceSynthesis.auditionWithStatus(
                fallbackText,
                selection: attention.store.assistantAuditionVoice
            )
        }
        lastStatusBySession[model.sessionID] = L("Auditioned locally (meeting audio off).")
    }

    private func syncRealtimeActiveFlag() {
        realtimeActive = realtimeSessions.values.contains(where: \.connected)
    }

    private func refreshSkillsCacheIfNeeded() {
        guard Date().timeIntervalSince(lastSkillRefreshAt) > 15 else { return }
        lastSkillRefreshAt = Date()
        Task { @MainActor [weak self] in
            await self?.refreshSkillsCache()
        }
    }

    private func refreshSkillsCache() async {
        guard let attention else { return }
        cachedSkills = await attention.listAssistantSkills()
        lastSkillRefreshAt = Date()
    }

    nonisolated static func pcm16ToAudioBuffer(data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        RealtimeVoiceAudio.pcm16ToAudioBuffer(data: data, sampleRate: sampleRate)
    }

    static func isLikelySelfEcho(
        candidate: String,
        lastSpoken: String,
        isLocal: Bool,
        withinEchoWindow: Bool
    ) -> Bool {
        AssistantWakePhraseMatcher.isLikelySelfEcho(
            candidate: candidate,
            lastSpoken: lastSpoken,
            isLocal: isLocal,
            withinEchoWindow: withinEchoWindow
        )
    }
}
