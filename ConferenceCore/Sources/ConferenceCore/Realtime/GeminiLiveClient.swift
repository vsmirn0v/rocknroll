import Foundation

/// Gemini Live API bidirectional WebSocket transport (`BidiGenerateContent`).
public actor GeminiLiveClient: RealtimeVoiceTransport {
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
        guard config.provider == .geminiLive else { throw RealtimeTransportError.disabled }
        guard !config.apiKey.isEmpty else { throw RealtimeTransportError.missingAPIKey }
        let base = config.endpointOverride.isEmpty ? RealtimeProviderKind.geminiLive.defaultEndpoint : config.endpointOverride
        guard let url = Self.makeEndpointURL(base: base, apiKey: config.apiKey) else {
            throw RealtimeTransportError.invalidEndpoint
        }

        let urlSession = URLSession(configuration: .ephemeral)
        let ws = urlSession.webSocketTask(with: url)
        ws.resume()
        self.session = urlSession
        self.task = ws

        try await sendJSON(Self.setupPayload(config: config), on: ws)
        continuation.yield(.connected)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(ws: ws)
        }
    }

    public func sendAudioPCM16(_ data: Data) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON(Self.realtimeAudioPayload(pcm16Data: data), on: ws)
    }

    public func sendTextTurn(_ text: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON(Self.clientTextPayload(text), on: ws)
    }

    public func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON(Self.toolResponsePayload(callID: callID, name: name, outputJSON: jsonOutput), on: ws)
    }

    public func updateInstructions(_ instructions: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        try await sendJSON([
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": "[System context update]\n\(instructions)"]]]
                ],
                "turnComplete": false,
            ]
        ], on: ws)
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
                guard let data, let parsed = Self.parseServerMessage(data) else { continue }
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

    public static func makeEndpointURL(base: String, apiKey: String) -> URL? {
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "key" }) && !apiKey.isEmpty {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    public static func setupPayload(config: RealtimeSessionConfig) -> [String: Any] {
        let modelPath = config.model.hasPrefix("models/") ? config.model : "models/\(config.model)"
        var setup: [String: Any] = [
            "model": modelPath,
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": config.voice]
                    ]
                ],
            ],
            "systemInstruction": [
                "parts": [["text": config.systemInstructions]]
            ],
        ]
        if !config.tools.isEmpty {
            let declarations: [[String: Any]] = config.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersDictionary(),
                ]
            }
            setup["tools"] = [["functionDeclarations": declarations]]
        }
        return ["setup": setup]
    }

    public static func realtimeAudioPayload(pcm16Data: Data, sampleRate: Int = 16_000) -> [String: Any] {
        [
            "realtimeInput": [
                "mediaChunks": [[
                    "mimeType": "audio/pcm;rate=\(sampleRate)",
                    "data": pcm16Data.base64EncodedString(),
                ]]
            ]
        ]
    }

    public static func clientTextPayload(_ text: String) -> [String: Any] {
        [
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [["text": text]],
                ]],
                "turnComplete": true,
            ]
        ]
    }

    public static func toolResponsePayload(callID: String, name: String, outputJSON: String) -> [String: Any] {
        let responseObject: Any
        if let data = outputJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            responseObject = parsed
        } else {
            responseObject = ["result": outputJSON]
        }
        return [
            "toolResponse": [
                "functionResponses": [[
                    "id": callID,
                    "name": name,
                    "response": responseObject,
                ]]
            ]
        ]
    }

    public static func parseServerMessage(_ data: Data) -> [RealtimeVoiceEvent]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var events: [RealtimeVoiceEvent] = []

        if let toolCall = json["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls {
                if let id = call["id"] as? String,
                   let name = call["name"] as? String {
                    let argsObj = call["args"] ?? [:]
                    let argsJSON = (try? JSONSerialization.data(withJSONObject: argsObj, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    events.append(.toolCall(callID: id, name: name, argumentsJSON: argsJSON))
                }
            }
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            if let inputTx = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String, !inputTx.isEmpty {
                events.append(.userTranscript(inputTx))
            }
            if let outputTx = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String, !outputTx.isEmpty {
                events.append(.assistantTranscriptDelta(outputTx))
            }
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let b64 = inline["data"] as? String,
                       let pcm = Data(base64Encoded: b64) {
                        events.append(.audioPCM16(pcm, sampleRate: 24_000))
                    } else if let text = part["text"] as? String, !text.isEmpty {
                        events.append(.assistantTranscriptDelta(text))
                    }
                }
            }
            if serverContent["turnComplete"] as? Bool == true {
                events.append(.audioDone)
            }
        }

        if let error = json["error"] as? [String: Any],
           let msg = error["message"] as? String {
            events.append(.error(msg))
        }

        return events.isEmpty ? nil : events
    }
}
