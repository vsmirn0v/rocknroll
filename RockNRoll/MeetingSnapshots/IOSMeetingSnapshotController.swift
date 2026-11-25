import ConferenceCore
import CoreMedia
import Foundation
import UIKit
import Vision

@MainActor
final class IOSMeetingSnapshotController: ObservableObject {
    struct TargetOption: Identifiable, Equatable {
        let id: String
        let scope: MeetingSnapshotScope
        let sourceID: String
        let sourceName: String
        let title: String
        let symbol: String
    }

    struct ActivePill: Equatable {
        let snapshotID: UUID
        let sessionID: UUID
        var record: MeetingSnapshotRecord
        var thumbnail: UIImage?
        var candidates: [TargetOption]
        var activeCandidateID: String
    }

    struct LiveTileSource {
        let key: String
        let scope: MeetingSnapshotScope
        let sourceName: String
        let captureFrame: @MainActor () -> (CMSampleBuffer, Int)?
        let isMirrored: Bool
    }

    @Published private(set) var activePill: ActivePill?
    @Published private(set) var hardwareOfferVisible = false
    @Published var isEditingCaption = false

    var sessionIDProvider: (() -> UUID)?
    var transcriptExcerptProvider: (() -> String)?
    var liveSourcesProvider: (() -> [LiveTileSource])?
    var primaryKeyProvider: (() -> String?)?
    var onFlashTile: ((String) -> Void)?
    var onOpenCaptionEditor: ((MeetingSnapshotRecord) -> Void)?

    private let fallbackSessionID = UUID()
    private var dismissTask: Task<Void, Never>?
    private var hardwareBannerTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isCallVisible = false

    init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { await RetroactiveSnapshotBuffer.shared.purge() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemScreenshot()
                }
            }
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        dismissTask?.cancel()
        hardwareBannerTask?.cancel()
    }

    func setCallVisible(_ visible: Bool) {
        isCallVisible = visible
        if !visible {
            dismissHardwareOffer()
        }
    }

    func teardown() {
        isCallVisible = false
        dismissPill()
        dismissHardwareOffer()
        Task { await RetroactiveSnapshotBuffer.shared.purge() }
    }

    func availableTargets() -> [TargetOption] {
        let sources = liveSourcesProvider?() ?? []
        let primaryKey = primaryKeyProvider?()
        let sorted = sources.sorted { lhs, rhs in
            if lhs.scope != rhs.scope { return lhs.scope == .screenShare }
            if lhs.key == primaryKey { return true }
            if rhs.key == primaryKey { return false }
            return lhs.sourceName.localizedStandardCompare(rhs.sourceName) == .orderedAscending
        }
        var options = sorted.map { source in
            let prefix = source.scope == .screenShare ? L("Screen") : L("Camera")
            return TargetOption(
                id: source.key,
                scope: source.scope,
                sourceID: source.key,
                sourceName: source.sourceName,
                title: "\(prefix) · \(source.sourceName)",
                symbol: source.scope.symbol
            )
        }
        if !options.isEmpty {
            options.append(TargetOption(
                id: "full-stage",
                scope: .fullStage,
                sourceID: "full-stage",
                sourceName: L("Full stage"),
                title: L("Full meeting stage"),
                symbol: MeetingSnapshotScope.fullStage.symbol
            ))
        }
        return options
    }

    func captureSmart() {
        let targets = availableTargets()
        guard !targets.isEmpty else { return }
        if let primaryKey = primaryKeyProvider?(),
           let match = targets.first(where: { $0.id == primaryKey }) {
            capture(targetID: match.id)
            return
        }
        if let share = targets.first(where: { $0.scope == .screenShare }) {
            capture(targetID: share.id)
            return
        }
        capture(targetID: targets[0].id)
    }

    func captureFullStage() {
        capture(targetID: "full-stage")
    }

    func capture(targetID: String) {
        let sources = liveSourcesProvider?() ?? []
        guard !sources.isEmpty else { return }
        let sessionID = sessionIDProvider?() ?? fallbackSessionID
        let excerpt = transcriptExcerptProvider?() ?? ""
        let format = MeetingSnapshotPreferences.imageFormat()

        let ordered = sources.sorted { lhs, rhs in
            if lhs.key == targetID { return true }
            if rhs.key == targetID { return false }
            if lhs.scope != rhs.scope { return lhs.scope == .screenShare }
            return lhs.sourceName < rhs.sourceName
        }

        let bounded = Array(ordered.prefix(4))
        // Grab lightweight frame references on MainActor immediately, then materialize/encode off-main.
        let rawFrames: [(key: String, scope: MeetingSnapshotScope, name: String, frame: (CMSampleBuffer, Int), mirrored: Bool)] = bounded.compactMap { source in
            guard let frame = source.captureFrame() else { return nil }
            return (source.key, source.scope, source.sourceName, frame, source.isMirrored)
        }
        guard !rawFrames.isEmpty else { return }

        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        onFlashTile?(targetID)

        Task { @MainActor [weak self] in
            guard let self else { return }

            let materialized: [(key: String, scope: MeetingSnapshotScope, name: String, image: CGImage)] = await Task.detached(priority: .userInitiated) {
                var result: [(key: String, scope: MeetingSnapshotScope, name: String, image: CGImage)] = []
                for item in rawFrames {
                    guard let pixels = CMSampleBufferGetImageBuffer(item.frame.0),
                          let ciImage = SharedTextImage.oriented(pixels, rotation: item.frame.1, mirrored: item.mirrored),
                          let cgImage = SharedTextImage.materialize(ciImage) else { continue }
                    result.append((item.key, item.scope, item.name, cgImage))
                }
                return result
            }.value

            guard !materialized.isEmpty else { return }

            let primaryScope: MeetingSnapshotScope
            let primarySourceID: String
            let primarySourceName: String
            let primaryImage: CGImage

            if targetID == "full-stage" {
                let tiles = materialized.map {
                    MeetingSnapshotCompositor.TileInput(image: $0.image, label: $0.name, isScreenShare: $0.scope == .screenShare)
                }
                guard let stage = await Task.detached(priority: .userInitiated, operation: {
                    MeetingSnapshotCompositor.composeStage(tiles: tiles)
                }).value else { return }
                primaryScope = .fullStage
                primarySourceID = "full-stage"
                primarySourceName = L("Full stage")
                primaryImage = stage
            } else if let selected = materialized.first(where: { $0.key == targetID }) ?? materialized.first {
                primaryScope = selected.scope
                primarySourceID = selected.key
                primarySourceName = selected.name
                primaryImage = selected.image
            } else {
                return
            }

            guard let encoded = await Task.detached(priority: .userInitiated, operation: {
                MeetingSnapshotEncoder.encode(primaryImage, scope: primaryScope, format: format)
            }).value else { return }

            guard let record = try? await MeetingSnapshotStore.shared.save(
                sessionID: sessionID,
                scope: primaryScope,
                sourceID: primarySourceID,
                sourceName: primarySourceName,
                encoded: encoded,
                transcriptExcerpt: excerpt
            ) else { return }

            var candidates: [RetroactiveSnapshotCandidate] = materialized.map { item in
                let prefix = item.scope == .screenShare ? L("Screen") : L("Camera")
                return RetroactiveSnapshotCandidate(
                    id: item.key,
                    scope: item.scope,
                    sourceID: item.key,
                    sourceName: item.name,
                    label: "\(prefix) · \(item.name)",
                    image: item.image
                )
            }
            candidates.append(RetroactiveSnapshotCandidate(
                id: "full-stage",
                scope: .fullStage,
                sourceID: "full-stage",
                sourceName: L("Full stage"),
                label: L("Full meeting stage"),
                image: nil
            ))

            await RetroactiveSnapshotBuffer.shared.store(
                snapshotID: record.id,
                sessionID: sessionID,
                candidates: candidates,
                activeCandidateID: primarySourceID
            )

            let options = candidates.map {
                TargetOption(id: $0.id, scope: $0.scope, sourceID: $0.sourceID, sourceName: $0.sourceName, title: $0.label, symbol: $0.scope.symbol)
            }
            activePill = ActivePill(
                snapshotID: record.id,
                sessionID: sessionID,
                record: record,
                thumbnail: UIImage(cgImage: primaryImage),
                candidates: options,
                activeCandidateID: primarySourceID
            )
            scheduleDismiss()
            UIAccessibility.post(notification: .announcement, argument: L("Captured %@, attached to meeting summary.", record.displayTitle))
            runOCRInBackground(image: primaryImage, snapshotID: record.id, sessionID: sessionID)
        }
    }

    func flipActivePill(to candidateID: String) {
        guard let pill = activePill, pill.activeCandidateID != candidateID else { return }
        let format = MeetingSnapshotPreferences.imageFormat()
        scheduleDismiss()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let updated = try? await RetroactiveSnapshotBuffer.shared.flip(
                snapshotID: pill.snapshotID,
                toCandidateID: candidateID,
                format: format,
                store: .shared
            ) else { return }

            let url = await MeetingSnapshotStore.shared.imageURL(for: updated)
            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                UIImage(contentsOfFile: url.path)
            }.value
            if var current = self.activePill, current.snapshotID == pill.snapshotID {
                current.record = updated
                current.activeCandidateID = candidateID
                if let loaded { current.thumbnail = loaded }
                self.activePill = current
            }
            if let cgImage = loaded?.cgImage {
                runOCRInBackground(image: cgImage, snapshotID: updated.id, sessionID: updated.sessionID)
            }
        }
    }

    func saveCaption(_ caption: String, for record: MeetingSnapshotRecord) {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingCaption = false
        scheduleDismiss()
        Task { @MainActor [weak self] in
            if let updated = try? await MeetingSnapshotStore.shared.updateCaption(trimmed, snapshotID: record.id, sessionID: record.sessionID),
               var current = self?.activePill, current.snapshotID == record.id {
                current.record = updated
                self?.activePill = current
            }
        }
    }

    func undoActive() {
        guard let pill = activePill else { return }
        dismissPill()
        Task {
            try? await MeetingSnapshotStore.shared.delete(snapshotID: pill.snapshotID, sessionID: pill.sessionID)
            await RetroactiveSnapshotBuffer.shared.purge()
        }
    }

    func dismissPill() {
        dismissTask?.cancel()
        dismissTask = nil
        isEditingCaption = false
        activePill = nil
        Task { await RetroactiveSnapshotBuffer.shared.purge() }
    }

    func dismissHardwareOffer() {
        hardwareBannerTask?.cancel()
        hardwareBannerTask = nil
        hardwareOfferVisible = false
    }

    private func handleSystemScreenshot() {
        guard isCallVisible,
              MeetingSnapshotPreferences.isIOSHardwareScreenshotBridgeEnabled(),
              !availableTargets().isEmpty else { return }
        hardwareBannerTask?.cancel()
        hardwareOfferVisible = true
        hardwareBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.hardwareOfferVisible = false
        }
    }

    func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard let self, !Task.isCancelled else { return }
            if isEditingCaption {
                scheduleDismiss()
                return
            }
            dismissPill()
        }
    }

    private func runOCRInBackground(image: CGImage, snapshotID: UUID, sessionID: UUID) {
        Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let recognized = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !recognized.isEmpty else { return }
            _ = try? await MeetingSnapshotStore.shared.updateOCRText(recognized, snapshotID: snapshotID, sessionID: sessionID)
        }
    }
}
