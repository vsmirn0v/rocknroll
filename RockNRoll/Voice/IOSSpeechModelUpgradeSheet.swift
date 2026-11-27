import SwiftUI

/// Non-intrusive boot invitation encouraging iOS users to download/switch to GigaAM v4 INT8.
struct IOSSpeechModelUpgradeSheet: View {
    @ObservedObject var modelStore: IOSListenModelStore
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    private var isDownloading: Bool {
        if case .downloading = modelStore.gigaamV4State { return true }
        return false
    }

    private var downloadProgress: Double {
        if case .downloading(let progress) = modelStore.gigaamV4State { return progress }
        return 0
    }

    private var hasV3InstalledOrSelected: Bool {
        modelStore.isUsingOutdatedV3Model || modelStore.gigaamState.isInstalled
    }

    private var targetSizeText: String {
        ByteCountFormatter.string(fromByteCount: IOSListenModelStore.gigaamV4TotalByteCount, countStyle: .file)
    }

    private var downloadFailure: String? {
        if case .failed(let message) = modelStore.gigaamV4State { return message }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: modelStore.isUsingOutdatedV3Model ? "exclamationmark.triangle.fill" : "waveform.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(modelStore.isUsingOutdatedV3Model ? .orange : .teal)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(modelStore.isUsingOutdatedV3Model
                                 ? L("Upgrade Speech Recognition to v4 INT8")
                                 : L("Recommended Speech Model: GigaAM v4 INT8"))
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(modelStore.isUsingOutdatedV3Model
                                 ? L("You are currently using GigaAM v3 (outdated). Upgrade for faster, smaller, bilingual offline transcripts.")
                                 : L("Download the lighter on-device model once for fast offline transcripts on Neural Engine."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        benefitRow(
                            symbol: "bolt.fill",
                            tint: .teal,
                            title: L("~4× faster on Neural Engine"),
                            detail: L("Lower battery and CPU impact during calls.")
                        )
                        benefitRow(
                            symbol: "arrow.down.circle.fill",
                            tint: .blue,
                            title: hasV3InstalledOrSelected
                                ? L("Nearly half the size (%@)", targetSizeText)
                                : L("Compact %@ download", targetSizeText),
                            detail: hasV3InstalledOrSelected
                                ? L("Replaces the ~446 MB v3 model with an INT8 quantized encoder.")
                                : L("Uses an INT8 quantized Core ML encoder for fast, accurate transcription.")
                        )
                        benefitRow(
                            symbol: "globe",
                            tint: .indigo,
                            title: L("Russian & English with punctuation"),
                            detail: L("Handles mixed Russian/English speech completely offline.")
                        )
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if isDownloading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: downloadProgress)
                            HStack {
                                Text(L("Downloading GigaAM v4 INT8… %ld%%", Int((downloadProgress * 100).rounded())))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(L("Cancel")) {
                                    modelStore.cancelV4Download()
                                }
                                .font(.caption)
                            }
                        }
                    } else if let downloadFailure {
                        Text(downloadFailure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text(L("Downloads in the background and will not interrupt ongoing meetings."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    Group {
                        if isDownloading {
                            Button {
                                modelStore.dismissUpgradePrompt()
                                onDismiss()
                            } label: {
                                Text(L("Continue in Background"))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        } else {
                            Button {
                                let alreadyInstalled = modelStore.gigaamV4State.isInstalled
                                modelStore.downloadAndSwitchToV4()
                                if alreadyInstalled {
                                    modelStore.dismissUpgradePrompt()
                                    onDismiss()
                                }
                            } label: {
                                Text(modelStore.gigaamV4State.isInstalled
                                     ? L("Switch to v4 INT8")
                                     : L("Download & Switch (%@)", targetSizeText))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("ios-speech-upgrade.confirm")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Not Now")) {
                        modelStore.dismissUpgradePrompt()
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Settings")) {
                        onDismiss()
                        onOpenSettings()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("ios-speech-upgrade.sheet")
        .onChange(of: modelStore.gigaamV4State.isInstalled) { _, installed in
            if installed && modelStore.selectedModel == .gigaamV4CoreMLInt8 {
                onDismiss()
            }
        }
    }

    private func benefitRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
