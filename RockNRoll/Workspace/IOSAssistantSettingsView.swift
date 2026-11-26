import AVFoundation
import ConferenceCore
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSAssistantSettingsView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    var skills: IOSAssistantSkillsController? = nil
    var board: IOSAssistantBoardController? = nil
    @ObservedObject private var voiceStore = IOSVoiceStore.shared

    @State private var apiKeyDraft = ""
    @State private var keyFeedback: String?
    @State private var keyFeedbackIsError = false
    @State private var choosingModel = false
    @State private var pickingArchiveFolder = false
    @State private var pickingExportBundleFolder = false
    @State private var pickingImportBundleFolder = false
    @State private var archiveFeedback: String?
    @AppStorage(MeetingSnapshotPreferences.imageFormatKey) private var snapshotImageFormatRaw = MeetingSnapshotImageFormat.jpeg.rawValue
    @AppStorage(MeetingSnapshotPreferences.iosHardwareBridgeKey) private var snapshotBridgeEnabled = true

    var body: some View {
        Form {
            Section {
                IOSFullRowMenuPicker(
                    L("Default mode in active meeting"),
                    selection: $assistant.defaultForegroundMode,
                    options: IOSMeetingAssistantMode.allCases,
                    optionTitle: \.title,
                    optionSymbol: \.symbol,
                    selectedTitle: assistant.defaultForegroundMode.title
                )
                .accessibilityIdentifier("assistant.settings.foregroundMode")
                IOSFullRowMenuPicker(
                    L("Default mode in background meetings"),
                    selection: $assistant.defaultBackgroundMode,
                    options: IOSMeetingAssistantMode.allCases,
                    optionTitle: \.title,
                    optionSymbol: \.symbol,
                    selectedTitle: assistant.defaultBackgroundMode.title
                )
                .accessibilityIdentifier("assistant.settings.backgroundMode")
                IOSFullRowMenuPicker(
                    L("When meeting sound is off"),
                    selection: $assistant.defaultSilencedMode,
                    options: IOSMeetingAssistantMode.allCases,
                    optionTitle: \.title,
                    optionSymbol: \.symbol,
                    selectedTitle: assistant.defaultSilencedMode.title
                )
                .accessibilityIdentifier("assistant.settings.silencedMode")
                IOSFullRowMenuPicker(
                    L("Participation reply channel"),
                    selection: $assistant.participationConfig.defaultOutput,
                    options: IOSParticipationOutput.allCases,
                    optionTitle: \.title,
                    optionSymbol: \.symbol,
                    selectedTitle: assistant.participationConfig.defaultOutput.title
                )
                .accessibilityIdentifier("assistant.settings.replyChannel")
                Toggle(L("Ask before sending replies"), isOn: $assistant.participationConfig.askBeforeSending)
                TextField(L("Default participation goal (optional)"), text: $assistant.participationConfig.goal, axis: .vertical)
                    .lineLimit(1...3)
                if let skills {
                    IOSFacilitatorSettingsToggleRow(skills: skills)
                }
            } header: {
                Text(L("Live Meeting Assistant"))
            } footer: {
                Text(L("Modes can be changed per meeting from the call header or active meetings list. Participation automatically pauses whenever your microphone is unmuted."))
            }

            if let skills, let board {
                IOSObsidianSkillsSettingsLink(skills: skills, board: board)
            }

            Section {
                Toggle(L("Hands-free “Rock” wake word"), isOn: $voiceStore.wakeWordEnabled)
                    .accessibilityIdentifier("assistant.wakeWord")
                    .onChange(of: voiceStore.wakeWordEnabled) { _, enabled in
                        guard enabled else { return }
                        Task { @MainActor in
                            _ = await AVAudioApplication.requestRecordPermission()
                            SFSpeechRecognizer.requestAuthorization { _ in }
                        }
                    }
                NavigationLink {
                    TranscriptionAndVoiceSettingsView()
                } label: {
                    LabeledContent(L("Assistant reply voice"), value: voiceStore.assistantAuditionVoice.localizedSummary)
                }
                Toggle(L("Speak voice-triggered replies aloud"), isOn: $voiceStore.autoAuditionVoiceReplies)
                Toggle(L("Speak typed replies aloud"), isOn: $voiceStore.autoAuditionTypedReplies)
                if AVAudioApplication.shared.recordPermission == .denied || SFSpeechRecognizer.authorizationStatus() == .denied {
                    Button(L("Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text(L("Voice Commands & Audition"))
            } footer: {
                Text(L("Always ready while you are in the app or muted in a call, and paused when your meeting microphone is unmuted. Open Assistant reply voice to preview voices or configure VoxCPM2."))
            }

            Section {
                Toggle(L("Generate summaries automatically after meetings"), isOn: $workspace.outcomeConfig.autoGenerateOnLeave)
                IOSFullRowMenuPicker(
                    L("Summary provider"),
                    selection: Binding(
                        get: { workspace.outcomeConfig.providerKind },
                        set: { kind in
                            var configuration = workspace.outcomeConfig
                            guard configuration.providerKind != kind else { return }
                            configuration.providerKind = kind
                            configuration.model = kind.defaultModel
                            configuration.contextTokens = nil
                            workspace.outcomeConfig = configuration
                            apiKeyDraft = workspace.readAPIKey(for: kind)
                            keyFeedback = nil
                            keyFeedbackIsError = false
                        }
                    ),
                    options: PortableOutcomeProviderKind.allCases,
                    optionTitle: \.title,
                    selectedTitle: workspace.outcomeConfig.providerKind.title
                )
                .accessibilityIdentifier("assistant.settings.summaryProvider")

                if workspace.outcomeConfig.providerKind == .custom {
                    TextField(L("Base URL (OpenAI-compatible /v1)"), text: $workspace.outcomeConfig.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if workspace.outcomeConfig.providerKind.needsKey {
                    if let endpoint = workspace.outcomeConfig.endpoint, let host = endpoint.host {
                        let recipient = endpoint.port.map { "\(host):\($0)" } ?? host
                        Toggle(L("Allow meeting data sharing with %@", recipient), isOn: Binding(
                            get: { workspace.remoteAISharingAllowed },
                            set: { workspace.setRemoteAIConsent($0) }
                        ))
                        .accessibilityIdentifier("assistant.remoteDataConsent")
                        Text(L("For summaries and live assistance, this device can send meeting titles, participant names, transcripts, chat, notes and assistant instructions to %@. This includes automatic summaries when enabled.", recipient))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        choosingModel = true
                    } label: {
                        Label(L("Choose provider model…"), systemImage: "list.bullet")
                    }
                    .disabled(workspace.outcomeConfig.modelCatalogEndpoint == nil || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField(L("Model"), text: Binding(
                        get: { workspace.outcomeConfig.model },
                        set: { model in
                            var configuration = workspace.outcomeConfig
                            guard configuration.model != model else { return }
                            configuration.model = model
                            configuration.contextTokens = nil
                            workspace.outcomeConfig = configuration
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("API Key (stored in Keychain)"), text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { saveSummaryAPIKey() }

                    HStack {
                        Button(L("Save Key")) {
                            saveSummaryAPIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        if !workspace.readAPIKey(for: workspace.outcomeConfig.providerKind).isEmpty || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(L("Remove"), role: .destructive) {
                                apiKeyDraft = ""
                                saveSummaryAPIKey(removing: true)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if let keyFeedback {
                        Text(keyFeedback)
                            .font(.caption)
                            .foregroundStyle(keyFeedbackIsError ? .red : .secondary)
                    }
                }
            } header: {
                Text(L("Meeting Summaries & Tasks"))
            } footer: {
                Text(L("When “Mac via iCloud” is selected, iPhone waits briefly for your Mac to produce and export the summary when Mac was in the call; otherwise iPhone generates it automatically."))
            }

            Section(L("Same-Room Back-to-Back Meetings")) {
                IOSFullRowMenuPicker(
                    L("Default behavior"),
                    selection: Binding(
                        get: { workspace.defaultTransitionMode },
                        set: { mode in Task { await workspace.saveDefaultTransitionMode(mode) } }
                    ),
                    options: IOSSameRoomTransitionMode.allCases,
                    optionTitle: \.title,
                    selectedTitle: workspace.defaultTransitionMode.title
                )
                .accessibilityIdentifier("assistant.settings.sameRoomTransition")
            }

            Section {
                Text(L("iCloud Workspace Sync options and transcript retention are configured in Settings → Across your devices."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("iCloud Workspace Sync"))
            }

            Section {
                HStack {
                    Text(L("Backup folder"))
                    Spacer()
                    Text(sync.archiveFolderName ?? L("App storage"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(L("Choose Backup Folder…")) {
                    pickingArchiveFolder = true
                }
                if sync.archiveFolderName != nil {
                    Button(L("Use Default App Storage")) {
                        sync.updateTranscriptArchiveFolder(url: nil)
                    }
                }

                HStack {
                    Text(L("Archived sessions"))
                    Spacer()
                    Text("\(workspace.archiveStats.archivedCount) · \(ByteCountFormatter.string(fromByteCount: workspace.archiveStats.totalBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }

                Button(L("Export Transcript Archive…")) {
                    pickingExportBundleFolder = true
                }
                Button(L("Import Transcript Archive…")) {
                    pickingImportBundleFolder = true
                }

                if let archiveFeedback {
                    Text(archiveFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Transcript Backup & Archive"))
            }

            Section {
                Button {
                    workspace.requestManualSync()
                } label: {
                    HStack {
                        Text(L("Sync Workspace Now"))
                        Spacer()
                        if workspace.isManualSyncing { ProgressView() }
                    }
                }
                .disabled(!sync.enabled || workspace.isManualSyncing)

                if let synced = workspace.lastSyncedAt {
                    HStack {
                        Text(L("Last synced"))
                        Spacer()
                        Text(synced.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = workspace.syncError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                let selectedFormat = MeetingSnapshotImageFormat(rawValue: snapshotImageFormatRaw) ?? .jpeg
                IOSFullRowMenuPicker(
                    L("Image format"),
                    selection: Binding(
                        get: { selectedFormat },
                        set: {
                            snapshotImageFormatRaw = $0.rawValue
                            MeetingSnapshotPreferences.setImageFormat($0)
                        }
                    ),
                    options: MeetingSnapshotImageFormat.allCases,
                    optionTitle: \.title,
                    selectedTitle: selectedFormat.title
                )
                .accessibilityIdentifier("snapshots.settings.imageFormat")

                Toggle(
                    L("Offer clean frame on system screenshot"),
                    isOn: Binding(
                        get: { snapshotBridgeEnabled },
                        set: {
                            snapshotBridgeEnabled = $0
                            MeetingSnapshotPreferences.setIOSHardwareScreenshotBridgeEnabled($0)
                        }
                    )
                )
                .accessibilityIdentifier("snapshots.settings.hardwareBridge")
            } header: {
                Text(L("Meeting Snapshots"))
            } footer: {
                let selectedFormat = MeetingSnapshotImageFormat(rawValue: snapshotImageFormatRaw) ?? .jpeg
                Text(selectedFormat.detail)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L("Assistant & Sync"))
        .sheet(isPresented: $choosingModel) {
            let configuration = workspace.outcomeConfig
            let trimmedDraft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveKey = trimmedDraft.isEmpty
                ? workspace.readAPIKey(for: configuration.providerKind)
                : trimmedDraft
            IOSSummaryModelPicker(configuration: configuration, key: effectiveKey) { model in
                var current = workspace.outcomeConfig
                guard current.providerKind == configuration.providerKind,
                      current.modelCatalogEndpoint == configuration.modelCatalogEndpoint else { return }
                current.model = model.id
                current.contextTokens = model.contextLength
                workspace.outcomeConfig = current
            }
        }
        .onAppear {
            apiKeyDraft = workspace.readAPIKey(for: workspace.outcomeConfig.providerKind)
            keyFeedback = nil
            Task { await workspace.refreshArchiveStats() }
        }
        .fileImporter(isPresented: $pickingArchiveFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                sync.updateTranscriptArchiveFolder(url: url)
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    await workspace.refreshArchiveStats()
                }
            }
        }
        .fileImporter(isPresented: $pickingExportBundleFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let count = try await workspace.exportArchiveBundle(to: url)
                        archiveFeedback = L("Exported %ld meeting transcripts.", count)
                    } catch {
                        archiveFeedback = error.localizedDescription
                    }
                }
            }
        }
        .fileImporter(isPresented: $pickingImportBundleFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let count = try await workspace.importArchiveBundle(from: url)
                        archiveFeedback = L("Imported %ld archived transcripts.", count)
                    } catch {
                        archiveFeedback = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// Full-row menu picker for SwiftUI `Form`/`List` sections so tapping anywhere on the label opens the inline options menu.
struct IOSFullRowMenuPicker<SelectionValue: Hashable, Option, ID: Hashable>: View {
    let title: String
    let selection: Binding<SelectionValue>
    let options: [Option]
    let id: KeyPath<Option, ID>
    let valueOf: (Option) -> SelectionValue
    let optionTitle: (Option) -> String
    let optionSymbol: ((Option) -> String)?
    let selectedTitle: String

    init(
        _ title: String,
        selection: Binding<SelectionValue>,
        options: [Option],
        id: KeyPath<Option, ID>,
        valueOf: @escaping (Option) -> SelectionValue,
        optionTitle: @escaping (Option) -> String,
        optionSymbol: ((Option) -> String)? = nil,
        selectedTitle: String
    ) {
        self.title = title
        self.selection = selection
        self.options = options
        self.id = id
        self.valueOf = valueOf
        self.optionTitle = optionTitle
        self.optionSymbol = optionSymbol
        self.selectedTitle = selectedTitle
    }

    var body: some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: id) { option in
                    if let symbol = optionSymbol?(option) {
                        Label(optionTitle(option), systemImage: symbol).tag(valueOf(option))
                    } else {
                        Text(optionTitle(option)).tag(valueOf(option))
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(selectedTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
        .accessibilityAddTraits(.isButton)
    }
}

extension IOSFullRowMenuPicker where Option: Identifiable, ID == Option.ID {
    init(
        _ title: String,
        selection: Binding<SelectionValue>,
        options: [Option],
        valueOf: @escaping (Option) -> SelectionValue,
        optionTitle: @escaping (Option) -> String,
        optionSymbol: ((Option) -> String)? = nil,
        selectedTitle: String
    ) {
        self.init(
            title,
            selection: selection,
            options: options,
            id: \.id,
            valueOf: valueOf,
            optionTitle: optionTitle,
            optionSymbol: optionSymbol,
            selectedTitle: selectedTitle
        )
    }
}

extension IOSFullRowMenuPicker where Option == SelectionValue, ID == Option {
    init(
        _ title: String,
        selection: Binding<SelectionValue>,
        options: [Option],
        optionTitle: @escaping (Option) -> String,
        optionSymbol: ((Option) -> String)? = nil,
        selectedTitle: String
    ) {
        self.init(
            title,
            selection: selection,
            options: options,
            id: \.self,
            valueOf: { $0 },
            optionTitle: optionTitle,
            optionSymbol: optionSymbol,
            selectedTitle: selectedTitle
        )
    }
}

private struct IOSSummaryModelPicker: View {
    let configuration: PortableOutcomeConfiguration
    let key: String
    let onSelect: (ProviderModelInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var models: [ProviderModelInfo] = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var loadAttempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView(L("Loading models…"))
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button(L("Try again")) { loadAttempt += 1 }
                    }
                    .padding()
                } else {
                    let shown = ProviderModelCatalog.filter(models, query: search)
                    List(shown) { model in
                        Button {
                            onSelect(model)
                            dismiss()
                        } label: {
                            modelRow(model)
                        }
                        .buttonStyle(.plain)
                    }
                    .overlay {
                        if shown.isEmpty { Text(L("No models match.")).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(configuration.providerKind.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: L("Search models"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
            .task(id: loadAttempt) {
                loading = true
                error = nil
                defer { loading = false }
                do {
                    models = try await ProviderModelCatalog.fetch(configuration: configuration, key: key)
                } catch where !Task.isCancelled {
                    self.error = error.localizedDescription
                } catch {}
            }
        }
    }

    private func modelRow(_ model: ProviderModelInfo) -> some View {
        let selected = model.id == configuration.resolvedModel
        var details: [String] = []
        if model.name != nil { details.append(model.id) }
        if let length = model.contextLength { details.append(L("%ld K context", length / 1000)) }
        if let price = model.promptPrice {
            details.append(price == 0 ? L("free") : L("$%.2f per million input tokens", price))
        }
        if model.structuredOutput == false { details.append(L("no structured output")) }
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name ?? model.id)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension IOSAssistantSettingsView {
    func saveSummaryAPIKey(removing: Bool = false) {
        let kind = workspace.outcomeConfig.providerKind
        workspace.saveAPIKey(removing ? "" : apiKeyDraft, for: kind)
        let savedNow = workspace.readAPIKey(for: kind)
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if removing || trimmed.isEmpty {
            if savedNow.isEmpty {
                keyFeedback = L("Removed API key from Keychain.")
                keyFeedbackIsError = false
            } else {
                keyFeedback = L("Could not remove the API key from the Keychain.")
                keyFeedbackIsError = true
            }
        } else if savedNow == trimmed {
            keyFeedback = L("Saved API key to Keychain.")
            keyFeedbackIsError = false
        } else {
            keyFeedback = L("Could not save the API key to the Keychain.")
            keyFeedbackIsError = true
        }
    }
}

private struct IOSFacilitatorSettingsToggleRow: View {
    @ObservedObject var skills: IOSAssistantSkillsController

    var body: some View {
        Toggle(L("Enable autonomous in-meeting voice facilitator"), isOn: $skills.autonomousMeetingVoiceEnabled)
    }
}

private struct IOSObsidianSkillsSettingsLink: View {
    @ObservedObject var skills: IOSAssistantSkillsController
    @ObservedObject var board: IOSAssistantBoardController

    var body: some View {
        Section(L("Obsidian Skills & Realtime")) {
            NavigationLink {
                IOSAssistantSkillsView(skills: skills, board: board)
            } label: {
                LabeledContent(
                    L("Skills, Prompts & People.md"),
                    value: skills.realtimeProvider == .disabled
                        ? L("%ld skills", skills.skills.filter(\.enabled).count)
                        : skills.realtimeProvider.title
                )
            }
        }
    }
}
