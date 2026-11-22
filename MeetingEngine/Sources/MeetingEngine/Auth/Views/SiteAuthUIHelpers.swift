import ConferenceCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct IdentifiableSiteOrigin: Identifiable, Hashable {
    public let url: URL
    public var id: String { url.absoluteString }

    public init(_ url: URL) {
        self.url = SiteOrigin.canonicalOrigin(for: url) ?? url
    }
}

enum SiteAuthClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum SiteAuthEngineLabel {
    static func title(for engine: MeetingEngineKind) -> String {
        switch engine {
        case .guest: return L("Guest meeting")
        case .trueconf: return L("TrueConf Server")
        case .telemost: return L("Yandex Telemost")
        case .community: return L("Rock Jam")
        }
    }
}

/// Shared .p12 / .pfx file reading + empty-passphrase fast-path + passphrase unlock flow.
@MainActor
final class PKCS12ImportFlow: ObservableObject {
    @Published var showingFileImporter = false
    @Published var pendingData: Data?
    @Published var pendingFilename = ""
    @Published var passphrase = ""
    @Published var customLabel = ""
    @Published var errorMessage: String?

    var isAwaitingPassphrase: Bool { pendingData != nil }

    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.pkcs12, .x509Certificate, .data]
        if let pfx = UTType(filenameExtension: "pfx"), !types.contains(pfx) {
            types.append(pfx)
        }
        return types
    }

    func handleFileResult(
        _ result: Result<[URL], Error>,
        store: SiteAccountStore,
        onImported: (ClientCertificateRecord) -> Void
    ) {
        errorMessage = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= ClientCertificateLoader.maxPKCS12Bytes else {
                    errorMessage = ClientCertificateError.oversizedData.localizedDescription
                    return
                }
                let defaultLabel = url.deletingPathExtension().lastPathComponent
                do {
                    let record = try store.importCertificate(data: data, passphrase: "", label: nil)
                    resetPending()
                    onImported(record)
                } catch ClientCertificateError.authenticationFailed {
                    pendingData = data
                    pendingFilename = url.lastPathComponent
                    passphrase = ""
                    customLabel = defaultLabel
                } catch {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func unlockPending(store: SiteAccountStore, onImported: (ClientCertificateRecord) -> Void) {
        guard let pendingData else { return }
        errorMessage = nil
        do {
            let cleanLabel = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = try store.importCertificate(
                data: pendingData,
                passphrase: passphrase,
                label: cleanLabel.isEmpty ? nil : cleanLabel
            )
            resetPending()
            onImported(record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetPending() {
        pendingData = nil
        pendingFilename = ""
        passphrase = ""
        customLabel = ""
        errorMessage = nil
    }
}

struct PKCS12PassphraseInlineCard: View {
    @ObservedObject var flow: PKCS12ImportFlow
    let store: SiteAccountStore
    let onImported: (ClientCertificateRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Unlock certificate: %@", flow.pendingFilename))
                .font(.subheadline.weight(.semibold))
            TextField(L("Certificate label (optional)"), text: $flow.customLabel)
                .textFieldStyle(.roundedBorder)
            SecureField(L("Certificate passphrase"), text: $flow.passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    flow.unlockPending(store: store, onImported: onImported)
                }
            if let error = flow.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button(L("Cancel")) { flow.resetPending() }
                Spacer()
                Button(L("Unlock & Save")) {
                    flow.unlockPending(store: store, onImported: onImported)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
