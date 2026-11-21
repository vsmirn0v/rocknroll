import Foundation

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
