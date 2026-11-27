import ConferenceCore
import Foundation

extension AttentionCoordinator {
    func configuredRoleAndMode(
        for model: NativeDesktopMeetingModel
    ) -> (skillID: String, presetID: String?, mode: AssistantEngagementMode, coreOutcomePolicy: CoreOutcomePolicy, destinationID: UUID?, routeEntireMeeting: Bool?) {
        let seriesIDs = [model.participationCalendar?.externalSeriesID, model.calendarSeriesID].compactMap { $0 }
        let presetConfig = store.autoFacilitatorConfiguration(
            room: model.invitation,
            seriesIDs: seriesIDs
        )
        let skillID = presetConfig.skillID ?? AssistantSkill.personalAssistantID
        let fallbackMode: AssistantEngagementMode = {
            if let explicit = presetConfig.mode { return explicit }
            if presetConfig.skillID != nil { return .facilitate }
            switch resolvedMode(model).mode {
            case .off: return .off
            case .mentions: return .mentions
            case .watch: return .follow
            }
        }()
        return (
            skillID: skillID,
            presetID: presetConfig.presetID,
            mode: fallbackMode,
            coreOutcomePolicy: presetConfig.coreOutcomePolicy ?? .full,
            destinationID: presetConfig.exportDestinationID,
            routeEntireMeeting: presetConfig.routeEntireMeeting
        )
    }

    func effectiveRoleAndMode(
        for model: NativeDesktopMeetingModel
    ) -> (skillID: String, presetID: String?, mode: AssistantEngagementMode) {
        let sid = model.sessionID
        if let active = advisorCoordinator?.activeSessions[sid] {
            return (active.skillID, active.presetID, active.mode)
        }
        if let facSkill = facilitator?.activeSessionSkills[sid] {
            let presetID = activeMeetingRoles[sid]?.presetID
            return (facSkill, presetID, .facilitate)
        }
        if model.participation.status != .inactive {
            let role = activeMeetingRoles[sid]
            return (role?.skillID ?? AssistantSkill.personalAssistantID, role?.presetID, .participate)
        }
        if let active = activeMeetingRoles[sid] {
            return active
        }
        let attMode = resolvedMode(model).mode
        let mapped: AssistantEngagementMode = switch attMode {
        case .off: .off
        case .mentions: .mentions
        case .watch: .follow
        }
        return (AssistantSkill.personalAssistantID, nil, mapped)
    }

    /// Single-entry-point setter enforcing one active `(Role × Preset × EngagementMode)` per meeting
    /// and updating `DominantRoleResolver` + SQLite `dominantRole` / `roleSegments`.
    func setMeetingRoleAndMode(
        model: NativeDesktopMeetingModel,
        skillID: String,
        presetID: String?,
        mode: AssistantEngagementMode,
        scope: ModeScope = .untilLeave
    ) {
        let sid = model.sessionID
        let normalizedSkillID = AssistantSkill.sanitizedSlug(from: skillID)
        let resolvedSkillID = normalizedSkillID.isEmpty ? AssistantSkill.personalAssistantID : normalizedSkillID

        // Tear down superseded active engines before activating the new mode.
        if mode != .participate && model.participation.status != .inactive {
            model.participation.stop()
        }
        if mode != .facilitate && facilitator?.activeSessionSkills[sid] != nil {
            facilitator?.disable(for: sid)
        }
        if !mode.isAdvisorFamily && advisorCoordinator?.activeSessions[sid] != nil {
            advisorCoordinator?.disable(for: sid)
        }

        if mode == .off {
            activeMeetingRoles.removeValue(forKey: sid)
            setMode(.off, for: model, scope: scope)
        } else {
            activeMeetingRoles[sid] = (resolvedSkillID, presetID, mode)
            switch mode {
            case .off:
                break
            case .mentions:
                setMode(.mentions, for: model, scope: scope)
            case .follow:
                setMode(.watch, for: model, scope: scope)
            case .observe, .advise:
                setMode(.off, for: model, scope: .untilLeave)
                Task { @MainActor [weak self, weak model] in
                    guard let self, let model, !model.isClosed else { return }
                    let (skills, presets) = await self.withCompositeSkillRepository { repo, _ in (repo.listSkills(), repo.listPresets()) }
                    let resolvedSkill = skills.first(where: { $0.id == resolvedSkillID })
                        ?? DefaultAssistantSkills.skill(id: resolvedSkillID)
                        ?? DefaultAssistantSkills.personalAssistant
                    let resolvedPreset = presetID.flatMap { pid in presets.first(where: { $0.skillID == resolvedSkill.id && $0.id == pid }) }
                    self.advisorCoordinator?.enable(for: model, skillID: resolvedSkill.id, presetID: resolvedPreset?.id, mode: mode)
                }
            case .participate:
                setMode(.watch, for: model, scope: .untilLeave)
                if model.participation.status == .paused {
                    model.participation.resume()
                } else if model.participation.status == .inactive {
                    participationPromptMeetingID = model.sessionID
                }
            case .facilitate:
                setMode(.off, for: model, scope: .untilLeave)
                facilitator?.enable(for: model, skillID: resolvedSkillID, suppressAutoGreet: false, trigger: "manual-unified")
            }
        }

        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            await self.recordLiveRoleSwitch(model: model, skillID: resolvedSkillID, presetID: presetID, mode: mode)
        }
    }

    func recordLiveRoleSwitch(
        model: NativeDesktopMeetingModel,
        skillID: String,
        presetID: String?,
        mode: AssistantEngagementMode
    ) async {
        let sid = model.workspaceSessionID
        let (skills, destinations) = await (
            withCompositeSkillRepository { repo, _ in repo.listSkills() },
            (try? await store.meetingLibrary.store.destinations()) ?? []
        )
        let skill = skills.first(where: { $0.id == skillID }) ?? DefaultAssistantSkills.skill(id: skillID)
        let seriesIDs = [model.participationCalendar?.externalSeriesID, model.calendarSeriesID].compactMap { $0 }
        let presetOverrides = store.autoFacilitatorConfiguration(room: model.invitation, seriesIDs: seriesIDs)

        let slugDestID = skill?.owningDestinationID
            ?? skill?.exportDestinationSlug.flatMap { slug in
                destinations.first(where: { $0.resolvedSlug.caseInsensitiveCompare(slug) == .orderedSame })?.id
            }
        let targetDestID = presetOverrides.exportDestinationID ?? slugDestID
        let routeEntire = presetOverrides.routeEntireMeeting ?? skill?.routeEntireMeeting ?? false
        let policy = presetOverrides.coreOutcomePolicy ?? skill?.coreOutcomePolicy ?? .full

        guard let existingSession = try? await store.meetingLibrary.store.session(sid) else { return }
        let resolved = DominantRoleResolver.resolveLiveSwitch(
            existingSegments: existingSession.roleSegments,
            previousDominant: existingSession.dominantRole,
            newSkillID: skillID,
            newPresetID: presetID,
            newMode: mode,
            coreOutcomePolicy: policy,
            exportDestinationID: targetDestID,
            routeEntireMeeting: routeEntire
        )
        try? await store.meetingLibrary.store.setSessionRoleState(
            sid,
            dominantRole: resolved.dominantRole,
            roleSegments: resolved.segments,
            bumpExportRevision: false
        )
        await store.meetingLibrary.refresh()
    }

    func effectiveCoreOutcomePolicy(
        forSessionID sessionID: UUID,
        room: URL?,
        latest: URL? = nil,
        seriesIDs: [String] = []
    ) async -> CoreOutcomePolicy {
        let session = try? await store.meetingLibrary.store.session(sessionID)
        let presetConfig = store.autoFacilitatorConfiguration(room: room, latest: latest, seriesIDs: seriesIDs)
        return DominantRoleResolver.effectiveCoreOutcomePolicy(
            dominantRole: session?.dominantRole,
            skill: nil,
            preset: nil,
            perMeetingOverride: presetConfig.coreOutcomePolicy
        )
    }

    func autoCaptureExpertBlockIfNeeded(
        forSessionID sessionID: UUID,
        title: String,
        endedAt: Date,
        invitation: URL?,
        seriesID: String?,
        events: [SyncedTranscriptEvent]
    ) async {
        guard let session = try? await store.meetingLibrary.store.session(sessionID),
              let dominant = session.dominantRole else { return }
        let shouldGenerate = dominant.skillID != AssistantSkill.personalAssistantID
            || dominant.mode.isAdvisorFamily
            || dominant.mode == .facilitate
            || dominant.coreOutcomePolicy == .expertOnly
        guard shouldGenerate else { return }
        guard !events.isEmpty else { return }
        let existing = (try? await store.meetingLibrary.store.expertBlocks(for: sessionID)) ?? []
        if existing.contains(where: { $0.skillID == dominant.skillID && $0.presetID == dominant.presetID }) {
            return
        }
        _ = try? await generateExpertSummary(
            sessionID: sessionID,
            skillID: dominant.skillID,
            presetID: dominant.presetID,
            focusSpeakers: nil,
            adHocContext: "",
            exportDestinationID: dominant.exportDestinationID,
            routeEntireMeeting: dominant.routeEntireMeeting,
            makePrimary: true,
            preloadedEvents: events,
            titleOverride: title,
            endedAtOverride: endedAt
        )
    }

    @discardableResult
    func generateExpertSummary(
        sessionID: UUID,
        skillID: String,
        presetID: String? = nil,
        focusSpeakers: [String]? = nil,
        adHocContext: String = "",
        exportDestinationID: UUID? = nil,
        routeEntireMeeting: Bool? = nil,
        makePrimary: Bool? = nil,
        useSavedSnapshotFromBlockID: UUID? = nil,
        preloadedEvents: [SyncedTranscriptEvent]? = nil,
        titleOverride: String? = nil,
        endedAtOverride: Date? = nil
    ) async throws -> SyncedMeetingExpertBlock {
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary.store
        guard let session = try await library.session(sessionID) else {
            throw MeetingLibraryError.invalidSession
        }

        let (skills, presets, people, teamContext) = await withCompositeSkillRepository { composite, _ in
            (composite.listSkills(), composite.listPresets(), composite.primary.loadPeople(), composite.primary.loadTeamContext())
        }
        let cleanSkillID = AssistantSkill.sanitizedSlug(from: skillID)
        let existingBlock: SyncedMeetingExpertBlock? = try await library.expertBlocks(for: sessionID)
            .first(where: { $0.id == useSavedSnapshotFromBlockID })

        let skill: AssistantSkill
        let preset: AssistantRolePreset?
        let resolvedContext: String
        let resolvedFocus: [String]
        let resolvedDestID: UUID?
        let resolvedRouteEntire: Bool

        if let existingBlock, useSavedSnapshotFromBlockID != nil {
            let snap = existingBlock.contextSnapshot.value
            skill = AssistantSkill(
                id: cleanSkillID,
                name: snap.skillName,
                role: snap.skillName,
                defaultMode: .advise,
                coreOutcomePolicy: session.dominantRole?.coreOutcomePolicy ?? .full,
                summaryBlockTitle: existingBlock.title.value,
                summaryVisibility: existingBlock.visibility.value,
                exportDestinationSlug: nil,
                routeEntireMeeting: existingBlock.routeEntireMeeting.value,
                instructions: snap.capturedInstructions
            )
            preset = snap.presetName.map {
                AssistantRolePreset(
                    id: existingBlock.presetID ?? AssistantSkill.sanitizedSlug(from: $0),
                    skillID: cleanSkillID,
                    name: $0,
                    rubricDimensions: snap.rubricDimensions,
                    instructions: snap.capturedInstructions
                )
            }
            resolvedContext = adHocContext.isEmpty ? snap.adHocContext : adHocContext
            resolvedFocus = focusSpeakers ?? snap.focusSpeakers
            resolvedDestID = exportDestinationID ?? existingBlock.exportDestinationID.value
            resolvedRouteEntire = routeEntireMeeting ?? existingBlock.routeEntireMeeting.value
        } else {
            skill = skills.first(where: { $0.id == cleanSkillID })
                ?? DefaultAssistantSkills.skill(id: cleanSkillID)
                ?? DefaultAssistantSkills.personalAssistant
            preset = presetID.flatMap { pid in presets.first(where: { $0.skillID == skill.id && $0.id == pid }) }
            resolvedContext = adHocContext
            let destinations = (try? await library.destinations()) ?? []
            let slugDestID = preset?.exportDestinationSlug.flatMap { slug in
                destinations.first(where: { $0.resolvedSlug.caseInsensitiveCompare(slug) == .orderedSame })?.id
            } ?? skill.owningDestinationID ?? skill.exportDestinationSlug.flatMap { slug in
                destinations.first(where: { $0.resolvedSlug.caseInsensitiveCompare(slug) == .orderedSame })?.id
            }
            resolvedDestID = exportDestinationID ?? slugDestID
            resolvedRouteEntire = routeEntireMeeting ?? skill.routeEntireMeeting
            resolvedFocus = focusSpeakers ?? []
        }

        let events: [SyncedTranscriptEvent]
        if let preloadedEvents, !preloadedEvents.isEmpty {
            events = preloadedEvents
        } else {
            let journalEvents = store.meetingLibrary.workspaceJournal.exportSyncedEvents(sessionID: sessionID, deviceID: "")
            if !journalEvents.isEmpty {
                events = journalEvents
            } else {
                let archive = TranscriptArchiveStore(preferences: .standard)
                events = (await archive.loadTranscript(sessionID: sessionID) ?? []).sorted {
                    ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id)
                }
            }
        }

        let notes = (try? await library.note(sessionID))?.markdown ?? ""
        let obsLog = (try? await library.roleObservations(for: sessionID))?.items ?? []
        let pinnedObs = obsLog.filter { $0.skillID == skill.id && $0.isPinned && !$0.isDismissed }
        let dismissedObs = obsLog.filter { $0.skillID == skill.id && $0.isDismissed }
        let visualRecords = await MeetingSnapshotStore.shared.snapshots(for: sessionID)
        let visualCaptions = visualRecords.compactMap { snap -> (at: Date, caption: String)? in
            let text = snap.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (snap.capturedAt, text)
        }

        let provider = store.effectiveWriter
        let (config, keyProvider) = AdvisorSessionCoordinator.portableConfiguration(for: provider, store: store)
        let localNames = store.profile.names(fallback: L("You"))
        let teamNames = (teamContext.notes.isEmpty && people.entries.isEmpty) ? [] : people.entries.map(\.displayName)
        let finalFocus = !resolvedFocus.isEmpty
            ? resolvedFocus
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
            snapshotCaptions: visualCaptions,
            focusSpeakers: finalFocus,
            focusSpeakerRole: preset?.focusSpeakerRole ?? "",
            localNames: localNames,
            teamMemberNames: teamNames,
            contextTokens: config.contextTokens,
            onDevice: config.providerKind == .appleOnDevice
        )

        let service = PortableExpertEvaluationService(apiKeyProvider: keyProvider)
        let result = try await service.generateExpertBlock(
            meetingTitle: titleOverride ?? session.title,
            endedAt: endedAtOverride ?? session.endedAt ?? Date(),
            skill: skill,
            preset: preset,
            adHocContext: resolvedContext,
            focusSpeakers: finalFocus,
            window: window,
            notes: notes,
            pinnedObservations: pinnedObs,
            dismissedObservations: dismissedObs,
            snapshotCaptions: visualCaptions,
            language: language,
            configuration: config
        )

        let now = Date()
        let deviceID = store.meetingLibrary.store.storeRoot.lastPathComponent
        let baseTitle = preset.map { "\(skill.resolvedSummaryBlockTitle) — \($0.name)" } ?? skill.resolvedSummaryBlockTitle
        let snapshot = RoleContextSnapshot(
            skillID: skill.id,
            skillName: skill.name,
            presetID: preset?.id,
            presetName: preset?.name,
            focusSpeakers: finalFocus,
            adHocContext: resolvedContext,
            rubricDimensions: preset?.rubricDimensions ?? [],
            instructionsDigest: AssistantCloudSync.skillDigest(skill),
            capturedInstructions: [skill.instructions, preset?.instructions ?? ""]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        )

        var resolvedCitations: [String: [String]] = [:]
        for (heading, refs) in result.citations {
            resolvedCitations[heading] = refs.compactMap { window.refToEventID[$0] ?? $0 }
        }

        let existingDBBlockID: UUID?
        if existingBlock == nil {
            existingDBBlockID = try await library.expertBlocks(for: sessionID)
                .first(where: { $0.skillID == skill.id && $0.presetID == preset?.id })?.id
        } else {
            existingDBBlockID = nil
        }
        let targetBlockID = existingBlock?.id ?? existingDBBlockID ?? UUID()

        var updatedVersions = existingBlock?.versions ?? []
        if let previous = existingBlock,
           !previous.markdownBody.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedVersions.insert(
                ExpertBlockVersionSnapshot(
                    revision: updatedVersions.count + 1,
                    headlineVerdict: previous.headlineVerdict.value,
                    markdownBody: previous.markdownBody.value,
                    savedAt: previous.updatedAt,
                    deviceID: deviceID
                ),
                at: 0
            )
            if updatedVersions.count > 5 { updatedVersions = Array(updatedVersions.prefix(5)) }
        }

        let nextCounter = max(existingBlock?.maximumCounter ?? 0, 0) + 1
        let syncVer = SyncVersion(counter: nextCounter, device: deviceID)
        let block = SyncedMeetingExpertBlock(
            id: targetBlockID,
            sessionID: sessionID,
            skillID: skill.id,
            presetID: preset?.id,
            title: SyncValue(baseTitle, version: syncVer),
            visibility: SyncValue(skill.summaryVisibility, version: syncVer),
            headlineVerdict: SyncValue(result.headlineVerdict, version: syncVer),
            markdownBody: SyncValue(result.markdownBody, version: syncVer),
            isEdited: false,
            contextSnapshot: SyncValue(snapshot, version: syncVer),
            citations: SyncValue(resolvedCitations, version: syncVer),
            exportDestinationID: SyncValue(resolvedDestID, version: syncVer),
            routeEntireMeeting: SyncValue(resolvedRouteEntire, version: syncVer),
            sourceCoverageLabel: window.sourceCoverageLabel,
            transcriptFingerprint: window.fingerprint,
            versions: updatedVersions,
            isDeleted: SyncValue(false, version: syncVer),
            createdAt: existingBlock?.createdAt ?? now,
            updatedAt: now
        )

        let nextDominant = DominantRoleResolver.resolveRetroactiveAdd(
            existingDominant: session.dominantRole,
            newBlock: block,
            coreOutcomePolicy: skill.coreOutcomePolicy,
            makePrimary: makePrimary,
            at: now
        )
        try await library.setSessionRoleState(
            sessionID,
            dominantRole: nextDominant,
            roleSegments: session.roleSegments,
            bumpExportRevision: false
        )
        try await library.upsertExpertBlock(block, bumpExportRevision: true)
        await store.meetingLibrary.refresh()
        objectWillChange.send()
        return block
    }

    func setPrimaryExpertBlock(sessionID: UUID, blockID: UUID) async throws {
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary.store
        guard let session = try await library.session(sessionID),
              let block = try await library.expertBlocks(for: sessionID).first(where: { $0.id == blockID }) else {
            throw MeetingLibraryError.invalidSession
        }
        let skills = await withCompositeSkillRepository { repo, _ in repo.listSkills() }
        let policy = skills.first(where: { $0.id == block.skillID })?.coreOutcomePolicy
            ?? DefaultAssistantSkills.skill(id: block.skillID)?.coreOutcomePolicy
            ?? .full
        let nextDominant = DominantRoleResolver.setPrimary(
            block: block,
            coreOutcomePolicy: policy,
            existingMode: session.dominantRole?.mode ?? .off
        )
        try await library.setSessionRoleState(
            sessionID,
            dominantRole: nextDominant,
            roleSegments: session.roleSegments,
            bumpExportRevision: true
        )
        await store.meetingLibrary.refresh()
        objectWillChange.send()
    }

    func updateExpertBlockMarkdown(
        sessionID: UUID,
        blockID: UUID,
        headlineVerdict: String?,
        markdownBody: String
    ) async throws {
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary.store
        guard var block = try await library.expertBlocks(for: sessionID).first(where: { $0.id == blockID }) else {
            throw MeetingLibraryError.invalidSession
        }
        let now = Date()
        let deviceID = library.storeRoot.lastPathComponent
        var versions = block.versions
        if !block.markdownBody.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            versions.insert(
                ExpertBlockVersionSnapshot(
                    revision: versions.count + 1,
                    headlineVerdict: block.headlineVerdict.value,
                    markdownBody: block.markdownBody.value,
                    savedAt: block.updatedAt,
                    deviceID: deviceID
                ),
                at: 0
            )
            if versions.count > 5 { versions = Array(versions.prefix(5)) }
        }
        let nextVer = SyncVersion(counter: block.maximumCounter + 1, device: deviceID)
        block.headlineVerdict = SyncValue(headlineVerdict, version: nextVer)
        block.markdownBody = SyncValue(markdownBody, version: nextVer)
        block.isEdited = true
        block.versions = versions
        block.updatedAt = now
        try await library.upsertExpertBlock(block, bumpExportRevision: true)
        await store.meetingLibrary.refresh()
        objectWillChange.send()
    }

    func deleteExpertBlock(sessionID: UUID, blockID: UUID) async throws {
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary.store
        let deviceID = library.storeRoot.lastPathComponent
        try await library.deleteExpertBlock(id: blockID, sessionID: sessionID, updatedBy: deviceID)
        if let session = try await library.session(sessionID),
           session.dominantRole?.expertBlockID == blockID {
            var nextDom = session.dominantRole
            nextDom?.expertBlockID = nil
            try await library.setSessionRoleState(sessionID, dominantRole: nextDom, roleSegments: session.roleSegments, bumpExportRevision: false)
        }
        await store.meetingLibrary.refresh()
        objectWillChange.send()
    }
}
