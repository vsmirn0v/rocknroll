import ConferenceCore
import SwiftUI
import UIKit

struct IOSSnapshotScopeSheet: View {
    @ObservedObject var controller: IOSMeetingSnapshotController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let targets = controller.availableTargets()
                if targets.isEmpty {
                    Text(L("No active video or screen share streams are visible."))
                        .foregroundStyle(.secondary)
                } else {
                    Section(L("Capture clean frame to summary")) {
                        ForEach(targets) { target in
                            Button {
                                dismiss()
                                controller.capture(targetID: target.id)
                            } label: {
                                Label(target.title, systemImage: target.symbol)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("Snap to Summary"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .tint(Color.rockBrandTint)
    }
}

struct IOSSnapshotPillView: View {
    @ObservedObject var controller: IOSMeetingSnapshotController

    var body: some View {
        if let pill = controller.activePill {
            HStack(spacing: 10) {
                if let thumbnail = pill.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.2), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Saved to Summary"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(pill.record.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if pill.candidates.count > 1 {
                    Menu {
                        ForEach(pill.candidates) { option in
                            Button {
                                controller.flipActivePill(to: option.id)
                            } label: {
                                if option.id == pill.activeCandidateID {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Label(option.title, systemImage: option.symbol)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 34, minHeight: 34)
                    }
                    .accessibilityLabel(L("Switch captured stream"))
                }
                Button {
                    controller.isEditingCaption = true
                    controller.onOpenCaptionEditor?(pill.record)
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 34, minHeight: 34)
                }
                .accessibilityLabel(L("Add caption"))

                Button {
                    controller.undoActive()
                } label: {
                    Text(L("Undo"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 34)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(IOSSnapshotGlassBacking(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
        }
    }
}

struct IOSSnapshotHardwareBannerView: View {
    @ObservedObject var controller: IOSMeetingSnapshotController

    var body: some View {
        if controller.hardwareOfferVisible {
            let targets = controller.availableTargets()
            let hasShare = targets.contains(where: { $0.scope == .screenShare })
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("Attach clean HD frame to Summary?"), systemImage: "camera.viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        controller.dismissHardwareOffer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .accessibilityLabel(L("Dismiss"))
                }
                HStack(spacing: 8) {
                    if hasShare {
                        Button(L("Shared Screen")) {
                            controller.dismissHardwareOffer()
                            controller.captureSmart()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button(L("Active Stream")) {
                            controller.dismissHardwareOffer()
                            controller.captureSmart()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button(L("Full Stage")) {
                        controller.dismissHardwareOffer()
                        controller.captureFullStage()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(IOSSnapshotGlassBacking(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.rockBrandTint.opacity(0.55), lineWidth: 1))
        }
    }
}

private struct IOSSnapshotGlassBacking: UIViewRepresentable {
    let cornerRadius: CGFloat
    func makeUIView(context: Context) -> MeetingChromeSurface {
        MeetingChromeSurface(cornerRadius: cornerRadius)
    }
    func updateUIView(_ uiView: MeetingChromeSurface, context: Context) {}
}
