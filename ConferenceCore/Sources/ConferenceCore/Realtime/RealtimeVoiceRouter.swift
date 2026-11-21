import Accelerate
import AVFoundation
import Foundation

/// Audio conversion utilities shared between macOS and iOS Realtime voice sessions.
public enum RealtimeVoiceAudio {
    private static let formatLock = NSLock()
    private static var cachedMonoFloatFormats: [Double: AVAudioFormat] = [:]

    private static func monoFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        formatLock.lock()
        if let hit = cachedMonoFloatFormats[sampleRate] {
            formatLock.unlock()
            return hit
        }
        formatLock.unlock()
        guard let created = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        formatLock.lock()
        cachedMonoFloatFormats[sampleRate] = created
        formatLock.unlock()
        return created
    }

    public static func pcm16ToAudioBuffer(data: Data, sampleRate: Double = 24_000) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let format = monoFloatFormat(sampleRate: sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var scale: Float = 1.0 / 32768.0
            let isAligned = (Int(bitPattern: base) & (MemoryLayout<Int16>.alignment - 1)) == 0
            #if _endian(little)
            if isAligned {
                let int16Ptr = base.assumingMemoryBound(to: Int16.self)
                vDSP_vflt16(int16Ptr, 1, channel, 1, vDSP_Length(frameCount))
                vDSP_vsmul(channel, 1, &scale, channel, 1, vDSP_Length(frameCount))
                return
            }
            #endif
            for i in 0..<frameCount {
                let sample = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                channel[i] = Float(Int16(littleEndian: sample)) * scale
            }
        }
        return buffer
    }

    public static func floatSamplesToPCM16Data(_ samples: [Float]) -> Data {
        let count = samples.count
        guard count > 0 else { return Data() }
        var pcmData = Data(count: count * MemoryLayout<Int16>.size)
        pcmData.withUnsafeMutableBytes { raw in
            guard let outBase = raw.baseAddress else { return }
            let scale = Float(Int16.max)
            let isAligned = (Int(bitPattern: outBase) & (MemoryLayout<Int16>.alignment - 1)) == 0
            #if _endian(little)
            if isAligned {
                let outPtr = outBase.assumingMemoryBound(to: Int16.self)
                for i in 0..<count {
                    let s = samples[i]
                    let clamped = s < -1.0 ? -1.0 : (s > 1.0 ? 1.0 : s)
                    outPtr[i] = Int16((clamped * scale).rounded())
                }
                return
            }
            #endif
            for i in 0..<count {
                let s = samples[i]
                let clamped = s < -1.0 ? -1.0 : (s > 1.0 ? 1.0 : s)
                let le = Int16((clamped * scale).rounded()).littleEndian
                raw.storeBytes(of: le, toByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
            }
        }
        return pcmData
    }

    /// Resamples mono 16-bit little-endian PCM data using linear interpolation.
    public static func resamplePCM16Mono(data: Data, fromRate: Int, toRate: Int) -> Data {
        guard fromRate > 0, toRate > 0, fromRate != toRate else { return data }
        let inCount = data.count / MemoryLayout<Int16>.size
        guard inCount > 0 else { return Data() }
        let outCount = max(1, Int((Double(inCount) * Double(toRate) / Double(fromRate)).rounded()))
        var output = Data(count: outCount * MemoryLayout<Int16>.size)
        let ratio = Double(fromRate) / Double(toRate)
        data.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                for i in 0..<outCount {
                    let srcPos = Double(i) * ratio
                    let idx0 = min(inCount - 1, Int(srcPos))
                    let idx1 = min(inCount - 1, idx0 + 1)
                    let frac = srcPos - Double(idx0)
                    let s0 = Int16(littleEndian: inRaw.loadUnaligned(fromByteOffset: idx0 * 2, as: Int16.self))
                    let s1 = Int16(littleEndian: inRaw.loadUnaligned(fromByteOffset: idx1 * 2, as: Int16.self))
                    let interpolated = Double(s0) + (Double(s1) - Double(s0)) * frac
                    let clamped = max(Double(Int16.min), min(Double(Int16.max), interpolated.rounded()))
                    outRaw.storeBytes(of: Int16(clamped).littleEndian, toByteOffset: i * 2, as: Int16.self)
                }
            }
        }
        return output
    }

    /// Mixes multiple mono 16-bit little-endian PCM tracks via clamped Int32 summation.
    public static func mixPCM16Mono(_ chunks: [Data]) -> Data {
        let nonEmpty = chunks.filter { $0.count >= MemoryLayout<Int16>.size }
        guard !nonEmpty.isEmpty else { return Data() }
        if nonEmpty.count == 1 { return nonEmpty[0] }
        let maxSamples = nonEmpty.map { $0.count / MemoryLayout<Int16>.size }.max() ?? 0
        guard maxSamples > 0 else { return Data() }
        var accum = [Int32](repeating: 0, count: maxSamples)
        for chunk in nonEmpty {
            let count = chunk.count / MemoryLayout<Int16>.size
            chunk.withUnsafeBytes { raw in
                for i in 0..<count {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    accum[i] += Int32(sample)
                }
            }
        }
        var output = Data(count: maxSamples * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { outRaw in
            for i in 0..<maxSamples {
                let sum = accum[i]
                let clamped = Int16(max(Int32(Int16.min), min(Int32(Int16.max), sum)))
                outRaw.storeBytes(of: clamped.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return output
    }

    public static func validateBoardURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        return url
    }
}

/// Coordinates optional WebSocket realtime voice sessions (`OpenAI Realtime` / `Gemini Live`)
/// and reports fallback status whenever standard STT → LLM → TTS should handle turns instead.
public actor RealtimeVoiceRouter {
    public typealias ToolExecutor = @Sendable (_ name: String, _ argumentsJSON: String) async -> String
    public typealias EventSink = @Sendable (RealtimeVoiceEvent) async -> Void

    private var transport: (any RealtimeVoiceTransport)?
    private var listenerTask: Task<Void, Never>?
    private var toolTasks: [UUID: Task<Void, Never>] = [:]
    public private(set) var isRealtimeConnected = false
    public private(set) var lastFailureReason: String?

    public init() {}

    public var shouldFallbackToStandardPipeline: Bool {
        !isRealtimeConnected
    }

    public func start(
        config: RealtimeSessionConfig,
        customTransport: (any RealtimeVoiceTransport)? = nil,
        executeTool: @escaping ToolExecutor,
        onEvent: @escaping EventSink
    ) async {
        await stop()
        guard config.provider != .disabled else {
            lastFailureReason = nil
            isRealtimeConnected = false
            return
        }

        let selected: any RealtimeVoiceTransport
        if let customTransport {
            selected = customTransport
        } else {
            switch config.provider {
            case .disabled:
                return
            case .openAIRealtime:
                selected = OpenAIRealtimeClient()
            case .geminiLive:
                selected = GeminiLiveClient()
            }
        }

        do {
            try await selected.connect(config: config)
            self.transport = selected
            self.isRealtimeConnected = true
            self.lastFailureReason = nil

            listenerTask = Task { [weak self] in
                for await event in selected.events {
                    if Task.isCancelled { break }
                    await self?.handleTransportEvent(event, on: selected, executeTool: executeTool, onEvent: onEvent)
                }
            }
        } catch {
            self.transport = nil
            self.isRealtimeConnected = false
            self.lastFailureReason = error.localizedDescription
            await onEvent(.error(error.localizedDescription))
        }
    }

    public func sendText(_ text: String) async -> Bool {
        guard let transport, isRealtimeConnected else { return false }
        do {
            try await transport.sendTextTurn(text)
            return true
        } catch {
            lastFailureReason = error.localizedDescription
            isRealtimeConnected = false
            return false
        }
    }

    public func sendAudioPCM16(_ data: Data) async -> Bool {
        guard let transport, isRealtimeConnected else { return false }
        do {
            try await transport.sendAudioPCM16(data)
            return true
        } catch {
            lastFailureReason = error.localizedDescription
            isRealtimeConnected = false
            return false
        }
    }

    public func updateInstructions(_ instructions: String) async {
        guard let transport, isRealtimeConnected else { return }
        try? await transport.updateInstructions(instructions)
    }

    public func stop() async {
        listenerTask?.cancel()
        listenerTask = nil
        for task in toolTasks.values {
            task.cancel()
        }
        toolTasks.removeAll()
        if let transport {
            await transport.disconnect()
        }
        transport = nil
        isRealtimeConnected = false
    }

    public func waitForPendingToolCalls(timeoutSeconds: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(max(0.05, timeoutSeconds))
        while !toolTasks.isEmpty, Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let tasks = Array(toolTasks.values)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for task in tasks {
                        await task.value
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(max(10, Int((remaining * 1000).rounded()))))
                }
                _ = await group.next()
                group.cancelAll()
            }
        }
    }

    private func completeToolTask(id: UUID) {
        toolTasks.removeValue(forKey: id)
    }

    private func handleTransportEvent(
        _ event: RealtimeVoiceEvent,
        on transport: any RealtimeVoiceTransport,
        executeTool: @escaping ToolExecutor,
        onEvent: @escaping EventSink
    ) async {
        switch event {
        case .toolCall(let callID, let name, let argsJSON):
            await onEvent(event)
            let taskID = UUID()
            toolTasks[taskID] = Task { [weak self] in
                let result = await executeTool(name, argsJSON)
                if !Task.isCancelled {
                    try? await transport.sendToolResult(callID: callID, name: name, jsonOutput: result)
                }
                await self?.completeToolTask(id: taskID)
            }
        case .disconnected(let reason):
            isRealtimeConnected = false
            if let reason, !reason.isEmpty { lastFailureReason = reason }
            await onEvent(event)
        case .error(let msg):
            lastFailureReason = msg
            await onEvent(event)
        default:
            await onEvent(event)
        }
    }
}

/// Coalesces per-track 10ms PCM16 frames off `@MainActor`, mixes concurrent tracks cleanly,
/// optionally resamples (e.g., 16 kHz -> 24 kHz for OpenAI Realtime), and delivers ~80ms batches in FIFO order.
public final class RealtimeAudioCoalescer: @unchecked Sendable {
    private let inputSampleRate: Int
    private let targetSampleRate: Int
    private let windowDurationMs: Int
    private let windowByteThreshold: Int
    private let lock = NSLock()
    private let flushQueue = DispatchQueue(label: "dev.vsmirn0v.realtime-audio-coalescer", qos: .userInitiated)
    private var buffersByTrack: [String: Data] = [:]
    private var pendingFlushWorkItem: DispatchWorkItem?
    private var finished = false
    private let continuation: AsyncStream<Data>.Continuation
    public let stream: AsyncStream<Data>

    public init(inputSampleRate: Int = 16_000, targetSampleRate: Int = 16_000, windowMs: Int = 80) {
        self.inputSampleRate = max(8_000, inputSampleRate)
        self.targetSampleRate = max(8_000, targetSampleRate)
        self.windowDurationMs = max(20, windowMs)
        let samplesPerWindow = max(160, (self.inputSampleRate * self.windowDurationMs) / 1000)
        self.windowByteThreshold = samplesPerWindow * MemoryLayout<Int16>.size

        var cont: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(12)) { cont = $0 }
        self.continuation = cont
    }

    deinit {
        finish()
    }

    public func append(trackID: String, pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        var readyChunks: [Data]?
        var scheduledWorkItem: DispatchWorkItem?
        lock.lock()
        if !finished {
            var current = buffersByTrack[trackID] ?? Data()
            current.append(pcm16)
            buffersByTrack[trackID] = current
            if current.count >= windowByteThreshold {
                pendingFlushWorkItem?.cancel()
                pendingFlushWorkItem = nil
                readyChunks = Array(buffersByTrack.values)
                buffersByTrack.removeAll(keepingCapacity: true)
            } else if pendingFlushWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.flush()
                }
                pendingFlushWorkItem = work
                scheduledWorkItem = work
            }
        }
        lock.unlock()

        if let scheduledWorkItem {
            flushQueue.asyncAfter(deadline: .now() + .milliseconds(windowDurationMs), execute: scheduledWorkItem)
        }
        if let readyChunks {
            emitMixed(readyChunks)
        }
    }

    public func flush() {
        lock.lock()
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil
        let remaining = finished ? [] : Array(buffersByTrack.values)
        buffersByTrack.removeAll(keepingCapacity: true)
        lock.unlock()
        if !remaining.isEmpty {
            emitMixed(remaining)
        }
    }

    public func finish() {
        lock.lock()
        let wasFinished = finished
        finished = true
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil
        let remaining = wasFinished ? [] : Array(buffersByTrack.values)
        buffersByTrack.removeAll()
        lock.unlock()
        if !wasFinished {
            if !remaining.isEmpty {
                emitMixed(remaining)
            }
            continuation.finish()
        }
    }

    private func emitMixed(_ chunks: [Data]) {
        let mixed = RealtimeVoiceAudio.mixPCM16Mono(chunks)
        guard !mixed.isEmpty else { return }
        let out = RealtimeVoiceAudio.resamplePCM16Mono(
            data: mixed,
            fromRate: inputSampleRate,
            toRate: targetSampleRate
        )
        if !out.isEmpty {
            continuation.yield(out)
        }
    }
}
