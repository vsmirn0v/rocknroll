import AVFoundation
import Foundation

/// Audio conversion utilities shared between macOS and iOS Realtime voice sessions.
public enum RealtimeVoiceAudio {
    public static func pcm16ToAudioBuffer(data: Data, sampleRate: Double = 24_000) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frameCount {
                channel[i] = Float(Int16(littleEndian: samples[i])) * scale
            }
        }
        return buffer
    }

    public static func floatSamplesToPCM16Data(_ samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }
        var pcmData = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0 as Float, min(1.0 as Float, sample))
            var intSample = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &intSample) { pcmData.append(contentsOf: $0) }
        }
        return pcmData
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
        if let transport {
            await transport.disconnect()
        }
        transport = nil
        isRealtimeConnected = false
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
            let result = await executeTool(name, argsJSON)
            try? await transport.sendToolResult(callID: callID, name: name, jsonOutput: result)
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
