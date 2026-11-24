import Combine
import Darwin
import Foundation

enum ClonedVoiceEnginePhase: Equatable, Sendable {
    case unloaded, loading, loaded, unloading, failed
}

struct ClonedVoiceRuntimeSnapshot: Equatable, Sendable {
    var folder: URL?
    var phase: ClonedVoiceEnginePhase = .unloaded
    var generation = 0
    var activeSpeeches = 0
    var queuedSpeeches = 0
    var idleDeadline: Date?
    var error: String?
}

struct ClonedVoiceWorkerOutput: Sendable {
    var samples: [Float]?
    var memoryBytes: UInt64?
    var message: String?
    var repairedAsset: String?
    var repairedAssets: [String]? = nil
}

protocol ClonedVoiceWorkerConnection: Sendable {
    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval) async throws -> ClonedVoiceWorkerOutput
    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval,
                 onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?) async throws -> ClonedVoiceWorkerOutput
    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval,
                 onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?,
                 onPCMChunk: (@Sendable ([Float]) -> Void)?) async throws -> ClonedVoiceWorkerOutput
    func cancelActiveSpeak()
    func stop() async
}

extension ClonedVoiceWorkerConnection {
    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval,
                 onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?) async throws -> ClonedVoiceWorkerOutput {
        try await execute(request, timeout: timeout)
    }

    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval,
                 onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?,
                 onPCMChunk: (@Sendable ([Float]) -> Void)?) async throws -> ClonedVoiceWorkerOutput {
        let output = try await execute(request, timeout: timeout, onProgress: onProgress)
        if let onPCMChunk, let samples = output.samples, !samples.isEmpty {
            onPCMChunk(samples)
        }
        return output
    }

    func cancelActiveSpeak() {}
}

/// Owns one child, one operation, and its idle timer. Identical callers share the
/// operation. A competing request receives backpressure without queuing stale replies.
actor ClonedVoiceEngine {
    static let shared = ClonedVoiceEngine()
    static let idleNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    nonisolated let runtime = CurrentValueSubject<ClonedVoiceRuntimeSnapshot, Never>(.init())
    private let idleNanoseconds: UInt64
    private let connect: @Sendable () throws -> any ClonedVoiceWorkerConnection
    private let tracksVoiceMemory: Bool
    private var worker: (any ClonedVoiceWorkerConnection)?
    private var operation: (request: ClonedVoiceWire.Request, task: Task<ClonedVoiceWorkerOutput, Error>)?
    private var idle: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var runtimeState = ClonedVoiceRuntimeSnapshot()

    init(idleNanoseconds: UInt64 = ClonedVoiceEngine.idleNanoseconds, tracksVoiceMemory: Bool = true,
         connect: @escaping @Sendable () throws -> any ClonedVoiceWorkerConnection = { try ClonedVoiceWorkerProcess() }) {
        self.idleNanoseconds = idleNanoseconds
        self.tracksVoiceMemory = tracksVoiceMemory
        self.connect = connect
    }

    var runtimeSnapshot: ClonedVoiceRuntimeSnapshot { runtimeState }

    @discardableResult func prepare(_ folder: URL, repairAsset: String? = nil, repairAssets: [String]? = nil,
                                    onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)? = nil) async throws -> [String] {
        if repairAsset != nil || !(repairAssets ?? []).isEmpty {
            // Never evict a cache entry while this process is using its model.
            guard operation == nil, stopping == nil else { throw ClonedVoiceWorkerError.busy }
            if worker != nil { await unload() }
        }
        let output = try await execute(.init(operation: .prepare, folder: folder.standardizedFileURL,
                                             repairAsset: repairAsset, repairAssets: repairAssets),
                                       onProgress: onProgress)
        return output.repairedAssets ?? (output.repairedAsset.map { [$0] } ?? [])
    }

    /// Checks specialization cache readiness in a short-lived background worker without updating residency UI.
    func verify(_ folder: URL) async throws {
        try Task.checkCancellation()
        if let stopping {
            await stopping.value
            try await verify(folder)
            return
        }
        guard operation == nil else { throw ClonedVoiceWorkerError.busy }
        let standardized = folder.standardizedFileURL
        if worker != nil, runtimeState.folder == standardized, runtimeState.phase == .loaded {
            return
        }
        if worker != nil {
            await unload()
            try await verify(standardized)
            return
        }
        let generation = runtimeState.generation
        let request = ClonedVoiceWire.Request(operation: .verify, folder: standardized)
        let task = Task<ClonedVoiceWorkerOutput, Error>(priority: .utility) {
            guard runtimeState.generation == generation, stopping == nil else { throw ClonedVoiceWorkerError.stopped }
            let probe = try connect()
            worker = probe
            do {
                let output = try await probe.execute(request, timeout: 60, onProgress: nil)
                guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                worker = nil
                operation = nil
                await stopProbe(probe, generation: generation)
                return output
            } catch {
                guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                worker = nil
                operation = nil
                await stopProbe(probe, generation: generation)
                throw error
            }
        }
        operation = (request, task)
        _ = try await task.value
    }

    private func stopProbe(_ probe: any ClonedVoiceWorkerConnection, generation: Int) async {
        let completion = Task { [weak self] in
            await probe.stop()
            await self?.finishProbeStop(generation: generation)
        }
        stopping = completion
        await completion.value
    }

    private func finishProbeStop(generation: Int) {
        if runtimeState.generation == generation {
            stopping = nil
        }
    }

    func speak(_ text: String, voice: VoxVoice, folder: URL,
               onChunk: (@Sendable ([Float]) -> Void)? = nil) async throws -> [Float] {
        let result = try await execute(.init(operation: .speak, folder: folder.standardizedFileURL, text: text, voice: voice),
                                       onPCMChunk: onChunk)
        guard let samples = result.samples else { throw ClonedVoiceWorkerError.protocolFailure }
        return samples
    }

    func speakZeroShot(_ text: String, folder: URL,
                       onChunk: (@Sendable ([Float]) -> Void)? = nil) async throws -> [Float] {
        let result = try await execute(.init(operation: .speak, folder: folder.standardizedFileURL, text: text, voice: nil),
                                       onPCMChunk: onChunk)
        guard let samples = result.samples else { throw ClonedVoiceWorkerError.protocolFailure }
        return samples
    }

    func cancelCurrentSpeakIfActive() {
        guard operation?.request.operation == .speak else { return }
        worker?.cancelActiveSpeak()
    }

    func unload() async {
        if let stopping { await stopping.value; return }
        idle?.cancel()
        idle = nil
        let generation = runtimeState.generation + 1
        runtimeState = .init(folder: runtimeState.folder, phase: .unloading, generation: generation)
        publish()
        operation = nil
        let child = worker
        worker = nil
        let completion = Task { [weak self] in
            await child?.stop()
            await self?.unloaded(generation: generation)
        }
        stopping = completion
        await completion.value
    }

    @discardableResult func unloadIfIdle() async -> Bool {
        guard operation == nil, stopping == nil else { return false }
        await unload()
        return true
    }

    private func unloaded(generation: Int) {
        runtimeState = .init(generation: generation)
        stopping = nil
        if tracksVoiceMemory { LocalModelMemoryTracker.shared.clear(.voice) }
        publish()
    }

    private func execute(_ request: ClonedVoiceWire.Request,
                         onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)? = nil,
                         onPCMChunk: (@Sendable ([Float]) -> Void)? = nil) async throws -> ClonedVoiceWorkerOutput {
        try Task.checkCancellation()
        if let stopping {
            await stopping.value
            return try await execute(request, onProgress: onProgress, onPCMChunk: onPCMChunk)
        }
        if let operation {
            guard operation.request == request else { throw ClonedVoiceWorkerError.busy }
            return try await operation.task.value
        }
        if worker != nil, runtimeState.folder != request.folder {
            await unload()
            return try await execute(request, onProgress: onProgress, onPCMChunk: onPCMChunk)
        }

        idle?.cancel()
        idle = nil
        runtimeState.idleDeadline = nil
        let isCold = worker == nil
        let generation = runtimeState.generation
        runtimeState.folder = request.folder
        runtimeState.error = nil
        runtimeState.phase = isCold ? .loading : .loaded
        runtimeState.activeSpeeches = request.operation == .speak ? 1 : 0
        publish()

        let priority: TaskPriority = request.operation == .prepare ? .utility : .userInitiated
        let task = Task(priority: priority) {
            guard runtimeState.generation == generation, stopping == nil else { throw ClonedVoiceWorkerError.stopped }
            do {
                if worker == nil { worker = try connect() }
                guard let worker else { throw ClonedVoiceWorkerError.unavailable }
                let timeout: TimeInterval = request.operation == .prepare ? 65 * 60 : (isCold ? 10 * 60 : 3 * 60)
                let output = try await worker.execute(request, timeout: timeout, onProgress: onProgress, onPCMChunk: onPCMChunk)
                guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                operation = nil
                runtimeState.phase = .loaded
                runtimeState.activeSpeeches = 0
                if tracksVoiceMemory, let bytes = output.memoryBytes { LocalModelMemoryTracker.shared.recordVoiceWorker(bytes: bytes) }
                scheduleIdleUnload(generation: generation)
                return output
            } catch {
                guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                if error is CancellationError {
                    operation = nil
                    runtimeState.activeSpeeches = 0
                    runtimeState.phase = .loaded
                    scheduleIdleUnload(generation: generation)
                } else if case ClonedVoiceWorkerError.context = error {
                    operation = nil
                    runtimeState.activeSpeeches = 0
                    runtimeState.phase = .loaded
                    scheduleIdleUnload(generation: generation)
                } else {
                    await worker?.stop()
                    guard runtimeState.generation == generation else { throw ClonedVoiceWorkerError.stopped }
                    worker = nil
                    operation = nil
                    runtimeState.activeSpeeches = 0
                    runtimeState.phase = .failed
                    runtimeState.error = error.localizedDescription
                    if tracksVoiceMemory { LocalModelMemoryTracker.shared.clear(.voice) }
                    publish()
                }
                throw error
            }
        }
        operation = (request, task)
        return try await task.value
    }

    private func scheduleIdleUnload(generation: Int) {
        runtimeState.idleDeadline = Date().addingTimeInterval(Double(idleNanoseconds) / 1_000_000_000)
        publish()
        idle = Task { [weak self, idleNanoseconds] in
            do { try await Task.sleep(nanoseconds: idleNanoseconds) } catch { return }
            await self?.unloadIfIdle(generation: generation)
        }
    }

    private func unloadIfIdle(generation: Int) async {
        guard !Task.isCancelled, generation == runtimeState.generation, operation == nil, stopping == nil else { return }
        await unload()
    }

    private func publish() { runtime.send(runtimeState) }
}

/// Blocking pipe reads and child reaping use a utility queue. The watchdog has an
/// independent queue and can kill a child stalled inside a noncooperative framework.
final class ClonedVoiceWorkerProcess: ClonedVoiceWorkerConnection, @unchecked Sendable {
    static let name = "RockClonedVoiceWorker"
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let io = DispatchQueue(label: "attention.voice-worker.io", qos: .utility)
    private let state = NSLock()
    private let inputLock = NSLock()
    private var current: UUID?
    private var activeOperation: ClonedVoiceWire.Request.Operation?
    private var canCooperativeCancel = false
    private var workerWarm = false
    private var cachedVoiceID: String?
    private var interruption: ClonedVoiceWorkerError?

    init(executable: URL? = Bundle.main.url(forAuxiliaryExecutable: name)) throws {
        guard let executable else { throw ClonedVoiceWorkerError.unavailable }
        let toChild = Pipe(), fromChild = Pipe()
        input = toChild.fileHandleForWriting
        output = fromChild.fileHandleForReading
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw ClonedVoiceWorkerError.unavailable }
        process.executableURL = executable
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.standardError
        do { try process.run() }
        catch { throw ClonedVoiceWorkerError.unavailable }
        probeLog("voice-worker-started", ["pid": process.processIdentifier])
    }

    deinit {
        interrupt(.stopped)
        let proc = process
        if proc.isRunning {
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
            }
        }
    }

    var pid: Int32 { process.processIdentifier }

    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval) async throws -> ClonedVoiceWorkerOutput {
        try await execute(request, timeout: timeout, onProgress: nil, onPCMChunk: nil)
    }

    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval,
                 onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?) async throws -> ClonedVoiceWorkerOutput {
        try await execute(request, timeout: timeout, onProgress: onProgress, onPCMChunk: nil)
    }

    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval,
                 onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?,
                 onPCMChunk: (@Sendable ([Float]) -> Void)?) async throws -> ClonedVoiceWorkerOutput {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                let id = UUID()
                self.state.lock()
                let previous = self.interruption
                self.current = id
                self.activeOperation = request.operation
                self.canCooperativeCancel = self.workerWarm && request.operation == .speak
                self.state.unlock()
                if let previous { continuation.resume(throwing: previous); return }
                let watchdog = DispatchWorkItem { [weak self] in self?.interrupt(.timeout, operation: id) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let result = Result { try self.exchange(request, onProgress: onProgress, onPCMChunk: onPCMChunk) }
                self.state.lock()
                self.current = nil
                self.activeOperation = nil
                self.canCooperativeCancel = false
                let interruption = self.interruption
                self.state.unlock()
                watchdog.cancel()
                if let interruption { continuation.resume(throwing: interruption) }
                else { continuation.resume(with: result) }
            }
        }
    }

    func cancelActiveSpeak() {
        state.lock()
        let allowed = current != nil && activeOperation == .speak && canCooperativeCancel && interruption == nil && process.isRunning
        state.unlock()
        guard allowed, let data = try? JSONEncoder().encode(ClonedVoiceWire.Request(operation: .cancel)) else { return }
        inputLock.lock()
        defer { inputLock.unlock() }
        try? ClonedVoiceWire.write(data, to: input, limit: ClonedVoiceWire.controlLimit)
    }

    func stop() async {
        interrupt(.stopped)
        await withCheckedContinuation { continuation in
            io.async {
                self.process.waitUntilExit()
                try? self.input.close()
                try? self.output.close()
                continuation.resume()
            }
        }
    }

    private func interrupt(_ error: ClonedVoiceWorkerError, operation: UUID? = nil) {
        state.lock()
        defer { state.unlock() }
        guard interruption == nil, operation == nil || current == operation else { return }
        interruption = error
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func exchange(_ request: ClonedVoiceWire.Request,
                          onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?,
                          onPCMChunk: (@Sendable ([Float]) -> Void)?) throws -> ClonedVoiceWorkerOutput {
        let wire = ClonedVoiceWire.self
        do {
            var wireRequest = request
            var binaryVoiceData: Data?
            var sentVoiceID: String?
            if request.operation == .speak, let voice = request.voice {
                let voiceID = voice.cacheID
                sentVoiceID = voiceID
                wireRequest.voiceID = voiceID
                state.lock()
                let alreadyCached = (cachedVoiceID == voiceID)
                state.unlock()
                if alreadyCached {
                    wireRequest.voice = nil
                    wireRequest.binaryVoiceFollows = false
                } else {
                    wireRequest.voice = VoxVoice(
                        revision: voice.revision,
                        mode: voice.mode,
                        transcript: voice.transcript,
                        reference: nil,
                        continuation: nil,
                        patches: voice.patches
                    )
                    wireRequest.binaryVoiceFollows = true
                    binaryVoiceData = wire.encodeBinaryVoiceFloats(voice)
                }
            }
            if request.operation == .speak, onPCMChunk != nil {
                wireRequest.streamPCM = true
            }
            let requestData = try JSONEncoder().encode(wireRequest)
            inputLock.lock()
            do {
                try wire.write(requestData, to: input, limit: wire.controlLimit)
                if let binaryVoiceData {
                    try wire.write(binaryVoiceData, to: input, limit: wire.pcmLimit)
                }
                inputLock.unlock()
            } catch {
                inputLock.unlock()
                throw error
            }

            var streamedSamples: [Float] = []
            let response = try readResponse(
                request: request.operation,
                onProgress: onProgress,
                onPCMChunk: onPCMChunk,
                streamedSamples: &streamedSamples
            )

            state.lock()
            if let sentVoiceID {
                cachedVoiceID = sentVoiceID
            }
            if request.operation == .prepare || request.operation == .speak {
                workerWarm = true
            }
            state.unlock()

            switch response.failure {
            case .busy: throw ClonedVoiceWorkerError.busy
            case .cancelled: throw CancellationError()
            case .context: throw ClonedVoiceWorkerError.context(response.message ?? "")
            case .runtime:
                if let failure = response.failureInfo {
                    probeLog("voice-worker-failure", failure.diagnosticFields.merging(["operation": request.operation.rawValue]) { current, _ in current })
                    throw ClonedVoiceWorkerError.diagnosed(failure, repairedAsset: response.repairedAsset, repairedAssets: response.repairedAssets)
                }
                throw ClonedVoiceWorkerError.runtime(response.message ?? "", repairAsset: response.repairAsset)
            case nil: break
            }
            if response.streamedPCM {
                guard !response.pcm, request.operation == .speak else { throw ClonedVoiceWorkerError.protocolFailure }
                try wire.validatePCM(streamedSamples)
                return .init(samples: streamedSamples, memoryBytes: response.memoryBytes, message: response.message,
                             repairedAsset: response.repairedAsset, repairedAssets: response.repairedAssets)
            }
            guard response.pcm == (request.operation == .speak), streamedSamples.isEmpty else {
                throw ClonedVoiceWorkerError.protocolFailure
            }
            let samples: [Float]?
            if response.pcm {
                guard let data = try wire.read(from: output, limit: wire.pcmLimit), data.count.isMultiple(of: 4) else {
                    throw ClonedVoiceWorkerError.protocolFailure
                }
                samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else {
                samples = nil
            }
            return .init(samples: samples, memoryBytes: response.memoryBytes, message: response.message,
                         repairedAsset: response.repairedAsset, repairedAssets: response.repairedAssets)
        } catch let error as CancellationError {
            throw error
        } catch let error as ClonedVoiceWorkerError {
            throw error
        } catch {
            throw ClonedVoiceWorkerError.protocolFailure
        }
    }

    private func readResponse(request: ClonedVoiceWire.Request.Operation,
                              onProgress: (@Sendable (ClonedVoiceWire.Response.Progress) -> Void)?,
                              onPCMChunk: (@Sendable ([Float]) -> Void)?,
                              streamedSamples: inout [Float]) throws -> ClonedVoiceWire.Response {
        let wire = ClonedVoiceWire.self
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var stageMessages = 0
        while true {
            guard let control = try wire.read(from: output, limit: wire.controlLimit) else {
                throw ClonedVoiceWorkerError.stopped
            }
            let response = try JSONDecoder().decode(wire.Response.self, from: control)
            if response.pcmChunk {
                guard let onPCMChunk,
                      let data = try wire.read(from: output, limit: wire.pcmLimit),
                      data.count.isMultiple(of: 4) else {
                    throw ClonedVoiceWorkerError.protocolFailure
                }
                let sampleCount = data.count / MemoryLayout<Float>.size
                guard streamedSamples.count + sampleCount <= wire.pcmLimit / MemoryLayout<Float>.size else {
                    throw ClonedVoiceWorkerError.protocolFailure
                }
                let chunk = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                streamedSamples.append(contentsOf: chunk)
                onPCMChunk(chunk)
                continue
            }
            guard let stage = response.stage ?? response.progress?.stage else { return response }
            stageMessages += 1
            guard stageMessages <= 32 else { throw ClonedVoiceWorkerError.protocolFailure }
            let progress = response.progress ?? .init(stage: stage)
            if progress.stage == .synthesize {
                state.lock()
                canCooperativeCancel = true
                state.unlock()
            }
            var fields: [String: Any] = ["operation": request.rawValue, "stage": progress.stage.rawValue, "pid": pid]
            if let asset = progress.asset, !asset.isEmpty, asset.count <= 64,
               asset.unicodeScalars.allSatisfy(identifierCharacters.contains), !asset.contains("..") {
                fields["asset"] = asset
            }
            if let step = progress.step { fields["step"] = step }
            if let totalSteps = progress.totalSteps { fields["totalSteps"] = totalSteps }
            probeLog("voice-worker-stage", fields)
            onProgress?(progress)
        }
    }

}
