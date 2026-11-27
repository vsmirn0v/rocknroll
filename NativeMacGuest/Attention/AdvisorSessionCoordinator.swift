import ConferenceCore
import Foundation

/// Runs silent in-meeting `observe` (structured Role Notes) and `advise` (live coaching probes,
/// contradictions, rubric pacing, and private Whisper Q&A) across one or more live meetings.
///
/// Enforces a hard outbound mute lock: `.observe` and `.advise` never open Realtime voice
/// sessions, synthesize TTS, send meeting chat messages/reactions, or open external shared boards.
@MainActor
final class AdvisorSessionCoordinator: ObservableObject {
    struct ActiveSession: Equatable {
        var sessionID: UUID
        var skillID: String
        var presetID: String?
        var mode: AssistantEngagementMode
        var startedAt: Date
        var focusSpeakers: [String] = []
        var adHocContext: String = ""
        var backfilledFromStart: Bool = false
        var lastEvaluatedLineCount: Int = 0
        var lastEvaluatedAt: Date? = nil
        var isEvaluating: Bool = false
        var lastError: String? = nil
    }

    @Published private(set) var activeSessions: [UUID: ActiveSession] = [:]
    @Published private(set) var observationsBySession: [UUID: [RoleObservationItem]] = [:]
    @Published private(set) var lastStatusBySession: [UUID: String] = [:]
    @Published private(set) var isEvaluatingSession: Set<UUID> = []

    weak var attention: AttentionCoordinator?
    private let evaluationService = PortableExpertEvaluationService()
    private var evalTasks: [UUID: Task<Void, Never>] = [:]
    private let cadenceSeconds: TimeInterval = 18

    init(attention: AttentionCoordinator? = nil) {
        self.attention = attention
    }

    /// Hard Outbound Mute Lock: `observe` and `advise` must never speak or post to the room.
    func isOutboundMuted(sessionID: UUID) -> Bool {
        guard let session = activeSessions[sessionID] else { return false }
        return session.mode.isSilentToRoom
    }

    func activeMode(for sessionID: UUID) -> AssistantEngagementMode? {
        activeSessions[sessionID]?.mode
    }

    func activeSkillID(for sessionID: UUID) -> String? {
        activeSessions[sessionID]?.skillID
    }

    func enable(
        for model: NativeDesktopMeetingModel,
        skillID: String,
        presetID: String? = nil,
        mode: AssistantEngagementMode,
        focusSpeakers: [String] = [],
        adHocContext: String = ""
    ) {
        precondition(mode == .observe || mode == .advise, "AdvisorSessionCoordinator only runs observe or advise modes.")
        let sid = model.sessionID
        let canonicalSkillID = AssistantSkill.sanitizedSlug(from: skillID)
        let resolvedSkillID = canonicalSkillID.isEmpty ? AssistantSkill.personalAssistantID : canonicalSkillID
        let existing = activeSessions[sid]
        let sameRole = existing?.skillID == resolvedSkillID && existing?.presetID == presetID

        var session = existing ?? ActiveSession(
            sessionID: sid,
            skillID: resolvedSkillID,
            presetID: presetID,
            mode: mode,
            startedAt: model.connectedSince ?? Date()
        )
        session.skillID = resolvedSkillID
        session.presetID = presetID
        session.mode = mode
        if !focusSpeakers.isEmpty { session.focusSpeakers = focusSpeakers }
        if !adHocContext.isEmpty { session.adHocContext = adHocContext }
        if !sameRole {
            session.backfilledFromStart = false
            session.lastEvaluatedLineCount = 0
        }
        activeSessions[sid] = session
        lastStatusBySession[sid] = mode == .observe ? L("Observing silently") : L("Advising privately")

        // Hydrate any persisted Role Notes so switching Observe <-> Advise or reconnecting keeps notes intact.
        if observationsBySession[sid] == nil, let attention {
            Task { @MainActor [weak self, weak attention] in
                guard let self, let attention else { return }
                if let log = try? await attention.store.meetingLibrary.store.roleObservations(for: sid) {
                    if self.observationsBySession[sid] == nil {
                        self.observationsBySession[sid] = log.items.filter { !$0.isDismissed }
                    }
                }
            }
        }
        model.participation.cancelPendingDispatch()
    }

    func disable(for sessionID: UUID) {
        evalTasks.removeValue(forKey: sessionID)?.cancel()
        isEvaluatingSession.remove(sessionID)
        activeSessions.removeValue(forKey: sessionID)
        lastStatusBySession.removeValue(forKey: sessionID)
    }

    func prune(liveSessionIDs: Set<UUID>) {
        for sid in Array(activeSessions.keys) where !liveSessionIDs.contains(sid) {
            disable(for: sid)
        }
    }

    func processTick(models: [NativeDesktopMeetingModel], prioritizedSessionIDs: [UUID]) {
        guard let attention else { return }
        let now = Date()
        let modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.sessionID, $0) })

        // P1 (.advise) is evaluated ahead of P2 (.observe) in prioritizedSessionIDs order.
        for sid in prioritizedSessionIDs {
            guard let model = modelsByID[sid], !model.isClosed, model.connected,
                  var session = activeSessions[sid],
                  !session.isEvaluating,
                  evalTasks[sid] == nil else {
                continue
            }
            let currentLineCount = model.transcript.count + model.chat.items.count
            guard currentLineCount > 0 else { continue }

            let needsBackfill = !session.backfilledFromStart
            let hasNewLines = currentLineCount > session.lastEvaluatedLineCount
            let cadenceElapsed = now.timeIntervalSince(session.lastEvaluatedAt ?? .distantPast) >= cadenceSeconds
            guard needsBackfill || (hasNewLines && cadenceElapsed) else { continue }

            session.isEvaluating = true
            session.backfilledFromStart = true
            session.lastEvaluatedLineCount = currentLineCount
            session.lastEvaluatedAt = now
            activeSessions[sid] = session
            isEvaluatingSession.insert(sid)

            evalTasks[sid] = Task { @MainActor [weak self, weak model, weak attention] in
                defer {
                    self?.evalTasks.removeValue(forKey: sid)
                    self?.isEvaluatingSession.remove(sid)
                    if var current = self?.activeSessions[sid] {
                        current.isEvaluating = false
                        self?.activeSessions[sid] = current
                    }
                }
                guard let self, let model, let attention, !Task.isCancelled else { return }
                await self.runEvaluationPass(model: model, attention: attention, whisperQuestion: nil)
            }
            // One live advisor LLM pass per tick preserves API headroom & battery.
            break
        }
    }

    @discardableResult
    func whisper(_ question: String, in model: NativeDesktopMeetingModel) async throws -> [RoleObservationItem] {
        guard let attention else {
            throw MeetingOutcomeFailure.configuration
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else { return [] }
        let sid = model.sessionID
        if activeSessions[sid] == nil {
            let role = attention.effectiveRoleAndMode(for: model)
            enable(for: model, skillID: role.skillID, presetID: role.presetID, mode: .advise)
        }
        isEvaluatingSession.insert(sid)
        defer { isEvaluatingSession.remove(sid) }
        return await runEvaluationPass(model: model, attention: attention, whisperQuestion: cleanQuestion)
    }

    func togglePin(observationID: UUID, sessionID: UUID) {
        guard var list = observationsBySession[sessionID],
              let idx = list.firstIndex(where: { $0.id == observationID }) else { return }
        list[idx].isPinned.toggle()
        list[idx].updatedAt = Date()
        observationsBySession[sessionID] = list
        persistObservations(list, sessionID: sessionID)
    }

    func dismiss(observationID: UUID, sessionID: UUID) {
        guard var list = observationsBySession[sessionID],
              let idx = list.firstIndex(where: { $0.id == observationID }) else { return }
        list[idx].isDismissed = true
        list[idx].updatedAt = Date()
        observationsBySession[sessionID] = list
        persistObservations(list, sessionID: sessionID)
    }

    func insertIntoNotes(observationID: UUID, sessionID: UUID, noteSessionID: UUID) {
        guard let attention,
              var list = observationsBySession[sessionID],
              let idx = list.firstIndex(where: { $0.id == observationID }) else { return }
        var item = list[idx]
        item.copiedToNotesAt = Date()
        item.updatedAt = Date()
        list[idx] = item
        observationsBySession[sessionID] = list
        persistObservations(list, sessionID: sessionID)

        let existing = attention.store.notes.buffer(sessionID: noteSessionID)
        let prefix = item.isPinned ? "★ " : ""
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = item.evidenceRefs.isEmpty ? "" : " " + item.evidenceRefs.map { "[\($0)]" }.joined()
        let line = title.isEmpty ? "- \(prefix)\(body)\(refs)" : "- \(prefix)**\(title)**: \(body)\(refs)"
        let next = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? line
            : existing.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n" + line
        attention.store.notes.update(sessionID: noteSessionID, text: next)
    }

    @discardableResult
    private func runEvaluationPass(
        model: NativeDesktopMeetingModel,
        attention: AttentionCoordinator,
        whisperQuestion: String?
    ) async -> [RoleObservationItem] {
        let sid = model.sessionID
        guard let active = activeSessions[sid] else { return [] }
        assert(active.mode.isSilentToRoom, "AdvisorSessionCoordinator only runs silent modes")

        let (skills, presets, people, teamContext) = await attention.withCompositeSkillRepository { composite, _ in
            (composite.listSkills(), composite.listPresets(), composite.primary.loadPeople(), composite.primary.loadTeamContext())
        }
        let skill = skills.first(where: { $0.id == active.skillID })
            ?? DefaultAssistantSkills.skill(id: active.skillID)
            ?? DefaultAssistantSkills.personalAssistant
        let preset = active.presetID.flatMap { pid in presets.first(where: { $0.skillID == skill.id && $0.id == pid }) }

        let events = Self.syncedEvents(from: model)
        let notes = attention.store.notes.buffer(sessionID: model.activeNoteSessionID)
        let provider = attention.store.effectiveWriter
        let (config, keyProvider) = Self.portableConfiguration(for: provider, store: attention.store)

        let localNames = attention.store.profile.names(fallback: model.displayName)
        let teamNames = teamContext.notes.isEmpty ? people.entries.map(\.displayName) : people.entries.map(\.displayName)
        let detectedFocus = !active.focusSpeakers.isEmpty
            ? active.focusSpeakers
            : (skill.id == "hiring-interviewer"
                ? Array(FullTranscriptEvaluationWindowBuilder.detectedExternalSpeakers(
                    events: events,
                    localNames: localNames,
                    teamMemberNames: teamNames
                ).prefix(2))
                : [])

        let window = FullTranscriptEvaluationWindowBuilder.build(
            events: events,
            notes: notes,
            focusSpeakers: detectedFocus,
            focusSpeakerRole: preset?.focusSpeakerRole ?? "",
            localNames: localNames,
            teamMemberNames: teamNames,
            contextTokens: config.contextTokens,
            onDevice: config.providerKind == .appleOnDevice
        )
        let previous = observationsBySession[sid] ?? []
        let service = PortableExpertEvaluationService(apiKeyProvider: keyProvider)

        do {
            let response = try await service.evaluateLiveAdvisor(
                meetingTitle: model.title,
                mode: whisperQuestion == nil ? active.mode : .advise,
                skill: skill,
                preset: preset,
                adHocContext: active.adHocContext,
                focusSpeakers: detectedFocus,
                window: window,
                previousObservations: previous,
                notes: notes,
                whisperQuestion: whisperQuestion,
                language: attention.language,
                configuration: config
            )
            guard !Task.isCancelled else { return [] }
            let now = Date()
            var created: [RoleObservationItem] = []
            for entry in response.entries {
                let cleanBody = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanBody.isEmpty else { continue }
                let duplicate = previous.contains {
                    !$0.isDismissed && $0.title.caseInsensitiveCompare(entry.title) == .orderedSame
                        && $0.body.caseInsensitiveCompare(cleanBody) == .orderedSame
                }
                guard !duplicate else { continue }
                let evidenceIDs = entry.evidenceRefs.compactMap { window.refToEventID[$0] }
                let item = RoleObservationItem(
                    sessionID: sid,
                    skillID: skill.id,
                    presetID: preset?.id,
                    mode: whisperQuestion == nil ? active.mode : .advise,
                    kind: entry.kind,
                    title: entry.title,
                    body: cleanBody,
                    evidenceLineIDs: evidenceIDs,
                    evidenceRefs: entry.evidenceRefs,
                    createdAt: now,
                    updatedAt: now
                )
                created.append(item)
            }
            if !created.isEmpty {
                var updated = previous
                if whisperQuestion != nil {
                    updated.insert(contentsOf: created, at: 0)
                } else {
                    updated.append(contentsOf: created)
                }
                observationsBySession[sid] = updated
                persistObservations(updated, sessionID: sid)
            }
            if var current = activeSessions[sid] {
                current.lastError = nil
                activeSessions[sid] = current
            }
            return created
        } catch {
            if var current = activeSessions[sid] {
                current.lastError = error.localizedDescription
                activeSessions[sid] = current
            }
            return []
        }
    }

    private func persistObservations(_ items: [RoleObservationItem], sessionID: UUID) {
        guard let attention else { return }
        let deviceID = attention.store.meetingLibrary.store.storeRoot.lastPathComponent
        let now = Date()
        Task {
            let previous = try? await attention.store.meetingLibrary.store.roleObservations(for: sessionID)
            let nextCounter = (previous?.version.counter ?? 0) + 1
            let log = SyncedRoleObservationLog(
                sessionID: sessionID,
                items: items,
                version: SyncVersion(counter: nextCounter, device: deviceID),
                updatedAt: now
            )
            try? await attention.store.meetingLibrary.store.upsertRoleObservations(log)
        }
    }

    static func syncedEvents(from model: NativeDesktopMeetingModel) -> [SyncedTranscriptEvent] {
        var events: [SyncedTranscriptEvent] = []
        for msg in model.transcript {
            let at = NativeDesktopMeetingModel.spokenAt(msg) ?? msg.sentAt ?? Date()
            events.append(SyncedTranscriptEvent(
                id: "t:" + msg.id,
                kind: "transcript",
                occurredAt: at,
                speaker: msg.participantName,
                isOwn: msg.isOwn,
                speakerRole: nil,
                text: msg.text,
                deviceID: "local"
            ))
        }
        for chat in model.chat.items {
            events.append(SyncedTranscriptEvent(
                id: "c:" + chat.id,
                kind: "chat",
                occurredAt: chat.sentAt,
                speaker: chat.sender,
                isOwn: chat.isOwn,
                speakerRole: nil,
                text: chat.text,
                deviceID: "local"
            ))
        }
        return events.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
    }

    static func portableConfiguration(
        for provider: AttentionProvider,
        store: AttentionStore
    ) -> (config: PortableOutcomeConfiguration, apiKeyProvider: @Sendable (PortableOutcomeProviderKind) -> String?) {
        let kind: PortableOutcomeProviderKind = switch provider.kind {
        case .apple: .appleOnDevice
        case .openAI: .openAI
        case .openRouter: .openRouter
        case .local, .rapidMLX, .custom: .custom
        }
        let config = PortableOutcomeConfiguration(
            autoGenerateOnLeave: store.generateOutcomes,
            providerKind: kind,
            baseURL: provider.baseURL,
            model: provider.model,
            contextTokens: provider.contextLength
        )
        let capturedKey = store.apiKey(for: provider)
        return (config, { _ in capturedKey })
    }
}
