import AppKit
import ConferenceCore
import CoreImage.CIFilterBuiltins
import MeetingEngine
import SwiftUI

enum NativeDesktopInvitationQR {
    private static let context = CIContext()

    static func image(for payload: String, scale: CGFloat = 6) -> NSImage? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(trimmed.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

private struct NativeDesktopSharingAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if anchor !== view {
                anchor = view
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if anchor !== nsView {
            DispatchQueue.main.async {
                anchor = nsView
            }
        }
    }
}

struct NativeDesktopSharingPickerButton<Label: View>: View {
    let item: URL
    @ViewBuilder let label: () -> Label
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            presentPicker()
        } label: {
            label()
        }
        .background(NativeDesktopSharingAnchorView(anchor: $anchorView))
    }

    @MainActor
    private func presentPicker() {
        guard let view = anchorView, view.window != nil else { return }
        let picker = NSSharingServicePicker(items: [item])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

struct NativeDesktopInstantSiteMenuContent: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject private var accountStore = SiteAccountStore.shared
    let onOpenOptions: (URL?) -> Void
    let onSignIn: (URL) -> Void
    let onManageWebsites: () -> Void

    var body: some View {
        let preferred = workspace.preferredInstantOrigin
        let available = workspace.instantAvailableOrigins
        if !available.isEmpty {
            ForEach(available, id: \.absoluteString) { candidate in
                let account = accountStore.account(for: candidate)
                let host = candidate.host ?? candidate.absoluteString
                let subtitle = account?.isSignedIn == true ? " · \(account?.displayAccountSummary ?? "")" : ""
                Button {
                    workspace.selectInstantOrigin(candidate)
                } label: {
                    if candidate == preferred {
                        Label("\(host)\(subtitle)", systemImage: "checkmark")
                    } else {
                        Text("\(host)\(subtitle)")
                    }
                }
            }
            Divider()
        }
        if let active = preferred {
            let activeAccount = accountStore.account(for: active)
            if activeAccount == nil || activeAccount?.needsReauthentication == true {
                Button {
                    onSignIn(active)
                } label: {
                    Label(L("Sign in to %@…", active.host ?? active.absoluteString), systemImage: "person.crop.circle.badge.checkmark")
                }
            }
        }
        Button {
            onManageWebsites()
        } label: {
            Label(L("Manage websites & sign in…"), systemImage: "globe")
        }
        Button {
            onOpenOptions(preferred)
        } label: {
            Label(L("New room with options…"), systemImage: "plus.bubble")
        }
        .accessibilityIdentifier("nativeGuest.createRoom")
    }
}

struct NativeDesktopInstantMeetingBar: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let onOpenOptions: (URL?) -> Void
    let onSignIn: (URL) -> Void
    let onManageWebsites: () -> Void

    @ObservedObject private var accountStore = SiteAccountStore.shared

    private var preferredOrigin: URL? {
        workspace.preferredInstantOrigin
    }

    private var activeAccount: SiteAccountRecord? {
        preferredOrigin.flatMap { accountStore.account(for: $0) }
    }

    var body: some View {
        let origin = preferredOrigin
        let isDisabled = workspace.isCreatingInstantRoom || workspace.joinSettingUp
        let accentFill = Color(red: 1, green: 0.60, blue: 0.33)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Button {
                    Task { await workspace.startInstantRoom(on: origin) }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.14))
                                .frame(width: 30, height: 30)
                            if workspace.isCreatingInstantRoom {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "video.badge.plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.black)
                            }
                        }
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(workspace.isCreatingInstantRoom ? L("Creating room…") : L("Instant meeting"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.black)
                                Text("⇧⌘N")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.black.opacity(0.68))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .accessibilityHidden(true)
                            }

                            HStack(spacing: 5) {
                                Text(
                                    origin.flatMap(\.host).map { L("Join & copy link · %@", $0) }
                                        ?? L("Choose website & start")
                                )
                                .font(.caption)
                                .foregroundStyle(Color.black.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.middle)

                                if let account = activeAccount, account.isSignedIn {
                                    Circle()
                                        .fill(Color(red: 0.08, green: 0.52, blue: 0.22))
                                        .frame(width: 6, height: 6)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityIdentifier("nativeGuest.instantRoom.start")

                Rectangle()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 1, height: 26)

                Menu {
                    NativeDesktopInstantSiteMenuContent(
                        workspace: workspace,
                        onOpenOptions: onOpenOptions,
                        onSignIn: onSignIn,
                        onManageWebsites: onManageWebsites
                    )
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.84))
                        .frame(width: 36, height: 46)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(workspace.isCreatingInstantRoom)
                .help(L("Choose meeting website"))
                .accessibilityLabel(L("Choose meeting website"))
                .accessibilityIdentifier("nativeGuest.instantRoom.menu")
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentFill.opacity(isDisabled ? 0.65 : 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let challenge = workspace.instantRoomAuthChallengeOrigin {
                Button {
                    onSignIn(challenge)
                } label: {
                    Label(
                        L("Sign in to %@…", challenge.host ?? challenge.absoluteString),
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("nativeGuest.instantRoom.signIn")
            } else if let errorText = workspace.instantRoomError {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct NativeDesktopInstantToolbarControl: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let onOpenOptions: (URL?) -> Void
    let onSignIn: (URL) -> Void
    let onManageWebsites: () -> Void

    @ObservedObject private var accountStore = SiteAccountStore.shared

    var body: some View {
        let origin = workspace.preferredInstantOrigin
        let account = origin.flatMap { accountStore.account(for: $0) }
        let signedIn = account?.isSignedIn == true
        let labelText = workspace.isCreatingInstantRoom
            ? L("Creating room…")
            : (origin?.host ?? L("Instant meeting"))
        let isDisabled = workspace.isCreatingInstantRoom || workspace.joinSettingUp

        HStack(spacing: 0) {
            Button {
                Task { await workspace.startInstantRoom() }
            } label: {
                HStack(spacing: 6) {
                    if workspace.isCreatingInstantRoom {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "video.badge.plus")
                            .foregroundStyle(.orange)
                    }
                    Text(labelText)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if origin != nil {
                        Circle()
                            .fill(signedIn ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(signedIn ? L("Signed in") : L("Saved website"))
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(
                origin?.host.map { L("Join & copy link · %@", $0) }
                    ?? L("Create, copy link & join")
            )
            .accessibilityIdentifier("nativeGuest.toolbar.instantRoom")

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 14)

            Menu {
                NativeDesktopInstantSiteMenuContent(
                    workspace: workspace,
                    onOpenOptions: onOpenOptions,
                    onSignIn: onSignIn,
                    onManageWebsites: onManageWebsites
                )
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(workspace.isCreatingInstantRoom)
            .help(L("Choose meeting website"))
            .accessibilityLabel(L("Choose meeting website"))
            .accessibilityIdentifier("nativeGuest.toolbar.instantMenu")
        }
        .background(Color.orange.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.32), lineWidth: 1))
    }
}

private struct NativeDesktopWaitingCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.18), lineWidth: 1))
        } else {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(false), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
        }
    }
}

struct NativeDesktopWaitingInviteCard: View {
    @ObservedObject var model: NativeDesktopMeetingModel
    let compact: Bool

    @State private var showingQR = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.connected ? L("You’re connected. Waiting for others.") : L("Connecting…"))
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer(minLength: 8)
                if model.invitationCopiedOnJoin || model.copiedToastRevision > 0 {
                    Label(L("Invitation link copied"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if !compact {
                Text(L("Share the invitation link so others can join this room."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(model.invitation.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                NativeDesktopSharingPickerButton(item: model.invitation) {
                    Label(L("Share…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("meeting.waitingInvite.share")

                Button {
                    model.copyInvitationLink()
                } label: {
                    Label(L("Copy Link"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("\(L("Copy Invitation Link")) (⇧⌘C)")
                .accessibilityIdentifier("meeting.waitingInvite.copy")

                Button {
                    showingQR.toggle()
                } label: {
                    Label(L("QR code"), systemImage: "qrcode")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("meeting.waitingInvite.qr")
                .popover(isPresented: $showingQR, arrowEdge: .bottom) {
                    VStack(spacing: 10) {
                        if let qr = NativeDesktopInvitationQR.image(for: model.invitation.absoluteString) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 172, height: 172)
                                .padding(10)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Text(L("Scan on iPhone to share link"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
        }
        .padding(compact ? 14 : 20)
        .frame(maxWidth: compact ? 460 : 500, alignment: .leading)
        .modifier(NativeDesktopWaitingCardSurface(cornerRadius: 20))
        .accessibilityIdentifier("meeting.waitingInviteCard")
    }
}

struct NativeDesktopCopiedLinkToast: View {
    @ObservedObject var model: NativeDesktopMeetingModel

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L("Link copied · Ready to paste"))
                        .font(.callout.weight(.medium))
                    Text(L("Press ⌘V to paste"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Dismiss"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .nativeMeetingChrome()
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("meeting.copiedLinkToast")
            }
        }
        .onAppear {
            if model.invitationCopiedOnJoin || model.copiedToastRevision > 0 {
                present()
            }
        }
        .onChange(of: model.invitationCopiedOnJoin) { copied in
            if copied { present() }
        }
        .onChange(of: model.copiedToastRevision) { revision in
            if revision > 0 { present() }
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    @MainActor
    private func present() {
        hideTask?.cancel()
        if reduceMotion {
            isVisible = true
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isVisible = true
            }
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.2))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    @MainActor
    private func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        if reduceMotion {
            isVisible = false
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                isVisible = false
            }
        }
    }
}
