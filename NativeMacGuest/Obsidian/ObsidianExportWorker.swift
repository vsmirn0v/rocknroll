import ConferenceCore
import Foundation

/// Actor-owned export loop. One pass drains the due outbox rows; each session's file
/// is written with read → conflict check → backup → atomic replace → verify → binding
/// commit. A worker never applies an older snapshot over a newer local revision: the
/// session row is re-read at commit time and a stale desired revision discards the
/// render. Retry uses the store's exponential backoff; conflicts pause the row.
actor ObsidianExportWorker {
    private let store: MeetingLibraryStore
    private let backupRoot: URL
    private let writer: ObsidianFileWriter
    private let vaultResolver: (Data) -> (resolution: ObsidianVaultAccess.Resolution, refreshedBookmark: Data?)
    private let transcriptProvider: @Sendable (MeetingSessionRecord) async -> String?
    private let snapshotSessionIDsProvider: @Sendable (UUID) async -> [UUID]
    private let snapshotStore: MeetingSnapshotStore
    private var running = false
    private var processing = false
    private var pendingWake = false
    private var loopTask: Task<Void, Never>?
    private struct VaultAccessBackoff {
        let destinationID: UUID
        let configRevision: Int
        let reason: String
        let message: String?
        var failures: Int
        var retryAt: Date
    }
    private var sleepWaiter: (id: UUID, continuation: CheckedContinuation<Void, Never>, timer: Task<Void, Never>)?
    private var vaultCaches: [UUID: (configRevision: Int, url: URL, started: Bool)] = [:]
    private var vaultBackoffs: [UUID: VaultAccessBackoff] = [:]

    var onLog: (String, [String: Any]) -> Void = { _, _ in }

    init(store: MeetingLibraryStore, backupRoot: URL, writer: ObsidianFileWriter? = nil,
         vaultResolver: ((Data) -> ObsidianVaultAccess.Resolution)? = nil,
         transcriptProvider: @escaping @Sendable (MeetingSessionRecord) async -> String? = { _ in nil },
         snapshotSessionIDsProvider: @escaping @Sendable (UUID) async -> [UUID] = { [$0] },
         snapshotStore: MeetingSnapshotStore = .shared,
         onLog: @escaping (String, [String: Any]) -> Void = { _, _ in }) {
        self.store = store
        self.backupRoot = backupRoot
        self.writer = writer ?? ObsidianFileWriter(backupRoot: backupRoot)
        if let vaultResolver {
            self.vaultResolver = { (vaultResolver($0), nil) }
        } else {
            self.vaultResolver = { ObsidianVaultAccess.resolveWithRefresh($0) }
        }
        self.transcriptProvider = transcriptProvider
        self.snapshotSessionIDsProvider = snapshotSessionIDsProvider
        self.snapshotStore = snapshotStore
        self.onLog = onLog
    }

    deinit {
        for cache in vaultCaches.values {
            cache.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Runs one pass over every due outbox row across all configured vault destinations.
    func runOnce(now: Date = Date()) async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        let destinations = (try? await store.destinations()) ?? []
        guard !destinations.isEmpty else {
            stopVaultAccess()
            return
        }
        let allDue = (try? await store.dueOutbox(now: now)) ?? []
        guard !allDue.isEmpty else { return }
        let destinationsByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: allDue, by: \.destinationID)
        for (destinationID, dueRows) in grouped {
            guard let destination = destinationsByID[destinationID] else { continue }
            if let backoff = vaultBackoffs[destinationID],
               backoff.configRevision == destination.configRevision,
               now < backoff.retryAt {
                continue
            }
            guard let vault = await resolveVault(destination, now: now) else { continue }
            for row in dueRows {
                if row.intent == .retract {
                    await retract(row: row, destination: destination, vault: vault, now: now)
                    continue
                }
                let overrides: MeetingAutoExportOverrides
                if let snap = row.snapshot {
                    overrides = (try? await store.autoExportOverrides(for: snap.session)) ?? .init()
                } else {
                    overrides = .init()
                }
                guard row.intent.permitted(by: destination, overrides: overrides) else { continue }
                let effectiveDestination = destination.effective(for: overrides)
                await export(row: row, destination: effectiveDestination, vault: vault, now: now)
            }
        }
    }

    /// Starts the background loop: immediate pass, then event-driven wake + smart retry sleep.
    func start() {
        store.setOutboxWakeHandler { [weak self] in
            self?.wake()
        }
        if running {
            wakeIsolated()
            return
        }
        running = true
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.clearPendingWake()
                await self.runOnce()
                let delay = await self.nextSleepDelay()
                await self.waitForWakeOrDelay(delay)
            }
        }
    }

    /// Wakes the background loop immediately when new outbox rows are queued or settings change.
    nonisolated func wake() {
        Task { await self.wakeIsolated() }
    }

    private func clearPendingWake() {
        pendingWake = false
    }

    private func wakeIsolated() {
        pendingWake = true
        finishSleepWaiter()
    }

    private func finishSleepWaiter(id: UUID? = nil) {
        guard let waiter = sleepWaiter, id == nil || waiter.id == id else { return }
        sleepWaiter = nil
        waiter.timer.cancel()
        waiter.continuation.resume()
    }

    func nextSleepDelay(now: Date = Date()) async -> TimeInterval {
        let destinations = ((try? await store.destinations()) ?? []).filter { $0.vaultBookmark != nil }
        guard !destinations.isEmpty else {
            return 30.0
        }
        var earliest: TimeInterval = .greatestFiniteMagnitude
        for destination in destinations {
            if let backoff = vaultBackoffs[destination.id],
               backoff.configRevision == destination.configRevision,
               backoff.retryAt > now {
                earliest = min(earliest, min(60.0, max(1.0, backoff.retryAt.timeIntervalSince(now))))
                continue
            }
            if let nextAttempt = try? await store.earliestActiveOutboxAttempt(destinationID: destination.id) {
                earliest = min(earliest, max(0.25, nextAttempt.timeIntervalSince(now)))
            }
        }
        return earliest == .greatestFiniteMagnitude ? 15.0 : earliest
    }

    private func waitForWakeOrDelay(_ delay: TimeInterval) async {
        if pendingWake || !running || Task.isCancelled { return }
        finishSleepWaiter()
        let waiterID = UUID()
        let _: Void = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if pendingWake || !running || Task.isCancelled {
                    continuation.resume()
                    return
                }
                let ms = max(50, Int((delay * 1000).rounded()))
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(ms))
                    await self?.finishSleepWaiter(id: waiterID)
                }
                sleepWaiter = (waiterID, continuation, timer)
            }
        }, onCancel: { [weak self] in
            Task { await self?.finishSleepWaiter(id: waiterID) }
        })
    }

    /// Stops the background loop and releases any security-scoped vault access.
    /// Safe to call from any isolation context.
    nonisolated func stop() {
        Task { await self.stopIsolated() }
    }

    private func stopIsolated() {
        running = false
        finishSleepWaiter()
        loopTask?.cancel()
        loopTask = nil
        stopVaultAccess()
    }

    /// Checks whether `destination`'s vault is accessible off the main thread, reusing
    /// the worker's active security-scoped handle when already open so status polling never
    /// blocks `@MainActor` or races `stopAccessingSecurityScopedResource()`.
    func isVaultAccessible(for destination: ObsidianDestinationRecord) async -> Bool {
        if let cache = vaultCaches[destination.id],
           cache.configRevision == destination.configRevision,
           cache.started {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: cache.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return await resolveVault(destination, interactiveProbe: true) != nil
    }

    private func resolveVault(_ destination: ObsidianDestinationRecord, now: Date = Date(), interactiveProbe: Bool = false) async -> URL? {
        if let cache = vaultCaches[destination.id],
           cache.configRevision == destination.configRevision, cache.started {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cache.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                vaultBackoffs[destination.id] = nil
                return cache.url
            }
        }
        stopVaultAccess(for: destination.id)
        func recordFailure(_ event: String, reason: String, message: String? = nil, fields: [String: Any] = [:]) {
            guard !interactiveProbe else { return }
            let existing = vaultBackoffs[destination.id]
            let sameFailure = existing?.configRevision == destination.configRevision &&
                existing?.reason == reason &&
                existing?.message == message
            if !sameFailure {
                onLog(event, fields)
            }
            let priorFailures = existing?.configRevision == destination.configRevision ? (existing?.failures ?? 0) : 0
            let failures = priorFailures + 1
            let delay = min(300.0, 15.0 * pow(2.0, Double(min(failures - 1, 5))))
            vaultBackoffs[destination.id] = VaultAccessBackoff(
                destinationID: destination.id,
                configRevision: destination.configRevision,
                reason: reason,
                message: message,
                failures: failures,
                retryAt: now.addingTimeInterval(delay)
            )
        }
        guard let bookmark = destination.vaultBookmark else {
            recordFailure("obsidian-export-no-bookmark", reason: "no-bookmark")
            return nil
        }
        let resolved = vaultResolver(bookmark)
        switch resolved.resolution {
        case .granted(let url):
            vaultBackoffs[destination.id] = nil
            if let refreshed = resolved.refreshedBookmark {
                try? await store.refreshDestinationVaultBookmark(
                    id: destination.id,
                    expectedConfigRevision: destination.configRevision,
                    bookmark: refreshed
                )
                onLog("obsidian-export-refreshed-stale-bookmark", ["destination": destination.id.uuidString])
            }
            vaultCaches[destination.id] = (destination.configRevision, url, true)
            return url
        case .stale:
            recordFailure("obsidian-export-stale-bookmark", reason: "stale", fields: ["destination": destination.id.uuidString])
            return nil
        case .missing:
            recordFailure("obsidian-export-vault-missing", reason: "missing")
            return nil
        case .denied(let message):
            recordFailure("obsidian-export-vault-denied", reason: "denied", message: message, fields: ["error": message])
            return nil
        }
    }

    private func stopVaultAccess(for destinationID: UUID? = nil) {
        if let destinationID {
            vaultCaches.removeValue(forKey: destinationID)?.url.stopAccessingSecurityScopedResource()
        } else {
            for cache in vaultCaches.values {
                cache.url.stopAccessingSecurityScopedResource()
            }
            vaultCaches.removeAll()
        }
    }

    private func retract(row: ObsidianOutboxRecord, destination: ObsidianDestinationRecord,
                         vault: URL, now: Date) async {
        let bindings = (try? await store.bindings(destinationID: destination.id, sessionID: row.sessionID)) ?? []
        var activeComponent = ObsidianExportComponent.meeting
        do {
            for binding in bindings where binding.state == .exported {
                activeComponent = binding.component
                guard case .success(let target) = ObsidianVaultAccess.validate(relativePath: binding.relativePath, in: vault),
                      case .success(let fileTarget) = ObsidianVaultAccess.validateFileTarget(target) else {
                    throw ObsidianExportError.pathEscapesVault(binding.relativePath)
                }
                guard let identity = try ObsidianFileWriter.FileIdentity.fingerprint(fileTarget) else {
                    try? await store.markBindingRetracted(destinationID: destination.id, sessionID: row.sessionID, component: binding.component)
                    continue
                }
                switch binding.component {
                case .meeting, .transcript:
                    if let expectedFileHash = binding.lastFileSHA256, identity.sha256 != expectedFileHash {
                        throw ObsidianExportError.managedBlockConflict
                    }
                    try await writer.delete(target: fileTarget, expectedIdentity: identity, vaultRoot: vault, relativePath: binding.relativePath)
                    try await store.markBindingRetracted(destinationID: destination.id, sessionID: row.sessionID, component: binding.component)
                case .worklog, .index:
                    let existingText = try String(contentsOf: fileTarget, encoding: .utf8)
                    guard let nonce = binding.markerID else {
                        throw ObsidianExportError.markerDamage("The managed binding has no marker identity.")
                    }
                    let stripped = try MarkdownFilePatcher.removeManagedBlock(
                        existing: existingText,
                        sessionID: row.sessionID,
                        nonce: nonce,
                        component: binding.component,
                        expectedBlockSHA256: binding.lastBlockSHA256
                    )
                    if stripped != existingText {
                        _ = try await writer.write(target: fileTarget, content: stripped, expectedIdentity: identity, vaultRoot: vault, relativePath: binding.relativePath)
                    }
                    try await store.markBindingRetracted(destinationID: destination.id, sessionID: row.sessionID, component: binding.component)
                }
            }
            try await store.completeRetractOutbox(destinationID: destination.id, sessionID: row.sessionID, configRevision: row.desiredConfigRevision)
            onLog("obsidian-retracted", ["session": row.sessionID.uuidString, "destination": destination.id.uuidString])
        } catch {
            let failure = error as? ObsidianExportError
            let code = failure.map { String(describing: $0) } ?? "retractFailed"
            if (try? await store.isAuthorizedForWrite(row)) == true {
                try? await store.failOutbox(destinationID: destination.id, sessionID: row.sessionID,
                    errorCode: code, transient: failure?.isTransient ?? true, now: now,
                    expectedRevision: row.desiredRevision, configRevision: row.desiredConfigRevision)
                try? await markBinding(destinationID: destination.id, sessionID: row.sessionID, component: activeComponent,
                    state: failure?.isTransient == false ? .conflict : .failed, errorCode: code)
            }
            onLog("obsidian-retract-failed", ["session": row.sessionID.uuidString, "destination": destination.id.uuidString, "error": code])
        }
    }

    private func export(row: ObsidianOutboxRecord, destination: ObsidianDestinationRecord,
                        vault: URL, now: Date) async {
        let ids = (destination.id, row.sessionID)
        var component = ObsidianExportComponent.meeting
        do {
            guard let snapshot = row.snapshot, snapshot.session.exportRevision == row.desiredRevision else {
                throw ObsidianExportError.staleRevision
            }
            let transcript = destination.layout.sections.contains(.transcript) ? await transcriptProvider(snapshot.session) : nil
            var transcriptRelativePath: String?
            // Deliver the transcript before writing a link to it in the worklog.
            if destination.mode == .worklog, transcript != nil {
                component = .transcript
                guard let receipt = try await exportComponent(component, row: row, destination: destination, vault: vault,
                    snapshot: snapshot, meetingRelativePath: nil, transcriptBody: transcript, now: now) else { return }
                transcriptRelativePath = receipt.relativePath
            }
            var meetingRelativePath: String?
            for required in destination.mode.requiredComponents {
                component = required
                guard let receipt = try await exportComponent(required, row: row, destination: destination, vault: vault,
                    snapshot: snapshot, meetingRelativePath: meetingRelativePath, transcriptBody: transcript,
                    transcriptRelativePath: transcriptRelativePath, now: now) else { return }
                if required == .meeting { meetingRelativePath = receipt.relativePath }
            }
            try await store.completeOutbox(destinationID: ids.0, sessionID: ids.1,
                throughRevision: row.desiredRevision, configRevision: row.desiredConfigRevision)
            onLog("obsidian-exported", ["session": ids.1.uuidString, "revision": row.desiredRevision])
        } catch {
            let failure = error as? ObsidianExportError
            let code = failure.map { String(describing: $0) } ?? "fileAccess"
            if (try? await store.isAuthorizedForWrite(row)) == true {
                try? await store.failOutbox(destinationID: ids.0, sessionID: ids.1,
                    errorCode: code, transient: failure?.isTransient ?? true, now: now,
                    expectedRevision: row.desiredRevision, configRevision: row.desiredConfigRevision)
                try? await markBinding(destinationID: ids.0, sessionID: ids.1, component: component,
                    state: failure?.isTransient == false ? .conflict : .failed, errorCode: code)
            }
            onLog("obsidian-export-failed", ["session": ids.1.uuidString, "error": code])
        }
    }

    private func exportComponent(_ component: ObsidianExportComponent, row: ObsidianOutboxRecord,
                                 destination: ObsidianDestinationRecord, vault: URL, snapshot: ObsidianExportSnapshot,
                                 meetingRelativePath: String?, transcriptBody: String?,
                                 transcriptRelativePath: String? = nil, now: Date) async throws -> ObsidianExportBindingRecord? {
        let session = snapshot.session
        let existing = try await store.binding(destinationID: destination.id, sessionID: session.id, component: component)
        var relativePath = existing?.relativePath ?? ObsidianComponentRenderer.relativePath(for: component,
            destination: destination, snapshot: snapshot)
        if existing == nil, component == .meeting || component == .transcript {
            let reservedPath = component == .transcript
                ? ObsidianComponentRenderer.relativePath(for: .worklog, destination: destination, snapshot: snapshot) : nil
            relativePath = try availableIndividualPath(relativePath, in: vault, excluding: reservedPath)
        }
        let section = ObsidianComponentRenderer.transcriptSection(component: component, layout: destination.layout,
            path: relativePath, body: transcriptBody, transcriptPath: transcriptRelativePath)
        let transcriptSignature = destination.layout.sections.contains(.transcript) && component != .index
            ? (section.isEmpty ? "" : MarkdownFilePatcher.sha256(section)) : nil
        guard case .success(let target) = ObsidianVaultAccess.validate(relativePath: relativePath, in: vault),
              case .success(let fileTarget) = ObsidianVaultAccess.validateFileTarget(target) else {
            throw ObsidianExportError.pathEscapesVault(relativePath)
        }
        var binding = existing ?? ObsidianExportBindingRecord(
            destinationID: destination.id, sessionID: session.id, component: component, relativePath: relativePath,
            markerID: ManagedBlock.newNonce(), lastExportedRevision: 0, lastBlockSHA256: nil, lastFileSHA256: nil,
            state: .idle, errorCode: nil, updatedAt: now)
        if existing == nil { try await store.saveBinding(binding) }

        let expected = try ObsidianFileWriter.FileIdentity.fingerprint(fileTarget)
        if expected == nil, binding.lastExportedRevision > 0 {
            throw ObsidianExportError.markerDamage("The previously exported file is missing or was moved.")
        }
        let existingText = expected == nil ? "" : try String(contentsOf: fileTarget, encoding: .utf8)
        guard try ObsidianFileWriter.FileIdentity.fingerprint(fileTarget) == expected else {
            throw ObsidianExportError.destinationChanged
        }
        if let expected,
           var prepared = try await store.preparedExportWrite(destinationID: destination.id, sessionID: session.id, component: component),
           prepared.relativePath == relativePath,
           let nonce = prepared.markerID, let expectedBlock = prepared.lastBlockSHA256,
           expected.sha256 == prepared.lastFileSHA256 ||
            (MarkdownFilePatcher.managedBlockHash(in: existingText, sessionID: session.id,
                nonce: nonce, component: component) == expectedBlock &&
             (try? self.metadataMatches(prepared, in: existingText)) == true) {
            prepared.lastFileSHA256 = expected.sha256
            try await store.commitExportWrite(prepared)
            binding = prepared
        }
        let includeSnapshots = destination.layout.sections.contains(.snapshots) && component != .index && component != .transcript
        let visualSnapshots: [MeetingSnapshotRecord]
        let snapshotsSignature: String?
        if includeSnapshots {
            let snapshotSessionIDs = await snapshotSessionIDsProvider(session.id)
            visualSnapshots = await snapshotStore.snapshots(for: snapshotSessionIDs)
            snapshotsSignature = Self.snapshotsDigest(visualSnapshots)
        } else {
            visualSnapshots = []
            snapshotsSignature = nil
        }

        let approval = try await store.approvedObsidianConflict(row: row, component: component)
        if approval == nil, binding.lastExportedRevision >= row.desiredRevision, binding.lastExportedRevision > 0,
           binding.transcriptSignature == transcriptSignature,
           binding.snapshotsSignature == snapshotsSignature {
            guard let nonce = binding.markerID,
                  MarkdownFilePatcher.managedBlockHash(in: existingText, sessionID: session.id,
                    nonce: nonce, component: component) == binding.lastBlockSHA256,
                  try metadataMatches(binding, in: existingText) else {
                throw ObsidianExportError.managedBlockConflict
            }
            return binding
        }
        if let approval {
            guard let nonce = binding.markerID,
                  MarkdownFilePatcher.managedBlockHash(in: existingText, sessionID: session.id,
                    nonce: nonce, component: component) == approval.blockHash else {
                throw ObsidianExportError.managedBlockConflict
            }
            binding.lastBlockSHA256 = approval.blockHash
            if binding.lastMetadataSHA256 != nil {
                guard let approved = approval.metadataHash,
                      try ObsidianOwnedMetadata.hash(in: existingText) == approved else {
                    throw ObsidianExportError.managedBlockConflict
                }
                binding.lastMetadataSHA256 = approved
            }
        }
        if !visualSnapshots.isEmpty {
            try await copySnapshotAttachments(visualSnapshots, destination: destination, relativeMarkdownPath: relativePath, in: vault)
        }
        let result = try ObsidianComponentRenderer.patch(existing: existingText, binding: binding,
            destination: destination, snapshot: snapshot, meetingRelativePath: meetingRelativePath,
            transcriptBody: transcriptBody, transcriptRelativePath: transcriptRelativePath,
            fileExists: expected != nil, visualSnapshots: visualSnapshots)
        if let reviewed = approval?.proposedBlockHash, reviewed != result.blockSHA256 {
            throw ObsidianExportError.managedBlockConflict
        }
        var receipt = ObsidianExportBindingRecord(
            destinationID: destination.id, sessionID: session.id, component: component, relativePath: relativePath,
            markerID: binding.markerID, lastExportedRevision: session.exportRevision,
            lastBlockSHA256: result.blockSHA256, lastFileSHA256: result.fileSHA256,
            state: .exported, errorCode: nil, updatedAt: now)
        receipt.lastMetadataSHA256 = result.metadataSHA256
        receipt.metadataOwnershipEvaluated = component == .meeting ? true : nil
        receipt.transcriptSignature = transcriptSignature
        receipt.snapshotsSignature = snapshotsSignature
        guard try await store.prepareExportWrite(row: row, binding: receipt) else { return nil }
        let outcome = try await writer.write(target: fileTarget, content: result.text, expectedIdentity: expected,
            vaultRoot: vault, relativePath: relativePath)
        receipt.lastFileSHA256 = outcome.identity.sha256
        try await store.commitExportWrite(receipt)
        return receipt
    }

    private static func snapshotsDigest(_ snapshots: [MeetingSnapshotRecord]) -> String {
        guard !snapshots.isEmpty else { return "" }
        let ordered = snapshots.sorted { ($0.capturedAt, $0.id.uuidString) < ($1.capturedAt, $1.id.uuidString) }
        let payload = ordered.map { snap in
            [
                snap.id.uuidString,
                snap.relativeFileName,
                snap.fileExtension,
                String(snap.updatedAt.timeIntervalSinceReferenceDate),
                snap.caption,
                snap.ocrText,
                snap.transcriptExcerpt
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return MarkdownFilePatcher.sha256(payload)
    }

    private func copySnapshotAttachments(
        _ snapshots: [MeetingSnapshotRecord],
        destination: ObsidianDestinationRecord,
        relativeMarkdownPath: String,
        in vault: URL
    ) async throws {
        let parentDir = (relativeMarkdownPath as NSString).deletingLastPathComponent
        let attachmentsDir = parentDir.isEmpty ? "Attachments" : parentDir + "/Attachments"
        for snap in snapshots {
            let relativeTarget = attachmentsDir + "/" + snap.exportFileName
            guard case .success(let targetURL) = ObsidianVaultAccess.validate(relativePath: relativeTarget, in: vault),
                  case .success(let fileURL) = ObsidianVaultAccess.validateFileTarget(targetURL) else {
                continue
            }
            let sourceURL = await snapshotStore.imageURL(for: snap)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let data = try Data(contentsOf: sourceURL)
            if let existing = try? Data(contentsOf: fileURL), existing == data { continue }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func metadataMatches(_ binding: ObsidianExportBindingRecord, in text: String) throws -> Bool {
        guard let expected = binding.lastMetadataSHA256 else { return true }
        return try ObsidianOwnedMetadata.hash(in: text) == expected
    }

    private func availableIndividualPath(_ proposed: String, in vault: URL, excluding reservedPath: String?) throws -> String {
        let path = proposed as NSString
        let base = path.deletingPathExtension
        let ext = path.pathExtension
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? proposed : base + " (\(attempt))." + ext
            if let reservedPath, candidate.caseInsensitiveCompare(reservedPath) == .orderedSame { continue }
            guard case .success(let url) = ObsidianVaultAccess.validate(relativePath: candidate, in: vault) else {
                throw ObsidianExportError.pathEscapesVault(candidate)
            }
            if !FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil {
                return candidate
            }
        }
        throw ObsidianExportError.notARegularFile(proposed)
    }

    func conflicts() async throws -> [ObsidianConflict] {
        let destinations = try await store.destinations()
        var conflicts: [ObsidianConflict] = []
        for destination in destinations {
            let rows = try await store.outboxRows(destinationID: destination.id).filter(\.paused)
            for row in rows {
                let components = destination.mode == .worklog ? [.transcript, .worklog] : destination.mode.requiredComponents
                for component in components {
                    if let binding = try await store.binding(destinationID: destination.id, sessionID: row.sessionID, component: component),
                       binding.state == .conflict {
                        conflicts.append(ObsidianConflict(row: row, binding: binding))
                    }
                }
            }
        }
        return conflicts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func compare(_ conflict: ObsidianConflict) async throws -> ObsidianConflictComparison {
        let row = conflict.row, binding = conflict.binding
        guard let rawDestination = try await store.destination(id: row.destinationID),
              let snapshot = row.snapshot else { throw ObsidianExportError.destinationChanged }
        let overrides = (try? await store.autoExportOverrides(for: snapshot.session)) ?? .init()
        let destination = rawDestination.effective(for: overrides)
        let transcript = destination.layout.sections.contains(.transcript) ? await transcriptProvider(snapshot.session) : nil
        let visualSnapshots = destination.layout.sections.contains(.snapshots)
            ? await snapshotStore.snapshots(for: await snapshotSessionIDsProvider(snapshot.session.id)) : []
        let copy = MeetingMarkdownTemplate.managedContent(session: snapshot.session, note: snapshot.note,
            outcome: snapshot.outcome, outcomeState: snapshot.outcomeState, sections: destination.layout.sections,
            snapshots: visualSnapshots, useWikiLinksForSnapshots: true,
            expertBlocks: snapshot.expertBlocks, dominantRole: snapshot.dominantRole ?? snapshot.session.dominantRole,
            coreOutcomePolicy: snapshot.coreOutcomePolicy)
            + ObsidianComponentRenderer.transcriptSection(component: .meeting, layout: destination.layout,
                path: binding.relativePath, body: transcript, transcriptPath: nil)
        guard let vault = await resolveVault(destination) else {
            return ObsidianConflictComparison(conflict: conflict, local: copy,
                external: L("Waiting for vault access"), standaloneCopy: copy, observedBlockHash: nil)
        }
        let meetingPath = try await store.binding(destinationID: destination.id, sessionID: row.sessionID,
                                                  component: .meeting)?.relativePath
        let transcriptPath = try await store.binding(destinationID: destination.id, sessionID: row.sessionID,
                                                     component: .transcript)?.relativePath
        guard case .success(let url) = ObsidianVaultAccess.validate(relativePath: binding.relativePath, in: vault),
              case .success = ObsidianVaultAccess.validateFileTarget(url),
              let text = try? String(contentsOf: url, encoding: .utf8), let nonce = binding.markerID else {
            return ObsidianConflictComparison(conflict: conflict, local: copy,
                external: L("The previously exported file could not be read."), standaloneCopy: copy, observedBlockHash: nil)
        }
        let block = MarkdownFilePatcher.managedBlockContent(in: text, sessionID: row.sessionID,
            nonce: nonce, component: binding.component)
        let hash = block.map(MarkdownFilePatcher.sha256)
        var reviewed = binding
        reviewed.lastBlockSHA256 = hash
        let currentMetadata = binding.lastMetadataSHA256 == nil ? nil : try? ObsidianOwnedMetadata.preview(in: text)
        if let currentMetadata { reviewed.lastMetadataSHA256 = MarkdownFilePatcher.sha256(currentMetadata) }
        let candidate = try? ObsidianComponentRenderer.patch(existing: text, binding: reviewed,
            destination: destination, snapshot: snapshot, meetingRelativePath: meetingPath,
            transcriptBody: transcript, transcriptRelativePath: transcriptPath, fileExists: true,
            visualSnapshots: visualSnapshots)
        let local = candidate.flatMap {
            MarkdownFilePatcher.managedBlockContent(in: $0.text, sessionID: row.sessionID,
                nonce: nonce, component: binding.component)
        } ?? copy
        let nextMetadata = currentMetadata == nil ? nil : candidate.flatMap { try? ObsidianOwnedMetadata.preview(in: $0.text) }
        let external = block ?? String(text.prefix(100_000))
        return ObsidianConflictComparison(conflict: conflict, local: conflictText(body: local, metadata: nextMetadata),
            external: conflictText(body: external, metadata: currentMetadata), standaloneCopy: copy,
            observedBlockHash: candidate != nil && binding.lastExportedRevision > 0 ? hash : nil,
            observedMetadataHash: currentMetadata.map(MarkdownFilePatcher.sha256),
            proposedBlockHash: candidate?.blockSHA256)
    }

    private func conflictText(body: String, metadata: String?) -> String {
        guard let metadata else { return body }
        return "---\n" + metadata + "\n---\n\n" + body
    }

    func replaceConflictingBlock(_ comparison: ObsidianConflictComparison) async throws {
        guard let hash = comparison.observedBlockHash else { throw ObsidianExportError.managedBlockConflict }
        try await store.approveObsidianConflictReplacement(row: comparison.conflict.row,
            component: comparison.conflict.binding.component, observedBlockHash: hash,
            observedMetadataHash: comparison.observedMetadataHash, proposedBlockHash: comparison.proposedBlockHash)
        await runOnce()
    }

    private func markBinding(destinationID: UUID, sessionID: UUID, component: ObsidianExportComponent,
                             state: ObsidianBindingState, errorCode: String?) async throws {
        guard var binding = try await store.binding(destinationID: destinationID, sessionID: sessionID, component: component) else { return }
        binding.state = state
        binding.errorCode = errorCode
        try await store.saveBinding(binding)
    }
}
