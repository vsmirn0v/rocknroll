import AppKit
import Combine
import ConferenceCore
import ImageIO
import SwiftUI
import Vision

@MainActor
final class NativeDesktopSnapshotRegistry {
    struct Entry {
        let id: String
        let participantID: String
        let participantName: String
        let scope: MeetingSnapshotScope
        let capture: () async -> CGImage?
    }

    private struct Registration {
        let token: UUID
        let entry: Entry
    }

    private var registrations: [String: [Registration]] = [:]

    func register(
        id: String,
        token: UUID = UUID(),
        participantID: String,
        participantName: String,
        scope: MeetingSnapshotScope,
        capture: @escaping () async -> CGImage?
    ) {
        let entry = Entry(
            id: id,
            participantID: participantID,
            participantName: participantName,
            scope: scope,
            capture: capture
        )
        var list = registrations[id] ?? []
        if let index = list.firstIndex(where: { $0.token == token }) {
            list[index] = Registration(token: token, entry: entry)
        } else {
            list.append(Registration(token: token, entry: entry))
        }
        registrations[id] = list
    }

    func unregister(id: String, token: UUID) {
        guard var list = registrations[id] else { return }
        list.removeAll { $0.token == token }
        if list.isEmpty {
            registrations.removeValue(forKey: id)
        } else {
            registrations[id] = list
        }
    }

    func unregister(id: String) {
        registrations.removeValue(forKey: id)
    }

    func removeAll() {
        registrations.removeAll()
    }

    var allEntries: [Entry] {
        registrations.values.compactMap(\.last?.entry)
    }

    func entry(id: String) -> Entry? {
        registrations[id]?.last?.entry
    }
}

@MainActor
final class NativeDesktopSnapshotController: ObservableObject {
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
        var thumbnail: NSImage?
        var candidates: [TargetOption]
        var activeCandidateID: String
    }

    @Published private(set) var activePill: ActivePill?
    @Published private(set) var flashingTargetID: String?
    @Published var captionDraft = ""
    @Published var isEditingCaption = false
    @Published var isHoveringPill = false

    private weak var model: NativeDesktopMeetingModel?
    private var dismissTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(model: NativeDesktopMeetingModel) {
        self.model = model
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { await RetroactiveSnapshotBuffer.shared.purge() }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
        dismissTask?.cancel()
        flashTask?.cancel()
    }

    func teardown() {
        dismissTask?.cancel()
        flashTask?.cancel()
        activePill = nil
        Task { await RetroactiveSnapshotBuffer.shared.purge() }
    }

    func availableTargets() -> [TargetOption] {
        guard let model else { return [] }
        let entries = model.snapshotRegistry.allEntries
        var options: [TargetOption] = []
        var seen = Set<String>()

        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope == .screenShare
            }
            if lhs.id == model.focusedVideo?.id { return true }
            if rhs.id == model.focusedVideo?.id { return false }
            return lhs.participantName.localizedStandardCompare(rhs.participantName) == .orderedAscending
        }

        for entry in sortedEntries where seen.insert(entry.id).inserted {
            let name = resolvedName(for: entry.participantID, fallback: entry.participantName, in: model)
            let prefix = entry.scope == .screenShare ? L("Screen") : L("Camera")
            options.append(TargetOption(
                id: entry.id,
                scope: entry.scope,
                sourceID: entry.id,
                sourceName: name,
                title: "\(prefix) · \(name)",
                symbol: entry.scope.symbol
            ))
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
        guard let model else { return }
        let targets = availableTargets()
        guard !targets.isEmpty else { return }
        if let focused = model.focusedVideo,
           let match = targets.first(where: { $0.id == focused.id }) {
            capture(targetID: match.id)
            return
        }
        if let firstShare = targets.first(where: { $0.scope == .screenShare }) {
            capture(targetID: firstShare.id)
            return
        }
        if let activeID = model.activeSpeaker?.id,
           let activeCam = targets.first(where: { entry in
               entry.scope == .participantCamera && model.snapshotRegistry.entry(id: entry.id)?.participantID == activeID
           }) {
            capture(targetID: activeCam.id)
            return
        }
        capture(targetID: targets[0].id)
    }

    func captureFullStage() {
        capture(targetID: "full-stage")
    }

    func capture(targetID: String) {
        guard let model else { return }
        let registry = model.snapshotRegistry
        let entries = registry.allEntries
        guard !entries.isEmpty else {
            probeLog("snapshot-capture-skipped", ["reason": "no-entries", "target": targetID])
            return
        }

        let sessionID = model.workspaceSessionID
        let excerpt = latestTranscriptExcerpt(from: model)
        let format = MeetingSnapshotPreferences.imageFormat()

        let orderedEntries = entries.sorted { lhs, rhs in
            if lhs.id == targetID { return true }
            if rhs.id == targetID { return false }
            if lhs.scope != rhs.scope { return lhs.scope == .screenShare }
            return lhs.participantName < rhs.participantName
        }

        let targetEntries = Array(orderedEntries.prefix(4))
        let descriptors: [(id: String, scope: MeetingSnapshotScope, name: String, capture: () async -> CGImage?)] = targetEntries.map { entry in
            (
                id: entry.id,
                scope: entry.scope,
                name: resolvedName(for: entry.participantID, fallback: entry.participantName, in: model),
                capture: entry.capture
            )
        }

        triggerFlash(targetID: targetID)

        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }

            var capturedFrames: [(id: String, scope: MeetingSnapshotScope, name: String, image: CGImage)] = []
            for item in descriptors {
                if let image = await item.capture() {
                    capturedFrames.append((item.id, item.scope, item.name, image))
                }
            }
            guard !capturedFrames.isEmpty else {
                probeLog("snapshot-capture-skipped", ["reason": "no-frames", "target": targetID, "session": sessionID.uuidString])
                return
            }

            let primaryScope: MeetingSnapshotScope
            let primarySourceID: String
            let primarySourceName: String
            let primaryImage: CGImage

            if targetID == "full-stage" {
                let tiles = capturedFrames.map {
                    MeetingSnapshotCompositor.TileInput(
                        image: $0.image,
                        label: $0.name,
                        isScreenShare: $0.scope == .screenShare
                    )
                }
                guard let stage = await Task.detached(priority: .userInitiated, operation: {
                    MeetingSnapshotCompositor.composeStage(tiles: tiles)
                }).value else {
                    probeLog("snapshot-capture-failed", ["reason": "compose-stage", "session": sessionID.uuidString])
                    return
                }
                primaryScope = .fullStage
                primarySourceID = "full-stage"
                primarySourceName = L("Full stage")
                primaryImage = stage
            } else if let selected = capturedFrames.first(where: { $0.id == targetID }) ?? capturedFrames.first {
                primaryScope = selected.scope
                primarySourceID = selected.id
                primarySourceName = selected.name
                primaryImage = selected.image
            } else {
                return
            }

            guard let encoded = await Task.detached(priority: .userInitiated, operation: {
                MeetingSnapshotEncoder.encode(primaryImage, scope: primaryScope, format: format)
            }).value else {
                probeLog("snapshot-capture-failed", ["reason": "encode", "scope": primaryScope.rawValue, "session": sessionID.uuidString])
                return
            }

            let record: MeetingSnapshotRecord
            do {
                record = try await MeetingSnapshotStore.shared.save(
                    sessionID: sessionID,
                    scope: primaryScope,
                    sourceID: primarySourceID,
                    sourceName: primarySourceName,
                    encoded: encoded,
                    transcriptExcerpt: excerpt
                )
            } catch {
                probeLog("snapshot-capture-failed", ["reason": "store-save", "error": error.localizedDescription, "session": sessionID.uuidString])
                return
            }
            probeLog("snapshot-captured", [
                "session": sessionID.uuidString,
                "snapshot": record.id.uuidString,
                "scope": primaryScope.rawValue,
                "width": record.pixelWidth,
                "height": record.pixelHeight
            ])

            var candidates: [RetroactiveSnapshotCandidate] = capturedFrames.map { frame in
                let prefix = frame.scope == .screenShare ? L("Screen") : L("Camera")
                return RetroactiveSnapshotCandidate(
                    id: frame.id,
                    scope: frame.scope,
                    sourceID: frame.id,
                    sourceName: frame.name,
                    label: "\(prefix) · \(frame.name)",
                    image: frame.image
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
            let thumb = NSImage(cgImage: primaryImage, size: NSSize(width: primaryImage.width, height: primaryImage.height))
            captionDraft = ""
            isEditingCaption = false
            activePill = ActivePill(
                snapshotID: record.id,
                sessionID: sessionID,
                record: record,
                thumbnail: thumb,
                candidates: options,
                activeCandidateID: primarySourceID
            )
            scheduleDismiss()
            runOCRInBackground(image: primaryImage, snapshotID: record.id, sessionID: sessionID)
            notifyObsidianExportIfNeeded(sessionID: sessionID, in: model)
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
            let loadedCG: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if var current = self.activePill, current.snapshotID == pill.snapshotID {
                current.record = updated
                current.activeCandidateID = candidateID
                if let loadedCG {
                    current.thumbnail = NSImage(cgImage: loadedCG, size: NSSize(width: loadedCG.width, height: loadedCG.height))
                }
                self.activePill = current
            }
            if let loadedCG {
                runOCRInBackground(image: loadedCG, snapshotID: updated.id, sessionID: updated.sessionID)
            }
            if let model = self.model {
                notifyObsidianExportIfNeeded(sessionID: updated.sessionID, in: model)
            }
        }
    }

    func saveCaption(_ caption: String) {
        guard let pill = activePill else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingCaption = false
        scheduleDismiss()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let updated = try? await MeetingSnapshotStore.shared.updateCaption(trimmed, snapshotID: pill.snapshotID, sessionID: pill.sessionID) {
                if var current = self.activePill, current.snapshotID == pill.snapshotID {
                    current.record = updated
                    self.activePill = current
                }
                if let model = self.model {
                    notifyObsidianExportIfNeeded(sessionID: updated.sessionID, in: model)
                }
            }
        }
    }

    func insertActiveIntoNotes() {
        guard let pill = activePill, let model else { return }
        let noteSessionID = model.activeNoteSessionID
        guard let notes = model.notes else { return }
        let existing = notes.buffer(sessionID: noteSessionID)
        let caption = pill.record.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "![[\(pill.record.exportFileName)]]" + (caption.isEmpty ? "" : "\n> \(caption)")
        let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? line
            : existing + "\n\n" + line
        notes.update(sessionID: noteSessionID, text: updated)
        model.panel = .notes
        dismissPill()
    }

    func undoActive() {
        guard let pill = activePill else { return }
        dismissPill()
        Task { @MainActor [weak self] in
            try? await MeetingSnapshotStore.shared.delete(snapshotID: pill.snapshotID, sessionID: pill.sessionID)
            await RetroactiveSnapshotBuffer.shared.purge()
            if let model = self?.model {
                self?.notifyObsidianExportIfNeeded(sessionID: pill.sessionID, in: model)
            }
        }
    }

    func dismissPill() {
        dismissTask?.cancel()
        dismissTask = nil
        isEditingCaption = false
        activePill = nil
        Task { await RetroactiveSnapshotBuffer.shared.purge() }
    }

    func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard let self, !Task.isCancelled else { return }
            if isEditingCaption || isHoveringPill {
                scheduleDismiss()
                return
            }
            dismissPill()
        }
    }

    private func triggerFlash(targetID: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        flashTask?.cancel()
        flashingTargetID = targetID
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled else { return }
            self.flashingTargetID = nil
        }
    }

    private func resolvedName(for participantID: String, fallback: String, in model: NativeDesktopMeetingModel) -> String {
        if let person = model.participants.first(where: { $0.id == participantID }) {
            return person.isLocal ? L("You") : person.name
        }
        return fallback.isEmpty ? L("Participant") : fallback
    }

    private func latestTranscriptExcerpt(from model: NativeDesktopMeetingModel) -> String {
        let rows = model.liveTextRows(limit: 12)
        for row in rows.reversed() {
            if case .line(let item, _) = row {
                let clean = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return String(clean.prefix(120)) }
            }
        }
        return ""
    }

    private func runOCRInBackground(image: CGImage, snapshotID: UUID, sessionID: UUID) {
        Task.detached(priority: .utility) { [weak self] in
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
            await MainActor.run { [weak self] in
                guard let self, let model = self.model else { return }
                self.notifyObsidianExportIfNeeded(sessionID: sessionID, in: model)
            }
        }
    }

    private func notifyObsidianExportIfNeeded(sessionID: UUID, in model: NativeDesktopMeetingModel) {
        guard let store = model.meetingLibrary?.store else { return }
        Task {
            try? await store.markSnapshotExportDirty(sessionID: sessionID)
        }
    }
}

struct NativeDesktopSnapshotFlashOverlay: View {
    @ObservedObject var controller: NativeDesktopSnapshotController
    let targetID: String
    let cornerRadius: CGFloat

    private var isFlashing: Bool {
        controller.flashingTargetID == targetID || controller.flashingTargetID == "full-stage"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(isFlashing ? Color.orange : .clear, lineWidth: 3)
            .allowsHitTesting(false)
    }
}

struct NativeDesktopSnapshotPill: View {
    @ObservedObject var controller: NativeDesktopSnapshotController

    var body: some View {
        if let pill = controller.activePill {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let thumbnail = pill.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Label(L("Attached to summary"), systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text(pill.record.capturedAt, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !pill.record.transcriptExcerpt.isEmpty {
                            Text(pill.record.transcriptExcerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
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
                            Label(
                                pill.candidates.first(where: { $0.id == pill.activeCandidateID })?.title ?? pill.record.displayTitle,
                                systemImage: pill.record.scope.symbol
                            )
                            .font(.caption.weight(.medium))
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .help(L("Switch captured stream from the same moment"))
                    }
                    Button(L("+ Note")) {
                        controller.isEditingCaption.toggle()
                        controller.scheduleDismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(L("+ In Notes")) {
                        controller.insertActiveIntoNotes()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(L("Undo")) {
                        controller.undoActive()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .controlSize(.small)
                    Button {
                        controller.dismissPill()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Dismiss"))
                }

                if controller.isEditingCaption {
                    HStack(spacing: 8) {
                        TextField(L("Add a quick caption…"), text: $controller.captionDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { controller.saveCaption(controller.captionDraft) }
                        Button(L("Save")) {
                            controller.saveCaption(controller.captionDraft)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 680)
            .nativeMeetingChrome()
            .onHover { hovering in
                controller.isHoveringPill = hovering
                if !hovering { controller.scheduleDismiss() }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
