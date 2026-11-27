import AppKit
import ConferenceCore
import SwiftUI

struct ExpertSummaryGeneratorSheet: View {
    @ObservedObject var attention: AttentionCoordinator
    let card: MeetingLibraryCard
    let sessionEvents: [SyncedTranscriptEvent]
    @Environment(\.dismiss) private var dismiss

    @State private var skills: [AssistantSkill] = []
    @State private var presets: [AssistantRolePreset] = []
    @State private var destinations: [ObsidianDestinationRecord] = []
    @State private var detectedSpeakers: [String] = []
    @State private var selectedSkillID: String = "hiring-interviewer"
    @State private var selectedPresetID: String = ""
    @State private var selectedSpeakers: Set<String> = []
    @State private var adHocContext: String = ""
    @State private var selectedDestinationID: String = ""
    @State private var routeEntireMeeting: Bool = false
    @State private var makePrimary: Bool = true
    @State private var generating = false
    @State private var errorMessage: String?

    var onGenerated: () -> Void

    private var presetsForSkill: [AssistantRolePreset] {
        presets.filter { $0.skillID == selectedSkillID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Add Expert Summary")).font(.title2.bold())
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(card.title).font(.subheadline).foregroundStyle(.secondary)

            Form {
                Picker(L("Role"), selection: $selectedSkillID) {
                    ForEach(skills.filter(\.enabled)) { skill in
                        Text(skill.name).tag(skill.id)
                    }
                }
                .onChange(of: selectedSkillID) { newID in
                    if let match = skills.first(where: { $0.id == newID }) {
                        routeEntireMeeting = match.routeEntireMeeting
                        if let slug = match.exportDestinationSlug,
                           let dest = destinations.first(where: { $0.resolvedSlug.caseInsensitiveCompare(slug) == .orderedSame }) {
                            selectedDestinationID = dest.id.uuidString
                        } else if let owning = match.owningDestinationID {
                            selectedDestinationID = owning.uuidString
                        }
                    }
                    selectedPresetID = presetsForSkill.first?.id ?? ""
                }

                if !presetsForSkill.isEmpty {
                    Picker(L("Role Preset"), selection: $selectedPresetID) {
                        Text(L("General (Role default)")).tag("")
                        ForEach(presetsForSkill) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }

                if !detectedSpeakers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Focus Speaker (Candidate / Subject)")).font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(detectedSpeakers, id: \.self) { speaker in
                                    let chosen = selectedSpeakers.contains(speaker)
                                    Button {
                                        if chosen { selectedSpeakers.remove(speaker) } else { selectedSpeakers.insert(speaker) }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                                            Text(speaker)
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(chosen ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if !destinations.isEmpty {
                    Picker(L("Export Vault / Repo"), selection: $selectedDestinationID) {
                        Text(L("Primary Vault (default)")).tag("")
                        ForEach(destinations) { dest in
                            Text(dest.displayName).tag(dest.id.uuidString)
                        }
                    }
                    Toggle(L("Route entire meeting exclusively to selected vault"), isOn: $routeEntireMeeting)
                }

                Toggle(L("Make Primary Role Summary for this meeting"), isOn: $makePrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Extra context / Job description / Focus notes")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $adHocContext)
                        .font(.callout)
                        .frame(minHeight: 80)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    generate()
                } label: {
                    HStack(spacing: 6) {
                        if generating { ProgressView().controlSize(.small) }
                        Text(generating ? L("Analyzing full meeting…") : L("Generate Expert Summary"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating || selectedSkillID.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .task {
            let (loadedSkills, loadedPresets, loadedPeople) = await attention.withCompositeSkillRepository { repo, _ in
                (repo.listSkills(), repo.listPresets(), repo.primary.loadPeople())
            }
            skills = loadedSkills
            presets = loadedPresets
            destinations = (try? await attention.store.meetingLibrary.store.destinations()) ?? []
            let localNames = attention.store.profile.names(fallback: L("You"))
            let teamNames = loadedPeople.entries.map(\.displayName)
            detectedSpeakers = FullTranscriptEvaluationWindowBuilder.detectedExternalSpeakers(
                events: sessionEvents,
                localNames: localNames,
                teamMemberNames: teamNames
            )
            if let hiring = loadedSkills.first(where: { $0.id == "hiring-interviewer" && $0.enabled }) {
                selectedSkillID = hiring.id
                routeEntireMeeting = hiring.routeEntireMeeting
            } else if let first = loadedSkills.first(where: { $0.enabled && $0.id != AssistantSkill.personalAssistantID }) ?? loadedSkills.first(where: \.enabled) {
                selectedSkillID = first.id
                routeEntireMeeting = first.routeEntireMeeting
            }
            selectedPresetID = presetsForSkill.first?.id ?? ""
            if selectedSkillID == "hiring-interviewer", let firstSpeaker = detectedSpeakers.first {
                selectedSpeakers = [firstSpeaker]
            }
        }
    }

    private func generate() {
        generating = true
        errorMessage = nil
        Task { @MainActor in
            defer { generating = false }
            do {
                _ = try await attention.generateExpertSummary(
                    sessionID: card.sessionID,
                    skillID: selectedSkillID,
                    presetID: selectedPresetID.isEmpty ? nil : selectedPresetID,
                    focusSpeakers: selectedSpeakers.isEmpty ? nil : Array(selectedSpeakers).sorted(),
                    adHocContext: adHocContext,
                    exportDestinationID: UUID(uuidString: selectedDestinationID),
                    routeEntireMeeting: routeEntireMeeting,
                    makePrimary: makePrimary,
                    preloadedEvents: sessionEvents
                )
                onGenerated()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ExpertBlockCardView: View {
    @ObservedObject var attention: AttentionCoordinator
    let block: SyncedMeetingExpertBlock
    let isPrimary: Bool
    let sessionEvents: [SyncedTranscriptEvent]
    var onChanged: () -> Void

    @State private var isEditing = false
    @State private var draftVerdict = ""
    @State private var draftMarkdown = ""
    @State private var busy = false
    @State private var showVersions = false
    @State private var confirmDelete = false
    @State private var selectedCitationRef: String?
    @State private var errorMessage: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    if isPrimary {
                        Label(L("Primary"), systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                    } else {
                        Text(L("Secondary Lens"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }

                    Text(block.title.value)
                        .font(.headline)
                        .lineLimit(2)

                    Spacer()

                    if let verdict = block.headlineVerdict.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !verdict.isEmpty {
                        Text(verdict)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    if let preset = block.contextSnapshot.value.presetName, !preset.isEmpty {
                        Label(preset, systemImage: "doc.text")
                    }
                    if !block.contextSnapshot.value.focusSpeakers.isEmpty {
                        Label(block.contextSnapshot.value.focusSpeakers.joined(separator: ", "), systemImage: "person")
                    }
                    if !block.sourceCoverageLabel.isEmpty {
                        Text(block.sourceCoverageLabel)
                    }
                    if block.isEdited {
                        Text(L("Edited"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isEditing {
                    TextField(L("Headline verdict (optional)"), text: $draftVerdict)
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $draftMarkdown)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 160)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    HStack {
                        Button(L("Cancel")) { isEditing = false }
                        Button(L("Save")) { saveEdit() }.buttonStyle(.borderedProminent).disabled(busy)
                    }
                } else {
                    Text(block.markdownBody.value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                let refs = ExpertSummaryPrompt.extractInlineRefs(in: block.markdownBody.value)
                if !refs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text(L("Citations:")).font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(Set(refs)).sorted(), id: \.self) { ref in
                                Button("[\(ref)]") {
                                    selectedCitationRef = selectedCitationRef == ref ? nil : ref
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                    if let selectedCitationRef {
                        citationExcerptView(for: selectedCitationRef)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }

                Divider()
                HStack(spacing: 8) {
                    if !isPrimary {
                        Button(L("Set as Primary")) { setAsPrimary() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy)
                    }
                    Button(L("Edit")) {
                        draftVerdict = block.headlineVerdict.value ?? ""
                        draftMarkdown = block.markdownBody.value
                        isEditing = true
                    }
                    .controlSize(.small)
                    .disabled(busy)

                    Menu(L("Regenerate")) {
                        Button(L("Using latest role / preset")) { regenerate(useSavedSnapshot: false) }
                        Button(L("Using saved meeting snapshot")) { regenerate(useSavedSnapshot: true) }
                    }
                    .controlSize(.small)
                    .disabled(busy)

                    if !block.versions.isEmpty {
                        Button(L("Versions (%ld)", block.versions.count)) {
                            showVersions.toggle()
                        }
                        .controlSize(.small)
                    }

                    Button(L("Copy Markdown")) {
                        var lines = ["## " + block.title.value]
                        if let v = block.headlineVerdict.value, !v.isEmpty { lines.append("**Verdict:** \(v)") }
                        lines.append(block.markdownBody.value)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n\n"), forType: .string)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .confirmationDialog(L("Delete expert summary?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(L("Delete"), role: .destructive) { deleteBlock() }
                        Button(L("Cancel"), role: .cancel) {}
                    }
                }

                if showVersions && !block.versions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(block.versions, id: \.revision) { ver in
                            HStack {
                                Text("v\(ver.revision) · \(ver.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("Restore")) {
                                    draftVerdict = ver.headlineVerdict ?? ""
                                    draftMarkdown = ver.markdownBody
                                    saveEdit()
                                    showVersions = false
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func citationExcerptView(for ref: String) -> some View {
        let idx = Int(ref.dropFirst()) ?? 0
        let sorted = sessionEvents.filter { $0.kind == "transcript" || $0.kind == "chat" }.sorted {
            ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id)
        }
        if idx > 0, idx <= sorted.count {
            let line = sorted[idx - 1]
            Text("[\(ref)] \(line.speaker ?? L("Speaker")): \(line.text)")
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text(L("Citation [%@] saved in meeting transcript.", ref))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setAsPrimary() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await attention.setPrimaryExpertBlock(sessionID: block.sessionID, blockID: block.id)
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveEdit() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await attention.updateExpertBlockMarkdown(
                    sessionID: block.sessionID,
                    blockID: block.id,
                    headlineVerdict: draftVerdict.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftVerdict,
                    markdownBody: draftMarkdown
                )
                isEditing = false
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func regenerate(useSavedSnapshot: Bool) {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await attention.generateExpertSummary(
                    sessionID: block.sessionID,
                    skillID: block.skillID,
                    presetID: block.presetID,
                    makePrimary: isPrimary,
                    useSavedSnapshotFromBlockID: useSavedSnapshot ? block.id : nil,
                    preloadedEvents: sessionEvents
                )
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteBlock() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await attention.deleteExpertBlock(sessionID: block.sessionID, blockID: block.id)
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
