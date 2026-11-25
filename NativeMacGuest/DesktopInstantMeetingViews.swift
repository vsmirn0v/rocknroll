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

struct NativeDesktopInstantMeetingCard: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let onOpenOptions: (URL?) -> Void
    let onSignIn: (URL) -> Void

    @ObservedObject private var accountStore = SiteAccountStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var preferredOrigin: URL? {
        workspace.preferredInstantOrigin
    }

    private var availableOrigins: [URL] {
        workspace.instantAvailableOrigins
    }

    private var cardBackground: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(.quaternary.opacity(0.32))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(L("Instant meeting"), systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("⇧⌘N")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
            }

            Text(L("Create, copy link & join"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let origin = preferredOrigin {
                HStack(spacing: 6) {
                    Button {
                        Task { await workspace.startInstantRoom(on: origin) }
                    } label: {
                        HStack(spacing: 7) {
                            if workspace.isCreatingInstantRoom {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(
                                workspace.isCreatingInstantRoom
                                    ? L("Creating room…")
                                    : L("Join & copy link · %@", origin.host ?? origin.absoluteString)
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(workspace.isCreatingInstantRoom || workspace.joinSettingUp)
                    .accessibilityIdentifier("nativeGuest.instantRoom.start")

                    Menu {
                        ForEach(availableOrigins, id: \.absoluteString) { candidate in
                            Button {
                                workspace.selectInstantOrigin(candidate)
                            } label: {
                                if candidate == origin {
                                    Label(candidate.host ?? candidate.absoluteString, systemImage: "checkmark")
                                } else {
                                    Text(candidate.host ?? candidate.absoluteString)
                                }
                            }
                        }
                        if !availableOrigins.isEmpty {
                            Divider()
                        }
                        Button {
                            onOpenOptions(origin)
                        } label: {
                            Label(L("New room with options…"), systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(workspace.isCreatingInstantRoom)
                    .help(L("Choose meeting website"))
                    .accessibilityLabel(L("Choose meeting website"))
                    .accessibilityIdentifier("nativeGuest.instantRoom.menu")
                }
            } else {
                Button {
                    onOpenOptions(nil)
                } label: {
                    Label(L("Choose website & start"), systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("nativeGuest.instantRoom.start")
            }

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

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    onOpenOptions(preferredOrigin)
                } label: {
                    Label(L("New room with options…"), systemImage: "plus.bubble")
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("nativeGuest.createRoom")

                Spacer()

                Label(L("Microphone and camera start off"), systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(reduceTransparency ? 0.03 : 0.06))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
        )
    }
}

struct NativeDesktopInstantToolbarControl: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    let onOpenOptions: (URL?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button {
                Task { await workspace.startInstantRoom() }
            } label: {
                Label(
                    workspace.isCreatingInstantRoom ? L("Creating room…") : L("Instant meeting"),
                    systemImage: "bolt.fill"
                )
            }
            .disabled(workspace.isCreatingInstantRoom || workspace.joinSettingUp)
            .help(L("Create, copy link & join"))
            .accessibilityIdentifier("nativeGuest.toolbar.instantRoom")

            Menu {
                let preferred = workspace.preferredInstantOrigin
                ForEach(workspace.instantAvailableOrigins, id: \.absoluteString) { candidate in
                    Button {
                        workspace.selectInstantOrigin(candidate)
                    } label: {
                        if candidate == preferred {
                            Label(candidate.host ?? candidate.absoluteString, systemImage: "checkmark")
                        } else {
                            Text(candidate.host ?? candidate.absoluteString)
                        }
                    }
                }
                if !workspace.instantAvailableOrigins.isEmpty {
                    Divider()
                }
                Button {
                    onOpenOptions(preferred)
                } label: {
                    Label(L("New room with options…"), systemImage: "plus.bubble")
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(workspace.isCreatingInstantRoom)
            .help(L("New room with options…"))
            .accessibilityLabel(L("New room with options…"))
        }
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
