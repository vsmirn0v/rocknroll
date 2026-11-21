import Foundation

/// OpenAI Realtime API WebSocket transport (`wss://api.openai.com/v1/realtime?model=...`).
public actor OpenAIRealtimeClient: RealtimeVoiceTransport {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
    public nonisolated let events: AsyncStream<RealtimeVoiceEvent>

    public init() {
        var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func connect(config: RealtimeSessionConfig) async throws {
        guard config.provider == .openAIRealtime else { throw RealtimeTransportError.disabled }
        guard !config.apiKey.isEmpty else { throw RealtimeTransportError.missingAPIKey }
        guard let url = Self.makeEndpointURL(base: config.endpointOverride.isEmpty ? RealtimeProviderKind.openAIRealtime.defaultEndpoint : config.endpointOverride, model: config.model) else {
            throw RealtimeTransportError.invalidEndpoint
        }

        let urlSession = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let ws = urlSession.webSocketTask(with: request)
        ws.resume()
        self.session = urlSession
        self.task = ws

        let update = Self.sessionUpdatePayload(config: config)
        try await sendJSON(update, on: ws)
        continuation.yield(.connected)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(ws: ws)
        }
    }

    public func sendAudioPCM16(_ data: Data) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON(Self.inputAudioAppendPayload(pcm16Data: data), on: ws)
    }

    public func sendTextTurn(_ text: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON(Self.textTurnPayload(text), on: ws)
        try await sendJSON(Self.responseCreatePayload(), on: ws)
    }

    public func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON(Self.functionCallOutputPayload(callID: callID, outputJSON: jsonOutput), on: ws)
        try await sendJSON(Self.responseCreatePayload(), on: ws)
    }

    public func updateInstructions(_ instructions: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        let payload: [String: Any] = [
            "type": "session.update",
            "session": ["instructions": instructions],
        ]
        try await sendJSON(payload, on: ws)
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.yield(.disconnected(nil))
    }

    private func receiveLoop(ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let raw): data = raw
                @unknown default: data = nil
                }
                guard let data, let parsed = Self.parseServerEvent(data) else { continue }
                for event in parsed {
                    continuation.yield(event)
                }
            } catch {
                if !Task.isCancelled {
                    continuation.yield(.disconnected(error.localizedDescription))
                }
                return
            }
        }
    }

    private func sendJSON(_ object: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(decoding: data, as: UTF8.self)
        try await ws.send(.string(text))
    }

    // MARK: - Pure Wire Payload Builders & Parsers

    public static func makeEndpointURL(base: String, model: String) -> URL? {
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "model" }) && !model.isEmpty {
            items.append(URLQueryItem(name: "model", value: model))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    public static func sessionUpdatePayload(config: RealtimeSessionConfig) -> [String: Any] {
        let toolDefs: [[String: Any]] = config.tools.map { tool in
            [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parametersDictionary(),
            ]
        }
        var sessionObject: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": config.systemInstructions,
            "voice": config.voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "input_audio_transcription": ["model": "whisper-1"],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 600,
            ],
        ]
        if !toolDefs.isEmpty {
            sessionObject["tools"] = toolDefs
        }
        return [
            "type": "session.update",
            "session": sessionObject,
        ]
    }

    public static func inputAudioAppendPayload(pcm16Data: Data) -> [String: Any] {
        [
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString(),
        ]
    }

    public static func textTurnPayload(_ text: String) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": text],
                ],
            ],
        ]
    }

    public static func responseCreatePayload() -> [String: Any] {
        ["type": "response.create"]
    }

    public static func functionCallOutputPayload(callID: String, outputJSON: String) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": outputJSON,
            ],
        ]
    }

    public static func parseServerEvent(_ data: Data) -> [RealtimeVoiceEvent]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        switch type {
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                return [.userTranscript(transcript)]
            }
        case "response.audio.delta", "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                return [.audioPCM16(pcm, sampleRate: 24_000)]
            }
        case "response.audio.done", "response.output_audio.done":
            return [.audioDone]
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                return [.assistantTranscriptDelta(delta)]
            }
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                return [.assistantTranscriptDone(transcript)]
            }
        case "response.function_call_arguments.done":
            if let callID = json["call_id"] as? String,
               let name = json["name"] as? String {
                let args = (json["arguments"] as? String) ?? "{}"
                return [.toolCall(callID: callID, name: name, argumentsJSON: args)]
            }
        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "Realtime server error"
            return [.error(message)]
        default:
            break
        }
        return nil
    }
}
