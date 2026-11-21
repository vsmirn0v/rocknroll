import AVFoundation
import ConferenceCore
import Foundation
import MeetingEngine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs autonomous in-meeting voice facilitation on iOS using Obsidian-backed skills,
/// `People.md` speaker approval (owner is always approved), optional `OpenAI Realtime` /
/// `Gemini Live` WebSocket acceleration with live PCM16 audio streaming, and local
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

    private weak var skills: IOSAssistantSkillsController?
    private weak var workspace: IOSWorkspaceCoordinator?
    private weak var board: IOSAssistantBoardController?
    private let resolveBridge: (UUID) -> IOSAssistantSessionBridge?

    private var seenEventIDsBySession: [UUID: Set<String>] = [:]
    private var recentEventsBySession: [UUID: [SyncedTranscriptEvent]] = [:]
    private var busySessions: Set<UUID> = []
    private var manuallyDisabledSessions: Set<UUID> = []
    private var lastSpokeAtBySession: [UUID: Date] = [:]
    private var lastVoiceDeliveryEndedAtBySession: [UUID: Date] = [:]
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

    private func resolveSkillID(explicitSkillID: String?, meetingTitle: String) -> String {
        if let explicit = explicitSkillID.map(AssistantSkill.sanitizedSlug(from:)), !explicit.isEmpty {
            return explicit
        }
        if let autoMatched = skills?.skills.first(where: {
            $0.enabled && $0.matches(meetingTitle: meetingTitle, commandText: "")
        })?.id {
            return autoMatched
        }
        return skills?.selectedSkillIDs.first ?? "scrum-master"
    }

    func enable(controllerID: UUID, title: String, skillID: String? = nil) {
        manuallyDisabledSessions.remove(controllerID)
        let chosen = resolveSkillID(explicitSkillID: skillID, meetingTitle: title)
        activeSessionSkills[controllerID] = chosen
        seenEventIDsBySession[controllerID] = Set((recentEventsBySession[controllerID] ?? []).map(\.id))
        lastStatusBySession[controllerID] = L("Autonomous voice facilitator active (%@)", chosen)
        let skill = skills?.skills.first(where: { $0.id == chosen })
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resolveBridge(controllerID)?.ensureFacilitatorTranscription()
            guard !self.manuallyDisabledSessions.contains(controllerID),
                  self.activeSessionSkills[controllerID] == chosen else { return }
            await self.maybeConnectRealtime(controllerID: controllerID, title: title, skill: skill, skillID: chosen)
            guard !self.manuallyDisabledSessions.contains(controllerID),
                  self.activeSessionSkills[controllerID] == chosen else { return }
            if skill?.autoGreet == true {
                await self.kickOffSkill(controllerID: controllerID, title: title, skillID: chosen)
            }
        }
    }

    func disable(controllerID: UUID) {
        manuallyDisabledSessions.insert(controllerID)
        activeSessionSkills.removeValue(forKey: controllerID)
        seenEventIDsBySession.removeValue(forKey: controllerID)
        recentEventsBySession.removeValue(forKey: controllerID)
        lastStatusBySession.removeValue(forKey: controllerID)
        lastSpokeAtBySession.removeValue(forKey: controllerID)
        lastVoiceDeliveryEndedAtBySession.removeValue(forKey: controllerID)
        busySessions.remove(controllerID)
        resolveBridge(controllerID)?.setRealtimeAudioTap(nil)
        if let state = realtimeSessions.removeValue(forKey: controllerID) {
            state.turnTimeoutTask?.cancel()
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
        seenEventIDsBySession.removeValue(forKey: controllerID)
        recentEventsBySession.removeValue(forKey: controllerID)
        lastStatusBySession.removeValue(forKey: controllerID)
        lastSpokeAtBySession.removeValue(forKey: controllerID)
        lastSpokenAnswerBySession.removeValue(forKey: controllerID)
        lastVoiceDeliveryEndedAtBySession.removeValue(forKey: controllerID)
        busySessions.remove(controllerID)
        resolveBridge(controllerID)?.setRealtimeAudioTap(nil)
        if let state = realtimeSessions.removeValue(forKey: controllerID) {
            state.turnTimeoutTask?.cancel()
            Task { await state.router.stop() }
        }
        syncRealtimeActiveFlag()
    }

    func kickOffSkill(controllerID: UUID, title: String, skillID: String? = nil) async {
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

    func observeEvents(
        controllerID: UUID,
        title: String,
        invitationURL: URL?,
        events: [SyncedTranscriptEvent],
        localNames: [String]
    ) {
        attachPendingSkillIfNeeded(
            controllerID: controllerID,
            title: title,
            roomURLString: invitationURL?.absoluteString ?? ""
        )

        recentEventsBySession[controllerID] = Array(events.suffix(30))
        guard let skillID = activeSessionSkills[controllerID],
              !busySessions.contains(controllerID) else { return }

        var seen = seenEventIDsBySession[controllerID] ?? []
        let unseen = events.filter {
            !seen.contains($0.id) && ($0.kind == "transcript" || $0.kind == "chat")
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !unseen.isEmpty else { return }
        for line in unseen { seen.insert(line.id) }
        seenEventIDsBySession[controllerID] = seen

        let now = Date()
        let inFollowUpWindow = lastSpokeAtBySession[controllerID].map { now.timeIntervalSince($0) <= 20 } ?? false
        let inEchoWindow = lastVoiceDeliveryEndedAtBySession[controllerID].map { now.timeIntervalSince($0) <= 6 } ?? false
        let lastSpoken = lastSpokenAnswerBySession[controllerID] ?? ""

        var matchedEvent: SyncedTranscriptEvent?
        var matchedCommand = ""
        for ev in unseen.reversed() {
            let clean = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if AssistantWakePhraseMatcher.isLikelySelfEcho(
                candidate: clean,
                lastSpoken: lastSpoken,
                isLocal: ev.isOwn,
                withinEchoWindow: inEchoWindow
            ) {
                continue
            }
            if case .command(let cmd) = AssistantWakePhraseMatcher.match(clean),
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchedEvent = ev
                matchedCommand = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            if inFollowUpWindow && clean.count >= 4 {
                matchedEvent = ev
                matchedCommand = clean
                break
            }
        }
        guard let trigger = matchedEvent, !matchedCommand.isEmpty else { return }

        busySessions.insert(controllerID)
        let commandText = matchedCommand
        let speakerName = trigger.speaker ?? (trigger.isOwn ? L("You") : L("Participant"))
        Task { @MainActor [weak self] in
            await self?.handleVoiceTurn(
                controllerID: controllerID,
                title: title,
                skillID: skillID,
                speakerName: speakerName,
                isLocalSpeaker: trigger.isOwn,
                commandText: commandText,
                localNames: localNames
            )
        }
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
            enable(controllerID: controllerID, title: title, skillID: queued)
        } else if skills?.autonomousMeetingVoiceEnabled == true,
                  !manuallyDisabledSessions.contains(controllerID),
                  let matched = skills?.skills.first(where: {
                      $0.enabled && $0.voiceActivation && $0.matches(meetingTitle: title, commandText: "")
                  }) {
            enable(controllerID: controllerID, title: title, skillID: matched.id)
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
        defer { busySessions.remove(controllerID) }
        guard let skills else { return }
        let skill = skills.skills.first(where: { $0.id == skillID })
        let allLocalNames = localNames + [resolveBridge(controllerID)?.localDisplayName ?? ""] + (workspace?.taskProfile.aliases ?? [])
        let allowWrites = isSpeakerAuthorized(
            speakerName: speakerName,
            isLocalSpeaker: isLocalSpeaker,
            skill: skill,
            localNames: allLocalNames
        )

        if !allowWrites, case .none = AssistantWakePhraseMatcher.match(commandText) {
            if lastSpokeAtBySession[controllerID] != nil && !isLocalSpeaker {
                return
            }
        }

        // 1. Optional Realtime acceleration if connected for this call.
        if let rtState = realtimeSessions[controllerID],
           await rtState.router.isRealtimeConnected {
            rtState.lastTurnAllowWrites = allowWrites
            rtState.lastApprovedTranscriptAt = allowWrites ? Date() : nil
            rtState.activeSkillID = skillID
            rtState.approvedSpeakersOnly = skill?.approvedSpeakersOnly ?? true
            rtState.audioChunks.removeAll()
            rtState.transcriptBuffer = ""
            let prefixedPrompt = "[\(speakerName) (approved=\(allowWrites)) in “\(title)”]: \(commandText)"
            if await rtState.router.sendText(prefixedPrompt) {
                lastStatusBySession[controllerID] = L("Realtime model handling request…")
                rtState.turnTimeoutTask?.cancel()
                rtState.turnTimeoutTask = Task { @MainActor [weak self, weak rtState] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, let rtState, !Task.isCancelled else { return }
                    let text = rtState.transcriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    rtState.transcriptBuffer = ""
                    if !text.isEmpty {
                        await self.speakIntoMeeting(text, controllerID: controllerID)
                    }
                }
                return
            }
        }

        // 2. Standard AI + deterministic iOS tool loop fallback.
        let reply = await executeStandardTurn(
            controllerID: controllerID,
            title: title,
            skillID: skillID,
            speakerName: speakerName,
            allowWrites: allowWrites,
            commandText: commandText
        )
        if !reply.isEmpty {
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

        // Direct deterministic board controls when allowed
        if (allowedGroups.isEmpty || allowedGroups.contains(.boardShare)),
           lower.contains("доск") || lower.contains("board") || lower.contains("jira"),
           (lower.contains("открой") || lower.contains("покажи") || lower.contains("open") || lower.contains("show")) {
            let boardURL = skills.teamContext.defaultJiraBoardURL
            if !boardURL.isEmpty, let msg = try? await board?.open(urlString: boardURL) {
                return msg
            }
        }

        // Direct deterministic task creation by approved speaker when allowed
        if allowWrites && (allowedGroups.isEmpty || allowedGroups.contains(.tasks)),
           let extractedTask = Self.extractDirectTaskInstruction(from: commandText, lower: lower) {
            if let created = await skills.createTaskWithPeopleResolution(
                sessionID: resolvedSessionID,
                title: extractedTask.title,
                owner: extractedTask.owner ?? speakerName
            ) {
                return created.resolvedOwner.isEmpty
                    ? L("Created task “%@”.", created.resolvedTitle)
                    : L("Created task “%@” for %@.", created.resolvedTitle, created.resolvedOwner)
            }
        }

        // LLM answer grounded in transcript + Obsidian knowledge + BasePersona + skill instructions
        let knowledgeHits = skills.searchKnowledge(query: commandText, limit: 5)
            .map { "[\($0.kind)] \($0.title): \($0.excerpt)" }
            .joined(separator: "\n")
        let transcriptLines = (recentEventsBySession[controllerID] ?? []).suffix(18).map { ev in
            let speaker = ev.isOwn ? "Owner" : (ev.speaker ?? "Participant")
            return "\(speaker): \(ev.text)"
        }.joined(separator: "\n")

        let sys = """
        \(rendered.basePersona)

        \(rendered.instructions)

        Keep spoken replies crisp (1–3 sentences) in the meeting language so they sound natural over voice.
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
                return await Self.executeSharedTool(
                    name: name,
                    argumentsJSON: argsJSON,
                    sessionID: resolvedSessionID,
                    allowWrites: allowWrites,
                    allowedGroups: skillToolSet,
                    skills: skills,
                    workspace: self.workspace,
                    board: self.board
                )
            }
           ),
           !answer.isEmpty {
            return answer
        }

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

        if let old = realtimeSessions.removeValue(forKey: controllerID) {
            old.turnTimeoutTask?.cancel()
            await old.router.stop()
        }

        let rendered = skills.renderPromptContext(explicitSkillIDs: [skillID], meetingTitle: title)
        let instructions = [rendered.basePersona, rendered.instructions]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let tools = Self.buildToolDeclarations(allowedGroups: skill.map { Set($0.tools) })
        let config = RealtimeSessionConfig(
            provider: kind,
            apiKey: apiKey,
            model: skills.realtimeModel,
            voice: skills.realtimeVoice,
            endpointOverride: skills.realtimeEndpoint,
            systemInstructions: instructions,
            tools: tools
        )

        let state = SessionRealtimeState(activeSkillID: skillID)
        state.approvedSpeakersOnly = skill?.approvedSpeakersOnly ?? true
        realtimeSessions[controllerID] = state
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
        if state.connected {
            attachAudioTap(controllerID: controllerID, state: state)
        }
        syncRealtimeActiveFlag()
    }

    private func attachAudioTap(controllerID: UUID, state: SessionRealtimeState) {
        let router = state.router
        resolveBridge(controllerID)?.setRealtimeAudioTap { [weak self, weak state] streamID, pcm in
            Task { @MainActor [weak self, weak state] in
                guard let self else { return }
                if streamID == "local" {
                    if self.resolveBridge(controllerID)?.isVoiceReplyInFlight() == true
                        || self.isInAudioEchoCooldown(controllerID: controllerID) {
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

    private func isInAudioEchoCooldown(controllerID: UUID) -> Bool {
        guard let ended = lastVoiceDeliveryEndedAtBySession[controllerID] else { return false }
        return Date().timeIntervalSince(ended) < 1.5
    }

    private func executeRealtimeTool(controllerID: UUID, name: String, argumentsJSON: String) async -> String {
        guard let skills else { return "{\"error\":\"Workspace unavailable\"}" }
        guard let state = realtimeSessions[controllerID] else { return "{\"error\":\"Session closed\"}" }
        let skill = skills.skills.first(where: { $0.id == state.activeSkillID })
        let allowedGroups = skill.map { Set($0.tools) }
        let sid = workspace?.workspaceSessionID(forControllerID: controllerID)
        return await Self.executeSharedTool(
            name: name,
            argumentsJSON: argumentsJSON,
            sessionID: sid,
            allowWrites: state.lastTurnAllowWrites,
            allowedGroups: allowedGroups,
            skills: skills,
            workspace: workspace,
            board: board
        )
    }

    static func executeSharedTool(
        name: String,
        argumentsJSON: String,
        sessionID: UUID?,
        allowWrites: Bool,
        allowedGroups: Set<AssistantSkillToolGroup>?,
        skills: IOSAssistantSkillsController,
        workspace: IOSWorkspaceCoordinator?,
        board: IOSAssistantBoardController?,
        directTalkJoinHandler: ((String, String?) async -> String)? = nil,
        joinableTargetsProvider: (() -> [JoinableMeetingCandidate])? = nil
    ) async -> String {
        func allows(_ group: AssistantSkillToolGroup) -> Bool {
            allowedGroups?.contains(group) ?? true
        }

        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]

        switch name {
        case "rocknroll_search_knowledge":
            let q = (args["query"] as? String) ?? ""
            let limit = (args["limit"] as? Int) ?? 8
            var items = skills.searchKnowledge(query: q, limit: limit).map {
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
                guard allowWrites else { return "{\"error\":\"Approved speaker required\"}" }
                guard let display = (args["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !display.isEmpty else {
                    return "{\"error\":\"display_name required\"}"
                }
                let entry = AssistantPersonEntry(
                    displayName: display,
                    aliases: args["aliases"] as? [String] ?? [],
                    jiraUsername: args["jira_username"] as? String,
                    jiraAccountID: args["jira_account_id"] as? String,
                    email: args["email"] as? String,
                    role: args["role"] as? String,
                    approvedVoiceCommander: (args["approved_voice_commander"] as? Bool) ?? false,
                    notes: args["notes"] as? String
                )
                let updated = try? skills.upsertPerson(entry)
                return jsonString(["saved": updated != nil, "display_name": display])
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
            return jsonString(["items": matches.map {
                [
                    "id": $0.id,
                    "display_name": $0.displayName,
                    "jira_username": $0.jiraUsername ?? "",
                    "jira_account_id": $0.jiraAccountID ?? "",
                    "approved": $0.approvedVoiceCommander
                ] as [String: Any]
            }])

        case "rocknroll_create_task":
            guard allowWrites && (allows(.tasks) || allows(.jira)) else { return "{\"error\":\"Task creation not allowed\"}" }
            guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return "{\"error\":\"title required\"}"
            }
            let created = await skills.createTaskWithPeopleResolution(
                sessionID: sessionID,
                title: title,
                owner: args["owner"] as? String,
                dueDay: args["due_day"] as? String,
                syncToJira: (args["sync_to_jira"] as? Bool) ?? false
            )
            return jsonString([
                "created": created != nil,
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
            let ok = await skills.updateMeetingArtifacts(
                sessionID: sessionID,
                summaryAppend: args["summary_append"] as? String,
                replaceSummary: args["replace_summary"] as? String,
                decisions: args["decisions"] as? [String] ?? [],
                openQuestions: args["open_questions"] as? [String] ?? [],
                actionItems: actionItems
            )
            return jsonString(["updated": ok, "action_items_added": actionItems.count])

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
            do {
                let issues = try await skills.searchJiraIssues(
                    jql: args["jql"] as? String,
                    query: args["query"] as? String,
                    maxResults: (args["max_results"] as? Int) ?? 15
                )
                return jsonString(["issues": issues.map { ["key": $0.key, "summary": $0.summary, "status": $0.statusName, "assignee": $0.assigneeName ?? ""] }])
            } catch {
                return jsonString(["error": error.localizedDescription])
            }

        case "rocknroll_control_board":
            guard allows(.boardShare), let board else { return "{\"error\":\"Board unavailable\"}" }
            let cmd = (args["command"] as? String) ?? "inspect"
            do {
                switch cmd {
                case "open_url":
                    let url = ((args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? skills.teamContext.defaultJiraBoardURL
                    let msg = try await board.open(urlString: url)
                    return jsonString(["message": msg])
                case "filter":
                    return jsonString(["message": try await board.filter(query: (args["query"] as? String) ?? (args["text"] as? String) ?? "")])
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
            busySessions.remove(controllerID)
            let combined = state.audioChunks.reduce(into: Data()) { $0.append($1) }
            state.audioChunks.removeAll()
            let text = state.transcriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            state.transcriptBuffer = ""
            if let buffer = RealtimeVoiceAudio.pcm16ToAudioBuffer(data: combined, sampleRate: 24_000) {
                await deliverSpokenBuffer(buffer, fallbackText: text, controllerID: controllerID)
            } else if !text.isEmpty {
                await speakIntoMeeting(text, controllerID: controllerID)
            }
        case .error(let msg):
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            busySessions.remove(controllerID)
            lastStatusBySession[controllerID] = L("Realtime fallback active (%@)", msg)
            state.connected = false
            syncRealtimeActiveFlag()
        case .disconnected:
            state.turnTimeoutTask?.cancel()
            state.turnTimeoutTask = nil
            busySessions.remove(controllerID)
            state.connected = false
            syncRealtimeActiveFlag()
        default:
            break
        }
    }

    func speakIntoMeeting(_ text: String, controllerID: UUID) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lastSpokeAtBySession[controllerID] = Date()
        lastSpokenAnswerBySession[controllerID] = clean
        defer { lastVoiceDeliveryEndedAtBySession[controllerID] = Date() }

        if let bridge = resolveBridge(controllerID) {
            do {
                try await bridge.speakVoice(clean)
                lastStatusBySession[controllerID] = L("Spoken into “%@”.", bridge.title)
                return
            } catch {
                // Fall back to local voice auditioning when call audio is off/disconnected.
            }
        }
        if let buffer = try? await IOSVoiceStore.shared.synthesizeAssistantResponse(clean) {
            try? IOSVoicePreviewPlayer.shared.play(buffer)
        }
        lastStatusBySession[controllerID] = L("Auditioned locally (meeting audio off).")
    }

    private func deliverSpokenBuffer(_ buffer: AVAudioPCMBuffer, fallbackText: String, controllerID: UUID) async {
        lastSpokeAtBySession[controllerID] = Date()
        if !fallbackText.isEmpty {
            lastSpokenAnswerBySession[controllerID] = fallbackText
        }
        defer { lastVoiceDeliveryEndedAtBySession[controllerID] = Date() }

        if let bridge = resolveBridge(controllerID) {
            if let speakBuffer = bridge.speakAudioBuffer {
                do {
                    try await speakBuffer(buffer)
                    lastStatusBySession[controllerID] = L("Spoken into “%@”.", bridge.title)
                    return
                } catch {}
            }
            if !fallbackText.isEmpty {
                do {
                    try await bridge.speakVoice(fallbackText)
                    lastStatusBySession[controllerID] = L("Spoken into “%@”.", bridge.title)
                    return
                } catch {}
            }
        }
        try? IOSVoicePreviewPlayer.shared.play(buffer)
        lastStatusBySession[controllerID] = L("Auditioned locally (meeting audio off).")
    }

    private func syncRealtimeActiveFlag() {
        realtimeActive = realtimeSessions.values.contains(where: \.connected)
    }

    // MARK: - Helpers

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
                    body["max_completion_tokens"] = 500
                } else {
                    body["max_tokens"] = 500
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
                      let message = choices.first?["message"] as? [String: Any] else {
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

                if let content = message["content"] as? String {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
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
            tokenLimit: 500,
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
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        "jira_username": ["type": "string"],
                        "jira_account_id": ["type": "string"],
                        "approved_voice_commander": ["type": "boolean"]
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
                description: "Search Jira issues or add a comment to a Jira issue.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "operation": ["type": "string", "enum": ["search", "comment"]],
                        "jql": ["type": "string"],
                        "query": ["type": "string"],
                        "issue_key": ["type": "string"],
                        "comment": ["type": "string"]
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
                description: "Control the in-app Assistant Board browser (open_url, filter, scroll, click, click_at, highlight, inspect, snapshot).",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "enum": ["open_url", "filter", "scroll", "click", "click_at", "highlight", "inspect", "snapshot"]],
                        "url": ["type": "string"],
                        "query": ["type": "string"],
                        "text": ["type": "string"],
                        "selector": ["type": "string"],
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
