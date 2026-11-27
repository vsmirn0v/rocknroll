import Foundation
import XCTest
@testable import ConferenceCore

final class UnifiedFacilitatorAdvisorTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnifiedAdvisorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRolePresetCodecRepositoryAndCompositeOverlay() throws {
        let primaryRoot = try makeTempDir()
        let secondaryRoot = try makeTempDir()
        let secondaryID = UUID()

        let primaryRepo = AssistantSkillRepository(rootURL: primaryRoot)
        let secondaryRepo = AssistantSkillRepository(rootURL: secondaryRoot, owningDestinationID: secondaryID)
        try primaryRepo.ensureDefaultsInstalled()

        let preset = AssistantRolePreset(
            id: "senior-ios-engineer",
            skillID: "hiring-interviewer",
            name: "Senior iOS Engineer",
            defaultMode: .advise,
            coreOutcomePolicy: .expertOnly,
            exportDestinationSlug: "hiring-repo",
            routeEntireMeeting: true,
            focusSpeakerRole: "Candidate",
            rubricDimensions: ["Swift Concurrency", "WebRTC Media", "Testing"],
            instructions: "Verify concrete production ownership."
        )
        _ = try secondaryRepo.savePreset(preset)

        let encoded = AssistantRolePresetMarkdownCodec.encode(preset)
        let decoded = AssistantRolePresetMarkdownCodec.decode(
            encoded,
            fallbackSkillID: "hiring-interviewer",
            fallbackSlug: "senior-ios-engineer"
        )
        XCTAssertEqual(decoded.id, "senior-ios-engineer")
        XCTAssertEqual(decoded.skillID, "hiring-interviewer")
        XCTAssertEqual(decoded.defaultMode, .advise)
        XCTAssertEqual(decoded.coreOutcomePolicy, .expertOnly)
        XCTAssertEqual(decoded.exportDestinationSlug, "hiring-repo")
        XCTAssertEqual(decoded.routeEntireMeeting, true)
        XCTAssertEqual(decoded.focusSpeakerRole, "Candidate")
        XCTAssertEqual(decoded.rubricDimensions, ["Swift Concurrency", "WebRTC Media", "Testing"])

        let composite = CompositeAssistantSkillRepository(primary: primaryRepo, secondary: [secondaryRepo])
        let presets = composite.listPresets(skillID: "hiring-interviewer")
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets.first?.owningDestinationID, secondaryID)
        XCTAssertTrue(composite.listSkills().contains { $0.id == "hiring-interviewer" })
    }

    func testDominantRoleResolverLiveSwitchRetroactiveAndManualPrimary() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 1. Live transient personal-assistant startup segment (<120s, unpinned) replaced by Hiring Interviewer
        let step1 = DominantRoleResolver.resolveLiveSwitch(
            existingSegments: [],
            previousDominant: nil,
            newSkillID: AssistantSkill.personalAssistantID,
            newPresetID: nil,
            newMode: .mentions,
            coreOutcomePolicy: .full,
            exportDestinationID: nil,
            routeEntireMeeting: false,
            at: t0
        )
        XCTAssertEqual(step1.segments.count, 1)
        XCTAssertEqual(step1.dominantRole?.skillID, AssistantSkill.personalAssistantID)

        let step2 = DominantRoleResolver.resolveLiveSwitch(
            existingSegments: step1.segments,
            previousDominant: step1.dominantRole,
            newSkillID: "hiring-interviewer",
            newPresetID: "senior-ios",
            newMode: .advise,
            coreOutcomePolicy: .expertOnly,
            exportDestinationID: UUID(),
            routeEntireMeeting: true,
            at: t0.addingTimeInterval(45)
        )
        XCTAssertEqual(step2.segments.count, 1, "Transient startup segment should be dropped")
        XCTAssertEqual(step2.dominantRole?.skillID, "hiring-interviewer")
        XCTAssertEqual(step2.dominantRole?.coreOutcomePolicy, .expertOnly)
        XCTAssertEqual(step2.dominantRole?.source, .liveSwitch)

        // 2. Retroactive upgrade on a past Personal Assistant meeting vs Secondary Lens when specialized dominant exists
        let sid = UUID()
        let v1 = SyncVersion(counter: 1, device: "mac")
        let hiringBlock = SyncedMeetingExpertBlock(
            id: UUID(),
            sessionID: sid,
            skillID: "hiring-interviewer",
            presetID: "senior-ios",
            title: SyncValue("Hiring Evaluation", version: v1),
            visibility: SyncValue(.privateOwnerOnly, version: v1),
            headlineVerdict: SyncValue("Hire", version: v1),
            markdownBody: SyncValue("Strong concurrency", version: v1),
            contextSnapshot: SyncValue(RoleContextSnapshot(skillID: "hiring-interviewer", skillName: "Hiring"), version: v1),
            citations: SyncValue([:], version: v1),
            exportDestinationID: SyncValue(UUID(), version: v1),
            routeEntireMeeting: SyncValue(true, version: v1),
            isDeleted: SyncValue(false, version: v1)
        )
        let upgraded = DominantRoleResolver.resolveRetroactiveAdd(
            existingDominant: step1.dominantRole,
            newBlock: hiringBlock,
            coreOutcomePolicy: .expertOnly,
            at: t0.addingTimeInterval(3600)
        )
        XCTAssertEqual(upgraded?.skillID, "hiring-interviewer")
        XCTAssertEqual(upgraded?.source, .retroactiveUpgrade)
        XCTAssertEqual(upgraded?.expertBlockID, hiringBlock.id)

        // Adding a second specialized lens keeps existing dominant unless makePrimary == true
        let secondaryBlock = SyncedMeetingExpertBlock(
            id: UUID(),
            sessionID: sid,
            skillID: "hiring-interviewer",
            presetID: "staff-ios",
            title: SyncValue("Hiring Evaluation (Staff)", version: v1),
            visibility: SyncValue(.privateOwnerOnly, version: v1),
            headlineVerdict: SyncValue("Leaning No Hire", version: v1),
            markdownBody: SyncValue("Needs deeper architecture scope", version: v1),
            contextSnapshot: SyncValue(RoleContextSnapshot(skillID: "hiring-interviewer", skillName: "Hiring"), version: v1),
            citations: SyncValue([:], version: v1),
            exportDestinationID: SyncValue(nil, version: v1),
            routeEntireMeeting: SyncValue(false, version: v1),
            isDeleted: SyncValue(false, version: v1)
        )
        let kept = DominantRoleResolver.resolveRetroactiveAdd(
            existingDominant: upgraded,
            newBlock: secondaryBlock,
            coreOutcomePolicy: .expertOnly,
            at: t0.addingTimeInterval(3700)
        )
        XCTAssertEqual(kept?.expertBlockID, hiringBlock.id)

        let promoted = DominantRoleResolver.setPrimary(
            block: secondaryBlock,
            coreOutcomePolicy: .expertOnly,
            at: t0.addingTimeInterval(3800)
        )
        XCTAssertEqual(promoted.expertBlockID, secondaryBlock.id)
        XCTAssertEqual(promoted.presetID, "staff-ios")
        XCTAssertEqual(promoted.source, .manualPrimary)
    }

    func testFullTranscriptWindowPreservesMiddleAndDisambiguatesCandidate() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var events: [SyncedTranscriptEvent] = []
        for i in 0..<600 {
            let isInterviewer = i % 2 == 0
            events.append(SyncedTranscriptEvent(
                id: "ev-\(i)",
                kind: "transcript",
                sourceTier: 2,
                occurredAt: t0.addingTimeInterval(Double(i) * 5),
                speaker: isInterviewer ? "Vitalii" : "Alex Candidate",
                isOwn: isInterviewer,
                text: i == 300 ? "MIDDLE_ANCHOR_CONCURRENCY_ANSWER" : "Line \(i) technical discussion.",
                deviceID: "mac"
            ))
        }

        let window = FullTranscriptEvaluationWindowBuilder.build(
            events: events,
            focusSpeakers: ["Alex Candidate"],
            focusSpeakerRole: "Candidate",
            localNames: ["Vitalii"],
            contextTokens: 32_768
        )
        XCTAssertEqual(window.lines.count, 600)
        XCTAssertTrue(window.lines.contains { $0.text == "MIDDLE_ANCHOR_CONCURRENCY_ANSWER" })
        XCTAssertEqual(window.lines[0].roleLabel, "Interviewer / You")
        XCTAssertEqual(window.lines[1].roleLabel, "Candidate")
        XCTAssertEqual(window.refToEventID["L301"], "ev-300")
    }

    func testLiveAdvisorPromptAndExpertSummaryParseAndCitations() throws {
        let liveJSON = """
        {"should_emit": true, "entries": [{"kind": "probe", "title": "Ask about actor reentrancy", "body": "Candidate skipped cancellation cleanup.", "evidence_refs": ["L12"]}]}
        """
        let live = try LiveAdvisorPrompt.parse(liveJSON)
        XCTAssertTrue(live.shouldEmit)
        XCTAssertEqual(live.entries.first?.kind, .probe)
        XCTAssertEqual(live.entries.first?.evidenceRefs, ["L12"])

        let summaryJSON = """
        {"headline_verdict": "Hire · Senior iOS", "markdown_body": "### Concurrency\\nSolid explanation [L12].", "citations": {"Concurrency": ["L12"]}}
        """
        let parsed = try ExpertSummaryPrompt.parse(summaryJSON, refToEventID: ["L12": "ev-12"])
        XCTAssertEqual(parsed.headlineVerdict, "Hire · Senior iOS")
        XCTAssertEqual(parsed.citations["Concurrency"], ["ev-12"])
    }

    func testWorkspaceSyncDocumentMergesExpertBlocksObservationsAndPresets() throws {
        let sessionID = UUID()
        let vMac = SyncVersion(counter: 2, device: "mac")
        let vIOS = SyncVersion(counter: 3, device: "ios")
        let now = Date(timeIntervalSince1970: 1_700_000_500)

        var macDoc = MeetingWorkspaceSyncDocument(device: "mac")
        var iosDoc = MeetingWorkspaceSyncDocument(device: "ios")

        let blockID = UUID()
        let macBlock = SyncedMeetingExpertBlock(
            id: blockID,
            sessionID: sessionID,
            skillID: "hiring-interviewer",
            presetID: "senior-ios",
            title: SyncValue("Hiring Evaluation", version: vMac),
            visibility: SyncValue(.privateOwnerOnly, version: vMac),
            headlineVerdict: SyncValue("Leaning Hire", version: vMac),
            markdownBody: SyncValue("Initial Mac assessment", version: vMac),
            contextSnapshot: SyncValue(RoleContextSnapshot(skillID: "hiring-interviewer", skillName: "Hiring"), version: vMac),
            citations: SyncValue([:], version: vMac),
            exportDestinationID: SyncValue(nil, version: vMac),
            routeEntireMeeting: SyncValue(true, version: vMac),
            isDeleted: SyncValue(false, version: vMac),
            createdAt: now,
            updatedAt: now
        )
        let iosBlock = SyncedMeetingExpertBlock(
            id: blockID,
            sessionID: sessionID,
            skillID: "hiring-interviewer",
            presetID: "senior-ios",
            title: SyncValue("Hiring Evaluation", version: vIOS),
            visibility: SyncValue(.privateOwnerOnly, version: vIOS),
            headlineVerdict: SyncValue("Hire", version: vIOS),
            markdownBody: SyncValue("Human edited on iOS", version: vIOS),
            isEdited: true,
            contextSnapshot: SyncValue(RoleContextSnapshot(skillID: "hiring-interviewer", skillName: "Hiring"), version: vIOS),
            citations: SyncValue([:], version: vIOS),
            exportDestinationID: SyncValue(nil, version: vIOS),
            routeEntireMeeting: SyncValue(true, version: vIOS),
            isDeleted: SyncValue(false, version: vIOS),
            createdAt: now,
            updatedAt: now.addingTimeInterval(10)
        )
        macDoc.upsertExpertBlock(macBlock)
        iosDoc.upsertExpertBlock(iosBlock)

        _ = macDoc.mergeLibraryRecords(iosDoc.allLibraryRecords)
        XCTAssertEqual(macDoc.expertBlocks[blockID]?.markdownBody.value, "Human edited on iOS")
        XCTAssertEqual(macDoc.expertBlocks[blockID]?.isEdited, true)

        // Meaningfulness treats expert-only sessions as meaningful
        XCTAssertTrue(MeetingContentMeaningfulness.isMeaningful(MeetingMeaningfulnessInput(hasExpertBlocks: true)))

        // CloudSync syncs presets and vault descriptors
        let preset = AssistantRolePreset(id: "senior-ios", skillID: "hiring-interviewer", name: "Senior iOS", instructions: "Rubric")
        let dest = SyncedVaultDestinationDescriptor(id: UUID(), slug: "hiring", name: "Hiring Vault", isPrimary: false)
        var baseline: AssistantLocalSyncBaseline?
        let input = AssistantCloudSync.LocalSnapshotInput(
            people: AssistantPeopleDirectory(),
            teamContext: .starter(),
            skills: DefaultAssistantSkills.all,
            presets: [preset],
            prompts: [],
            preferences: LocalAssistantPortablePreferences(),
            vaultDestinations: [dest]
        )
        let changed = AssistantCloudSync.exportLocalState(input, into: &macDoc, baseline: &baseline)
        XCTAssertTrue(changed.contains(AssistantCloudSync.presetsScopeKey))
        XCTAssertTrue(changed.contains(AssistantCloudSync.vaultDestinationsScopeKey))

        let emptyLocal = AssistantCloudSync.LocalSnapshotInput(
            people: AssistantPeopleDirectory(),
            teamContext: .starter(),
            skills: DefaultAssistantSkills.all,
            presets: [],
            prompts: [],
            preferences: LocalAssistantPortablePreferences(),
            vaultDestinations: []
        )
        let plan = try XCTUnwrap(AssistantCloudSync.planRemoteApplication(
            from: macDoc.contextSettings,
            currentInput: emptyLocal,
            previousBaseline: nil
        ))
        XCTAssertEqual(plan.presetsToSave.map(\.id), ["senior-ios"])
        XCTAssertEqual(plan.updatedVaultDestinations, [dest])
    }
}
