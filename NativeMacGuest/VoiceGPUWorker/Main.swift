import ConferenceCore
import Darwin
import Foundation
import MLXAudioCore
import MLXAudioTTS

@main
struct ClonedVoiceGPUWorkerMain {
    static func main() async {
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
        let output = GPUPipeWriter(handle: FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true))
        let input = FileHandle.standardInput
        let worker = GPUVoiceWorkerRuntime()
        let dispatchState = GPUWorkerDispatchState()

        let (requests, requestContinuation) = AsyncStream<(ClonedVoiceWire.Request, Data?)>.makeStream()
        DispatchQueue(label: "gpu-voice-worker.stdin", qos: .userInitiated).async {
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
                probeLog("gpu-voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            }
            requestContinuation.finish()
        }

        do {
            for await (request, binaryVoiceData) in requests {
                let task = Task.detached(priority: request.operation == .prepare ? .utility : .userInitiated) {
                    await worker.perform(request, binaryVoiceData: binaryVoiceData, progress: { stage in
                        if stage == .synthesize {
                            dispatchState.markSynthesizing()
                        }
                        if let data = try? JSONEncoder().encode(ClonedVoiceWire.Response(stage: stage)) {
                            try? output.write(data, limit: ClonedVoiceWire.controlLimit)
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
                    try output.write(samples.withUnsafeBytes { Data($0) }, limit: ClonedVoiceWire.pcmLimit)
                }
            }
        } catch {
            probeLog("gpu-voice-worker-ipc-failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
        }
    }
}

private final class GPUWorkerDispatchState: @unchecked Sendable {
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

private final class GPUPipeWriter: @unchecked Sendable {
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

private final class GPUVoiceWorkerRuntime: @unchecked Sendable {
    private let baseline = ProcessMemoryProbe.footprint()
    private var folder: URL?
    private var lease: ClonedVoiceLease?
    private var model: VoxCPM2Model?
    private var tokenizer: VoxTokenizer?
    private var voiceCache: [String: VoxVoice] = [:]
    private var voiceCacheOrder: [String] = []
    private static let maximumCachedVoices = 4

    func perform(_ request: ClonedVoiceWire.Request,
                 binaryVoiceData: Data? = nil,
                 progress: @escaping @Sendable (ClonedVoiceWire.Response.Stage) -> Void,
                 onPCMChunk: (@Sendable ([Float]) -> Void)? = nil) async -> (ClonedVoiceWire.Response, [Float]?) {
        do {
            if request.operation == .ping { return (.init(), nil) }
            if request.operation == .cacheScope { return (.init(message: "gpu-worker"), nil) }
            guard let folder = request.folder, folder.isFileURL else { throw ClonedVoiceWorkerError.protocolFailure }
            let result = try await generate(request, binaryVoiceData: binaryVoiceData, folder: folder, progress: progress, onPCMChunk: onPCMChunk)
            let memory: UInt64? = {
                guard let baseline, let footprint = ProcessMemoryProbe.footprint(), footprint > baseline else { return nil }
                return footprint - baseline
            }()
            return (.init(pcm: result.trailingPCM != nil, streamedPCM: result.streamedPCM, memoryBytes: memory), result.trailingPCM)
        } catch is CancellationError {
            return (.init(failure: .cancelled, message: "cancelled"), nil)
        } catch ClonedVoiceWorkerError.busy {
            return (.init(failure: .busy), nil)
        } catch VoxError.context(let message) {
            return (.init(failure: .context, message: message), nil)
        } catch {
            let detail = error as NSError
            probeLog("gpu-voice-worker-failed", ["domain": detail.domain, "code": detail.code])
            return (.init(failure: .runtime, message: "The GPU voice model could not run (\(detail.domain) \(detail.code))."), nil)
        }
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

    private func generate(_ request: ClonedVoiceWire.Request, binaryVoiceData: Data?, folder: URL,
                          progress: @escaping @Sendable (ClonedVoiceWire.Response.Stage) -> Void,
                          onPCMChunk: (@Sendable ([Float]) -> Void)?) async throws -> (trailingPCM: [Float]?, streamedPCM: Bool) {
        let folder = folder.standardizedFileURL
        guard self.folder == nil || self.folder == folder else { throw ClonedVoiceWorkerError.protocolFailure }
        if lease == nil { lease = try ClonedVoiceLease(folder: folder, purpose: "worker") }
        self.folder = folder
        let resolvedVoice = request.operation == .speak ? try resolveVoice(for: request, binaryVoiceData: binaryVoiceData) : nil
        let loaded: VoxCPM2Model
        if let model { loaded = model }
        else {
            progress(.load)
            loaded = try await VoxCPM2Model.fromModelDirectory(folder, hfToken: nil)
            guard loaded.sampleRate == 48_000 else { throw VoxError.audio("unexpected sample rate") }
            tokenizer = try VoxTokenizer(url: folder.appendingPathComponent("tokenizer.json"))
            model = loaded
        }
        let text: String
        let voice: VoxVoice
        switch request.operation {
        case .prepare:
            progress(.validate)
            text = "The voice is ready."
            voice = VoxVoice(mode: .clone, transcript: "", reference: (0..<256).map { 0.25 * sin(Float($0) * 0.1) }, continuation: nil, patches: 1)
        case .speak:
            try Task.checkCancellation()
            progress(.synthesize)
            guard let inputText = request.text else { throw ClonedVoiceWorkerError.protocolFailure }
            guard let inputVoice = resolvedVoice else {
                guard let tokenizer else { throw ClonedVoiceWorkerError.protocolFailure }
                let clean = inputText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let ids = tokenizer.encode(clean)
                let streamCallback: (@Sendable ([Float]) -> Void)? = (request.streamPCM && onPCMChunk != nil) ? onPCMChunk : nil
                let samples = try await loaded.synthesizeZeroShotSamples(text: clean, tokenIDs: ids, maxTokens: 256, onAudioChunk: streamCallback)
                guard samples.count <= ClonedVoiceWire.pcmLimit / MemoryLayout<Float>.size else {
                    throw ClonedVoiceWorkerError.protocolFailure
                }
                try ClonedVoiceWire.validatePCM(samples)
                return streamCallback != nil ? (nil, true) : (samples, false)
            }
            text = inputText
            voice = inputVoice
        case .ping, .cacheScope, .verify, .cancel: return (nil, false)
        }
        guard voice.revision == VoxVoice.revision,
              (voice.mode == .clone && voice.reference != nil && voice.continuation == nil) ||
              (voice.mode == .continuation && voice.reference == nil && voice.continuation != nil) ||
              (voice.mode == .cloneContinuation && voice.reference != nil && voice.continuation != nil)
        else { throw VoxError.context("This saved voice is not compatible with the GPU voice model.") }
        guard let tokenizer else { throw ClonedVoiceWorkerError.protocolFailure }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let tokenIDs = tokenizer.encode((voice.continuation != nil ? voice.transcript : "") + clean)
        if request.operation == .speak && request.streamPCM, let onPCMChunk {
            let samples = try await loaded.synthesizeSavedVoiceSamples(
                text: clean, transcript: voice.transcript, patches: voice.patches,
                reference: voice.reference, continuation: voice.continuation, tokenIDs: tokenIDs,
                maxTokens: 256, onAudioChunk: onPCMChunk)
            guard samples.count <= ClonedVoiceWire.pcmLimit / MemoryLayout<Float>.size else { throw ClonedVoiceWorkerError.protocolFailure }
            try ClonedVoiceWire.validatePCM(samples)
            return (nil, true)
        }
        let output = try await loaded.generateSavedVoice(text: text, transcript: voice.transcript, patches: voice.patches,
            reference: voice.reference, continuation: voice.continuation, tokenIDs: tokenIDs,
            generationParameters: GenerateParameters(maxTokens: request.operation == .prepare ? 64 : 256))
        let samples = output.asArray(Float.self)
        guard samples.count <= ClonedVoiceWire.pcmLimit / MemoryLayout<Float>.size else { throw ClonedVoiceWorkerError.protocolFailure }
        try ClonedVoiceWire.validatePCM(samples)
        return request.operation == .speak ? (samples, false) : (nil, false)
    }
}
