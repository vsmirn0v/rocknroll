import ConferenceCore
import SwiftUI

struct IOSInCallNotesView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    let sessionID: UUID
    let title: String
    let roomURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var guidanceInput = ""
    @FocusState private var editingFieldFocused: Bool

    private var roomScopeKey: String? {
        roomURL.map { "room:" + $0.absoluteString }
    }

    private var roomGuidance: [SyncedGuidanceRule] {
        guard let key = roomScopeKey, let settings = workspace.settings(for: key) else { return [] }
        return settings.guidanceRules.values.map(\.value).filter { !$0.deleted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Live Meeting Notes"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draft)
                            .font(.body)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            .focused($editingFieldFocused)
                            .onChange(of: draft) { _, newValue in
                                workspace.updateNoteDraft(newValue, for: sessionID)
                            }
                    }
                    .padding(.horizontal)

                    if let assistant = workspace.assistantCoordinator {
                        IOSInCallAdvisorPanel(
                            workspace: workspace,
                            assistant: assistant,
                            sessionID: sessionID,
                            controllerID: workspace.controllerID(forSessionID: sessionID)
                        )
                        .padding(.horizontal)
                    }

                    if let scopeKey = roomScopeKey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Private Assistant Guidance"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField(L("Add instruction for this room…"), text: $guidanceInput)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($editingFieldFocused)
                                Button(L("Add")) {
                                    let text = guidanceInput
                                    guidanceInput = ""
                                    Task {
                                        await workspace.addGuidanceRule(
                                            text,
                                            scopeKey: scopeKey,
                                            scopeKind: .room,
                                            title: title
                                        )
                                    }
                                }
                                .disabled(guidanceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if !roomGuidance.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(roomGuidance) { rule in
                                        HStack {
                                            Text(rule.text)
                                                .font(.footnote)
                                            Spacer()
                                            Button {
                                                Task { await workspace.removeGuidanceRule(id: rule.id, scopeKey: scopeKey) }
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .frame(minWidth: 44, minHeight: 44)
                                                    .contentShape(Rectangle())
                                            }
                                            .accessibilityLabel(L("Delete"))
                                        }
                                        .padding(8)
                                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("Done")) {
                        editingFieldFocused = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        Task {
                            await workspace.flushNotesNow()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                draft = workspace.noteDraft(for: sessionID)
            }
            .onDisappear {
                Task { await workspace.flushNotesNow() }
            }
        }
    }
}

private struct IOSInCallAdvisorPanel: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    let sessionID: UUID
    let controllerID: UUID?

    @State private var whisperInput = ""

    private var activeControllerID: UUID { controllerID ?? sessionID }

    private var currentMode: IOSMeetingAssistantMode {
        assistant.resolvedMode(for: activeControllerID)
    }

    private var activeObservations: [RoleObservationItem] {
        let live = assistant.observationsBySession[activeControllerID]
            ?? workspace.roleObservationsBySession[sessionID]?.items
            ?? []
        return live.filter { !$0.isDismissed }
    }

    var body: some View {
        let shouldShow = currentMode.isSilentToRoom || !activeObservations.isEmpty
        if shouldShow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(L("Advisor & Role Notes"), systemImage: currentMode == .advise ? "lightbulb.max.fill" : "note.text")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if currentMode.isSilentToRoom {
                        Label(L("Silent"), systemImage: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.cyan.opacity(0.18), in: Capsule())
                            .foregroundStyle(.cyan)
                    }
                    Menu {
                        Button(L("Observe")) {
                            assistant.setRoleAndMode(
                                skillID: assistant.resolvedRoleID(for: activeControllerID),
                                presetID: assistant.resolvedPresetID(for: activeControllerID),
                                mode: .observe,
                                for: activeControllerID
                            )
                        }
                        Button(L("Advise")) {
                            assistant.setRoleAndMode(
                                skillID: assistant.resolvedRoleID(for: activeControllerID),
                                presetID: assistant.resolvedPresetID(for: activeControllerID),
                                mode: .advise,
                                for: activeControllerID
                            )
                        }
                    } label: {
                        Text(currentMode.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }

                if activeObservations.isEmpty {
                    Text(L("Listening silently for structured observations and coaching notes…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeObservations) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.kind.rawValue.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                                Text(item.title)
                                    .font(.footnote.weight(.semibold))
                                Spacer()
                                if item.isPinned {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                            }
                            Text(item.body)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.evidenceRefs.isEmpty {
                                Text(item.evidenceRefs.map { "[\($0)]" }.joined(separator: " "))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Button(item.isPinned ? L("Unpin") : L("Pin")) {
                                    assistant.toggleObservationPin(observationID: item.id, for: activeControllerID)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                Button(L("+ To Notes")) {
                                    assistant.insertObservationIntoNotes(observationID: item.id, for: activeControllerID)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                Button(L("Dismiss")) {
                                    assistant.dismissObservation(observationID: item.id, for: activeControllerID)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                HStack(spacing: 8) {
                    TextField(L("Whisper a private question…"), text: $whisperInput)
                        .textFieldStyle(.roundedBorder)
                    if assistant.whisperInFlight.contains(activeControllerID) {
                        ProgressView()
                    } else {
                        Button {
                            let q = whisperInput
                            whisperInput = ""
                            Task { await assistant.whisper(q, for: activeControllerID) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                        }
                        .disabled(whisperInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
