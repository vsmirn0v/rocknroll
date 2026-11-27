import SwiftUI

/// Non-intrusive boot invitation encouraging users to download/switch to GigaAM v4 INT8.
struct SpeechModelUpgradePromptView: View {
    @ObservedObject var store: ListenModelStore
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    private var targetModel: ListenModelCatalog.Model? {
        store.recommendedModel
    }

    private var targetSizeText: String {
        guard let targetModel else { return "246 MB" }
        return ByteCountFormatter.string(fromByteCount: targetModel.size, countStyle: .file)
    }

    private var downloadProgress: Double? {
        guard let targetModel, case .downloading(let progress) = store.state(targetModel) else { return nil }
        return progress
    }

    private var isTargetInstalled: Bool {
        guard let targetModel else { return false }
        return store.state(targetModel).installed
    }

    private var downloadFailure: String? {
        guard let targetModel, case .failed(let message) = store.state(targetModel) else { return nil }
        return message
    }

    private var hasV3InstalledOrSelected: Bool {
        if store.isSelectedModelOutdated { return true }
        if let v3 = store.catalog.model(ListenModelStore.previousDefaultModel) {
            return store.state(v3).installed
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.isSelectedModelOutdated ? "exclamationmark.triangle.fill" : "waveform.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(store.isSelectedModelOutdated ? .orange : .teal)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isSelectedModelOutdated ? L("Upgrade Speech Recognition to v4 INT8") : L("Recommended Speech Model: GigaAM v4 INT8"))
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let current = store.selected, store.isOutdated(current) {
                        Text(L("You are currently using %@ (outdated v3). Switching gives you faster and more accurate offline transcripts.", current.title))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("Download the lighter on-device model once for fast, private meeting transcripts on Apple Neural Engine."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Button(L("Model Settings…")) {
                    onDismiss()
                    onOpenSettings()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 10) {
                benefitRow(
                    symbol: "bolt.fill",
                    tint: .teal,
                    title: L("~4× faster on Apple Neural Engine"),
                    detail: L("Processes speech in milliseconds with almost no CPU load on Apple Silicon (macOS 15+ Core ML).")
                )
                benefitRow(
                    symbol: "arrow.down.circle.fill",
                    tint: .blue,
                    title: hasV3InstalledOrSelected
                        ? L("Nearly half the size (%@)", targetSizeText)
                        : L("Compact %@ download", targetSizeText),
                    detail: hasV3InstalledOrSelected
                        ? L("Replaces the 446 MB v3 model with an INT8 quantized encoder without losing accuracy.")
                        : L("Uses an INT8 quantized Core ML encoder for fast, accurate transcription without bloated storage.")
                )
                benefitRow(
                    symbol: "globe",
                    tint: .indigo,
                    title: L("Russian & English with punctuation"),
                    detail: L("Handles mixed Russian/English technical meetings offline.")
                )
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let progress = downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text(L("Downloading GigaAM v4 INT8… %ld%%", Int((progress * 100).rounded())))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Cancel")) {
                            if let targetModel { store.cancel(targetModel) }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .accessibilityIdentifier("speech-upgrade.progress")
            } else if let downloadFailure {
                Text(downloadFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Downloads in the background and switches only when no meeting is transcribing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()

                if downloadProgress != nil {
                    Button(L("Continue in Background")) {
                        store.dismissUpgradePrompt()
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    Button(L("Not Now")) {
                        store.dismissUpgradePrompt()
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                    Button(isTargetInstalled ? L("Switch to v4 INT8") : L("Download & Switch (%@)", targetSizeText)) {
                        let alreadyInstalled = isTargetInstalled
                        store.startRecommendedModelUpgrade()
                        if alreadyInstalled {
                            store.dismissUpgradePrompt()
                            onDismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(targetModel == nil)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("speech-upgrade.confirm")
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .accessibilityIdentifier("speech-upgrade.prompt")
        .onChange(of: isTargetInstalled) { installed in
            if installed && (store.selectedID == targetModel?.id || store.pendingID == targetModel?.id) {
                store.dismissUpgradePrompt()
                onDismiss()
            }
        }
    }

    private func benefitRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
