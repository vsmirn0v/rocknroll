import AVFoundation
import ConferenceCore
import Foundation

/// Runs autonomous in-meeting voice facilitation using Obsidian-backed skills,
/// `People.md` speaker approval (owner is always approved), per-session optional
/// `OpenAI Realtime` / `Gemini Live` / `Yandex Realtime` WebSocket acceleration with live audio streaming,
/// and automatic local STT -> LLM -> TTS fallback.
@MainActor
final class AutonomousMeetingFacilitator: ObservableObject {
    @Published private(set) var activeSessionSkills: [UUID: String] = [:]
    @Published private(set) var pendingSkillByTitleOrURL: [String: String] = [:]
    @Published private(set) var lastStatusBySession: [UUID: String] = [:]
    @Published private(set) var lastSpokenAnswerBySession: [UUID: String] = [:]
    @Published private(set) var realtimeActive = false

    private final class AudioTapGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastVoiceDeliveryEndedAt: Date?
        private var approvedSpeakersOnly = true
        private var lastApprovedTranscriptAt: Date?
        private var lastRemoteAudioAt: Date?
        private var lastForwardedAudioAt: Date?
        private var lastTurnAllowWrites = false
        private var voiceDeliveryInFlight = false
        var coalescer: RealtimeAudioCoalescer?
        var senderTask: Task<Void, Never>?

        func setApprovedSpeakersOnly(_ enabled: Bool) {
            lock.lock()
            approvedSpeakersOnly = enabled
            lock.unlock()
        }

        func setTurnApproval(allowWrites: Bool, approvedTranscriptAt: Date?) {
            lock.lock()
            lastTurnAllowWrites = allowWrites
            lastApprovedTranscriptAt = approvedTranscriptAt
            lock.unlock()
        }

        func markVoiceDeliveryStarted() {
            lock.lock()
            voiceDeliveryInFlight = true
            lastVoiceDeliveryEndedAt = nil
            lock.unlock()
        }

        func markVoiceDeliveryEnded(at date: Date) {
            lock.lock()
            voiceDeliveryInFlight = false
            lastVoiceDeliveryEndedAt = date
            lock.unlock()
        }

        func currentAllowWrites() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return lastTurnAllowWrites
        }

        func shouldAcceptAudio(isLocal: Bool) -> Bool {
            let now = Date()
            lock.lock()
            defer { lock.unlock() }
            if isLocal {
                if voiceDeliveryInFlight { return false }
                if let ended = lastVoiceDeliveryEndedAt, now.timeIntervalSince(ended) < 1.5 {
                    return false
                }
                let recentRemote = lastRemoteAudioAt.map { now.timeIntervalSince($0) <= 3.0 } ?? false
                if !recentRemote {
                    lastTurnAllowWrites = true
                }
                lastForwardedAudioAt = now
                return true
            } else {
                lastRemoteAudioAt = now
                if approvedSpeakersOnly {
                    let recentApproved = lastApprovedTranscriptAt.map { now.timeIntervalSince($0) <= 8.0 } ?? false
                    if !recentApproved {
                        lastTurnAllowWrites = false
                    }
                } else {
                    lastTurnAllowWrites = true
                }
                lastForwardedAudioAt = now
                return true
            }
        }

        func recentlyForwardedAudio(within seconds: TimeInterval, now: Date = Date()) -> Bool {
            lock.lock()
            let at = lastForwardedAudioAt
            lock.unlock()
            guard let at else { return false }
            return now.timeIntervalSince(at) <= seconds
        }
    }

    private final class SessionRealtimeState {
        let router = RealtimeVoiceRouter()
        let gate = AudioTapGate()
        var connected = false
        var responseInProgress = false
        var audioChunks: [Data] = []
        var outputSampleRate: Double = 24_000
        var transcriptBuffer = ""
        var activeSkillID: String
        var turnTimeoutTask: Task<Void, Never>?

        init(activeSkillID: String, outputSampleRate: Double = 24_000) {
            self.activeSkillID = activeSkillID
            self.outputSampleRate = outputSampleRate
        }
    }

    var wakeCoalesceDelay: Duration = .milliseconds(350)
    var followUpCoalesceDelay: Duration = .milliseconds(1500)
    var silencePollInterval: Duration = .milliseconds(180)
    var maxSilenceWaitDuration: Duration = .seconds(5)

    private static let followUpWindowSeconds: TimeInterval = 90

    private weak var attention: AttentionCoordinator?
    private var processedLineIDsBySession: [UUID: Set<String>] = [:]
    private var processedLineOrderBySession: [UUID: [String]] = [:]
    private var pendingTranscriptObservationSessions: Set<UUID> = []
    private var coalesceTasksBySession: [UUID: Task<Void, Never>] = [:]
    private var busySessions: Set<UUID> = []
    private var manuallyDisabledSessions: Set<UUID> = []
    private var lastSpokeAtBySession: [UUID: Date] = [:]
    private var lastVoiceDeliveryEndedAtBySession: [UUID: Date] = [:]
    private var recentSpokenAnswersBySession: [UUID: [String]] = [:]
    private var speakingSessions: Set<UUID> = []
    private var speechCancelEpochBySession: [UUID: UInt64] = [:]
    private var speechActivityEpochBySession: [UUID: UInt64] = [:]
    private var turnExecutedWriteToolBySession: [UUID: Bool] = [:]
    private var activeSpeechTasksBySession: [UUID: Task<Void, Never>] = [:]
    private var activeSpeechTokenBySession: [UUID: UUID] = [:]
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

    func enable(
        for model: NativeDesktopMeetingModel,
        skillID: String? = nil,
        suppressAutoGreet: Bool = false,
        trigger: String = "manual"
    ) {
        manuallyDisabledSessions.remove(model.sessionID)
        var chosen = resolveSkillID(explicitSkillID: skillID, meetingTitle: model.title)
        activeSessionSkills[model.sessionID] = chosen
        model.isFacilitatorActive = { [weak self, sessionID = model.sessionID] in
            self?.activeSessionSkills[sessionID] != nil
        }
        model.participation.cancelPendingDispatch()
        probeLog("assistant-facilitator-enable", [
            "skill": chosen,
            "trigger": trigger
        ])
        // Skip pre-existing lines at activation time so Rock responds to new spoken instructions.
        let initialIDs = model.transcript.map(\.id)
        processedLineIDsBySession[model.sessionID] = Set(initialIDs)
        processedLineOrderBySession[model.sessionID] = initialIDs
        coalesceTasksBySession.removeValue(forKey: model.sessionID)?.cancel()
        model.onTranscriptChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            self.observeTranscriptChanged(for: model)
        }
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
            if !suppressAutoGreet, skill?.autoGreet == true {
                await self.kickOffSkill(for: model, skillID: chosen)
            }
        }
    }

    func disable(for sessionID: UUID) {
        manuallyDisabledSessions.insert(sessionID)
        let removedSkill = activeSessionSkills.removeValue(forKey: sessionID)
        if let removedSkill {
            probeLog("assistant-facilitator-disable", ["skill": removedSkill])
        }
        coalesceTasksBySession.removeValue(forKey: sessionID)?.cancel()
        processedLineIDsBySession.removeValue(forKey: sessionID)
        processedLineOrderBySession.removeValue(forKey: sessionID)
        pendingTranscriptObservationSessions.remove(sessionID)
        lastStatusBySession.removeValue(forKey: sessionID)
        lastSpokeAtBySession.removeValue(forKey: sessionID)
        lastSpokenAnswerBySession.removeValue(forKey: sessionID)
        lastVoiceDeliveryEndedAtBySession.removeValue(forKey: sessionID)
        recentSpokenAnswersBySession.removeValue(forKey: sessionID)
        speechActivityEpochBySession.removeValue(forKey: sessionID)
        turnExecutedWriteToolBySession.removeValue(forKey: sessionID)
        activeSpeechTokenBySession.removeValue(forKey: sessionID)
        cancelActiveSpeechForBargeIn(sessionID: sessionID)
        busySessions.remove(sessionID)
        if let model = attention?.meetings().first(where: { $0.sessionID == sessionID }) {
            model.onRealtimeAudioPCM16 = nil
            model.onTranscriptChanged = nil
            model.isFacilitatorActive = nil
        }
        if let state = realtimeSessions.removeValue(forKey: sessionID) {
            state.turnTimeoutTask?.cancel()
            state.gate.coalescer?.finish()
            state.gate.coalescer = nil
            state.gate.senderTask?.cancel()
            state.gate.senderTask = nil
            Task { await state.router.stop() }
        }
        syncRealtimeActiveFlag()
    }

    /// Proactively introduces the bound skill into the meeting (e.g. starting a Daily Standup).
    func kickOffSkill(for model: NativeDesktopMeetingModel, skillID: String? = nil) async {
        guard let attention, !model.isClosed, !busySessions.contains(model.sessionID) else { return }
        busySessions.insert(model.sessionID)
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

    /// Event-driven trigger invoked when new transcript lines arrive on `@MainActor`,
    /// avoiding 0-2,000 ms polling latency before wake-phrase activation.
    func observeTranscriptChanged(for model: NativeDesktopMeetingModel) {
        let sid = model.sessionID
        guard activeSessionSkills[sid] != nil, !model.isClosed, model.connected else { return }
        guard pendingTranscriptObservationSessions.insert(sid).inserted else { return }
        Task { @MainActor [weak self, weak model] in
            guard let self else { return }
            self.pendingTranscriptObservationSessions.remove(sid)
            guard let model, !model.isClosed, model.connected,
                  let skillID = self.activeSessionSkills[sid] else { return }
            self.evaluateTranscriptLines(for: model, skillID: skillID, now: Date())
        }
    }

    func processTick(models: [NativeDesktopMeetingModel]) {
        refreshSkillsCacheIfNeeded()

        // 1. Attach queued skills (voice/MCP join), then per-meeting/series setting,
        // then optional global voice-activation fallback (default off).
        for model in models where !model.isClosed && model.connected && activeSessionSkills[model.sessionID] == nil {
            if let queued = pendingSkillByTitleOrURL.removeValue(forKey: model.invitation.absoluteString.lowercased())
                ?? pendingSkillByTitleOrURL.removeValue(forKey: model.title.trimmed.lowercased()) {
                enable(for: model, skillID: queued, trigger: "pending")
            } else if !manuallyDisabledSessions.contains(model.sessionID) {
                let seriesIDs = [model.participationCalendar?.externalSeriesID, model.calendarSeriesID]
                    .compactMap { $0 }
                if let configuredSkillID = attention?.store.autoFacilitatorSkillID(room: model.invitation, seriesIDs: seriesIDs),
                   let configuredSkill = cachedSkills.first(where: { $0.id == configuredSkillID && $0.enabled }) {
                    enable(for: model, skillID: configuredSkill.id, trigger: "meeting-setting")
                } else if attention?.store.autonomousMeetingVoiceEnabled == true,
                          let matched = cachedSkills.first(where: {
                              $0.enabled && $0.voiceActivation && $0.matches(meetingTitle: model.title, commandText: "")
                          }) {
                    enable(for: model, skillID: matched.id, trigger: "auto-title")
                }
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
            guard let skillID = activeSessionSkills[model.sessionID] else { continue }
            if model.participationRemoteSpeaking && speakingSessions.contains(model.sessionID) {
                cancelActiveSpeechForBargeIn(sessionID: model.sessionID)
            }
            evaluateTranscriptLines(for: model, skillID: skillID, now: now)
        }
    }

    private func recordSpokenAnswer(_ text: String, for sessionID: UUID) {
        lastSpokeAtBySession[sessionID] = Date()
        lastSpokenAnswerBySession[sessionID] = text
        var history = recentSpokenAnswersBySession[sessionID] ?? []
        if history.last != text {
            history.append(text)
            if history.count > 3 {
                history.removeFirst(history.count - 3)
            }
            recentSpokenAnswersBySession[sessionID] = history
        }
    }

    private func recentEchoCandidates(for sessionID: UUID) -> [String] {
        if let history = recentSpokenAnswersBySession[sessionID], !history.isEmpty {
            return history
        }
        if let last = lastSpokenAnswerBySession[sessionID]?.trimmed, !last.isEmpty {
            return [last]
        }
        return []
    }

    private func isWithinEchoWindow(for sessionID: UUID, at now: Date = Date()) -> Bool {
        if speakingSessions.contains(sessionID) {
            return true
        }
        if let endedAt = lastVoiceDeliveryEndedAtBySession[sessionID],
           now.timeIntervalSince(endedAt) <= 6 {
            return true
        }
        if let spokenAt = lastSpokeAtBySession[sessionID],
           now.timeIntervalSince(spokenAt) <= 6 {
            return true
        }
        return false
    }

    func cancelActiveSpeechForBargeIn(sessionID: UUID) {
        speechCancelEpochBySession[sessionID, default: 0] &+= 1
        let wasSpeaking = speakingSessions.remove(sessionID) != nil
        activeSpeechTasksBySession.removeValue(forKey: sessionID)?.cancel()
        if wasSpeaking {
            VoicePreviewPlayer.shared.stop()
            lastStatusBySession[sessionID] = L("Listening…")
        }
        if let rtState = realtimeSessions[sessionID], rtState.responseInProgress {
            rtState.turnTimeoutTask?.cancel()
            rtState.turnTimeoutTask = nil
            rtState.responseInProgress = false
            rtState.audioChunks.removeAll()
            rtState.transcriptBuffer = ""
            busySessions.remove(sessionID)
        }
    }

    private func waitForSpeakerSilence(for model: NativeDesktopMeetingModel) async {
        guard maxSilenceWaitDuration > .zero, silencePollInterval > .zero else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxSilenceWaitDuration)
        while !Task.isCancelled && clock.now < deadline {
            if model.isClosed || !model.connected { return }
            if !model.participationSomeoneSpeaking {
                return
            }
            try? await clock.sleep(for: silencePollInterval)
        }
    }

    private func markLinesSeen(_ lines: [GuestMeetingMessage], for sessionID: UUID) {
        guard !lines.isEmpty else { return }
        var seen = processedLineIDsBySession[sessionID] ?? []
        var order = processedLineOrderBySession[sessionID] ?? []
        for line in lines where seen.insert(line.id).inserted {
            order.append(line.id)
        }
        if order.count > 2_000 {
            let overflow = order.count - 2_000
            for evicted in order.prefix(overflow) {
                seen.remove(evicted)
            }
            order.removeFirst(overflow)
        }
        processedLineIDsBySession[sessionID] = seen
        processedLineOrderBySession[sessionID] = order
    }

    private func evaluateTranscriptLines(for model: NativeDesktopMeetingModel, skillID: String, now: Date) {
        let seen = processedLineIDsBySession[model.sessionID] ?? []
        let unseen = model.transcript.suffix(80).filter {
            !seen.contains($0.id) && !$0.text.trimmed.isEmpty
        }
        guard !unseen.isEmpty else { return }

        let inFollowUpWindow = lastSpokeAtBySession[model.sessionID].map {
            now.timeIntervalSince($0) <= Self.followUpWindowSeconds
        } ?? false
        let inEchoWindow = isWithinEchoWindow(for: model.sessionID, at: now)
        let recentAnswers = recentEchoCandidates(for: model.sessionID)

        var hasWake = false
        var hasFollowUp = false
        var sawGenuineHumanSpeech = false
        for line in unseen {
            if line.id.hasPrefix("assistant:") || AssistantSpeechLedger.isAssistantSpeaker(line.participantName, role: nil) {
                continue
            }
            let rawText = line.text.trimmed
            guard !rawText.isEmpty else { continue }
            if AssistantWakePhraseMatcher.isLikelySelfEcho(
                candidate: rawText,
                recentAssistantUtterances: recentAnswers,
                isLocal: line.isOwn,
                withinEchoWindow: inEchoWindow
            ) {
                continue
            }
            let text = AssistantWakePhraseMatcher.stripAssistantEcho(
                from: rawText,
                recentAssistantUtterances: recentAnswers,
                withinEchoWindow: inEchoWindow
            )
            guard !text.isEmpty else { continue }
            sawGenuineHumanSpeech = true
            switch AssistantWakePhraseMatcher.match(text) {
            case .command(let cmd) where !cmd.trimmed.isEmpty:
                hasWake = true
            case .wakeOnly:
                hasWake = true
            default:
                if inFollowUpWindow && text.count >= 3 {
                    hasFollowUp = true
                }
            }
        }

        if sawGenuineHumanSpeech {
            speechActivityEpochBySession[model.sessionID, default: 0] &+= 1
            if speakingSessions.contains(model.sessionID) || realtimeSessions[model.sessionID]?.responseInProgress == true {
                cancelActiveSpeechForBargeIn(sessionID: model.sessionID)
            }
        }

        guard !busySessions.contains(model.sessionID) else { return }

        if !hasWake && !hasFollowUp {
            markLinesSeen(unseen, for: model.sessionID)
            return
        }

        let sid = model.sessionID
        coalesceTasksBySession.removeValue(forKey: sid)?.cancel()
        let baseDelay = hasWake ? wakeCoalesceDelay : followUpCoalesceDelay
        let delay = model.participationSomeoneSpeaking ? max(baseDelay, silencePollInterval) : baseDelay
        coalesceTasksBySession[sid] = Task { @MainActor [weak self, weak model] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, let model else { return }
            self.coalesceTasksBySession.removeValue(forKey: sid)
            await self.flushCoalescedTranscriptTurn(for: model, skillID: skillID)
        }
    }

    private func flushCoalescedTranscriptTurn(for model: NativeDesktopMeetingModel, skillID: String) async {
        let sid = model.sessionID
        guard !busySessions.contains(sid),
              activeSessionSkills[sid] == skillID,
              !model.isClosed, model.connected else { return }

        await waitForSpeakerSilence(for: model)
        guard !Task.isCancelled,
              !busySessions.contains(sid),
              activeSessionSkills[sid] == skillID,
              !model.isClosed, model.connected else { return }

        let seen = processedLineIDsBySession[sid] ?? []
        let unseen = model.transcript.suffix(80).filter {
            !seen.contains($0.id) && !$0.text.trimmed.isEmpty
        }
        guard !unseen.isEmpty else { return }
        markLinesSeen(unseen, for: sid)

        let now = Date()
        let inFollowUpWindow = lastSpokeAtBySession[sid].map {
            now.timeIntervalSince($0) <= Self.followUpWindowSeconds
        } ?? false
        let inEchoWindow = isWithinEchoWindow(for: sid, at: now)
        let recentAnswers = recentEchoCandidates(for: sid)

        var sawWake = false
        var fragments: [String] = []
        var triggerLine: GuestMeetingMessage?
        for line in unseen {
            if line.id.hasPrefix("assistant:") || AssistantSpeechLedger.isAssistantSpeaker(line.participantName, role: nil) {
                continue
            }
            let rawText = line.text.trimmed
            guard !rawText.isEmpty else { continue }
            if AssistantWakePhraseMatcher.isLikelySelfEcho(
                candidate: rawText,
                recentAssistantUtterances: recentAnswers,
                isLocal: line.isOwn,
                withinEchoWindow: inEchoWindow
            ) {
                continue
            }
            let text = AssistantWakePhraseMatcher.stripAssistantEcho(
                from: rawText,
                recentAssistantUtterances: recentAnswers,
                withinEchoWindow: inEchoWindow
            )
            guard !text.isEmpty else { continue }
            switch AssistantWakePhraseMatcher.match(text) {
            case .command(let cmd) where !cmd.trimmed.isEmpty:
                sawWake = true
                triggerLine = line
                fragments.append(cmd.trimmed)
            case .wakeOnly:
                sawWake = true
                triggerLine = line
                fragments.append(text)
            default:
                if (inFollowUpWindow || sawWake) && text.count >= 3 {
                    triggerLine = line
                    fragments.append(text)
                }
            }
        }
        guard let trigger = triggerLine else { return }
        var deduped: [String] = []
        for fragment in fragments where !deduped.contains(fragment) {
            deduped.append(fragment)
        }
        let commandText = deduped.joined(separator: "\n")
        guard !commandText.isEmpty else { return }

        busySessions.insert(sid)
        await handleVoiceTurn(
            model: model,
            skillID: skillID,
            speakerName: trigger.participantName,
            isLocalSpeaker: trigger.isOwn,
            commandText: commandText
        )
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
        let hasWakeInBatch = commandText
            .components(separatedBy: .newlines)
            .contains { AssistantWakePhraseMatcher.match($0) != .none }
        if !approved, !hasWakeInBatch {
            if let lastSpoke = lastSpokeAtBySession[model.sessionID],
               Date().timeIntervalSince(lastSpoke) <= Self.followUpWindowSeconds,
               !isLocalSpeaker {
                // Only proceed without wake phrase in follow-up window if speaker is approved (or skill allows everyone).
                if skill?.approvedSpeakersOnly != false {
                    busySessions.remove(model.sessionID)
                    if activeSessionSkills[model.sessionID] != nil {
                        observeTranscriptChanged(for: model)
                    }
                    return
                }
            }
        }

        // Direct deterministic board controls (share, stop share, quick/person filter, clear filters, open URL)
        if allowWrites, (allowedGroups == nil || allowedGroups?.contains(.boardShare) == true) {
            let jiraConfig = await attention.resolvedJiraBoardConfig(for: model)
            let team = await attention.loadTeamContext()
            let defaultBoardURL = jiraConfig.boardURL?.absoluteString ?? team.defaultJiraBoardURL
            if let boardReply = await Self.handleDeterministicBoardCommand(
                commandText,
                board: attention.boardController,
                defaultBoardURL: defaultBoardURL,
                model: model,
                people: directory
            ) {
                probeLog("assistant-facilitator-turn", [
                    "skill": skillID,
                    "route": "deterministic-board",
                    "allowWrites": allowWrites
                ])
                busySessions.remove(model.sessionID)
                if !boardReply.isEmpty {
                    await speakIntoMeeting(boardReply, model: model)
                }
                if activeSessionSkills[model.sessionID] != nil {
                    observeTranscriptChanged(for: model)
                }
                return
            }
        }

        // Try Realtime WebSocket acceleration first if connected for this session;
        // falls back immediately to standard agent + local VoiceSynthesis otherwise.
        if let rtState = realtimeSessions[model.sessionID],
           await rtState.router.isRealtimeConnected {
            rtState.gate.setTurnApproval(allowWrites: allowWrites, approvedTranscriptAt: allowWrites ? Date() : nil)
            rtState.activeSkillID = skillID
            rtState.gate.setApprovedSpeakersOnly(skill?.approvedSpeakersOnly ?? true)
            if rtState.responseInProgress
                || !rtState.audioChunks.isEmpty
                || !rtState.transcriptBuffer.isEmpty
                || rtState.gate.recentlyForwardedAudio(within: 3.0) {
                if !rtState.responseInProgress {
                    busySessions.remove(model.sessionID)
                    if activeSessionSkills[model.sessionID] != nil {
                        observeTranscriptChanged(for: model)
                    }
                }
                return
            }
            let prefixedPrompt = "[\(speakerName) (approved=\(allowWrites)) in “\(model.title)”]: \(commandText)"
            if await rtState.router.sendText(prefixedPrompt) {
                probeLog("assistant-facilitator-turn", [
                    "skill": skillID,
                    "route": "realtime",
                    "allowWrites": allowWrites
                ])
                lastStatusBySession[model.sessionID] = L("Realtime model handling request…")
                rtState.turnTimeoutTask?.cancel()
                let sid = model.sessionID
                rtState.turnTimeoutTask = Task { @MainActor [weak self, weak rtState] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, let rtState, !Task.isCancelled else { return }
                    self.busySessions.remove(sid)
                    let buffered = AssistantSpeechLedger.sanitizeSpokenReply(rtState.transcriptBuffer)
                    rtState.transcriptBuffer = ""
                    if !buffered.isEmpty {
                        await self.speakIntoMeeting(buffered, model: model)
                    }
                    if self.activeSessionSkills[sid] != nil {
                        self.observeTranscriptChanged(for: model)
                    }
                }
                return
            }
        }

        defer {
            busySessions.remove(model.sessionID)
            if activeSessionSkills[model.sessionID] != nil {
                observeTranscriptChanged(for: model)
            }
        }

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
            allowPeopleIdentityBinding: true,
            allowedToolGroups: allowedGroups
        )
        let context = await AssistantSkillToolRegistrar.enrichedContext(
            base: AssistantNativeToolProvider.context(snapshot: snapshot),
            attention: attention,
            explicitSkillIDs: [skillID],
            meetingTitle: model.title,
            meetingID: model.sessionID,
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
        let turnEpoch = speechActivityEpochBySession[model.sessionID, default: 0]
        turnExecutedWriteToolBySession[model.sessionID] = false
        let framedPrompt = "\(speakerName) says: \(commandText)\n" +
            (allowWrites
                ? "(Approved speaker. Answer concisely for voice playback in 1-3 sentences after running any needed tools.)"
                : "(Read-only guest speaker. Do not create/update tasks, schedule meetings, or control the board unless an approved member confirms. Answer concisely for voice playback.)")
        probeLog("assistant-facilitator-turn", [
            "skill": skillID,
            "route": "llm",
            "allowWrites": allowWrites
        ])
        let outcome = await runtime.submit(framedPrompt, environment: environment)

        let spokenText: String?
        let didMutate: Bool
        switch outcome {
        case .success(.completed(let text, let sources, _)):
            spokenText = text
            let writeIndicators = ["create", "update", "task", "jira", "board", "schedule", "people", "summary", "artifacts"]
            let sourceMutated = sources.contains { src in
                let hay = (src.kind + " " + src.title).lowercased()
                return writeIndicators.contains { hay.contains($0) }
            }
            didMutate = sourceMutated || (turnExecutedWriteToolBySession[model.sessionID] ?? false)
        case .success(.needsUserInput(let question)):
            spokenText = question
            didMutate = false
        case .success(.approvalRequired(let approval)):
            lastStatusBySession[model.sessionID] = L("Approval required: %@", approval.title)
            spokenText = nil
            didMutate = false
        case .failure:
            spokenText = nil
            didMutate = false
        }

        if let spokenText, !spokenText.trimmed.isEmpty {
            await waitForSpeakerSilence(for: model)
            guard !model.isClosed, model.connected,
                  activeSessionSkills[model.sessionID] != nil,
                  !manuallyDisabledSessions.contains(model.sessionID) else { return }
            let activityAdvanced = speechActivityEpochBySession[model.sessionID, default: 0] != turnEpoch
            let seenNow = processedLineIDsBySession[model.sessionID] ?? []
            let hasNewUnseen = model.transcript.contains { !seenNow.contains($0.id) && !$0.text.trimmed.isEmpty }
            if !didMutate && ((activityAdvanced && hasNewUnseen) || model.participationSomeoneSpeaking) {
                return
            }
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
            old.gate.coalescer?.finish()
            old.gate.coalescer = nil
            old.gate.senderTask?.cancel()
            old.gate.senderTask = nil
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
            meetingID: model.sessionID,
            commandText: "",
            speakerName: nil,
            isApprovedSpeaker: true
        )
        let basePersona = promptCtx["obsidian_base_persona"] ?? ""
        let skillsText = promptCtx["obsidian_skills"] ?? "Facilitate the meeting concisely in the user's language."
        let participantNames = [model.displayName] + model.participants.filter { !$0.isLocal }.map(\.name)
        let identityGuidance = DefaultAssistantPrompts.jiraIdentityResolutionGuidance(meetingParticipants: participantNames)
        let instructions = [basePersona, skillsText, identityGuidance].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let tools = AssistantSkillToolRegistrar.exportRealtimeTools(from: registry)
        let targetInputRate = kind.defaultInputSampleRate
        let config = RealtimeSessionConfig(
            provider: kind,
            apiKey: apiKey,
            model: attention.store.realtimeModel,
            voice: attention.store.realtimeVoice,
            endpointOverride: attention.store.realtimeEndpoint,
            systemInstructions: instructions,
            inputSampleRate: targetInputRate,
            tools: tools,
            folderID: attention.store.realtimeFolderID,
            voiceRole: attention.store.realtimeVoiceRole
        )

        let state = SessionRealtimeState(activeSkillID: skillID, outputSampleRate: Double(config.outputSampleRate))
        state.gate.setApprovedSpeakersOnly(skill?.approvedSpeakersOnly ?? true)
        realtimeSessions[model.sessionID] = state
        probeLog("assistant-facilitator-realtime", [
            "provider": kind.rawValue,
            "state": "connecting",
            "inputSampleRate": targetInputRate,
            "outputSampleRate": Int(config.outputSampleRate)
        ])
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
        guard realtimeSessions[sessionID] === state, !model.isClosed else {
            await state.router.stop()
            syncRealtimeActiveFlag()
            return
        }
        if state.connected {
            attachAudioTap(to: model, state: state, targetSampleRate: targetInputRate)
        }
        syncRealtimeActiveFlag()
    }

    private func attachAudioTap(to model: NativeDesktopMeetingModel, state: SessionRealtimeState, targetSampleRate: Int) {
        let router = state.router
        let gate = state.gate
        let coalescer = RealtimeAudioCoalescer(
            inputSampleRate: 16_000,
            targetSampleRate: targetSampleRate,
            windowMs: 80
        )
        gate.coalescer = coalescer
        gate.senderTask?.cancel()
        gate.senderTask = Task.detached(priority: .userInitiated) {
            for await batch in coalescer.stream {
                if Task.isCancelled { break }
                _ = await router.sendAudioPCM16(batch)
            }
        }
        model.onRealtimeAudioPCM16 = { [weak gate] _, trackID, pcm in
            guard let gate else { return }
            let isLocal = trackID == MeetingTranscriber.localTrackID
            guard gate.shouldAcceptAudio(isLocal: isLocal) else {
                return
            }
            coalescer.append(trackID: trackID, pcm16: pcm)
        }
    }

    private func executeRealtimeTool(sessionID: UUID, name: String, argumentsJSON: String) async -> String {
        guard let attention else { return "{\"error\":\"Workspace unavailable\"}" }
        guard let state = realtimeSessions[sessionID] else {
            return "{\"error\":\"Session closed\"}"
        }
        // Strictly enforce People.md approval and skill capability scopes for Realtime tool calls.
        let allowWrites = state.gate.currentAllowWrites()
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
            allowPeopleIdentityBinding: true,
            allowedToolGroups: allowedGroups
        )
        let result = await AssistantSkillToolRegistrar.executeToolCallJSON(
            registry: registry,
            name: name,
            argumentsJSON: argumentsJSON
        )
        let parsedArgs = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]
        let command = (parsedArgs?["command"] as? String) ?? (parsedArgs?["operation"] as? String) ?? ""
        probeLog("assistant-facilitator-tool", [
            "tool": name,
            "command": command,
            "ok": !result.contains("\"error\"")
        ])
        return result
    }

    private func handleRealtimeEvent(_ event: RealtimeVoiceEvent, state: SessionRealtimeState, model: NativeDesktopMeetingModel?) async {
        switch event {
        case .connected:
            state.connected = true
            probeLog("assistant-facilitator-realtime", [
                "state": "connected",
                "outputSampleRate": Int(state.outputSampleRate)
            ])
            syncRealtimeActiveFlag()
        case .audioPCM16(let pcm, let sampleRate):
            state.responseInProgress = true
            if sampleRate > 0 {
                state.outputSampleRate = Double(sampleRate)
            }
            state.audioChunks.append(pcm)
        case .assistantTranscriptDelta(let delta):
            state.responseInProgress = true
            state.transcriptBuffer += delta
        case .assistantTranscriptDone(let text):
            state.transcriptBuffer = text
        case .toolCall:
            state.responseInProgress = true
        case .audioDone:
            state.responseInProgress = false
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            if let sessionID = model?.sessionID {
                busySessions.remove(sessionID)
            }
            let combined = Self.combinePCMChunks(state.audioChunks)
            state.audioChunks.removeAll()
            let text = AssistantSpeechLedger.sanitizeSpokenReply(state.transcriptBuffer)
            state.transcriptBuffer = ""
            if let model, !model.isClosed, model.connected,
               activeSessionSkills[model.sessionID] != nil,
               !manuallyDisabledSessions.contains(model.sessionID) {
                await waitForSpeakerSilence(for: model)
                guard !model.isClosed, model.connected,
                      activeSessionSkills[model.sessionID] != nil,
                      !manuallyDisabledSessions.contains(model.sessionID),
                      !model.participationSomeoneSpeaking else {
                    if activeSessionSkills[model.sessionID] != nil {
                        observeTranscriptChanged(for: model)
                    }
                    return
                }
                if let buffer = Self.pcm16ToAudioBuffer(data: combined, sampleRate: state.outputSampleRate) {
                    await deliverSpokenBuffer(buffer, fallbackText: text, model: model)
                } else if !text.isEmpty {
                    await speakIntoMeeting(text, model: model)
                }
                if activeSessionSkills[model.sessionID] != nil {
                    observeTranscriptChanged(for: model)
                }
            }
        case .error(let msg):
            state.responseInProgress = false
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            let stillConnected = await state.router.isRealtimeConnected
            if let sessionID = model?.sessionID {
                busySessions.remove(sessionID)
                if !stillConnected {
                    lastStatusBySession[sessionID] = L("Realtime fallback active (%@)", msg)
                }
                if let model, activeSessionSkills[sessionID] != nil {
                    observeTranscriptChanged(for: model)
                }
            }
            if !stillConnected {
                state.connected = false
            }
            probeLog("assistant-facilitator-realtime", [
                "state": "error",
                "outputSampleRate": Int(state.outputSampleRate)
            ])
            syncRealtimeActiveFlag()
        case .disconnected:
            state.responseInProgress = false
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            if let sessionID = model?.sessionID {
                busySessions.remove(sessionID)
                if let model, activeSessionSkills[sessionID] != nil {
                    observeTranscriptChanged(for: model)
                }
            }
            state.connected = false
            probeLog("assistant-facilitator-realtime", [
                "state": "disconnected",
                "outputSampleRate": Int(state.outputSampleRate)
            ])
            syncRealtimeActiveFlag()
        default:
            break
        }
    }

    func speakIntoMeeting(_ text: String, model: NativeDesktopMeetingModel) async {
        let sid = model.sessionID
        guard let attention,
              !model.isClosed,
              model.connected,
              activeSessionSkills[sid] != nil,
              !manuallyDisabledSessions.contains(sid) else { return }
        let clean = AssistantSpeechLedger.sanitizeSpokenReply(text)
        guard !clean.isEmpty else { return }
        let startEpoch = speechCancelEpochBySession[sid, default: 0]
        let speechToken = UUID()
        activeSpeechTasksBySession[sid]?.cancel()
        activeSpeechTokenBySession[sid] = speechToken
        recordSpokenAnswer(clean, for: sid)
        realtimeSessions[sid]?.gate.markVoiceDeliveryStarted()
        speakingSessions.insert(sid)
        defer {
            if activeSpeechTokenBySession[sid] == speechToken {
                activeSpeechTokenBySession.removeValue(forKey: sid)
                speakingSessions.remove(sid)
                activeSpeechTasksBySession.removeValue(forKey: sid)
                let endedAt = Date()
                lastSpokeAtBySession[sid] = endedAt
                lastVoiceDeliveryEndedAtBySession[sid] = endedAt
                realtimeSessions[sid]?.gate.markVoiceDeliveryEnded(at: endedAt)
            }
        }

        let speechTask = Task<Void, Never> { @MainActor [weak self, weak model, weak attention] in
            guard let self, let model, let attention,
                  !Task.isCancelled,
                  self.activeSpeechTokenBySession[sid] == speechToken,
                  self.speechCancelEpochBySession[sid, default: 0] == startEpoch else { return }
            do {
                if attention.canStreamVoiceDelivery, model.supportsVoiceReply, model.snapshot.playoutOn {
                    if !model.ownsMicrophone, let arbiter = model.microphoneArbiter {
                        _ = await arbiter(model)
                    }
                    try Task.checkCancellation()
                    guard !model.isClosed, model.connected,
                          self.activeSpeechTokenBySession[sid] == speechToken,
                          self.speechCancelEpochBySession[sid, default: 0] == startEpoch,
                          self.activeSessionSkills[sid] != nil,
                          !self.manuallyDisabledSessions.contains(sid) else { return }
                    let request = UUID()
                    let pre = try await AttentionCoordinator.preparePrepulledStream(
                        from: attention.streamSynthesize(clean, cloneRequest: request),
                        cloneRequest: request
                    )
                    let utteranceID = UUID().uuidString
                    let startedAt = Date()
                    model.recordAssistantSpokenUtterance(id: utteranceID, text: clean, startedAt: startedAt, endedAt: nil)
                    do {
                        try await attention.deliverVoiceStream(model, pre.replayStream)
                        model.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                        if !Task.isCancelled,
                           self.activeSpeechTokenBySession[sid] == speechToken,
                           self.speechCancelEpochBySession[sid, default: 0] == startEpoch {
                            self.lastStatusBySession[sid] = L("Spoken into “%@”.", model.title)
                        }
                        return
                    } catch {
                        pre.cancel()
                        model.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                        guard !Task.isCancelled,
                              self.activeSpeechTokenBySession[sid] == speechToken,
                              self.speechCancelEpochBySession[sid, default: 0] == startEpoch,
                              !model.isClosed, model.connected,
                              !model.participationRemoteSpeaking,
                              self.activeSessionSkills[sid] != nil,
                              !self.manuallyDisabledSessions.contains(sid) else { return }
                    }
                } else if !model.supportsVoiceReply || !model.snapshot.playoutOn {
                    guard !model.isClosed, model.connected,
                          self.activeSpeechTokenBySession[sid] == speechToken,
                          self.speechCancelEpochBySession[sid, default: 0] == startEpoch,
                          self.activeSessionSkills[sid] != nil,
                          !self.manuallyDisabledSessions.contains(sid),
                          !model.participationRemoteSpeaking else { return }
                    let utteranceID = UUID().uuidString
                    let startedAt = Date()
                    model.recordAssistantSpokenUtterance(id: utteranceID, text: clean, startedAt: startedAt, endedAt: nil)
                    await self.playLocalAuditionAndWait(clean, attention: attention)
                    model.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                    if !Task.isCancelled,
                       self.activeSpeechTokenBySession[sid] == speechToken,
                       self.speechCancelEpochBySession[sid, default: 0] == startEpoch {
                        self.lastStatusBySession[sid] = L("Auditioned locally (meeting audio off).")
                    }
                    return
                }
                guard !Task.isCancelled,
                      self.activeSpeechTokenBySession[sid] == speechToken,
                      self.speechCancelEpochBySession[sid, default: 0] == startEpoch,
                      !model.isClosed, model.connected,
                      !model.participationRemoteSpeaking else { return }
                let buffer: AVAudioPCMBuffer
                if let synthesizeOverride = attention.synthesizeOverride {
                    buffer = try await synthesizeOverride(clean)
                } else {
                    buffer = try await attention.store.voiceConfiguration.synthesize(clean)
                }
                try Task.checkCancellation()
                guard self.activeSpeechTokenBySession[sid] == speechToken,
                      self.speechCancelEpochBySession[sid, default: 0] == startEpoch,
                      !model.isClosed, model.connected,
                      !model.participationRemoteSpeaking else { return }
                await self.deliverSpokenBufferCore(buffer, fallbackText: clean, model: model, startEpoch: startEpoch)
            } catch {
                if !Task.isCancelled, self.activeSpeechTokenBySession[sid] == speechToken {
                    self.lastStatusBySession[sid] = error.localizedDescription
                }
            }
        }
        activeSpeechTasksBySession[sid] = speechTask
        await speechTask.value
    }

    private func playLocalAuditionAndWait(_ text: String, attention: AttentionCoordinator) async {
        final class OnceContinuation: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<Void, Never>?
            private var resumed = false
            func install(_ c: CheckedContinuation<Void, Never>) {
                lock.lock()
                if resumed {
                    lock.unlock()
                    c.resume()
                    return
                }
                cont = c
                lock.unlock()
            }
            func resume() {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                let pending = cont
                cont = nil
                lock.unlock()
                pending?.resume()
            }
        }
        let once = OnceContinuation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.install(continuation)
                Task { @MainActor in
                    do {
                        _ = try await VoiceSynthesis.streamAuditionWithStatus(
                            text,
                            selection: attention.store.assistantAuditionVoice,
                            player: .shared,
                            onComplete: { once.resume() },
                            store: attention.store
                        )
                    } catch {
                        once.resume()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in VoicePreviewPlayer.shared.stop() }
            once.resume()
        }
    }

    private func deliverSpokenBuffer(_ buffer: AVAudioPCMBuffer, fallbackText: String, model: NativeDesktopMeetingModel) async {
        let sid = model.sessionID
        guard let attention,
              !model.isClosed,
              model.connected,
              activeSessionSkills[sid] != nil,
              !manuallyDisabledSessions.contains(sid) else { return }
        _ = attention
        let cleanFallback = AssistantSpeechLedger.sanitizeSpokenReply(fallbackText)
        let startEpoch = speechCancelEpochBySession[sid, default: 0]
        let speechToken = UUID()
        activeSpeechTasksBySession[sid]?.cancel()
        activeSpeechTokenBySession[sid] = speechToken
        if !cleanFallback.isEmpty {
            recordSpokenAnswer(cleanFallback, for: sid)
        } else {
            lastSpokeAtBySession[sid] = Date()
        }
        realtimeSessions[sid]?.gate.markVoiceDeliveryStarted()
        speakingSessions.insert(sid)
        defer {
            if activeSpeechTokenBySession[sid] == speechToken {
                activeSpeechTokenBySession.removeValue(forKey: sid)
                speakingSessions.remove(sid)
                activeSpeechTasksBySession.removeValue(forKey: sid)
                let endedAt = Date()
                lastSpokeAtBySession[sid] = endedAt
                lastVoiceDeliveryEndedAtBySession[sid] = endedAt
                realtimeSessions[sid]?.gate.markVoiceDeliveryEnded(at: endedAt)
            }
        }
        let speechTask = Task<Void, Never> { @MainActor [weak self, weak model] in
            guard let self, let model,
                  !Task.isCancelled,
                  self.activeSpeechTokenBySession[sid] == speechToken,
                  self.speechCancelEpochBySession[sid, default: 0] == startEpoch else { return }
            await self.deliverSpokenBufferCore(buffer, fallbackText: cleanFallback, model: model, startEpoch: startEpoch)
        }
        activeSpeechTasksBySession[sid] = speechTask
        await speechTask.value
    }

    private func deliverSpokenBufferCore(
        _ buffer: AVAudioPCMBuffer,
        fallbackText cleanFallback: String,
        model: NativeDesktopMeetingModel,
        startEpoch: UInt64
    ) async {
        let sid = model.sessionID
        guard let attention else { return }
        if model.supportsVoiceReply && model.snapshot.playoutOn {
            if !model.ownsMicrophone, let arbiter = model.microphoneArbiter {
                _ = await arbiter(model)
            }
            guard !Task.isCancelled,
                  speechCancelEpochBySession[sid, default: 0] == startEpoch,
                  !model.isClosed, model.connected,
                  activeSessionSkills[sid] != nil,
                  !manuallyDisabledSessions.contains(sid) else { return }
            let utteranceID = UUID().uuidString
            let startedAt = Date()
            if !cleanFallback.isEmpty {
                model.recordAssistantSpokenUtterance(id: utteranceID, text: cleanFallback, startedAt: startedAt, endedAt: nil)
            }
            do {
                try await attention.deliverVoice(model, buffer)
                model.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                if !Task.isCancelled, speechCancelEpochBySession[sid, default: 0] == startEpoch {
                    lastStatusBySession[sid] = L("Spoken into “%@”.", model.title)
                }
                return
            } catch {
                model.assistantSpeechLedger.endUtterance(id: utteranceID, endedAt: Date())
                let canAuditionLocally = !Task.isCancelled
                    && speechCancelEpochBySession[sid, default: 0] == startEpoch
                    && !model.isClosed
                    && model.connected
                    && activeSessionSkills[sid] != nil
                    && !manuallyDisabledSessions.contains(sid)
                    && !model.participationRemoteSpeaking
                    && !model.snapshot.playoutOn
                guard canAuditionLocally else { return }
            }
        }
        guard !Task.isCancelled,
              speechCancelEpochBySession[sid, default: 0] == startEpoch,
              !model.isClosed, model.connected,
              activeSessionSkills[sid] != nil,
              !manuallyDisabledSessions.contains(sid),
              !model.participationRemoteSpeaking else { return }
        if (try? VoicePreviewPlayer.shared.play(buffer)) == nil, !cleanFallback.isEmpty {
            await playLocalAuditionAndWait(cleanFallback, attention: attention)
        }
        if !Task.isCancelled, speechCancelEpochBySession[sid, default: 0] == startEpoch {
            lastStatusBySession[sid] = L("Auditioned locally (meeting audio off).")
        }
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

    nonisolated private static func combinePCMChunks(_ chunks: [Data]) -> Data {
        guard !chunks.isEmpty else { return Data() }
        if chunks.count == 1 { return chunks[0] }
        let total = chunks.reduce(0) { $0 + $1.count }
        var combined = Data()
        combined.reserveCapacity(total)
        for chunk in chunks { combined.append(chunk) }
        return combined
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

    static func handleDeterministicBoardCommand(
        _ input: String,
        board: AssistantBoardWindowController?,
        defaultBoardURL: String,
        model: NativeDesktopMeetingModel,
        people: AssistantPeopleDirectory = AssistantPeopleDirectory()
    ) async -> String? {
        guard let board else { return nil }
        let lower = input.lowercased().replacingOccurrences(of: "ё", with: "е")
        let hasBoardKeyword = lower.contains("доск") || lower.contains("board") || lower.contains("jira")
        let hasFilterKeyword = lower.contains("квикфильт") || lower.contains("quick filter")
            || lower.contains("фильтр по имени") || lower.contains("фильтр ")
        guard hasBoardKeyword || hasFilterKeyword else {
            return nil
        }

        let hasJiraTaskAction = lower.contains("задач") || lower.contains("таск")
            || lower.contains("описан") || lower.contains("issue") || lower.contains("ticket")

        let asksClearFilter = (lower.contains("сброс") || lower.contains("очист") || lower.contains("убер")
            || lower.contains("удал") || lower.contains("сним") || lower.contains("clear") || lower.contains("reset"))
            && (lower.contains("фильтр") || lower.contains("квикфильт") || lower.contains("filter"))
        if asksClearFilter && !hasJiraTaskAction {
            do {
                return try await board.clearFilters()
            } catch {
                return error.localizedDescription
            }
        }

        if let filterQuery = extractPersonFilterQuery(from: input, lower: lower), !hasJiraTaskAction {
            let trimmedDefault = defaultBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if board.currentURL == nil && !trimmedDefault.isEmpty {
                _ = try? await board.open(urlString: trimmedDefault)
            }
            do {
                return try await board.selectPersonFilter(query: filterQuery, people: people)
            } catch {
                return error.localizedDescription
            }
        }

        let asksStop = lower.contains("останов") || lower.contains("прекрат") || lower.contains("выключ")
            || lower.contains("stop shar") || lower.contains("unshare")
        if asksStop && hasBoardKeyword {
            board.stopSharing()
            return L("Stopped sharing the Assistant Board.")
        }

        let asksShare = lower.contains("расшар") || lower.contains("пошар") || lower.contains("демонстр")
            || lower.contains("поделис") || lower.contains("share") || lower.contains("present")
        if asksShare && hasBoardKeyword {
            let trimmedDefault = defaultBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if board.currentURL == nil && !trimmedDefault.isEmpty {
                _ = try? await board.open(urlString: trimmedDefault)
            }
            do {
                return try await board.startSharing(to: model)
            } catch {
                return error.localizedDescription
            }
        }

        let asksOpen = lower.contains("открой") || lower.contains("покажи") || lower.contains("open") || lower.contains("show")
        if asksOpen && hasBoardKeyword && !hasJiraTaskAction {
            let trimmedDefault = defaultBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDefault.isEmpty, let msg = try? await board.open(urlString: trimmedDefault) {
                return msg
            }
        }
        return nil
    }

    nonisolated static func extractPersonFilterQuery(from input: String, lower: String) -> String? {
        let markers = [
            "фильтр по имени ", "квикфильтр по имени ", "квикфильт по имени ",
            "квикфильтр на ", "квикфильт на ", "квикфильтр ", "квикфильт ",
            "quick filter by name ", "quick filter by ", "quick filter ",
            "filter by name ", "filter by ", "отфильтруй по ", "фильтр на "
        ]
        for marker in markers {
            if let range = lower.range(of: marker) {
                let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
                guard offset < input.count else { continue }
                let idx = input.index(input.startIndex, offsetBy: offset)
                var tail = String(input[idx...])
                    .components(separatedBy: CharacterSet(charactersIn: ".,;!?\n"))
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                for conjunction in [" и ", " and ", " пожалуйста", " please"] {
                    let lowerTail = tail.lowercased().replacingOccurrences(of: "ё", with: "е")
                    if let cRange = lowerTail.range(of: conjunction) {
                        let cOffset = lowerTail.distance(from: lowerTail.startIndex, to: cRange.lowerBound)
                        tail = String(tail.prefix(cOffset)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if !tail.isEmpty {
                    return tail
                }
            }
        }
        return nil
    }
}
