import SwiftUI

/// Settings → Transcription: transcribe meetings on this Mac, and the models to do it with.
struct NativeDesktopTranscriptionSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ListenModelStore
    /// Readiness and memory of the on-device models. Nil when the settings
    /// view is built without an Attention coordinator (previews, tests).
    var models: LocalModelStatusStore? = nil
    @State private var modelPendingDeletion: ListenModelCatalog.Model?

    private var warningColor: Color {
        colorScheme == .dark ? .orange : Color(red: 0.72, green: 0.35, blue: 0.0)
    }

    private var recommendedColor: Color {
        colorScheme == .dark ? .green : Color(red: 0.08, green: 0.45, blue: 0.16)
    }

    private func isFailedState(_ state: ListenModelStore.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    var body: some View {
        Form {
            if store.isSelectedModelOutdated,
               let recommended = store.recommendedModel,
               store.pendingID != recommended.id || isFailedState(store.state(recommended)) {
                let recSize = ByteCountFormatter.string(fromByteCount: recommended.size, countStyle: .file)
                let failedMessage: String? = {
                    if case .failed(let message) = store.state(recommended) { return message }
                    return nil
                }()
                Section {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(warningColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("You are using an outdated GigaAM v3 model"))
                                .font(.callout.weight(.semibold))
                            if let failedMessage {
                                Text(failedMessage)
                                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(L("Upgrade to %@ (%@) for ~4× faster recognition and Russian & English support.", recommended.title, recSize))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        Button(failedMessage != nil ? L("Try Again") : (store.state(recommended).installed ? L("Switch") : L("Download & Switch"))) {
                            store.startRecommendedModelUpgrade()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                NativeSettingsSwitch(
                    title: L("Transcribe meetings on this Mac"), isOn: $store.enabled, id: "settings.transcribe",
                    fallbackFor: !store.enabled && store.pendingID == nil ? ["settings.voice-detector"] : [],
                    accessibilityID: "transcription.local.enabled"
                )
                Text(L("When a meeting is not transcribed by its service, other participants' speech is turned into text here, for Live text and Catch up. It keeps working while the meeting's sound is off."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("If a guest meeting is being transcribed but its transcript is not available to you, this Mac transcribes it when a speech model is already installed. Otherwise it asks before downloading the model."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.enabled, !store.ready {
                    if store.selected.map({ store.state($0).installed }) != true {
                        Label(L("Download a speech model below to start."), systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let selected = store.selected, !store.modelConfigurationReady(selected) {
                        Label(L("The selected speech model has an invalid configuration. Choose another model or check for an app update."), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                NativeSettingsSwitch(
                    title: L("Include my microphone"), isOn: $store.includesMicrophone,
                    id: "settings.transcribe-mic", accessibilityID: "transcription.local.microphone"
                ).disabled(!store.enabled)
                Text(L("What you say joins the transcript of the meeting that holds your microphone, while it is unmuted. Nothing is transcribed while you are muted."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Meetings to transcribe")) {
                NativeSettingsSwitch(
                    title: L("Telemost and TrueConf"), isOn: $store.transcribesExternal,
                    id: "settings.transcribe-external", accessibilityID: "transcription.local.external"
                ).disabled(!store.enabled)
                Text(L("These services send everyone's voice as one stream. Names come from who the service shows as speaking; TrueConf does not report it, so its lines show “Participant”."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NativeSettingsSwitch(
                    title: L("Rock jam sessions"), isOn: $store.transcribesRock,
                    id: "settings.transcribe-rock", accessibilityID: "transcription.local.rock"
                ).disabled(!store.enabled)
                Text(L("Off by default: jam sessions are mostly music. Each musician is transcribed separately."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Speech model")) {
                if store.catalog.listen.isEmpty {
                    Text(L("No speech models available.")).foregroundStyle(.secondary)
                        .accessibilityIdentifier("transcription.speech-model.management")
                        .nativeSettingAnchor("settings.speech-model")
                } else {
                    Text(L("The selected model is used when transcription next starts. Meetings already transcribing continue with their current model."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("transcription.speech-model.management")
                        .nativeSettingAnchor("settings.speech-model")
                }
                if let pending = store.pendingID.flatMap(store.catalog.model),
                   !isFailedState(store.state(pending)) {
                    Text(L("Switching to %@ when it and the voice detector are ready. The current model stays selected in the meantime.", pending.title))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.catalog.listen) { model in row(model) }
                Text(L("Models run on this Mac, on its processor or Neural Engine. They are downloaded over HTTPS, checked against a fixed checksum, and stored in this app's folder."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.enabled || store.pendingID != nil {
                Section(L("Voice detector")) { voiceDetectorStatus }
            }
            if let models {
                Section(L("On-device models")) {
                    LocalModelStatusIndicator(models: models, settingsID: "settings.transcription-model-status")
                    Text(L("Readiness and memory of the speech and voice models that run on this Mac. A model can be ready while not loaded; it loads when a meeting needs it."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("Privacy")) {
                Label(L("Local transcription processes audio in memory and does not send audio to a transcription provider. Your unmuted microphone audio is still sent to your meeting participants."), systemImage: "lock")
                Label(L("The app does not tell other participants. Let them know if your organisation requires it."), systemImage: "person.2")
                Label(L("Your microphone is transcribed only while you are unmuted in a meeting."), systemImage: "mic")
            }.font(.callout)
        }.formStyle(.grouped).nativeSettingsReveal()
            .onAppear { store.refresh() }
    }

    @ViewBuilder private var voiceDetectorStatus: some View {
        if let vad = store.catalog.vad {
            switch store.state(vad) {
            case .installed:
                if store.detectorConfigurationReady {
                    Label(L("Voice detector ready"), systemImage: "checkmark.circle").foregroundStyle(.green)
                        .nativeSettingAnchor("settings.voice-detector")
                } else {
                    Label(L("The installed voice detector has an invalid configuration. Check for an app update."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).nativeSettingAnchor("settings.voice-detector")
                }
            case .downloading(let progress):
                HStack {
                    ProgressView(value: progress) { Text(L("Downloading the voice detector…")) }
                    NativeSettingsButton(title: L("Cancel"), id: "settings.voice-detector") { store.cancel(vad) }
                }
            case .absent:
                HStack {
                    Label(L("Voice detector is not downloaded."), systemImage: "exclamationmark.triangle")
                    Spacer()
                    NativeSettingsButton(title: L("Download"), id: "settings.voice-detector") { store.download(vad) }
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(L("Voice detector download failed."), systemImage: "exclamationmark.triangle")
                        Spacer()
                        NativeSettingsButton(title: L("Try Again"), id: "settings.voice-detector") { store.download(vad) }
                    }
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Label(L("Voice detector is unavailable in this model catalog."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).nativeSettingAnchor("settings.voice-detector")
        }
    }

    @ViewBuilder private func row(_ model: ListenModelCatalog.Model) -> some View {
        let state = store.state(model), chosen = store.selectedID == model.id, pending = store.pendingID == model.id
        HStack(alignment: .top, spacing: 10) {
            Button { store.selectModel(model) } label: {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).accessibilityLabel(L("Use %@", model.title))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.title).font(.body.weight(chosen ? .semibold : .regular))
                    if model.id == ListenModelStore.defaultModel {
                        Text(L("Recommended")).font(.caption2.weight(.semibold))
                            .foregroundStyle(recommendedColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.green.opacity(colorScheme == .dark ? 0.20 : 0.16), in: Capsule())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if store.isOutdated(model) {
                        Text(L("Outdated")).font(.caption2.weight(.semibold))
                            .foregroundStyle(warningColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Text(detail(model)).font(.caption).foregroundStyle(.secondary)
                if pending {
                    switch state {
                    case .installed:
                        if !store.modelConfigurationReady(model) {
                            Text(L("The downloaded model has an invalid configuration. Choose another model or check for an app update."))
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else if !store.detectorConfigurationReady {
                            Text(L("Downloaded; waiting for the voice detector.")).font(.caption).foregroundStyle(.secondary)
                        } else if store.activeRecognizerUsers > 0 {
                            Text(L("Ready to switch after active transcription finishes.")).font(.caption).foregroundStyle(.secondary)
                        }
                    case .absent:
                        Text(L("Download interrupted. Retry to continue." )).font(.caption).foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                }
                switch state {
                case .downloading(let progress):
                    ProgressView(value: progress).frame(maxWidth: 240)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                default: EmptyView()
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .installed:
                if pending { Button(L("Cancel Switch")) { store.cancelPendingSelection() } }
                else {
                    Button(L("Delete")) { modelPendingDeletion = model }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .confirmationDialog(L("Delete"), isPresented: Binding(
                            get: { modelPendingDeletion?.id == model.id },
                            set: { if !$0 { modelPendingDeletion = nil } }
                        ), titleVisibility: .visible) {
                            Button(L("Delete"), role: .destructive) {
                                store.delete(model)
                                modelPendingDeletion = nil
                            }
                            Button(L("Cancel"), role: .cancel) { modelPendingDeletion = nil }
                        }
                }
            case .downloading:
                Button(L("Cancel")) { store.cancel(model) }.buttonStyle(.borderless)
            case .absent, .failed:
                if pending { Button(L("Cancel Switch")) { store.cancelPendingSelection() } }
                Button(pending ? L("Try Again") : L("Download")) { store.selectModel(model) }
            }
        }.padding(.vertical, 2).contentShape(Rectangle())
    }

    private func detail(_ model: ListenModelCatalog.Model) -> String {
        let languages = model.languages == ["*"] ? L("99 languages") : model.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", ")
        let size = ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)
        let note: String
        switch model.id {
        case "gigaam-v4-coreml-int8": note = L("Russian & English, with punctuation; ~4× faster INT8 on Neural Engine")
        case "gigaam-v4-coreml": note = L("Russian & English, with punctuation; FP16 on Neural Engine")
        case "gigaam-v3-rnnt-punct": note = L("Outdated · Russian, with punctuation; runs on the processor")
        case "gigaam-v3-e2e-ctc": note = L("Outdated · Russian, with punctuation")
        case "gigaam-v3-e2e-rnnt-coreml": note = L("Outdated · Previous-generation Neural Engine model (Russian only)")
        case "whisper-large-v3-turbo": note = L("Mixed languages; about 15 times slower")
        default: note = ""
        }
        return [languages, size, model.licence, note].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
