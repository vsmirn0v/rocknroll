import ConferenceCore
import Darwin
import Foundation

@main
struct ClonedVoiceWorkerMain {
    static func main() async {
        // This child is owned by the app. It must stop even during a Core AI call
        // if the parent crashes or is force-quit before it can close the pipe.
        let parent = getppid()
        guard parent > 1 else { return }
        let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        parentExit.setEventHandler { _exit(1) }
        parentExit.activate()
        guard getppid() == parent else { return }
        defer { parentExit.cancel() }

        signal(SIGPIPE, SIG_IGN)
        let protocolOutput = dup(STDOUT_FILENO)
        guard protocolOutput >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return }
        let output = PipeWriter(handle: FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true))
        let input = FileHandle.standardInput
        let worker = ClonedVoiceWorkerRuntime()
        let dispatchState = WorkerDispatchState()

        let (requests, requestContinuation) = AsyncStream<(ClonedVoiceWire.Request, Data?)>.makeStream()
        DispatchQueue(label: "voice-worker.stdin", qos: .userInitiated).async {
            do {
                while let bytes = try ClonedVoiceWire.read(from: input, limit: ClonedVoiceWire.controlLimit) {
                    let request = try JSONDecoder().decode(ClonedVoiceWire.Request.self, from: bytes)
                    if request.operation == .cancel {
                        dispatchState.cancelActiveSpeak()
                        continue
                    }
                    let binaryVoiceData: Data?
                    if request.binaryVoiceFollows {
                        guard let data = try ClonedVoiceWire.read(from: input, limit: ClonedVoiceWire.pcmLimit) else {
                            throw ClonedVoiceWorkerError.protocolFailure
                        }
                        binaryVoiceData = data
                    } else {
                        binaryVoiceData = nil
                    }
                    requestContinuation.yield((request, binaryVoiceData))
                }
            } catch {
                probeLog("voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            }
            requestContinuation.finish()
        }

        do {
            for await (request, binaryVoiceData) in requests {
                let priority: TaskPriority = (request.operation == .prepare || request.operation == .verify) ? .utility : .userInitiated
                let task = Task.detached(priority: priority) {
                    await worker.perform(request, binaryVoiceData: binaryVoiceData, progress: { update in
                        if update.stage == .synthesize {
                            dispatchState.markSynthesizing()
                        }
                        if let bytes = try? JSONEncoder().encode(ClonedVoiceWire.Response(stage: update.stage, progress: update)) {
                            try? output.write(bytes, limit: ClonedVoiceWire.controlLimit)
                        }
                    }, onPCMChunk: { chunk in
                        try? output.writePCMChunk(chunk)
                    })
                }
                dispatchState.setActiveTask(task, operation: request.operation)
                let result = await task.value
                dispatchState.clearActiveTask()
                try output.write(JSONEncoder().encode(result.0), limit: ClonedVoiceWire.controlLimit)
                if let samples = result.1 {
                    let pcm = samples.withUnsafeBytes { Data($0) }
                    try output.write(pcm, limit: ClonedVoiceWire.pcmLimit)
                }
            }
        } catch {
            probeLog("voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
        }
    }
}

private final class WorkerDispatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeTask: Task<(ClonedVoiceWire.Response, [Float]?), Never>?
    private var activeOperation: ClonedVoiceWire.Request.Operation?
    private var synthesizing = false

    func setActiveTask(_ task: Task<(ClonedVoiceWire.Response, [Float]?), Never>, operation: ClonedVoiceWire.Request.Operation) {
        lock.lock()
        activeTask = task
        activeOperation = operation
        synthesizing = false
        lock.unlock()
    }

    func markSynthesizing() {
        lock.lock()
        if activeOperation == .speak {
            synthesizing = true
        }
        lock.unlock()
    }

    func cancelActiveSpeak() {
        lock.lock()
        let task = (activeOperation == .speak && synthesizing) ? activeTask : nil
        lock.unlock()
        task?.cancel()
    }

    func clearActiveTask() {
        lock.lock()
        activeTask = nil
        activeOperation = nil
        synthesizing = false
        lock.unlock()
    }
}

private final class PipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) { self.handle = handle }

    func write(_ data: Data, limit: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try ClonedVoiceWire.write(data, to: handle, limit: limit)
    }

    func writePCMChunk(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let header = try JSONEncoder().encode(ClonedVoiceWire.Response(pcmChunk: true))
        let pcm = samples.withUnsafeBytes { Data($0) }
        lock.lock()
        defer { lock.unlock() }
        try ClonedVoiceWire.write(header, to: handle, limit: ClonedVoiceWire.controlLimit)
        try ClonedVoiceWire.write(pcm, to: handle, limit: ClonedVoiceWire.pcmLimit)
    }
}

private final class ClonedVoiceWorkerRuntime: @unchecked Sendable {
    private let baseline = ProcessMemoryProbe.footprint()
    private var folder: URL?
    private var lease: ClonedVoiceLease?
    private var model: AnyObject?
    private var repairedAssets: [String] = []
    private var pendingRepairAsset: String?
    private var voiceCache: [String: VoxVoice] = [:]
    private var voiceCacheOrder: [String] = []
    private static let maximumCachedVoices = 4

    private var primaryRepaired: String? { repairedAssets.first }
    private var reportedRepairedList: [String]? { repairedAssets.isEmpty ? nil : repairedAssets }

    func perform(_ request: ClonedVoiceWire.Request,
                 binaryVoiceData: Data? = nil,
                 progress: @escaping @Sendable (ClonedVoiceWire.Response.Progress) -> Void,
                 onPCMChunk: (@Sendable ([Float]) -> Void)? = nil) async -> (ClonedVoiceWire.Response, [Float]?) {
        repairedAssets = []
        pendingRepairAsset = nil
        do {
            if request.operation == .ping { return (.init(), nil) }
            #if canImport(CoreAI)
            if #available(macOS 27.0, *) {
                if request.operation == .cacheScope { return (.init(message: "worker-default"), nil) }
                if let folder = request.folder {
                    let result = try await generate(request, binaryVoiceData: binaryVoiceData, folder: folder, progress: progress, onPCMChunk: onPCMChunk)
                    let memory = (result.trailingPCM != nil || result.streamedPCM || model != nil) ? measuredMemory : nil
                    return (.init(repairedAssets: reportedRepairedList, repairedAsset: primaryRepaired,
                                  pcm: result.trailingPCM != nil, streamedPCM: result.streamedPCM, memoryBytes: memory),
                            result.trailingPCM)
                }
            }
            #endif
            if request.operation == .cacheScope { return (.init(message: "Core AI unavailable on this OS"), nil) }
            throw VoxError.unsupported("Core AI is unavailable")
        } catch is CancellationError {
            return (.init(failure: .cancelled, message: "cancelled"), nil)
        } catch ClonedVoiceWorkerError.busy {
            return (.init(failure: .busy), nil)
        } catch VoxError.context(let message) where request.operation == .speak {
            return (.init(failure: .context, message: message), nil)
        } catch let failure as VoicePreparationStorageError {
            let diagnosis = ClonedVoiceFailure(kind: .preparationSpace, storage: failure.snapshot,
                technicalDetails: failure.localizedDescription,
                repairAsset: pendingRepairAsset, failedAt: Date())
            return (.init(failure: .runtime, message: failure.localizedDescription,
                          repairedAssets: reportedRepairedList,
                          failureInfo: diagnosis, repairedAsset: primaryRepaired), nil)
        } catch let failure as VoxVerificationFailure {
            let isStorage = VoiceStorage.isOutOfSpace(failure.cause)
            let primary = isStorage ? nil : failure.staleAssets.first
            let batch = (isStorage || failure.staleAssets.isEmpty) ? nil : failure.staleAssets
            let kind: ClonedVoiceFailure.Kind = isStorage ? .storage : .cache
            let detail = failure.cause as NSError
            let diagnosis = ClonedVoiceFailure(kind: kind, technicalDetails: failure.localizedDescription,
                                                repairAsset: primary, repairAssets: batch, failedAt: Date(),
                                                asset: failure.staleAssets.first, errorDomain: detail.domain, errorCode: detail.code)
            probeLog("voice-worker-failure-classified", ["kind": kind.rawValue, "repairAvailable": primary != nil])
            return (.init(failure: .runtime, message: failure.localizedDescription, repairAsset: primary,
                          repairedAssets: reportedRepairedList, failureInfo: diagnosis, repairedAsset: primaryRepaired), nil)
        } catch let failure as VoxAssetFailure {
            let asset = failure.missingSpecialization ? failure.asset : nil
            let kind: ClonedVoiceFailure.Kind = VoiceStorage.isOutOfSpace(failure.cause) ? .storage :
                (asset != nil ? .cache : (failure.duringSpecialization ? .compilation : .unknown))
            let detail = failure.cause as NSError
            let diagnosis = ClonedVoiceFailure(kind: kind, technicalDetails: failure.localizedDescription,
                                                repairAsset: asset, failedAt: Date(), asset: failure.asset,
                                                errorDomain: detail.domain, errorCode: detail.code)
            probeLog("voice-worker-failure-classified", ["kind": kind.rawValue, "repairAvailable": asset != nil])
            return (.init(failure: .runtime, message: failure.localizedDescription, repairAsset: asset,
                          repairedAssets: reportedRepairedList, failureInfo: diagnosis, repairedAsset: primaryRepaired), nil)
        } catch {
            let detail = error as NSError
            probeLog("voice-worker-operation-failed", ["domain": detail.domain, "code": detail.code])
            let message = error is VoxError ? error.localizedDescription : "The Neural Engine could not run the voice model (\(detail.domain) \(detail.code))."
            let kind: ClonedVoiceFailure.Kind = VoiceStorage.isOutOfSpace(error) ? .storage : .unknown
            return (.init(failure: .runtime, message: message,
                          repairedAssets: reportedRepairedList,
                          failureInfo: .init(kind: kind, technicalDetails: message, failedAt: Date()),
                          repairedAsset: primaryRepaired), nil)
        }
    }

    private var measuredMemory: UInt64? {
        guard let baseline, let footprint = ProcessMemoryProbe.footprint(), footprint > baseline else { return nil }
        return footprint - baseline
    }

    private func resolveVoice(for request: ClonedVoiceWire.Request, binaryVoiceData: Data?) throws -> VoxVoice? {
        if request.binaryVoiceFollows {
            guard let skeleton = request.voice, let binaryVoiceData else {
                throw ClonedVoiceWorkerError.protocolFailure
            }
            let hydrated = try ClonedVoiceWire.attachBinaryVoiceFloats(skeleton, data: binaryVoiceData)
            cacheVoice(hydrated, key: request.voiceID ?? hydrated.cacheID)
            return hydrated
        }
        if let explicit = request.voice {
            cacheVoice(explicit, key: request.voiceID ?? explicit.cacheID)
            return explicit
        }
        if let voiceID = request.voiceID {
            guard let cached = voiceCache[voiceID] else {
                throw ClonedVoiceWorkerError.protocolFailure
            }
            return cached
        }
        return nil
    }

    private func cacheVoice(_ voice: VoxVoice, key: String) {
        voiceCache[key] = voice
        voiceCacheOrder.removeAll { $0 == key }
        voiceCacheOrder.append(key)
        while voiceCacheOrder.count > Self.maximumCachedVoices {
            let evicted = voiceCacheOrder.removeFirst()
            voiceCache.removeValue(forKey: evicted)
        }
    }

    #if canImport(CoreAI)
    @available(macOS 27.0, *)
    private func generate(_ request: ClonedVoiceWire.Request, binaryVoiceData: Data?, folder: URL,
                          progress: @escaping @Sendable (ClonedVoiceWire.Response.Progress) -> Void,
                          onPCMChunk: (@Sendable ([Float]) -> Void)?) async throws -> (trailingPCM: [Float]?, streamedPCM: Bool) {
        let folder = folder.standardizedFileURL
        guard self.folder == nil || self.folder == folder else { throw ClonedVoiceWorkerError.protocolFailure }
        if lease == nil { lease = try ClonedVoiceLease(folder: folder, purpose: "worker") }
        self.folder = folder
        if request.operation == .verify {
            progress(.init(stage: .validate))
            if let resident = model as? VoxCPM2 {
                try resident.verifyLoadedFunctions()
            } else {
                try VoxCoreAI.verify(bundle: folder)
            }
            return (nil, false)
        }
        let resolvedVoice = request.operation == .speak ? try resolveVoice(for: request, binaryVoiceData: binaryVoiceData) : nil
        let loaded: VoxCPM2
        if let resident = model as? VoxCPM2 {
            // An owner still using the model must never have its cache invalidated.
            guard request.repairAsset == nil, (request.repairAssets ?? []).isEmpty else { throw ClonedVoiceWorkerError.busy }
            loaded = resident
        } else {
            progress(.init(stage: .load))
            if request.operation == .prepare {
                var seen = Set<String>()
                let targets = (request.repairAssets ?? (request.repairAsset.map { [$0] } ?? [])).filter { seen.insert($0).inserted }
                for asset in targets {
                    pendingRepairAsset = asset
                    if try VoxCoreAI.repair(asset, in: folder) { repairedAssets.append(asset) }
                    pendingRepairAsset = nil
                }
                loaded = try await VoxCPM2(bundle: folder) { role, _, step, total in
                    progress(.init(stage: .load, asset: role, step: step, totalSteps: total))
                }
            } else {
                loaded = try await VoxCPM2(bundle: folder)
            }
            model = loaded
        }

        switch request.operation {
        case .ping, .cacheScope, .verify, .cancel: return (nil, false)
        case .prepare:
            progress(.init(stage: .validate))
            try loaded.verifyLoadedFunctions()
            // A reference patch drives the encoder too, unlike a text-only probe.
            // This is synthetic conditioning data, independent of the user's enrollment.
            let reference = (0..<256).map { 0.25 * sin(Float($0) * 0.1) }
            let voice = VoxVoice(mode: .clone, transcript: "", reference: reference, continuation: nil, patches: 1)
            let pcm = try await loaded.generate("The voice is ready.", voice: voice, seed: 3,
                                               options: .init(minimumPatches: 2, maximumPatches: 16))
            guard loaded.sampleRate == 48_000 else { throw VoxError.audio("unexpected sample rate") }
            try ClonedVoiceWire.validatePCM(pcm)
            return (nil, false)
        case .speak:
            try Task.checkCancellation()
            progress(.init(stage: .synthesize))
            guard let text = request.text else { throw ClonedVoiceWorkerError.protocolFailure }
            let seed = UInt64.random(in: UInt64.min...UInt64.max)
            if request.streamPCM, let onPCMChunk {
                var startupBuffer: [Float] = []
                var startupConfirmed = false
                let pcm = try await loaded.generate(text, voice: resolvedVoice, seed: seed) { piece in
                    guard !piece.isEmpty, !Task.isCancelled else { return }
                    if startupConfirmed {
                        onPCMChunk(piece)
                        return
                    }
                    startupBuffer.append(contentsOf: piece)
                    if ClonedVoiceWire.hasAudibleEnergy(startupBuffer) {
                        startupConfirmed = true
                        onPCMChunk(startupBuffer)
                        startupBuffer.removeAll(keepingCapacity: false)
                    }
                }
                try ClonedVoiceWire.validatePCM(pcm)
                if !startupConfirmed && !startupBuffer.isEmpty {
                    onPCMChunk(startupBuffer)
                }
                return (nil, true)
            }
            let pcm = try await loaded.generate(text, voice: resolvedVoice, seed: seed)
            try ClonedVoiceWire.validatePCM(pcm)
            return (pcm, false)
        }
    }
    #endif
}
