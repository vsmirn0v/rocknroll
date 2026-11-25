import CoreGraphics
import Foundation

public struct RetroactiveSnapshotCandidate: Identifiable, @unchecked Sendable {
    public let id: String
    public let scope: MeetingSnapshotScope
    public let sourceID: String
    public let sourceName: String
    public let label: String
    /// Nil for `.fullStage` so compositing runs lazily only if selected.
    public let image: CGImage?

    public init(
        id: String,
        scope: MeetingSnapshotScope,
        sourceID: String,
        sourceName: String,
        label: String,
        image: CGImage?
    ) {
        self.id = id
        self.scope = scope
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.label = label
        self.image = image
    }
}

/// Holds at most ONE transient capture slot for up to `ttl` (default 6s) so the
/// user can flip an already-taken snapshot to a sibling stream at that exact moment.
/// Zero timers or buffers exist when idle.
public actor RetroactiveSnapshotBuffer {
    public static let shared = RetroactiveSnapshotBuffer()

    private struct Slot {
        let snapshotID: UUID
        let sessionID: UUID
        let candidates: [RetroactiveSnapshotCandidate]
        var activeCandidateID: String
    }

    private let ttl: Duration
    private var slot: Slot?
    private var purgeTask: Task<Void, Never>?

    public init(ttl: Duration = .seconds(6)) {
        self.ttl = ttl
    }

    public var hasActiveSlot: Bool { slot != nil }

    public func candidates(for snapshotID: UUID) -> [RetroactiveSnapshotCandidate] {
        guard let slot, slot.snapshotID == snapshotID else { return [] }
        return slot.candidates
    }

    public func store(
        snapshotID: UUID,
        sessionID: UUID,
        candidates: [RetroactiveSnapshotCandidate],
        activeCandidateID: String
    ) {
        purgeTask?.cancel()
        purgeTask = nil
        // Cap sibling retention to keep RAM strictly bounded.
        let bounded = Array(candidates.prefix(5))
        slot = Slot(
            snapshotID: snapshotID,
            sessionID: sessionID,
            candidates: bounded,
            activeCandidateID: activeCandidateID
        )
        let currentID = snapshotID
        purgeTask = Task { [weak self, ttl] in
            try? await Task.sleep(for: ttl)
            guard !Task.isCancelled else { return }
            await self?.purgeIfMatching(snapshotID: currentID)
        }
    }

    public func purge() {
        purgeTask?.cancel()
        purgeTask = nil
        slot = nil
    }

    private func purgeIfMatching(snapshotID: UUID) {
        guard slot?.snapshotID == snapshotID else { return }
        purge()
    }

    public func flip(
        snapshotID: UUID,
        toCandidateID candidateID: String,
        format: MeetingSnapshotImageFormat,
        store: MeetingSnapshotStore
    ) async throws -> MeetingSnapshotRecord? {
        guard var current = slot, current.snapshotID == snapshotID,
              let target = current.candidates.first(where: { $0.id == candidateID }) else {
            return nil
        }

        let resolvedImage: CGImage?
        if let direct = target.image {
            resolvedImage = direct
        } else if target.scope == .fullStage {
            let tiles = current.candidates.compactMap { candidate -> MeetingSnapshotCompositor.TileInput? in
                guard candidate.scope != .fullStage, let image = candidate.image else { return nil }
                return MeetingSnapshotCompositor.TileInput(
                    image: image,
                    label: candidate.sourceName,
                    isScreenShare: candidate.scope == .screenShare
                )
            }
            resolvedImage = MeetingSnapshotCompositor.composeStage(tiles: tiles)
        } else {
            resolvedImage = nil
        }

        guard let resolvedImage,
              let encoded = MeetingSnapshotEncoder.encode(resolvedImage, scope: target.scope, format: format) else {
            return nil
        }

        let updated = try await store.replaceImage(
            snapshotID: snapshotID,
            sessionID: current.sessionID,
            scope: target.scope,
            sourceID: target.sourceID,
            sourceName: target.sourceName,
            encoded: encoded
        )
        if updated != nil {
            current.activeCandidateID = candidateID
            slot = current
        }
        return updated
    }
}
