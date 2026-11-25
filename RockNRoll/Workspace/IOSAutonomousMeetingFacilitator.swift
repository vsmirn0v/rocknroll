import AVFoundation
import ConferenceCore
import Foundation
import MeetingEngine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs autonomous in-meeting voice facilitation on iOS using Obsidian-backed skills,
/// `People.md` speaker approval (owner is always approved), optional `OpenAI Realtime` /
/// `Gemini Live` / `Yandex Realtime` WebSocket acceleration with live PCM16 audio streaming, and local
/// STT -> LLM (with function calling / Apple FoundationModels) -> TTS fallback.
@MainActor
final class IOSAutonomousMeetingFacilitator: ObservableObject {
    @Published private(set) var activeSessionSkills: [UUID: String] = [:]
    @Published private(set) var pendingSkillByTitleOrURL: [String: String] = [:]
    @Published private(set) var lastStatusBySession: [UUID: String] = [:]
    @Published private(set) var lastSpokenAnswerBySession: [UUID: String] = [:]
    @Published private(set) var realtimeActive = false

    var customRealtimeTransportFactory: (@Sendable () -> any RealtimeVoiceTransport)?
    var llmURLSession: URLSession = .shared

    private final class AudioTapGate: @unchecked Sendable {
        private let lock = NSLock()
        private var voiceDeliveryInFlight = false
        private var lastVoiceDeliveryEndedAt: Date?
        private var approvedSpeakersOnly = true
        private var lastApprovedTranscriptAt: Date?
        private var lastRemoteAudioAt: Date?
        private var lastForwardedAudioAt: Date?
        private var lastTurnAllowWrites = false
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

        func shouldAcceptAudio(isLocal: Bool, externalVoiceReplyInFlight: Bool = false) -> Bool {
            let now = Date()
            lock.lock()
            defer { lock.unlock() }
            if isLocal {
                if voiceDeliveryInFlight || externalVoiceReplyInFlight { return false }
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
        let provider: RealtimeProviderKind
        var outputSampleRate: Double = 24_000
        var transcriptBuffer = ""
        var activeSkillID: String
        var turnTimeoutTask: Task<Void, Never>?

        init(activeSkillID: String, provider: RealtimeProviderKind = .disabled, outputSampleRate: Double = 24_000) {
            self.activeSkillID = activeSkillID
            self.provider = provider
            self.outputSampleRate = outputSampleRate
        }
    }

    private static let maxSeenEventIDsPerSession = 2_000
    private static let maxRecentEventsPerSession = 60
    private static let followUpWindowSeconds: TimeInterval = 90

    var wakeCoalesceDelay: Duration = .milliseconds(350)
    var followUpCoalesceDelay: Duration = .milliseconds(1500)
    var silencePollInterval: Duration = .milliseconds(180)
    var maxSilenceWaitDuration: Duration = .seconds(5)

    private weak var skills: IOSAssistantSkillsController?
    private weak var workspace: IOSWorkspaceCoordinator?
    private weak var board: IOSAssistantBoardController?
    private let resolveBridge: (UUID) -> IOSAssistantSessionBridge?

    private var seenEventIDsBySession: [UUID: Set<String>] = [:]
    private var seenEventOrderBySession: [UUID: [String]] = [:]
    private var recentEventsBySession: [UUID: [SyncedTranscriptEvent]] = [:]
    private var pendingUnseenEventsBySession: [UUID: [SyncedTranscriptEvent]] = [:]
    private var coalesceTasksBySession: [UUID: Task<Void, Never>] = [:]
    private var sessionContextByController: [UUID: (title: String, invitationURL: URL?, localNames: [String])] = [:]
    private var busySessions: Set<UUID> = []
    private var manuallyDisabledSessions: Set<UUID> = []
    private var lastSpokeAtBySession: [UUID: Date] = [:]
    private var lastVoiceDeliveryEndedAtBySession: [UUID: Date] = [:]
    private var recentSpokenAnswersBySession: [UUID: [String]] = [:]
    private var activePartialEventIDsBySession: [UUID: Set<String>] = [:]
    private var speakingSessions: Set<UUID> = []
    private var speechCancelEpochBySession: [UUID: UInt64] = [:]
    private var speechActivityEpochBySession: [UUID: UInt64] = [:]
    private var turnExecutedWriteToolBySession: [UUID: Bool] = [:]
    private var activeSpeechTaskBySession: [UUID: Task<Void, Never>] = [:]
    private var activeSpeechTokenBySession: [UUID: UUID] = [:]
    private var realtimeSessions: [UUID: SessionRealtimeState] = [:]

    init(
        skills: IOSAssistantSkillsController,
        workspace: IOSWorkspaceCoordinator?,
        board: IOSAssistantBoardController?,
        resolveBridge: @escaping (UUID) -> IOSAssistantSessionBridge?
    ) {
        self.skills = skills
        self.workspace = workspace
        self.board = board
        self.resolveBridge = resolveBridge
    }

    func queuePendingSkill(_ skillID: String, title: String?, invitation: URL?) {
        let slug = AssistantSkill.sanitizedSlug(from: skillID)
        guard !slug.isEmpty else { return }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingSkillByTitleOrURL[title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = slug
        }
        if let invitation {
            pendingSkillByTitleOrURL[invitation.absoluteString.lowercased()] = slug
        }
    }

    func skillDisplayName(for skillID: String) -> String {
        skills?.skills.first(where: { $0.id == skillID })?.name
            ?? DefaultAssistantSkills.skill(id: skillID)?.name
            ?? skillID
    }

    func recommendedSkillID(for meetingTitle: String) -> String? {
        skills?.skills.first(where: {
            $0.enabled && $0.matches(meetingTitle: meetingTitle, commandText: "")
        })?.id
    }

    private func resolveSkillID(explicitSkillID: String?, meetingTitle: String) -> String {
        if let explicit = explicitSkillID.map(AssistantSkill.sanitizedSlug(from:)), !explicit.isEmpty {
            return explicit
        }
        if let autoMatched = recommendedSkillID(for: meetingTitle) {
            return autoMatched
        }
        return skills?.selectedSkillIDs.first ?? "scrum-master"
    }

    func enable(
        controllerID: UUID,
        title: String,
        skillID: String? = nil,
        trigger: String = "manual",
        suppressAutoGreet: Bool = false
    ) {
        manuallyDisabledSessions.remove(controllerID)
        let chosen = resolveSkillID(explicitSkillID: skillID, meetingTitle: title)
        activeSessionSkills[controllerID] = chosen
        AppDiagnostics.log("assistant-facilitator-enable", [
            "skill": chosen,
            "trigger": trigger
        ])
        let recentIDs = (recentEventsBySession[controllerID] ?? []).map(\.id)
        seenEventIDsBySession[controllerID] = Set(recentIDs)
        seenEventOrderBySession[controllerID] = recentIDs
        pendingUnseenEventsBySession.removeValue(forKey: controllerID)
        coalesceTasksBySession.removeValue(forKey: controllerID)?.cancel()
        let skill = skills?.skills.first(where: { $0.id == chosen })
        lastStatusBySession[controllerID] = L("Autonomous voice facilitator active (%@)", skill?.name ?? chosen)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resolveBridge(controllerID)?.ensureFacilitatorTranscription()
            guard !self.manuallyDisabledSessions.contains(controllerID),
                  self.activeSessionSkills[controllerID] == chosen else { return }
            await self.maybeConnectRealtime(controllerID: controllerID, title: title, skill: skill, skillID: chosen)
            guard !self.manuallyDisabledSessions.contains(controllerID),
                  self.activeSessionSkills[controllerID] == chosen else { return }
            if !suppressAutoGreet, skill?.autoGreet == true {
                await self.kickOffSkill(controllerID: controllerID, title: title, skillID: chosen)
            }
        }
    }

    private func teardownRealtimeSession(controllerID: UUID) async {
        resolveBridge(controllerID)?.setRealtimeAudioTap(nil)
        if let state = realtimeSessions.removeValue(forKey: controllerID) {
            state.turnTimeoutTask?.cancel()
            state.gate.senderTask?.cancel()
            state.gate.coalescer?.finish()
            await state.router.stop()
        }
    }

    func disable(controllerID: UUID) {
        manuallyDisabledSessions.insert(controllerID)
        let removedSkill = activeSessionSkills.removeValue(forKey: controllerID)
        if let removedSkill {
            AppDiagnostics.log("assistant-facilitator-disable", ["skill": removedSkill])
        }
        coalesceTasksBySession.removeValue(forKey: controllerID)?.cancel()
        pendingUnseenEventsBySession.removeValue(forKey: controllerID)
        sessionContextByController.removeValue(forKey: controllerID)
        seenEventIDsBySession.removeValue(forKey: controllerID)
        seenEventOrderBySession.removeValue(forKey: controllerID)
        recentEventsBySession.removeValue(forKey: controllerID)
        lastStatusBySession.removeValue(forKey: controllerID)
        lastSpokeAtBySession.removeValue(forKey: controllerID)
        lastVoiceDeliveryEndedAtBySession.removeValue(forKey: controllerID)
        recentSpokenAnswersBySession.removeValue(forKey: controllerID)
        activePartialEventIDsBySession.removeValue(forKey: controllerID)
        speechActivityEpochBySession.removeValue(forKey: controllerID)
        turnExecutedWriteToolBySession.removeValue(forKey: controllerID)
        activeSpeechTokenBySession.removeValue(forKey: controllerID)
        cancelActiveSpeechForBargeIn(controllerID: controllerID)
        busySessions.remove(controllerID)
        resolveBridge(controllerID)?.setRealtimeAudioTap(nil)
        if let state = realtimeSessions.removeValue(forKey: controllerID) {
            state.turnTimeoutTask?.cancel()
            state.gate.senderTask?.cancel()
            state.gate.coalescer?.finish()
            Task { await state.router.stop() }
        }
        syncRealtimeActiveFlag()
        Task { @MainActor [weak self] in
            await self?.resolveBridge(controllerID)?.releaseFacilitatorTranscription()
        }
    }

    /// Attaches any queued skill or matching voice-activated skill immediately on call connect.
    func sessionConnected(controllerID: UUID) {
        guard let bridge = resolveBridge(controllerID) else { return }
        attachPendingSkillIfNeeded(
            controllerID: controllerID,
            title: bridge.title,
            roomURLString: bridge.roomKey
        )
    }

    /// Re-evaluates queued/title-matched skills when a room reports a real title after connect.
    func sessionTitleUpdated(controllerID: UUID, title: String) {
        let roomKey = resolveBridge(controllerID)?.roomKey ?? ""
        attachPendingSkillIfNeeded(
            controllerID: controllerID,
            title: title,
            roomURLString: roomKey
        )
    }

    /// Cleans up per-session buffers and Realtime WebSockets when a meeting ends.
    func sessionEnded(controllerID: UUID) {
        manuallyDisabledSessions.remove(controllerID)
        activeSessionSkills.removeValue(forKey: controllerID)
        coalesceTasksBySession.removeValue(forKey: controllerID)?.cancel()
        pendingUnseenEventsBySession.removeValue(forKey: controllerID)
        sessionContextByController.removeValue(forKey: controllerID)
        seenEventIDsBySession.removeValue(forKey: controllerID)
        seenEventOrderBySession.removeValue(forKey: controllerID)
        recentEventsBySession.removeValue(forKey: controllerID)
        lastStatusBySession.removeValue(forKey: controllerID)
        lastSpokeAtBySession.removeValue(forKey: controllerID)
        lastSpokenAnswerBySession.removeValue(forKey: controllerID)
        lastVoiceDeliveryEndedAtBySession.removeValue(forKey: controllerID)
        recentSpokenAnswersBySession.removeValue(forKey: controllerID)
        activePartialEventIDsBySession.removeValue(forKey: controllerID)
        speechActivityEpochBySession.removeValue(forKey: controllerID)
        turnExecutedWriteToolBySession.removeValue(forKey: controllerID)
        activeSpeechTokenBySession.removeValue(forKey: controllerID)
        cancelActiveSpeechForBargeIn(controllerID: controllerID)
        busySessions.remove(controllerID)
        resolveBridge(controllerID)?.setRealtimeAudioTap(nil)
        if let state = realtimeSessions.removeValue(forKey: controllerID) {
            state.turnTimeoutTask?.cancel()
            state.gate.senderTask?.cancel()
            state.gate.coalescer?.finish()
            Task { await state.router.stop() }
        }
        syncRealtimeActiveFlag()
    }

    func kickOffSkill(controllerID: UUID, title: String, skillID: String? = nil) async {
        guard !busySessions.contains(controllerID) else { return }
        busySessions.insert(controllerID)
        let activeID = skillID ?? activeSessionSkills[controllerID] ?? "scrum-master"
        let skillName = skills?.skills.first(where: { $0.id == activeID })?.name ?? activeID
        let prompt = L("Briefly greet the meeting and kick off your role (%@) in 1–2 crisp sentences.", skillName)
        let speaker = resolveBridge(controllerID)?.localDisplayName ?? L("You")
        await handleVoiceTurn(
            controllerID: controllerID,
            title: title,
            skillID: activeID,
            speakerName: speaker,
            isLocalSpeaker: true,
            commandText: prompt
        )
    }

    private func mergeRecentEvents(_ incoming: [SyncedTranscriptEvent], for controllerID: UUID) {
        guard !incoming.isEmpty else { return }
        var rolling = recentEventsBySession[controllerID] ?? []
        for event in incoming {
            guard event.kind == "transcript" || event.kind == "chat" else { continue }
            let cleanText = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            if let existingIndex = rolling.firstIndex(where: { $0.id == event.id }) {
                rolling[existingIndex] = event
            } else {
                rolling.append(event)
            }
        }
        rolling.sort {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id < $1.id
        }
        if rolling.count > Self.maxRecentEventsPerSession {
            rolling.removeFirst(rolling.count - Self.maxRecentEventsPerSession)
        }
        recentEventsBySession[controllerID] = rolling
    }

    private func markEventsSeen(_ events: [SyncedTranscriptEvent], for controllerID: UUID) {
        guard !events.isEmpty else { return }
        var seen = seenEventIDsBySession[controllerID] ?? []
        var order = seenEventOrderBySession[controllerID] ?? []
        for line in events where seen.insert(line.id).inserted {
            order.append(line.id)
        }
        if order.count > Self.maxSeenEventIDsPerSession {
            let overflow = order.count - Self.maxSeenEventIDsPerSession
            for staleID in order.prefix(overflow) {
                seen.remove(staleID)
            }
            order.removeFirst(overflow)
        }
        seenEventIDsBySession[controllerID] = seen
        seenEventOrderBySession[controllerID] = order
    }

    private func recordSpokenAnswer(_ text: String, for controllerID: UUID) {
        lastSpokeAtBySession[controllerID] = Date()
        lastSpokenAnswerBySession[controllerID] = text
        var history = recentSpokenAnswersBySession[controllerID] ?? []
        if history.last != text {
            history.append(text)
            if history.count > 3 {
                history.removeFirst(history.count - 3)
            }
            recentSpokenAnswersBySession[controllerID] = history
        }
    }

    private func recentEchoCandidates(for controllerID: UUID) -> [String] {
        if let history = recentSpokenAnswersBySession[controllerID], !history.isEmpty {
            return history
        }
        if let last = lastSpokenAnswerBySession[controllerID]?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            return [last]
        }
        return []
    }

    private func isWithinEchoWindow(for controllerID: UUID, at now: Date = Date()) -> Bool {
        if speakingSessions.contains(controllerID) {
            return true
        }
        if let endedAt = lastVoiceDeliveryEndedAtBySession[controllerID],
           now.timeIntervalSince(endedAt) <= 6 {
            return true
        }
        if let spokenAt = lastSpokeAtBySession[controllerID],
           now.timeIntervalSince(spokenAt) <= 6 {
            return true
        }
        return false
    }

    func updatePartialActivity(controllerID: UUID, partialEventIDs: Set<String>) {
        let previous = activePartialEventIDsBySession[controllerID] ?? []
        activePartialEventIDsBySession[controllerID] = partialEventIDs
        if !partialEventIDs.subtracting(previous).isEmpty, speakingSessions.contains(controllerID) {
            cancelActiveSpeechForBargeIn(controllerID: controllerID)
        }
        if partialEventIDs.isEmpty && !previous.isEmpty {
            schedulePendingTurnIfNeeded(controllerID: controllerID)
        }
    }

    func handleExternalVoiceBargeIn(controllerID: UUID) {
        cancelActiveSpeechForBargeIn(controllerID: controllerID)
    }

    private func cancelActiveSpeechForBargeIn(controllerID: UUID) {
        speechCancelEpochBySession[controllerID, default: 0] &+= 1
        let wasSpeaking = speakingSessions.remove(controllerID) != nil
        activeSpeechTaskBySession.removeValue(forKey: controllerID)?.cancel()
        if wasSpeaking {
            IOSVoicePreviewPlayer.shared.stop()
            resolveBridge(controllerID)?.cancelVoiceReplyForBargeIn()
            lastStatusBySession[controllerID] = L("Listening…")
        }
        if let rtState = realtimeSessions[controllerID], rtState.responseInProgress {
            rtState.turnTimeoutTask?.cancel()
            rtState.turnTimeoutTask = nil
            rtState.responseInProgress = false
            rtState.audioChunks.removeAll()
            rtState.transcriptBuffer = ""
            busySessions.remove(controllerID)
        }
    }

    private func waitForSpeakerSilence(controllerID: UUID) async {
        guard maxSilenceWaitDuration > .zero, silencePollInterval > .zero else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxSilenceWaitDuration)
        while !Task.isCancelled && clock.now < deadline {
            let hasPartials = !(activePartialEventIDsBySession[controllerID]?.isEmpty ?? true)
            let humanSpeaking = resolveBridge(controllerID)?.isHumanSpeaking() ?? false
            if !hasPartials && !humanSpeaking {
                return
            }
            try? await clock.sleep(for: silencePollInterval)
        }
    }

    func observeEvents(
        controllerID: UUID,
        title: String,
        invitationURL: URL?,
        events: [SyncedTranscriptEvent],
        localNames: [String]
    ) {
        sessionContextByController[controllerID] = (title: title, invitationURL: invitationURL, localNames: localNames)
        attachPendingSkillIfNeeded(
            controllerID: controllerID,
            title: title,
            roomURLString: invitationURL?.absoluteString ?? ""
        )

        mergeRecentEvents(events, for: controllerID)
        guard activeSessionSkills[controllerID] != nil else { return }

        let now = Date()
        let inEchoWindow = isWithinEchoWindow(for: controllerID, at: now)
        let recentAnswers = recentEchoCandidates(for: controllerID)

        let seen = seenEventIDsBySession[controllerID] ?? []
        var staged = pendingUnseenEventsBySession[controllerID] ?? []
        var appended = false
        var sawGenuineHumanSpeech = false
        for ev in events {
            guard !seen.contains(ev.id),
                  ev.kind == "transcript" || ev.kind == "chat",
                  !ev.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !AssistantSpeechLedger.isAssistantSpeaker(ev.speaker, role: ev.speakerRole) {
                let clean = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isEcho = AssistantWakePhraseMatcher.isLikelySelfEcho(
                    candidate: clean,
                    recentAssistantUtterances: recentAnswers,
                    isLocal: ev.isOwn,
                    withinEchoWindow: inEchoWindow
                )
                if !isEcho {
                    let stripped = AssistantWakePhraseMatcher.stripAssistantEcho(
                        from: clean,
                        recentAssistantUtterances: recentAnswers,
                        withinEchoWindow: inEchoWindow
                    )
                    if !stripped.isEmpty {
                        sawGenuineHumanSpeech = true
                    }
                }
            }
            if let existingIndex = staged.firstIndex(where: { $0.id == ev.id }) {
                staged[existingIndex] = ev
            } else {
                staged.append(ev)
                appended = true
            }
        }
        if sawGenuineHumanSpeech {
            speechActivityEpochBySession[controllerID, default: 0] &+= 1
            if speakingSessions.contains(controllerID) {
                cancelActiveSpeechForBargeIn(controllerID: controllerID)
            }
        }
        guard !staged.isEmpty else { return }
        pendingUnseenEventsBySession[controllerID] = staged
        if appended || coalesceTasksBySession[controllerID] == nil {
            schedulePendingTurnIfNeeded(controllerID: controllerID)
        }
    }

    private func schedulePendingTurnIfNeeded(controllerID: UUID) {
        guard !busySessions.contains(controllerID),
              activeSessionSkills[controllerID] != nil,
              let staged = pendingUnseenEventsBySession[controllerID],
              !staged.isEmpty else { return }

        let now = Date()
        let inFollowUpWindow = lastSpokeAtBySession[controllerID].map {
            now.timeIntervalSince($0) <= Self.followUpWindowSeconds
        } ?? false
        let inEchoWindow = isWithinEchoWindow(for: controllerID, at: now)
        let recentAnswers = recentEchoCandidates(for: controllerID)

        var hasWake = false
        var hasFollowUp = false
        for ev in staged {
            if AssistantSpeechLedger.isAssistantSpeaker(ev.speaker, role: ev.speakerRole) {
                continue
            }
            let rawClean = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawClean.isEmpty || AssistantWakePhraseMatcher.isLikelySelfEcho(
                candidate: rawClean,
                recentAssistantUtterances: recentAnswers,
                isLocal: ev.isOwn,
                withinEchoWindow: inEchoWindow
            ) {
                continue
            }
            let clean = AssistantWakePhraseMatcher.stripAssistantEcho(
                from: rawClean,
                recentAssistantUtterances: recentAnswers,
                withinEchoWindow: inEchoWindow
            )
            guard !clean.isEmpty else { continue }
            switch AssistantWakePhraseMatcher.match(clean) {
            case .command(let cmd) where !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                hasWake = true
            case .wakeOnly:
                hasWake = true
            default:
                if inFollowUpWindow && clean.count >= 3 {
                    hasFollowUp = true
                }
            }
        }

        if !hasWake && !hasFollowUp {
            if !(activePartialEventIDsBySession[controllerID]?.isEmpty ?? true) {
                return
            }
            markEventsSeen(staged, for: controllerID)
            pendingUnseenEventsBySession.removeValue(forKey: controllerID)
            return
        }

        coalesceTasksBySession.removeValue(forKey: controllerID)?.cancel()
        let baseDelay = hasWake ? wakeCoalesceDelay : followUpCoalesceDelay
        let delay = (!(activePartialEventIDsBySession[controllerID]?.isEmpty ?? true) || (resolveBridge(controllerID)?.isHumanSpeaking() == true))
            ? max(baseDelay, silencePollInterval)
            : baseDelay
        coalesceTasksBySession[controllerID] = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.coalesceTasksBySession.removeValue(forKey: controllerID)
            await self.flushPendingBatchTurn(controllerID: controllerID)
        }
    }

    private func flushPendingBatchTurn(controllerID: UUID) async {
        guard !busySessions.contains(controllerID),
              let skillID = activeSessionSkills[controllerID],
              let initial = pendingUnseenEventsBySession[controllerID],
              !initial.isEmpty else { return }

        await waitForSpeakerSilence(controllerID: controllerID)
        guard !Task.isCancelled,
              !busySessions.contains(controllerID),
              activeSessionSkills[controllerID] == skillID,
              let batch = pendingUnseenEventsBySession.removeValue(forKey: controllerID),
              !batch.isEmpty else { return }

        markEventsSeen(batch, for: controllerID)

        let now = Date()
        let inFollowUpWindow = lastSpokeAtBySession[controllerID].map {
            now.timeIntervalSince($0) <= Self.followUpWindowSeconds
        } ?? false
        let inEchoWindow = isWithinEchoWindow(for: controllerID, at: now)
        let recentAnswers = recentEchoCandidates(for: controllerID)

        var sawWake = false
        var fragments: [String] = []
        var triggerEvent: SyncedTranscriptEvent?
        for ev in batch {
            if AssistantSpeechLedger.isAssistantSpeaker(ev.speaker, role: ev.speakerRole) {
                continue
            }
            let rawClean = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawClean.isEmpty || AssistantWakePhraseMatcher.isLikelySelfEcho(
                candidate: rawClean,
                recentAssistantUtterances: recentAnswers,
                isLocal: ev.isOwn,
                withinEchoWindow: inEchoWindow
            ) {
                continue
            }
            let clean = AssistantWakePhraseMatcher.stripAssistantEcho(
                from: rawClean,
                recentAssistantUtterances: recentAnswers,
                withinEchoWindow: inEchoWindow
            )
            guard !clean.isEmpty else { continue }
            switch AssistantWakePhraseMatcher.match(clean) {
            case .command(let cmd):
                let trimmedCmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedCmd.isEmpty {
                    sawWake = true
                    triggerEvent = ev
                    fragments.append(trimmedCmd)
                }
            case .wakeOnly:
                sawWake = true
                triggerEvent = ev
                fragments.append(clean)
            case .none:
                if inFollowUpWindow && clean.count >= 3 {
                    triggerEvent = ev
                    fragments.append(clean)
                } else if sawWake && clean.count >= 3 {
                    triggerEvent = ev
                    fragments.append(clean)
                }
            }
        }
        guard let trigger = triggerEvent else { return }
        var combinedParts: [String] = []
        for fragment in fragments where !combinedParts.contains(fragment) {
            combinedParts.append(fragment)
        }
        let commandText = combinedParts.joined(separator: "\n")
        guard !commandText.isEmpty else { return }

        let context = sessionContextByController[controllerID]
        let title = context?.title ?? resolveBridge(controllerID)?.title ?? L("Meeting")
        let localNames = context?.localNames ?? []
        let speakerName = trigger.speaker ?? (trigger.isOwn ? L("You") : L("Participant"))

        busySessions.insert(controllerID)
        await handleVoiceTurn(
            controllerID: controllerID,
            title: title,
            skillID: skillID,
            speakerName: speakerName,
            isLocalSpeaker: trigger.isOwn,
            commandText: commandText,
            localNames: localNames
        )
    }

    private func attachPendingSkillIfNeeded(
        controllerID: UUID,
        title: String,
        roomURLString: String
    ) {
        guard activeSessionSkills[controllerID] == nil else { return }
        let urlKey = roomURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let titleKey = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let queued = (!urlKey.isEmpty ? pendingSkillByTitleOrURL.removeValue(forKey: urlKey) : nil)
            ?? (!titleKey.isEmpty ? pendingSkillByTitleOrURL.removeValue(forKey: titleKey) : nil) {
            enable(controllerID: controllerID, title: title, skillID: queued, trigger: "pending")
        } else if !manuallyDisabledSessions.contains(controllerID) {
            let bridge = resolveBridge(controllerID)
            let seriesIDs = [bridge?.calendarSeriesKey, bridge?.localCalendarSeriesKey].compactMap { $0 }
            let roomKeys = [roomURLString, bridge?.roomKey].compactMap { $0 }.filter { !$0.isEmpty }
            if let configuredSkillID = workspace?.autoFacilitatorSkillID(seriesIDs: seriesIDs, roomKeys: roomKeys),
               let configuredSkill = skills?.skills.first(where: { $0.id == configuredSkillID && $0.enabled }) {
                enable(controllerID: controllerID, title: title, skillID: configuredSkill.id, trigger: "meeting-setting")
            } else if skills?.autonomousMeetingVoiceEnabled == true,
                      let matched = skills?.skills.first(where: {
                          $0.enabled && $0.voiceActivation && $0.matches(meetingTitle: title, commandText: "")
                      }) {
                enable(controllerID: controllerID, title: title, skillID: matched.id, trigger: "auto-title")
            }
        }
    }

    // MARK: - Authorization & Execution

    func isSpeakerAuthorized(
        speakerName: String,
        isLocalSpeaker: Bool,
        skill: AssistantSkill?,
        localNames: [String]
    ) -> Bool {
        if isLocalSpeaker { return true }
        let approved = skills?.people.isApprovedSpeaker(speakerName, localUserNames: localNames) ?? false
        if approved { return true }
        return skill?.approvedSpeakersOnly == false
    }

    func handleVoiceTurn(
        controllerID: UUID,
        title: String,
        skillID: String,
        speakerName: String,
        isLocalSpeaker: Bool,
        commandText: String,
        localNames: [String] = []
    ) async {
        defer {
            busySessions.remove(controllerID)
            schedulePendingTurnIfNeeded(controllerID: controllerID)
        }
        guard let skills else { return }
        let skill = skills.skills.first(where: { $0.id == skillID })
        let allLocalNames = localNames + [resolveBridge(controllerID)?.localDisplayName ?? ""] + (workspace?.taskProfile.aliases ?? [])
        let allowWrites = isSpeakerAuthorized(
            speakerName: speakerName,
            isLocalSpeaker: isLocalSpeaker,
            skill: skill,
            localNames: allLocalNames
        )

        let hasWakeInBatch = commandText
            .components(separatedBy: .newlines)
            .contains { AssistantWakePhraseMatcher.match($0) != .none }
        if !allowWrites, !hasWakeInBatch {
            if lastSpokeAtBySession[controllerID] != nil && !isLocalSpeaker {
                return
            }
        }

        // 1. Optional Realtime acceleration if connected for this call.
        if let rtState = realtimeSessions[controllerID],
           await rtState.router.isRealtimeConnected {
            rtState.gate.setTurnApproval(allowWrites: allowWrites, approvedTranscriptAt: allowWrites ? Date() : nil)
            rtState.activeSkillID = skillID
            rtState.gate.setApprovedSpeakersOnly(skill?.approvedSpeakersOnly ?? true)
            if rtState.responseInProgress
                || !rtState.audioChunks.isEmpty
                || !rtState.transcriptBuffer.isEmpty
                || rtState.gate.recentlyForwardedAudio(within: 3.0) {
                return
            }
            let prefixedPrompt = "[\(speakerName) (approved=\(allowWrites)) in “\(title)”]: \(commandText)"
            if await rtState.router.sendText(prefixedPrompt) {
                AppDiagnostics.log("assistant-facilitator-turn", [
                    "skill": skillID,
                    "route": "realtime",
                    "allowWrites": allowWrites
                ])
                lastStatusBySession[controllerID] = L("Realtime model handling request…")
                rtState.turnTimeoutTask?.cancel()
                rtState.turnTimeoutTask = Task { @MainActor [weak self, weak rtState] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, let rtState, !Task.isCancelled else { return }
                    let text = AssistantSpeechLedger.sanitizeSpokenReply(rtState.transcriptBuffer)
                    rtState.transcriptBuffer = ""
                    if !text.isEmpty {
                        await self.speakIntoMeeting(text, controllerID: controllerID)
                    }
                }
                return
            }
        }

        // 2. Standard AI + deterministic iOS tool loop fallback.
        let turnEpoch = speechActivityEpochBySession[controllerID, default: 0]
        turnExecutedWriteToolBySession[controllerID] = false
        let reply = await executeStandardTurn(
            controllerID: controllerID,
            title: title,
            skillID: skillID,
            speakerName: speakerName,
            allowWrites: allowWrites,
            commandText: commandText
        )
        if !reply.isEmpty {
            await waitForSpeakerSilence(controllerID: controllerID)
            guard activeSessionSkills[controllerID] != nil,
                  !manuallyDisabledSessions.contains(controllerID) else { return }
            let didMutate = turnExecutedWriteToolBySession[controllerID] ?? false
            let hasNewPending = !(pendingUnseenEventsBySession[controllerID]?.isEmpty ?? true)
            let activityAdvanced = speechActivityEpochBySession[controllerID, default: 0] != turnEpoch
            if !didMutate && (activityAdvanced && hasNewPending) {
                return
            }
            if !didMutate && ((resolveBridge(controllerID)?.isHumanSpeaking() ?? false) || !(activePartialEventIDsBySession[controllerID]?.isEmpty ?? true)) {
                return
            }
            await speakIntoMeeting(reply, controllerID: controllerID)
        }
    }

    func executeStandardTurn(
        controllerID: UUID,
        title: String,
        skillID: String,
        speakerName: String,
        allowWrites: Bool,
        commandText: String
    ) async -> String {
        guard let skills, let workspace else { return "" }
        let lower = commandText.lowercased().replacingOccurrences(of: "ё", with: "е")
        let rendered = skills.renderPromptContext(
            explicitSkillIDs: [skillID],
            meetingTitle: title,
            commandText: commandText
        )
        let skillToolSet = rendered.selectedSkills.first.map { Set($0.tools) }
        let allowedGroups = Set(rendered.selectedSkills.flatMap(\.tools))
        let resolvedSessionID = workspace.workspaceSessionID(forControllerID: controllerID)
        let jiraConfig = workspace.resolvedJiraBoardConfig(
            for: resolvedSessionID,
            defaultBoardURL: skills.teamContext.defaultJiraBoardURL,
            defaultProjectKey: skills.teamContext.defaultJiraProjectKey,
            lastBoardURL: skills.lastBoardURL,
            jiraSettings: workspace.taskSync.preferences.jira
        )
        let boardDerivedKeys = await workspace.taskSync.resolveBoardDerivedProjectKeys()
        let globalFallbackKeys = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: [
            skills.teamContext.defaultJiraProjectKey,
            workspace.taskSync.preferences.jira.cleanProjectKey
        ])
        let effectiveProjectKeys = WorkspaceTaskSyncController.resolvedEffectiveJiraProjectKeys(
            configured: jiraConfig.projectKeys,
            globalFallback: globalFallbackKeys,
            boardDerived: boardDerivedKeys
        )
        let effectiveBoardURL = jiraConfig.boardURL?.absoluteString ?? skills.teamContext.defaultJiraBoardURL

        // Direct deterministic board controls when allowed
        if (allowedGroups.isEmpty || allowedGroups.contains(.boardShare)),
           let boardReply = await Self.handleDeterministicBoardCommand(
               commandText,
               board: board,
               defaultBoardURL: effectiveBoardURL,
               targetID: controllerID,
               people: skills.people
           ) {
            turnExecutedWriteToolBySession[controllerID] = true
            AppDiagnostics.log("assistant-facilitator-turn", [
                "skill": skillID,
                "route": "deterministic-board",
                "allowWrites": allowWrites
            ])
            return boardReply
        }

        // Direct deterministic task creation by approved speaker when allowed
        if allowWrites && (allowedGroups.isEmpty || allowedGroups.contains(.tasks)),
           let extractedTask = Self.extractDirectTaskInstruction(from: commandText, lower: lower) {
            if let created = await skills.createTaskDetailedWithPeopleResolution(
                sessionID: resolvedSessionID,
                title: extractedTask.title,
                owner: extractedTask.owner ?? speakerName
            ) {
                turnExecutedWriteToolBySession[controllerID] = true
                AppDiagnostics.log("assistant-facilitator-turn", [
                    "skill": skillID,
                    "route": "deterministic-task",
                    "allowWrites": allowWrites
                ])
                if created.alreadyExisted {
                    return created.resolvedOwner.isEmpty
                        ? L("Task “%@” is already on the list.", created.resolvedTitle)
                        : L("Task “%@” for %@ is already on the list.", created.resolvedTitle, created.resolvedOwner)
                }
                return created.resolvedOwner.isEmpty
                    ? L("Created task “%@”.", created.resolvedTitle)
                    : L("Created task “%@” for %@.", created.resolvedTitle, created.resolvedOwner)
            }
        }

        // LLM answer grounded in transcript + Obsidian knowledge + BasePersona + skill instructions
        let knowledgeHits = await skills.searchKnowledgeAsync(query: commandText, limit: 5)
            .map { "[\($0.kind)] \($0.title): \($0.excerpt)" }
            .joined(separator: "\n")
        let youLabel = L("You")
        let transcriptLines = (recentEventsBySession[controllerID] ?? []).suffix(35).map { ev in
            let speaker = AssistantSpeechLedger.displayAuthor(
                speaker: ev.speaker,
                isOwn: ev.isOwn,
                speakerRole: ev.speakerRole,
                youLabel: youLabel
            )
            return "\(speaker): \(ev.text)"
        }.joined(separator: "\n")
        let bridge = resolveBridge(controllerID)
        let meetingParticipants = bridge.map {
            AssistantPersonEntry.deduped([$0.localDisplayName] + $0.participantNames)
        } ?? []
        let identityGuidance = DefaultAssistantPrompts.jiraIdentityResolutionGuidance(meetingParticipants: meetingParticipants)
        let boardRuntimeContext = """
        Live Board & Jira Context:
        - board_open: \(board?.currentURL != nil)
        - board_current_url: \(board?.currentURL?.absoluteString ?? "none")
        - board_sharing: \(board?.isSharing == true), reconnecting: \(board?.isRecoveringShare == true)
        - effective_jira_board_url: \(effectiveBoardURL.isEmpty ? "none" : effectiveBoardURL)
        - effective_jira_project_keys: \(effectiveProjectKeys.isEmpty ? "none" : effectiveProjectKeys.joined(separator: ", "))
        - board_derived_project_keys: \(boardDerivedKeys.isEmpty ? "none" : boardDerivedKeys.joined(separator: ", "))
        - participants: \(meetingParticipants.isEmpty ? "unknown" : meetingParticipants.joined(separator: ", "))
        """

        let sys = """
        \(rendered.basePersona)

        \(rendered.instructions)

        \(identityGuidance)

        \(boardRuntimeContext)

        Voice & Facilitation Rules:
        - Keep spoken replies crisp (1–3 sentences) in the meeting language so they sound natural over voice.
        - Never repeat a sentence or paragraph, and never output Markdown syntax such as backticks (`KEY-1`) or bold (`**`) in spoken answers.
        - When facilitating a standup/daily, move through participants step-by-step (yesterday, today, blockers) and offer the next clear prompt rather than repeating the same question.
        - If a participant asks to apply a quick/person filter on the board, call rocknroll_control_board(command="select_person_filter", query="<name>") or clear_filters; if they ask to share or stop sharing the board, call share_to_meeting or stop_share.
        Speaker: \(speakerName) (authorized_for_writes=\(allowWrites)).
        Never claim to have modified external tasks, summaries, calendar events, or People.md unless confirmed by a tool call result.
        """
        let usr = """
        Meeting: \(title)
        Team Knowledge Matches:
        \(knowledgeHits.isEmpty ? "None" : knowledgeHits)

        Recent Transcript:
        \(transcriptLines)

        Request: \(commandText)
        """

        let toolDeclarations = Self.buildToolDeclarations(allowedGroups: skillToolSet)
        if let config = try? workspace.permittedAIConfiguration(),
           let answer = await callLLMWithTools(
            systemPrompt: sys,
            userPrompt: usr,
            configuration: config,
            apiKey: workspace.readAPIKey(for: config.providerKind),
            tools: toolDeclarations,
            toolExecutor: { [weak self] name, argsJSON in
                guard let self else { return "{}" }
                if name == "rocknroll_create_task"
                    || name == "rocknroll_update_task"
                    || name == "rocknroll_update_meeting_artifacts"
                    || name == "rocknroll_schedule_meeting"
                    || name == "rocknroll_people_directory" {
                    self.turnExecutedWriteToolBySession[controllerID] = true
                } else if name == "rocknroll_jira_action" || name == "rocknroll_control_board" {
                    let lowerArgs = argsJSON.lowercased()
                    if !lowerArgs.contains("\"search\"") && !lowerArgs.contains("\"inspect\"") && !lowerArgs.contains("\"board_users\"") {
                        self.turnExecutedWriteToolBySession[controllerID] = true
                    }
                }
                return await Self.executeSharedTool(
                    name: name,
                    argumentsJSON: argsJSON,
                    sessionID: resolvedSessionID,
                    controllerID: controllerID,
                    allowWrites: allowWrites,
                    allowedGroups: skillToolSet,
                    skills: skills,
                    workspace: self.workspace,
                    board: self.board,
                    meetingParticipants: meetingParticipants
                )
            }
           ) {
            let cleanAnswer = AssistantSpeechLedger.sanitizeSpokenReply(answer)
            if !cleanAnswer.isEmpty {
                AppDiagnostics.log("assistant-facilitator-turn", [
                    "skill": skillID,
                    "route": "llm",
                    "allowWrites": allowWrites
                ])
                return cleanAnswer
            }
        }

        AppDiagnostics.log("assistant-facilitator-turn", [
            "skill": skillID,
            "route": "fallback",
            "allowWrites": allowWrites
        ])
        if !knowledgeHits.isEmpty {
            return knowledgeHits
        }
        return L("Got it, %@. I'm listening.", speakerName)
    }

    // MARK: - Realtime Per-Session Helpers

    private func maybeConnectRealtime(
        controllerID: UUID,
        title: String,
        skill: AssistantSkill?,
        skillID: String
    ) async {
        guard let skills else { return }
        let kind = skills.realtimeProvider
        guard kind != .disabled,
              let apiKey = skills.realtimeAPIKey(for: kind),
              !apiKey.isEmpty else {
            syncRealtimeActiveFlag()
            return
        }

        await teardownRealtimeSession(controllerID: controllerID)

        let rendered = skills.renderPromptContext(explicitSkillIDs: [skillID], meetingTitle: title)
        let bridge = resolveBridge(controllerID)
        let meetingParticipants = bridge.map {
            AssistantPersonEntry.deduped([$0.localDisplayName] + $0.participantNames)
        } ?? []
        let identityGuidance = DefaultAssistantPrompts.jiraIdentityResolutionGuidance(meetingParticipants: meetingParticipants)
        let sid = workspace?.workspaceSessionID(forControllerID: controllerID)
        let jiraConfig = workspace?.resolvedJiraBoardConfig(
            for: sid,
            defaultBoardURL: skills.teamContext.defaultJiraBoardURL,
            defaultProjectKey: skills.teamContext.defaultJiraProjectKey,
            lastBoardURL: skills.lastBoardURL,
            jiraSettings: workspace?.taskSync.preferences.jira ?? .init()
        )
        let boardDerivedKeys = await workspace?.taskSync.resolveBoardDerivedProjectKeys() ?? []
        let globalFallbackKeys = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: [
            skills.teamContext.defaultJiraProjectKey,
            workspace?.taskSync.preferences.jira.cleanProjectKey ?? ""
        ])
        let mergedKeys = WorkspaceTaskSyncController.resolvedEffectiveJiraProjectKeys(
            configured: jiraConfig?.projectKeys ?? globalFallbackKeys,
            globalFallback: globalFallbackKeys,
            boardDerived: boardDerivedKeys
        )
        let boardLine = "Effective Jira board URL: \(jiraConfig?.boardURL?.absoluteString ?? skills.teamContext.defaultJiraBoardURL). Effective project keys: \(mergedKeys.joined(separator: ", ")). Board-derived project keys: \(boardDerivedKeys.joined(separator: ", "))."
        let instructions = [rendered.basePersona, rendered.instructions, identityGuidance, boardLine]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let tools = Self.buildToolDeclarations(allowedGroups: skill.map { Set($0.tools) })
        let targetInputRate = kind.defaultInputSampleRate
        let config = RealtimeSessionConfig(
            provider: kind,
            apiKey: apiKey,
            model: skills.realtimeModel,
            voice: skills.realtimeVoice,
            endpointOverride: skills.realtimeEndpoint,
            systemInstructions: instructions,
            inputSampleRate: targetInputRate,
            tools: tools,
            folderID: skills.realtimeFolderID,
            voiceRole: skills.realtimeVoiceRole
        )

        let state = SessionRealtimeState(
            activeSkillID: skillID,
            provider: kind,
            outputSampleRate: Double(config.outputSampleRate)
        )
        state.gate.setApprovedSpeakersOnly(skill?.approvedSpeakersOnly ?? true)
        realtimeSessions[controllerID] = state
        AppDiagnostics.log("assistant-facilitator-realtime", [
            "provider": kind.rawValue,
            "state": "connecting",
            "inputSampleRate": targetInputRate,
            "outputSampleRate": Int(config.outputSampleRate)
        ])
        await state.router.start(
            config: config,
            customTransport: customRealtimeTransportFactory?(),
            executeTool: { [weak self] name, argsJSON in
                guard let self else { return "{}" }
                return await self.executeRealtimeTool(controllerID: controllerID, name: name, argumentsJSON: argsJSON)
            },
            onEvent: { [weak self, weak state] event in
                guard let self, let state else { return }
                await self.handleRealtimeEvent(event, controllerID: controllerID, state: state)
            }
        )
        state.connected = await state.router.isRealtimeConnected
        guard realtimeSessions[controllerID] === state else {
            await state.router.stop()
            syncRealtimeActiveFlag()
            return
        }
        if state.connected {
            attachAudioTap(controllerID: controllerID, state: state, targetSampleRate: targetInputRate)
        }
        syncRealtimeActiveFlag()
    }

    private func attachAudioTap(controllerID: UUID, state: SessionRealtimeState, targetSampleRate: Int) {
        let router = state.router
        let gate = state.gate
        let externalVoiceCheck = resolveBridge(controllerID)?.isVoiceReplyInFlightNonisolated
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
        resolveBridge(controllerID)?.setRealtimeAudioTap { [weak gate] streamID, pcm in
            guard let gate else { return }
            let isLocal = (streamID == "local")
            let externalInFlight = isLocal && (externalVoiceCheck?() == true)
            guard gate.shouldAcceptAudio(isLocal: isLocal, externalVoiceReplyInFlight: externalInFlight) else { return }
            coalescer.append(trackID: streamID, pcm16: pcm)
        }
    }

    private func executeRealtimeTool(controllerID: UUID, name: String, argumentsJSON: String) async -> String {
        guard let skills else { return "{\"error\":\"Workspace unavailable\"}" }
        guard let state = realtimeSessions[controllerID] else { return "{\"error\":\"Session closed\"}" }
        let skill = skills.skills.first(where: { $0.id == state.activeSkillID })
        let allowedGroups = skill.map { Set($0.tools) }
        let sid = workspace?.workspaceSessionID(forControllerID: controllerID)
        let bridge = resolveBridge(controllerID)
        let participants = bridge.map {
            AssistantPersonEntry.deduped([$0.localDisplayName] + $0.participantNames)
        } ?? []
        return await Self.executeSharedTool(
            name: name,
            argumentsJSON: argumentsJSON,
            sessionID: sid,
            controllerID: controllerID,
            allowWrites: state.gate.currentAllowWrites(),
            allowedGroups: allowedGroups,
            skills: skills,
            workspace: workspace,
            board: board,
            meetingParticipants: participants
        )
    }

    static func executeSharedTool(
        name: String,
        argumentsJSON: String,
        sessionID: UUID?,
        controllerID: UUID? = nil,
        allowWrites: Bool,
        allowedGroups: Set<AssistantSkillToolGroup>?,
        skills: IOSAssistantSkillsController,
        workspace: IOSWorkspaceCoordinator?,
        board: IOSAssistantBoardController?,
        meetingParticipants: [String] = [],
        directTalkJoinHandler: ((String, String?) async -> String)? = nil,
        joinableTargetsProvider: (() -> [JoinableMeetingCandidate])? = nil
    ) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let command = (args["command"] as? String) ?? (args["operation"] as? String) ?? ""
        let result = await executeSharedToolCore(
            name: name,
            args: args,
            sessionID: sessionID,
            controllerID: controllerID,
            allowWrites: allowWrites,
            allowedGroups: allowedGroups,
            skills: skills,
            workspace: workspace,
            board: board,
            meetingParticipants: meetingParticipants,
            directTalkJoinHandler: directTalkJoinHandler,
            joinableTargetsProvider: joinableTargetsProvider
        )
        AppDiagnostics.log("assistant-facilitator-tool", [
            "tool": name,
            "command": command,
            "ok": !result.contains("\"error\"")
        ])
        return result
    }

    private static func executeSharedToolCore(
        name: String,
        args: [String: Any],
        sessionID: UUID?,
        controllerID: UUID?,
        allowWrites: Bool,
        allowedGroups: Set<AssistantSkillToolGroup>?,
        skills: IOSAssistantSkillsController,
        workspace: IOSWorkspaceCoordinator?,
        board: IOSAssistantBoardController?,
        meetingParticipants: [String],
        directTalkJoinHandler: ((String, String?) async -> String)?,
        joinableTargetsProvider: (() -> [JoinableMeetingCandidate])?
    ) async -> String {
        func allows(_ group: AssistantSkillToolGroup) -> Bool {
            allowedGroups?.contains(group) ?? true
        }

        let jiraConfig = workspace?.resolvedJiraBoardConfig(
            for: sessionID,
            defaultBoardURL: skills.teamContext.defaultJiraBoardURL,
            defaultProjectKey: skills.teamContext.defaultJiraProjectKey,
            lastBoardURL: skills.lastBoardURL,
            jiraSettings: workspace?.taskSync.preferences.jira ?? .init()
        )
        let boardDerivedKeys = await workspace?.taskSync.resolveBoardDerivedProjectKeys() ?? []
        let globalFallbackKeys = SyncedMeetingContextSettings.normalizedJiraProjectKeys(from: [
            skills.teamContext.defaultJiraProjectKey,
            workspace?.taskSync.preferences.jira.cleanProjectKey ?? ""
        ])
        let configuredKeys = jiraConfig?.projectKeys ?? globalFallbackKeys
        let effectiveProjectKeys = WorkspaceTaskSyncController.resolvedEffectiveJiraProjectKeys(
            configured: configuredKeys,
            globalFallback: globalFallbackKeys,
            boardDerived: boardDerivedKeys
        )
        let allProjectCandidates = effectiveProjectKeys + boardDerivedKeys.filter { !effectiveProjectKeys.contains($0) }
        let effectiveBoardURL = jiraConfig?.boardURL?.absoluteString ?? skills.teamContext.defaultJiraBoardURL

        switch name {
        case "rocknroll_search_knowledge":
            let q = (args["query"] as? String) ?? ""
            let limit = (args["limit"] as? Int) ?? 8
            var items = await skills.searchKnowledgeAsync(query: q, limit: limit).map {
                ["source": "obsidian", "title": $0.title, "path": $0.relativePath, "excerpt": $0.excerpt]
            }
            if let workspace, items.count < limit {
                let hits = await workspace.search(query: q)
                for hit in hits.prefix(max(0, limit - items.count)) {
                    items.append([
                        "source": "meeting",
                        "title": hit.title,
                        "path": hit.startedAt.formatted(date: .abbreviated, time: .shortened),
                        "excerpt": hit.snippet
                    ])
                }
            }
            return jsonString(["items": items])

        case "rocknroll_manage_people":
            let op = (args["operation"] as? String) ?? "lookup"
            if op == "upsert" {
                guard let display = (args["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !display.isEmpty else {
                    return "{\"error\":\"display_name required\"}"
                }
                let rawAliases = (args["aliases"] as? [String])
                    ?? ((args["aliases"] as? String).map {
                        $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } ?? [])
                let jiraUser = (args["jira_username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let jiraAccount = (args["jira_account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let forceWithoutJira = (args["force_without_jira"] as? Bool) ?? false
                let existingMatch = skills.people.resolvePerson(matching: display)
                let hasExistingHandle = !((existingMatch?.jiraAccountID ?? existingMatch?.jiraUsername ?? "").isEmpty)
                let hasNewHandle = !(jiraUser ?? "").isEmpty || !(jiraAccount ?? "").isEmpty

                if !hasNewHandle && !hasExistingHandle && !forceWithoutJira && skills.isJiraConnected {
                    let candidates = (try? await skills.searchJiraUsers(query: display, maxResults: 8)) ?? []
                    return jsonString([
                        "saved": false,
                        "needs_user_confirmation": true,
                        "display_name": display,
                        "jira_user_candidates": candidates.map(WorkspaceTaskSyncController.jiraUserPayload),
                        "instruction": candidates.isEmpty
                            ? "No Jira user matched automatically. Ask the user for their Jira username/email or offer to copy it from a task on the board via rocknroll_jira_action(operation='copy_user_from_issue'). Only pass force_without_jira=true if they do not have a Jira account."
                            : "Ask the user which of these Jira candidates matches \(display), then call upsert with jira_username/jira_account_id."
                    ])
                }

                let explicitApproved = args["approved_voice_commander"] as? Bool
                let allowPrivilegeChange = allowWrites && (explicitApproved != nil)
                let entry = AssistantPersonEntry(
                    displayName: display,
                    aliases: rawAliases,
                    jiraUsername: jiraUser,
                    jiraAccountID: jiraAccount,
                    email: args["email"] as? String,
                    role: args["role"] as? String,
                    approvedVoiceCommander: allowPrivilegeChange ? (explicitApproved ?? false) : false,
                    notes: args["notes"] as? String
                )
                let updated = try? skills.upsertPerson(entry, allowPrivilegeChange: allowPrivilegeChange)
                return jsonString([
                    "saved": updated != nil,
                    "display_name": display,
                    "jira_bound": hasNewHandle || hasExistingHandle
                ])
            } else if op == "remove" {
                guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let targetName = (args["display_name"] as? String) ?? (args["query"] as? String) ?? ""
                let personID = id ?? skills.people.resolvePerson(matching: targetName)?.id
                guard let personID, !personID.isEmpty else {
                    return "{\"error\":\"Person not found\"}"
                }
                let updated = try? skills.removePerson(id: personID)
                return jsonString(["removed": updated != nil, "id": personID])
            }
            let q = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let matches: [AssistantPersonEntry] = q.isEmpty
                ? skills.people.entries
                : (skills.people.resolvePerson(matching: q).map { [$0] } ?? [])
            let participantRows: [[String: Any]] = AssistantPersonEntry.deduped(meetingParticipants).map { participantName in
                let matched = skills.people.resolvePerson(matching: participantName)
                return [
                    "name": participantName,
                    "matched_id": matched?.id ?? "",
                    "jira_username": matched?.jiraUsername ?? "",
                    "jira_account_id": matched?.jiraAccountID ?? ""
                ]
            }
            return jsonString([
                "items": matches.map {
                    [
                        "id": $0.id,
                        "display_name": $0.displayName,
                        "aliases": $0.aliases,
                        "jira_username": $0.jiraUsername ?? "",
                        "jira_account_id": $0.jiraAccountID ?? "",
                        "email": $0.email ?? "",
                        "role": $0.role ?? "",
                        "approved_voice_commander": $0.approvedVoiceCommander,
                        "notes": $0.notes ?? ""
                    ] as [String: Any]
                },
                "meeting_participants": participantRows
            ])

        case "rocknroll_create_task":
            guard allowWrites && (allows(.tasks) || allows(.jira)) else { return "{\"error\":\"Task creation not allowed\"}" }
            guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return "{\"error\":\"title required\"}"
            }
            let created = await skills.createTaskDetailedWithPeopleResolution(
                sessionID: sessionID,
                title: title,
                owner: args["owner"] as? String,
                dueDay: args["due_day"] as? String,
                syncToJira: (args["sync_to_jira"] as? Bool) ?? false
            )
            return jsonString([
                "created": created != nil && created?.alreadyExisted == false,
                "already_existed": created?.alreadyExisted ?? false,
                "ok": created != nil,
                "title": created?.resolvedTitle ?? title,
                "owner": created?.resolvedOwner ?? ""
            ])

        case "rocknroll_update_task":
            guard allowWrites && (allows(.tasks) || allows(.jira)) else { return "{\"error\":\"Task updates not allowed\"}" }
            guard let updated = await skills.updateTaskWithPeopleResolution(
                taskID: args["task_id"] as? String,
                query: args["query"] as? String,
                done: args["done"] as? Bool,
                newTitle: args["title"] as? String,
                owner: args["owner"] as? String,
                dueDay: args["due_day"] as? String,
                syncToJira: (args["sync_to_jira"] as? Bool) ?? false
            ) else {
                return "{\"error\":\"Matching task not found\"}"
            }
            return jsonString([
                "updated": true,
                "task_id": updated.id.uuidString,
                "title": updated.title,
                "done": updated.done,
                "owner": updated.owner
            ])

        case "rocknroll_update_meeting_artifacts":
            guard allowWrites && allows(.meetingSummary) else { return "{\"error\":\"Summary update not allowed\"}" }
            var actionItems: [(text: String, owner: String, dueDay: String?)] = []
            if let rawItems = args["action_items"] as? [[String: Any]] {
                for raw in rawItems {
                    let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else { continue }
                    let owner = (raw["owner"] as? String) ?? ""
                    let dueDay = raw["due_day"] as? String
                    actionItems.append((text: text, owner: owner, dueDay: dueDay))
                }
            } else if let rawStrings = args["action_items"] as? [String] {
                for raw in rawStrings where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    actionItems.append((text: raw.trimmingCharacters(in: .whitespacesAndNewlines), owner: "", dueDay: nil))
                }
            }
            let details = await skills.updateMeetingArtifactsDetailed(
                sessionID: sessionID,
                summaryAppend: args["summary_append"] as? String,
                replaceSummary: args["replace_summary"] as? String,
                decisions: args["decisions"] as? [String] ?? [],
                openQuestions: args["open_questions"] as? [String] ?? [],
                actionItems: actionItems
            )
            return jsonString([
                "updated": details.updated,
                "action_items_added": details.createdTaskCount,
                "action_items_deduplicated": details.deduplicatedTaskCount
            ])

        case "rocknroll_schedule_meeting":
            guard allowWrites && allows(.calendarSchedule) else { return "{\"error\":\"Calendar scheduling not allowed\"}" }
            let iso = ISO8601DateFormatter()
            guard let title = args["title"] as? String,
                  let sRaw = args["start_at"] as? String, let start = iso.date(from: sRaw),
                  let eRaw = args["end_at"] as? String, let end = iso.date(from: eRaw),
                  end > start else {
                return "{\"error\":\"title, start_at and later end_at are required\"}"
            }
            if let linked = try? await skills.scheduleCalendarMeeting(
                title: title,
                startAt: start,
                endAt: end,
                meetingURL: args["meeting_url"] as? String,
                agendaNotes: (args["agenda_notes"] as? String) ?? ""
            ) {
                return jsonString(["scheduled": true, "title": linked.title])
            }
            return "{\"error\":\"Calendar creation failed\"}"

        case "rocknroll_jira_action":
            guard allows(.jira) else { return "{\"error\":\"Jira not enabled for this skill\"}" }
            let op = (args["operation"] as? String) ?? "search"
            if op == "comment" {
                guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                guard let key = args["issue_key"] as? String, let comment = args["comment"] as? String else {
                    return "{\"error\":\"issue_key and comment required\"}"
                }
                do {
                    try await skills.commentOnJiraIssue(key: key, comment: comment)
                    return jsonString(["commented": true, "issue_key": key])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            if op == "search_users" {
                let query = ((args["query"] as? String) ?? (args["assignee"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let maxResults = max(1, min((args["max_results"] as? Int) ?? 15, 50))
                do {
                    let users: [JiraUserContact]
                    if let workspace, let scopedProject = effectiveProjectKeys.first {
                        users = try await workspace.taskSync.searchJiraUsers(
                            query: query,
                            projectKey: scopedProject,
                            maxResults: maxResults
                        )
                    } else {
                        users = try await skills.searchJiraUsers(query: query, maxResults: maxResults)
                    }
                    return jsonString(["users": users.map(WorkspaceTaskSyncController.jiraUserPayload)])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            if op == "board_users" {
                let maxResults = max(1, min((args["max_results"] as? Int) ?? 40, 60))
                do {
                    let (users, issues) = try await skills.fetchJiraBoardUsersAndIssues(maxResults: maxResults)
                    return jsonString([
                        "users": users.map(WorkspaceTaskSyncController.jiraUserPayload),
                        "issues": issues.map(WorkspaceTaskSyncController.jiraIssuePayload)
                    ])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            if op == "copy_user_from_issue" {
                let issueKey = args["issue_key"] as? String
                let searchQuery = (args["query"] as? String) ?? (args["text"] as? String)
                let role = (args["role"] as? String) ?? "assignee"
                do {
                    let (copiedUser, sourceIssueKey) = try await skills.copyJiraUserFromIssue(
                        issueKey: issueKey,
                        searchQuery: searchQuery,
                        role: role
                    )
                    var savedToPeople = false
                    if let targetName = (args["save_to_people_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !targetName.isEmpty, allowWrites {
                        let extraAliases = (args["aliases"] as? [String]) ?? []
                        let existing = skills.people.resolvePerson(matching: targetName)
                        var mergedAliases = (existing?.aliases ?? []) + extraAliases
                        if existing?.displayName.caseInsensitiveCompare(targetName) != .orderedSame {
                            mergedAliases.append(targetName)
                        }
                        let entry = AssistantPersonEntry(
                            id: existing?.id,
                            displayName: existing?.displayName ?? targetName,
                            aliases: AssistantPersonEntry.deduped(mergedAliases),
                            jiraUsername: copiedUser.username ?? (copiedUser.isServerOrDC ? copiedUser.identifier : existing?.jiraUsername),
                            jiraAccountID: copiedUser.accountId ?? (!copiedUser.isServerOrDC ? copiedUser.identifier : existing?.jiraAccountID),
                            email: copiedUser.emailAddress ?? existing?.email,
                            role: existing?.role,
                            approvedVoiceCommander: existing?.approvedVoiceCommander ?? false,
                            notes: existing?.notes
                        )
                        savedToPeople = (try? skills.upsertPerson(entry, allowPrivilegeChange: false)) != nil
                    }
                    return jsonString([
                        "issue_key": sourceIssueKey,
                        "copied_user": WorkspaceTaskSyncController.jiraUserPayload(copiedUser),
                        "saved_to_people": savedToPeople
                    ])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            if op == "transition" {
                guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                guard let key = (args["issue_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                      let status = ((args["status"] as? String) ?? (args["text"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !status.isEmpty else {
                    return "{\"error\":\"issue_key and status required\"}"
                }
                do {
                    let updated = try await skills.transitionJiraIssue(key: key, status: status, comment: args["comment"] as? String)
                    return jsonString([
                        "transitioned": true,
                        "issue": WorkspaceTaskSyncController.jiraIssuePayload(updated)
                    ])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            if op == "assign" {
                guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                guard let key = (args["issue_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    return "{\"error\":\"issue_key required\"}"
                }
                do {
                    let assigneeContact: JiraUserContact?
                    if let explicitAccount = (args["jira_account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitAccount.isEmpty {
                        assigneeContact = JiraUserContact(
                            identifier: explicitAccount,
                            username: args["jira_username"] as? String,
                            accountId: explicitAccount,
                            displayName: (args["assignee"] as? String) ?? explicitAccount,
                            isServerOrDC: false
                        )
                    } else if let explicitUser = (args["jira_username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitUser.isEmpty {
                        assigneeContact = JiraUserContact(
                            identifier: explicitUser,
                            username: explicitUser,
                            accountId: nil,
                            displayName: (args["assignee"] as? String) ?? explicitUser,
                            isServerOrDC: true
                        )
                    } else if let rawAssignee = (args["assignee"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAssignee.isEmpty {
                        guard let resolution = await skills.resolveJiraAssignee(rawAssignee) else {
                            return "{\"error\":\"Workspace unavailable\"}"
                        }
                        switch resolution {
                        case .resolved(let handle, let person):
                            let isDC = !(workspace?.taskSync.preferences.jira.isCloudHost ?? false)
                            assigneeContact = JiraUserContact(
                                identifier: handle,
                                username: person?.jiraUsername ?? handle,
                                accountId: person?.jiraAccountID,
                                displayName: person?.displayName ?? rawAssignee,
                                isServerOrDC: person?.jiraAccountID == nil && isDC
                            )
                        case .unresolved(let unresolvedQuery, let candidates):
                            return jsonString(WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                                query: unresolvedQuery,
                                candidates: candidates
                            ))
                        }
                    } else {
                        assigneeContact = nil
                    }
                    let updated = try await skills.assignJiraIssue(key: key, assignee: assigneeContact)
                    return jsonString([
                        "assigned": true,
                        "issue": WorkspaceTaskSyncController.jiraIssuePayload(updated)
                    ])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            if op == "create" {
                guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                guard let summary = ((args["summary"] as? String) ?? (args["query"] as? String) ?? (args["text"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !summary.isEmpty else {
                    return "{\"error\":\"summary required\"}"
                }
                do {
                    var assigneeContact: JiraUserContact?
                    if let rawAssignee = (args["assignee"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAssignee.isEmpty {
                        if let resolution = await skills.resolveJiraAssignee(rawAssignee) {
                            switch resolution {
                            case .resolved(let handle, let person):
                                let isDC = !(workspace?.taskSync.preferences.jira.isCloudHost ?? false)
                                assigneeContact = JiraUserContact(
                                    identifier: handle,
                                    username: person?.jiraUsername ?? handle,
                                    accountId: person?.jiraAccountID,
                                    displayName: person?.displayName ?? rawAssignee,
                                    isServerOrDC: person?.jiraAccountID == nil && isDC
                                )
                            case .unresolved(let unresolvedQuery, let candidates):
                                return jsonString(WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                                    query: unresolvedQuery,
                                    candidates: candidates
                                ))
                            }
                        }
                    }
                    let kind = (args["issue_kind"] as? String).flatMap(TaskIssueKind.init(rawValue:)) ?? .task
                    let priority = (args["priority"] as? String).flatMap(TaskPriorityLevel.init(rawValue:))
                    let explicitProjectKey = (args["project_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedProjectKey = WorkspaceTaskSyncController.resolveSpokenProjectKey(
                        explicitProjectKey ?? "",
                        candidates: allProjectCandidates
                    ) ?? effectiveProjectKeys.first
                    let created = try await skills.createJiraIssueDirect(
                        summary: summary,
                        description: (args["description"] as? String) ?? "",
                        projectKey: resolvedProjectKey,
                        issueKind: kind,
                        assignee: assigneeContact,
                        priority: priority,
                        parentEpicKey: args["parent_epic_key"] as? String
                    )
                    return jsonString([
                        "created": true,
                        "issue": WorkspaceTaskSyncController.jiraIssuePayload(created)
                    ])
                } catch {
                    return jsonString(["error": error.localizedDescription])
                }
            }
            do {
                var resolvedAssigneeID: String?
                let rawAssignee = (args["assignee"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !rawAssignee.isEmpty {
                    let resolution: WorkspaceTaskSyncController.JiraAssigneeResolution?
                    if let workspace, let scopedProject = effectiveProjectKeys.first {
                        resolution = await workspace.taskSync.resolveJiraAssignee(
                            rawAssignee,
                            people: skills.people,
                            defaultProjectKey: scopedProject
                        )
                    } else {
                        resolution = await skills.resolveJiraAssignee(rawAssignee)
                    }
                    if let resolution {
                        switch resolution {
                        case .resolved(let jqlID, _):
                            resolvedAssigneeID = jqlID
                        case .unresolved(let unresolvedQuery, let candidates):
                            return jsonString(WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                                query: unresolvedQuery,
                                candidates: candidates
                            ))
                        }
                    }
                }
                let rawQuery = args["query"] as? String
                let jql = skills.resolvedJiraJQL(
                    rawJQL: args["jql"] as? String,
                    query: rawQuery,
                    assigneeIdentifier: resolvedAssigneeID,
                    projectKeys: effectiveProjectKeys
                )
                let maxResults = max(1, min((args["max_results"] as? Int) ?? 15, 50))
                var finalJQL = jql
                var issues: [JiraRemoteIssue]
                do {
                    issues = try await skills.searchJiraIssues(jql: jql, maxResults: maxResults)
                } catch JiraConnectorError.badRequest(let detail) {
                    if let literalAssignee = WorkspaceTaskSyncController.extractLiteralAssigneeFromJQL(jql),
                       let resolution = await skills.resolveJiraAssignee(literalAssignee) {
                        switch resolution {
                        case .resolved(let handle, _):
                            finalJQL = WorkspaceTaskSyncController.replacingLiteralAssignee(in: jql, with: handle)
                            issues = try await skills.searchJiraIssues(jql: finalJQL, maxResults: maxResults)
                        case .unresolved(let unresolvedQuery, let candidates):
                            return jsonString(WorkspaceTaskSyncController.unresolvedJiraAssigneePayload(
                                query: unresolvedQuery,
                                candidates: candidates
                            ))
                        }
                    } else {
                        throw JiraConnectorError.badRequest(detail)
                    }
                }
                let cleanSearchQuery = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let hasExactMatch = !cleanSearchQuery.isEmpty && issues.contains {
                    $0.key.localizedCaseInsensitiveContains(cleanSearchQuery)
                        || $0.summary.localizedCaseInsensitiveContains(cleanSearchQuery)
                }
                if board?.currentURL != nil, (issues.isEmpty || (!cleanSearchQuery.isEmpty && !hasExactMatch)) {
                    if let (_, boardIssues) = try? await skills.fetchJiraBoardUsersAndIssues(maxResults: 50),
                       !boardIssues.isEmpty {
                        let normalizedQuery = cleanSearchQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        let normalizedAssignee = (resolvedAssigneeID ?? rawAssignee)
                            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        let visibleMatches = boardIssues.filter { issue in
                            let queryOK: Bool = normalizedQuery.isEmpty
                                || issue.key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedQuery)
                                || issue.summary.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedQuery)
                            let assigneeOK: Bool = normalizedAssignee.isEmpty
                                || (issue.assigneeName ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                                || (issue.assigneeIdentifier ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                                || (issue.assigneeContact?.username ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                                || (issue.assigneeContact?.accountId ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(normalizedAssignee)
                            return queryOK && assigneeOK
                        }
                        if !visibleMatches.isEmpty {
                            let existingKeys = Set(visibleMatches.map(\.key))
                            issues = visibleMatches + issues.filter { !existingKeys.contains($0.key) }
                        }
                    }
                }
                return jsonString([
                    "jql": finalJQL,
                    "issues": Array(issues.prefix(maxResults)).map {
                        ["key": $0.key, "summary": $0.summary, "status": $0.statusName, "assignee": $0.assigneeName ?? ""]
                    }
                ])
            } catch {
                return jsonString(["error": error.localizedDescription])
            }

        case "rocknroll_control_board":
            guard allows(.boardShare), let board else { return "{\"error\":\"Board unavailable\"}" }
            let cmd = (args["command"] as? String) ?? "inspect"
            do {
                switch cmd {
                case "open_url":
                    let explicitURL = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = (explicitURL?.isEmpty == false ? explicitURL! : effectiveBoardURL)
                    let msg = try await board.open(urlString: url)
                    return jsonString(["message": msg])
                case "share_to_meeting":
                    let rawURL = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let explicitURL: String?
                    if let rawURL, !rawURL.isEmpty {
                        explicitURL = rawURL
                    } else if board.currentURL == nil {
                        let fallback = effectiveBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        explicitURL = fallback.isEmpty ? nil : fallback
                    } else {
                        explicitURL = nil
                    }
                    let targetUUID = (args["meeting_id"] as? String).flatMap(UUID.init(uuidString:)) ?? controllerID ?? sessionID
                    let msg = try await board.startSharing(targetID: targetUUID, urlOverride: explicitURL)
                    return jsonString(["sharing": true, "message": msg])
                case "stop_share":
                    board.stopSharing()
                    return jsonString(["sharing": false, "message": L("Stopped sharing the Assistant Board.")])
                case "filter":
                    if board.currentURL == nil, !effectiveBoardURL.isEmpty {
                        _ = try? await board.open(urlString: effectiveBoardURL)
                    }
                    return jsonString(["message": try await board.filter(query: (args["query"] as? String) ?? (args["text"] as? String) ?? "")])
                case "select_person_filter":
                    if board.currentURL == nil, !effectiveBoardURL.isEmpty {
                        _ = try? await board.open(urlString: effectiveBoardURL)
                    }
                    let q = ((args["query"] as? String) ?? (args["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return jsonString(["message": try await board.selectPersonFilter(query: q, people: skills.people)])
                case "clear_filters":
                    return jsonString(["message": try await board.clearFilters()])
                case "move_issue":
                    guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                    guard let key = (args["issue_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                          let status = ((args["status"] as? String) ?? (args["text"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !status.isEmpty else {
                        return "{\"error\":\"issue_key and status required\"}"
                    }
                    let updated = try await skills.transitionJiraIssue(
                        key: key,
                        status: status,
                        comment: args["comment"] as? String
                    )
                    return jsonString([
                        "moved": true,
                        "issue": WorkspaceTaskSyncController.jiraIssuePayload(updated)
                    ])
                case "scroll":
                    return jsonString(["message": try await board.scroll(deltaY: (args["delta_y"] as? Int) ?? 450)])
                case "click":
                    return jsonString(["message": try await board.click(selector: args["selector"] as? String, text: args["text"] as? String)])
                case "click_at":
                    let x = (args["x"] as? NSNumber)?.doubleValue ?? 0.5
                    let y = (args["y"] as? NSNumber)?.doubleValue ?? 0.5
                    return jsonString(["message": try await board.clickAt(x: x, y: y, normalized: (args["normalized"] as? Bool) ?? true)])
                case "highlight":
                    return jsonString(["message": try await board.highlight(text: (args["text"] as? String) ?? (args["query"] as? String) ?? "")])
                case "inspect":
                    return jsonString(await board.inspect())
                case "snapshot":
                    let snap = try await board.snapshotBase64()
                    return jsonString(["width": snap.width, "height": snap.height, "image_base64": snap.jpegBase64])
                default:
                    return "{\"error\":\"Unsupported command\"}"
                }
            } catch {
                return jsonString(["error": error.localizedDescription])
            }

        case "rocknroll_workspace_overview":
            let cal = Calendar.current
            let now = Date()
            let monthSessions = workspace?.historySessions.filter {
                cal.isDate($0.startedAt, equalTo: now, toGranularity: .month)
            } ?? []
            let openTasks = workspace?.tasks.filter {
                !$0.done && workspace?.taskArchivedAt($0) == nil
            }.prefix(15).map {
                ["id": $0.id.uuidString, "title": $0.text, "owner": $0.owner, "due_day": $0.dueDay ?? ""]
            } ?? []
            let upcoming = (joinableTargetsProvider?() ?? []).prefix(8).map {
                ["title": $0.title, "url": $0.invitation.absoluteString]
            }
            return jsonString([
                "meetings_this_month_count": monthSessions.count,
                "meetings_this_month": monthSessions.prefix(10).map(\.title),
                "open_tasks": openTasks,
                "joinable_meetings": upcoming
            ])

        case "rocknroll_join_meetings":
            guard let directTalkJoinHandler else { return "{\"error\":\"Join handler unavailable\"}" }
            let skillID = args["skill_id"] as? String
            if let queries = args["queries"] as? [String], !queries.isEmpty {
                var results: [String] = []
                for q in queries {
                    results.append(await directTalkJoinHandler(q, skillID))
                }
                return jsonString(["results": results])
            }
            let query = (args["query"] as? String) ?? ""
            return await directTalkJoinHandler(query, skillID)

        default:
            return "{\"error\":\"Unsupported tool\"}"
        }
    }

    private func handleRealtimeEvent(
        _ event: RealtimeVoiceEvent,
        controllerID: UUID,
        state: SessionRealtimeState
    ) async {
        switch event {
        case .connected:
            state.connected = true
            AppDiagnostics.log("assistant-facilitator-realtime", [
                "provider": state.provider.rawValue,
                "state": "connected",
                "inputSampleRate": state.provider.defaultInputSampleRate,
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
            busySessions.remove(controllerID)
            let totalBytes = state.audioChunks.reduce(0) { $0 + $1.count }
            var combined = Data()
            combined.reserveCapacity(totalBytes)
            for chunk in state.audioChunks {
                combined.append(chunk)
            }
            state.audioChunks.removeAll()
            let text = AssistantSpeechLedger.sanitizeSpokenReply(state.transcriptBuffer)
            state.transcriptBuffer = ""
            await waitForSpeakerSilence(controllerID: controllerID)
            guard activeSessionSkills[controllerID] != nil,
                  !manuallyDisabledSessions.contains(controllerID),
                  resolveBridge(controllerID)?.isConnected() == true,
                  !(resolveBridge(controllerID)?.isHumanSpeaking() ?? false) else {
                schedulePendingTurnIfNeeded(controllerID: controllerID)
                return
            }
            if let buffer = RealtimeVoiceAudio.pcm16ToAudioBuffer(data: combined, sampleRate: state.outputSampleRate) {
                state.gate.markVoiceDeliveryStarted()
                await deliverSpokenBuffer(buffer, fallbackText: text, controllerID: controllerID)
            } else if !text.isEmpty {
                state.gate.markVoiceDeliveryStarted()
                await speakIntoMeeting(text, controllerID: controllerID)
            }
            schedulePendingTurnIfNeeded(controllerID: controllerID)
        case .error(let msg):
            state.responseInProgress = false
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            busySessions.remove(controllerID)
            let stillConnected = await state.router.isRealtimeConnected
            if !stillConnected {
                lastStatusBySession[controllerID] = L("Realtime fallback active (%@)", msg)
                state.connected = false
            }
            AppDiagnostics.log("assistant-facilitator-realtime", [
                "provider": state.provider.rawValue,
                "state": "error",
                "inputSampleRate": state.provider.defaultInputSampleRate,
                "outputSampleRate": Int(state.outputSampleRate)
            ])
            syncRealtimeActiveFlag()
            schedulePendingTurnIfNeeded(controllerID: controllerID)
        case .disconnected:
            state.responseInProgress = false
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            busySessions.remove(controllerID)
            state.connected = false
            AppDiagnostics.log("assistant-facilitator-realtime", [
                "provider": state.provider.rawValue,
                "state": "disconnected",
                "inputSampleRate": state.provider.defaultInputSampleRate,
                "outputSampleRate": Int(state.outputSampleRate)
            ])
            syncRealtimeActiveFlag()
            schedulePendingTurnIfNeeded(controllerID: controllerID)
        default:
            break
        }
    }

    func speakIntoMeeting(_ text: String, controllerID: UUID) async {
        guard activeSessionSkills[controllerID] != nil,
              !manuallyDisabledSessions.contains(controllerID),
              let initialBridge = resolveBridge(controllerID),
              initialBridge.isConnected() else {
            return
        }
        let clean = AssistantSpeechLedger.sanitizeSpokenReply(text)
        guard !clean.isEmpty else { return }
        let startEpoch = speechCancelEpochBySession[controllerID, default: 0]
        let speechToken = UUID()
        activeSpeechTaskBySession[controllerID]?.cancel()
        activeSpeechTokenBySession[controllerID] = speechToken
        recordSpokenAnswer(clean, for: controllerID)
        mergeRecentEvents([
            SyncedTranscriptEvent(
                id: "assistant:\(UUID().uuidString)",
                kind: "transcript",
                occurredAt: Date(),
                speaker: AssistantSpeechLedger.canonicalSpeakerName,
                isOwn: false,
                speakerRole: AssistantSpeechLedger.speakerRoleAssistant,
                text: clean,
                deviceID: "local-assistant"
            )
        ], for: controllerID)
        realtimeSessions[controllerID]?.gate.markVoiceDeliveryStarted()
        speakingSessions.insert(controllerID)
        defer {
            if activeSpeechTokenBySession[controllerID] == speechToken {
                activeSpeechTokenBySession.removeValue(forKey: controllerID)
                speakingSessions.remove(controllerID)
                activeSpeechTaskBySession.removeValue(forKey: controllerID)
                let endedAt = Date()
                lastSpokeAtBySession[controllerID] = endedAt
                lastVoiceDeliveryEndedAtBySession[controllerID] = endedAt
                realtimeSessions[controllerID]?.gate.markVoiceDeliveryEnded(at: endedAt)
            }
        }

        if let bridge = resolveBridge(controllerID), bridge.isConnected() {
            let speechTask = Task<Void, Never> { @MainActor [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.activeSpeechTokenBySession[controllerID] == speechToken,
                      self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch,
                      self.activeSessionSkills[controllerID] != nil,
                      !self.manuallyDisabledSessions.contains(controllerID) else {
                    return
                }
                do {
                    try await bridge.speakVoice(clean)
                    guard !Task.isCancelled,
                          self.activeSpeechTokenBySession[controllerID] == speechToken,
                          self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch else {
                        return
                    }
                    self.lastStatusBySession[controllerID] = L("Spoken into “%@”.", bridge.title)
                    return
                } catch {
                    // Only fall back to local auditioning when STILL connected in the meeting and meeting audio is muted/disabled;
                    // never talk out loud after leaving, disconnecting, disabling facilitator, or being interrupted by human barge-in.
                    let canAuditionLocally = !Task.isCancelled
                        && self.activeSpeechTokenBySession[controllerID] == speechToken
                        && self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch
                        && self.activeSessionSkills[controllerID] != nil
                        && !self.manuallyDisabledSessions.contains(controllerID)
                        && bridge.isConnected()
                        && !bridge.isMeetingSoundEnabled
                        && !bridge.isHumanSpeaking()
                    guard canAuditionLocally else { return }
                }
                await self.playLocalAuditionAndWait(clean)
                if !Task.isCancelled,
                   self.activeSpeechTokenBySession[controllerID] == speechToken,
                   self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch {
                    self.lastStatusBySession[controllerID] = L("Auditioned locally (meeting audio off).")
                }
            }
            activeSpeechTaskBySession[controllerID] = speechTask
            await speechTask.value
        }
    }

    private func playLocalAuditionAndWait(_ text: String) async {
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
                        try await IOSVoiceStore.shared.streamPlayAssistantResponse(
                            text,
                            player: .shared,
                            onComplete: { once.resume() }
                        )
                    } catch {
                        once.resume()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in IOSVoicePreviewPlayer.shared.stop() }
            once.resume()
        }
    }

    private func deliverSpokenBuffer(_ buffer: AVAudioPCMBuffer, fallbackText: String, controllerID: UUID) async {
        guard activeSessionSkills[controllerID] != nil,
              !manuallyDisabledSessions.contains(controllerID),
              let initialBridge = resolveBridge(controllerID),
              initialBridge.isConnected() else {
            return
        }
        let cleanFallback = AssistantSpeechLedger.sanitizeSpokenReply(fallbackText)
        let startEpoch = speechCancelEpochBySession[controllerID, default: 0]
        let speechToken = UUID()
        activeSpeechTaskBySession[controllerID]?.cancel()
        activeSpeechTokenBySession[controllerID] = speechToken
        if !cleanFallback.isEmpty {
            recordSpokenAnswer(cleanFallback, for: controllerID)
            mergeRecentEvents([
                SyncedTranscriptEvent(
                    id: "assistant:\(UUID().uuidString)",
                    kind: "transcript",
                    occurredAt: Date(),
                    speaker: AssistantSpeechLedger.canonicalSpeakerName,
                    isOwn: false,
                    speakerRole: AssistantSpeechLedger.speakerRoleAssistant,
                    text: cleanFallback,
                    deviceID: "local-assistant"
                )
            ], for: controllerID)
        } else {
            lastSpokeAtBySession[controllerID] = Date()
        }
        realtimeSessions[controllerID]?.gate.markVoiceDeliveryStarted()
        speakingSessions.insert(controllerID)
        defer {
            if activeSpeechTokenBySession[controllerID] == speechToken {
                activeSpeechTokenBySession.removeValue(forKey: controllerID)
                speakingSessions.remove(controllerID)
                activeSpeechTaskBySession.removeValue(forKey: controllerID)
                let endedAt = Date()
                lastSpokeAtBySession[controllerID] = endedAt
                lastVoiceDeliveryEndedAtBySession[controllerID] = endedAt
                realtimeSessions[controllerID]?.gate.markVoiceDeliveryEnded(at: endedAt)
            }
        }

        if let bridge = resolveBridge(controllerID), bridge.isConnected() {
            let speechTask = Task<Void, Never> { @MainActor [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.activeSpeechTokenBySession[controllerID] == speechToken,
                      self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch,
                      self.activeSessionSkills[controllerID] != nil,
                      !self.manuallyDisabledSessions.contains(controllerID) else {
                    return
                }
                if let speakBuffer = bridge.speakAudioBuffer {
                    let utteranceID = UUID().uuidString
                    let startedAt = Date()
                    if !cleanFallback.isEmpty {
                        bridge.recordAssistantSpeech(utteranceID, cleanFallback, startedAt, nil)
                    }
                    do {
                        defer {
                            if !cleanFallback.isEmpty {
                                bridge.recordAssistantSpeech(utteranceID, cleanFallback, startedAt, Date())
                            }
                        }
                        try await speakBuffer(buffer)
                        if !Task.isCancelled,
                           self.activeSpeechTokenBySession[controllerID] == speechToken,
                           self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch {
                            self.lastStatusBySession[controllerID] = L("Spoken into “%@”.", bridge.title)
                        }
                        return
                    } catch {}
                }
                if !cleanFallback.isEmpty,
                   !Task.isCancelled,
                   self.activeSpeechTokenBySession[controllerID] == speechToken,
                   self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch,
                   self.activeSessionSkills[controllerID] != nil,
                   !self.manuallyDisabledSessions.contains(controllerID),
                   bridge.isConnected() {
                    do {
                        try await bridge.speakVoice(cleanFallback)
                        if !Task.isCancelled,
                           self.activeSpeechTokenBySession[controllerID] == speechToken,
                           self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch {
                            self.lastStatusBySession[controllerID] = L("Spoken into “%@”.", bridge.title)
                        }
                        return
                    } catch {}
                }
                let canAuditionLocally = !Task.isCancelled
                    && self.activeSpeechTokenBySession[controllerID] == speechToken
                    && self.speechCancelEpochBySession[controllerID, default: 0] == startEpoch
                    && self.activeSessionSkills[controllerID] != nil
                    && !self.manuallyDisabledSessions.contains(controllerID)
                    && bridge.isConnected()
                    && !bridge.isMeetingSoundEnabled
                    && !bridge.isHumanSpeaking()
                guard canAuditionLocally else { return }
                try? IOSVoicePreviewPlayer.shared.play(buffer)
                self.lastStatusBySession[controllerID] = L("Auditioned locally (meeting audio off).")
            }
            activeSpeechTaskBySession[controllerID] = speechTask
            await speechTask.value
        }
    }

    private func syncRealtimeActiveFlag() {
        realtimeActive = realtimeSessions.values.contains(where: \.connected)
    }

    // MARK: - Helpers

    static func handleDeterministicBoardCommand(
        _ input: String,
        board: IOSAssistantBoardController?,
        defaultBoardURL: String,
        targetID: UUID?,
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
        if asksStop && hasBoardKeyword && !hasJiraTaskAction {
            board.stopSharing()
            return L("Stopped sharing the Assistant Board.")
        }

        let asksShare = lower.contains("расшар") || lower.contains("пошар") || lower.contains("демонстр")
            || lower.contains("поделис") || lower.contains("share") || lower.contains("present")
        if asksShare && hasBoardKeyword && !hasJiraTaskAction {
            let trimmedDefault = defaultBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlOverride = board.currentURL == nil && !trimmedDefault.isEmpty ? trimmedDefault : nil
            do {
                return try await board.startSharing(targetID: targetID, urlOverride: urlOverride)
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

    nonisolated static func extractDirectTaskInstruction(
        from input: String,
        lower: String
    ) -> (title: String, owner: String?)? {
        for marker in ["создай задачу ", "добавь задачу ", "поставь задачу ", "create task ", "add task "] {
            if let range = lower.range(of: marker) {
                let tailIdx = input.index(input.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let raw = String(input[tailIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return nil }
                for prep in [" на ", " для ", " for "] {
                    if let pRange = raw.range(of: prep, options: [.caseInsensitive, .backwards]) {
                        let title = String(raw[..<pRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let owner = String(raw[pRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty && !owner.isEmpty && owner.count <= 40 {
                            return (title, owner)
                        }
                    }
                }
                return (raw, nil)
            }
        }
        return nil
    }

    private func callLLMWithTools(
        systemPrompt: String,
        userPrompt: String,
        configuration: PortableOutcomeConfiguration,
        apiKey: String,
        tools: [RealtimeToolDeclaration],
        toolExecutor: @escaping (String, String) async -> String
    ) async -> String? {
        switch configuration.providerKind {
        case .preferMac, .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *),
               SystemLanguageModel.default.availability == .available {
                do {
                    let session = LanguageModelSession(instructions: systemPrompt)
                    let response = try await session.respond(to: userPrompt)
                    let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                } catch {}
            }
            #endif
            return nil

        case .openAI, .openRouter, .custom:
            guard let endpoint = configuration.endpoint, !configuration.resolvedModel.isEmpty else { return nil }
            let openAITools: [[String: Any]] = tools.map { decl in
                [
                    "type": "function",
                    "function": [
                        "name": decl.name,
                        "description": decl.description,
                        "parameters": decl.parametersDictionary()
                    ]
                ]
            }

            var conversation: [[String: Any]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]

            for iteration in 0..<5 {
                var body: [String: Any] = [
                    "model": configuration.resolvedModel,
                    "messages": conversation
                ]
                if configuration.providerKind == .openAI {
                    body["max_completion_tokens"] = 2_000
                } else {
                    body["max_tokens"] = 2_000
                    body["temperature"] = 0.25
                }
                if !openAITools.isEmpty {
                    body["tools"] = openAITools
                }

                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
                req.httpBody = bodyData

                guard let (data, response) = try? await MeetingAITransfer.send(req, using: llmURLSession),
                      let http = response as? HTTPURLResponse else {
                    return nil
                }

                // Some custom/legacy OpenAI-compatible proxies reject `tools`; retry once plain text.
                if !(200..<300).contains(http.statusCode) {
                    if iteration == 0 && !openAITools.isEmpty {
                        return await callLLMPlainText(
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            configuration: configuration,
                            apiKey: apiKey
                        )
                    }
                    return nil
                }

                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any] else {
                    return nil
                }

                if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    conversation.append(message)
                    for call in toolCalls {
                        let callID = (call["id"] as? String) ?? UUID().uuidString
                        let fn = call["function"] as? [String: Any]
                        let name = (fn?["name"] as? String) ?? ""
                        let argsJSON = (fn?["arguments"] as? String) ?? "{}"
                        let output = await toolExecutor(name, argsJSON)
                        conversation.append([
                            "role": "tool",
                            "tool_call_id": callID,
                            "content": output
                        ])
                    }
                    continue
                }

                let finishReason = first["finish_reason"] as? String ?? ""
                let trimmed = OpenAIChatResponseExtractor.extractPlainText(
                    from: message,
                    finishReason: finishReason
                )
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    }

    private func callLLMPlainText(
        systemPrompt: String,
        userPrompt: String,
        configuration: PortableOutcomeConfiguration,
        apiKey: String
    ) async -> String? {
        guard let endpoint = configuration.endpoint, !configuration.resolvedModel.isEmpty else { return nil }
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        var body = PortableOutcomeService.requestBody(
            messages: messages,
            model: configuration.resolvedModel,
            provider: configuration.providerKind,
            tokenLimit: 2_000,
            temperature: 0.25
        )
        body.removeValue(forKey: "response_format")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData
        guard let (data, response) = try? await MeetingAITransfer.send(req, using: llmURLSession),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return nil
        }
        let finishReason = first["finish_reason"] as? String ?? ""
        let trimmed = OpenAIChatResponseExtractor.extractPlainText(
            from: message,
            finishReason: finishReason
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    nonisolated static func buildToolDeclarations(
        allowedGroups: Set<AssistantSkillToolGroup>?,
        includeDirectTalkTools: Bool = false
    ) -> [RealtimeToolDeclaration] {
        func allows(_ g: AssistantSkillToolGroup) -> Bool { allowedGroups?.contains(g) ?? true }
        var tools: [RealtimeToolDeclaration] = [
            .init(
                name: "rocknroll_search_knowledge",
                description: "Search Obsidian vault Markdown files, People.md, TeamContext.md, and workspace meeting transcripts.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer"]
                    ],
                    "required": ["query"]
                ]
            ),
            .init(
                name: "rocknroll_manage_people",
                description: "Look up, remember, or remove member name-to-Jira mappings and voice approval in People.md.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "operation": ["type": "string", "enum": ["lookup", "upsert", "remove"]],
                        "id": ["type": "string"],
                        "query": ["type": "string"],
                        "display_name": ["type": "string"],
                        "aliases": ["type": "array", "items": ["type": "string"]],
                        "jira_username": ["type": "string"],
                        "jira_account_id": ["type": "string"],
                        "email": ["type": "string"],
                        "role": ["type": "string"],
                        "notes": ["type": "string"],
                        "approved_voice_commander": ["type": "boolean"],
                        "force_without_jira": ["type": "boolean"]
                    ],
                    "required": ["operation"]
                ]
            )
        ]
        if allows(.tasks) || allows(.jira) {
            tools.append(.init(
                name: "rocknroll_create_task",
                description: "Create a task resolving owner via People.md.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "owner": ["type": "string"],
                        "due_day": ["type": "string"],
                        "sync_to_jira": ["type": "boolean"]
                    ],
                    "required": ["title"]
                ]
            ))
            tools.append(.init(
                name: "rocknroll_update_task",
                description: "Update, complete, rename, or reassign an existing workspace task (resolving owner via People.md).",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string"],
                        "query": ["type": "string"],
                        "done": ["type": "boolean"],
                        "title": ["type": "string"],
                        "owner": ["type": "string"],
                        "due_day": ["type": "string"],
                        "sync_to_jira": ["type": "boolean"]
                    ]
                ]
            ))
        }
        if allows(.jira) {
            tools.append(.init(
                name: "rocknroll_jira_action",
                description: "Search Jira issues/board users, copy a Jira user from a board issue, create/assign/transition issues, or add a comment.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "operation": ["type": "string", "enum": ["search", "search_users", "board_users", "copy_user_from_issue", "comment", "transition", "assign", "create"]],
                        "jql": ["type": "string"],
                        "query": ["type": "string"],
                        "assignee": ["type": "string"],
                        "max_results": ["type": "integer"],
                        "issue_key": ["type": "string"],
                        "comment": ["type": "string"],
                        "status": ["type": "string"],
                        "role": ["type": "string", "enum": ["assignee", "reporter"]],
                        "save_to_people_name": ["type": "string"],
                        "aliases": ["type": "array", "items": ["type": "string"]],
                        "summary": ["type": "string"],
                        "description": ["type": "string"],
                        "project_key": ["type": "string"],
                        "issue_kind": ["type": "string", "enum": ["task", "story", "bug", "epic"]],
                        "priority": ["type": "string", "enum": ["critical", "high", "medium", "low"]],
                        "parent_epic_key": ["type": "string"],
                        "jira_username": ["type": "string"],
                        "jira_account_id": ["type": "string"]
                    ],
                    "required": ["operation"]
                ]
            ))
        }
        if allows(.calendarSchedule) {
            tools.append(.init(
                name: "rocknroll_schedule_meeting",
                description: "Schedule a new Apple Calendar meeting.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start_at": ["type": "string"],
                        "end_at": ["type": "string"],
                        "meeting_url": ["type": "string"],
                        "agenda_notes": ["type": "string"]
                    ],
                    "required": ["title", "start_at", "end_at"]
                ]
            ))
        }
        if allows(.meetingSummary) {
            tools.append(.init(
                name: "rocknroll_update_meeting_artifacts",
                description: "Update the meeting summary, decisions, open questions, or action items.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "summary_append": ["type": "string"],
                        "replace_summary": ["type": "string"],
                        "decisions": ["type": "array", "items": ["type": "string"]],
                        "open_questions": ["type": "array", "items": ["type": "string"]],
                        "action_items": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "text": ["type": "string"],
                                    "owner": ["type": "string"],
                                    "due_day": ["type": "string"]
                                ]
                            ]
                        ]
                    ]
                ]
            ))
        }
        if allows(.boardShare) {
            tools.append(.init(
                name: "rocknroll_control_board",
                description: "Control the in-app desktop-sized (1440x810) Assistant Board browser, select person filters during standups, move Jira cards, and stream it directly to an active meeting.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "enum": ["open_url", "share_to_meeting", "stop_share", "filter", "select_person_filter", "clear_filters", "scroll", "click", "click_at", "highlight", "inspect", "snapshot", "move_issue"]],
                        "url": ["type": "string"],
                        "meeting_id": ["type": "string"],
                        "query": ["type": "string"],
                        "text": ["type": "string"],
                        "selector": ["type": "string"],
                        "issue_key": ["type": "string"],
                        "status": ["type": "string"],
                        "comment": ["type": "string"],
                        "delta_y": ["type": "integer"],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "normalized": ["type": "boolean"]
                    ],
                    "required": ["command"]
                ]
            ))
        }
        if includeDirectTalkTools {
            tools.append(.init(
                name: "rocknroll_workspace_overview",
                description: "Get monthly meeting count, open tasks, and upcoming joinable meetings.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ))
            tools.append(.init(
                name: "rocknroll_join_meetings",
                description: "Join one or more upcoming/ongoing meetings with an optional skill role.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "queries": ["type": "array", "items": ["type": "string"]],
                        "skill_id": ["type": "string"]
                    ]
                ]
            ))
        }
        return tools
    }
}
