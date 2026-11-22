import AVFoundation
import Foundation

/// Yandex Cloud AI Studio OpenAI-compatible Realtime WebSocket transport
/// (`wss://ai.api.cloud.yandex.net/v1/realtime/openai?model=gpt://<folder_id>/<model>/latest`).
public actor YandexRealtimeClient: RealtimeVoiceTransport {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var isTTSOnly = false
    private var outputSampleRate: Int = 44_100
    private var emittedAudioDoneForCurrentTurn = false
    private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
    public nonisolated let events: AsyncStream<RealtimeVoiceEvent>

    public init() {
        var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func connect(config: RealtimeSessionConfig) async throws {
        guard config.provider == .yandexRealtime else { throw RealtimeTransportError.disabled }
        guard !config.apiKey.isEmpty else { throw RealtimeTransportError.missingAPIKey }

        let base = config.endpointOverride.isEmpty
            ? RealtimeProviderKind.yandexRealtime.defaultEndpoint
            : config.endpointOverride
        guard let baseComponents = URLComponents(string: base),
              let scheme = baseComponents.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = baseComponents.host?.lowercased(), !host.isEmpty,
              baseComponents.user == nil, baseComponents.password == nil, baseComponents.fragment == nil else {
            throw RealtimeTransportError.invalidEndpoint
        }

        let existingModel = baseComponents.queryItems?
            .first(where: { $0.name == "model" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedModelURI: String
        let resolvedFolderID: String?
        if let existingModel, !existingModel.isEmpty {
            resolvedModelURI = existingModel
            if let parsed = Self.resolveModelURI(model: existingModel, folderID: config.folderID) {
                resolvedFolderID = parsed.folderID
            } else {
                let trimmedFolder = config.folderID.trimmingCharacters(in: .whitespacesAndNewlines)
                resolvedFolderID = trimmedFolder.isEmpty ? nil : trimmedFolder
            }
        } else {
            guard let resolved = Self.resolveModelURI(model: config.model, folderID: config.folderID) else {
                throw RealtimeTransportError.missingFolderID
            }
            resolvedModelURI = resolved.uri
            resolvedFolderID = resolved.folderID
        }

        guard let url = Self.makeEndpointURL(base: base, modelURI: resolvedModelURI) else {
            throw RealtimeTransportError.invalidEndpoint
        }

        self.isTTSOnly = Self.isTTSOnlyModel(resolvedModelURI)
        self.outputSampleRate = max(8_000, config.outputSampleRate)
        self.emittedAudioDoneForCurrentTurn = false

        let urlSession = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url)
        request.setValue(Self.authorizationHeaderValue(for: config.apiKey), forHTTPHeaderField: "Authorization")
        if let resolvedFolderID, !resolvedFolderID.isEmpty {
            request.setValue(resolvedFolderID, forHTTPHeaderField: "x-folder-id")
            request.setValue(resolvedFolderID, forHTTPHeaderField: "OpenAI-Project")
        }

        let ws = urlSession.webSocketTask(with: request)
        ws.resume()
        self.session = urlSession
        self.task = ws

        let update = Self.sessionUpdatePayload(config: config, isTTSOnly: isTTSOnly)
        do {
            try await sendJSON(update, on: ws)
        } catch {
            ws.cancel(with: .goingAway, reason: nil)
            urlSession.invalidateAndCancel()
            self.task = nil
            self.session = nil
            throw error
        }
        continuation.yield(.connected)

        let rate = outputSampleRate
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(ws: ws, outputSampleRate: rate)
        }
    }

    public func sendAudioPCM16(_ data: Data) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        guard !isTTSOnly else { return }
        let b64 = data.base64EncodedString()
        var text = "{\"type\":\"input_audio_buffer.append\",\"audio\":\""
        text.reserveCapacity(text.count + b64.count + 2)
        text += b64
        text += "\"}"
        try await ws.send(.string(text))
    }

    public func sendTextTurn(_ text: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        emittedAudioDoneForCurrentTurn = false
        try await sendJSON(Self.textTurnPayload(text), on: ws)
        try await sendJSON(Self.responseCreatePayload(), on: ws)
    }

    public func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        emittedAudioDoneForCurrentTurn = false
        try await sendJSON(Self.functionCallOutputPayload(callID: callID, outputJSON: jsonOutput), on: ws)
        try await sendJSON(Self.responseCreatePayload(), on: ws)
    }

    public func updateInstructions(_ instructions: String) async throws {
        guard let ws = task else { throw RealtimeTransportError.notConnected }
        guard !isTTSOnly else { return }
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
            ],
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

    private func receiveLoop(ws: URLSessionWebSocketTask, outputSampleRate: Int) async {
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                let data: Data?
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: data = nil
                }
                guard let data,
                      let parsed = Self.parseServerEvent(data, outputSampleRate: outputSampleRate) else {
                    continue
                }
                if parsed.isResponseCreated {
                    emittedAudioDoneForCurrentTurn = false
                }
                for event in parsed.events {
                    if case .audioDone = event {
                        if emittedAudioDoneForCurrentTurn {
                            continue
                        }
                        emittedAudioDoneForCurrentTurn = true
                    }
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

    public static func resolveModelURI(model: String, folderID: String) -> (uri: String, folderID: String?)? {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFolder = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty ? RealtimeProviderKind.yandexRealtime.defaultModel : cleanModel

        if effectiveModel.hasPrefix("gpt://") {
            let suffix = String(effectiveModel.dropFirst("gpt://".count))
            let parts = suffix.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return nil
            }
            let uriFolder = parts[0]
            if parts.count == 2 {
                return ("gpt://\(uriFolder)/\(parts[1])/latest", uriFolder)
            }
            return ("gpt://\(parts.joined(separator: "/"))", uriFolder)
        }

        guard !cleanFolder.isEmpty else { return nil }
        if effectiveModel.contains("/") {
            return ("gpt://\(cleanFolder)/\(effectiveModel)", cleanFolder)
        }
        return ("gpt://\(cleanFolder)/\(effectiveModel)/latest", cleanFolder)
    }

    public static func isTTSOnlyModel(_ modelOrURI: String) -> Bool {
        let lower = modelOrURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("tts-live") && !lower.contains("max-tts-live")
    }

    public static func splitVoiceAndRole(voice: String, explicitRole: String) -> (voice: String, role: String) {
        let cleanVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRole = explicitRole.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanRole.isEmpty, let colon = cleanVoice.firstIndex(of: ":") {
            let name = String(cleanVoice[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedRole = String(cleanVoice[cleanVoice.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? RealtimeProviderKind.yandexRealtime.defaultVoice : name, parsedRole)
        }
        return (cleanVoice.isEmpty ? RealtimeProviderKind.yandexRealtime.defaultVoice : cleanVoice, cleanRole)
    }

    public static func authorizationHeaderValue(for rawKey: String) -> String {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("api-key ") || lower.hasPrefix("bearer ") {
            return trimmed
        }
        if trimmed.hasPrefix("t1.") {
            return "Bearer \(trimmed)"
        }
        return "Api-Key \(trimmed)"
    }

    public static func makeEndpointURL(base: String, modelURI: String) -> URL? {
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            return nil
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "model" }) && !modelURI.isEmpty {
            items.append(URLQueryItem(name: "model", value: modelURI))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    public static func sessionUpdatePayload(config: RealtimeSessionConfig, isTTSOnly: Bool) -> [String: Any] {
        let (resolvedVoice, resolvedRole) = splitVoiceAndRole(voice: config.voice, explicitRole: config.voiceRole)
        let outRate = max(8_000, config.outputSampleRate)

        var outputAudio: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": outRate,
            ],
            "voice": resolvedVoice,
        ]
        if !resolvedRole.isEmpty {
            outputAudio["role"] = resolvedRole
        }

        if isTTSOnly {
            return [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "output_modalities": ["audio"],
                    "audio": [
                        "output": outputAudio,
                    ],
                ],
            ]
        }

        let inRate = max(8_000, config.inputSampleRate)
        let audioConfig: [String: Any] = [
            "input": [
                "format": [
                    "type": "audio/pcm",
                    "rate": inRate,
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 600,
                    "create_response": true,
                    "interrupt_response": true,
                ],
            ],
            "output": outputAudio,
        ]

        var sessionObject: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": audioConfig,
        ]

        let cleanInstructions = config.systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanInstructions.isEmpty {
            sessionObject["instructions"] = config.systemInstructions
        }

        if !config.tools.isEmpty {
            let toolDefs: [[String: Any]] = config.tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersDictionary(),
                ]
            }
            sessionObject["tools"] = toolDefs
            sessionObject["tool_choice"] = "auto"
        }

        return [
            "type": "session.update",
            "session": sessionObject,
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

    public static func parseServerEvent(
        _ data: Data,
        outputSampleRate: Int = 44_100
    ) -> (events: [RealtimeVoiceEvent], isResponseCreated: Bool, isTerminalResponseDone: Bool)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "response.created":
            return ([], true, false)
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                return ([.userTranscript(transcript)], false, false)
            }
        case "response.audio.delta", "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                return ([.audioPCM16(pcm, sampleRate: outputSampleRate)], false, false)
            }
        case "response.audio.done", "response.output_audio.done":
            return ([.audioDone], false, false)
        case "response.done":
            if let response = json["response"] as? [String: Any],
               let status = response["status"] as? String,
               status == "failed" {
                let details = response["status_details"] as? [String: Any]
                let err = details?["error"] as? [String: Any]
                let msg = (err?["message"] as? String)
                    ?? (details?["reason"] as? String)
                    ?? "Yandex Realtime response failed"
                return ([.error(msg)], false, true)
            }
            return ([.audioDone], false, true)
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta",
             "response.output_text.delta", "response.text.delta":
            if let delta = json["delta"] as? String {
                return ([.assistantTranscriptDelta(delta)], false, false)
            }
        case "response.audio_transcript.done", "response.output_audio_transcript.done",
             "response.output_text.done", "response.text.done":
            if let transcript = json["transcript"] as? String ?? json["text"] as? String {
                return ([.assistantTranscriptDone(transcript)], false, false)
            }
        case "response.function_call_arguments.done":
            if let callID = json["call_id"] as? String,
               let name = json["name"] as? String {
                let args = (json["arguments"] as? String) ?? "{}"
                return ([.toolCall(callID: callID, name: name, argumentsJSON: args)], false, false)
            }
        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "Realtime server error"
            return ([.error(message)], false, false)
        default:
            break
        }
        return nil
    }
}

public enum YandexRealtimeTTSError: LocalizedError, Equatable, Sendable {
    case emptyText
    case missingAPIKey
    case missingFolderID
    case invalidEndpoint
    case serverError(String)
    case emptyAudio
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .emptyText: return L("Enter text to speak first.")
        case .missingAPIKey: return L("Save your Yandex API key in Voice settings first.")
        case .missingFolderID: return L("Enter your Yandex Cloud Folder ID or a full gpt:// model URI first.")
        case .invalidEndpoint: return L("Realtime endpoint URL is invalid.")
        case .serverError(let detail): return detail
        case .emptyAudio: return L("Yandex LiveTTS returned no audio.")
        case .timedOut: return L("Yandex LiveTTS timed out.")
        }
    }
}

/// One-shot TTS synthesis over Yandex Realtime WebSocket (`speech-realtime-tts-live`).
public enum YandexRealtimeTTS {
    public static func synthesize(
        text: String,
        apiKey: String,
        folderID: String,
        model: String = YandexRealtimePreferences.defaultTTSModel,
        voice: String = RealtimeProviderKind.yandexRealtime.defaultVoice,
        role: String = "",
        endpointOverride: String = "",
        outputSampleRate: Int = 44_100,
        customTransport: (any RealtimeVoiceTransport)? = nil,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> AVAudioPCMBuffer {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { throw YandexRealtimeTTSError.emptyText }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw YandexRealtimeTTSError.missingAPIKey }

        let cleanFolder = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty ? YandexRealtimePreferences.defaultTTSModel : cleanModel
        let cleanEndpoint = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        let base = cleanEndpoint.isEmpty
            ? RealtimeProviderKind.yandexRealtime.defaultEndpoint
            : cleanEndpoint
        guard let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw YandexRealtimeTTSError.invalidEndpoint
        }
        let hasModelQuery = components.queryItems?.contains(where: {
            $0.name == "model" && !($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) ?? false
        if !hasModelQuery, YandexRealtimeClient.resolveModelURI(model: effectiveModel, folderID: cleanFolder) == nil {
            throw YandexRealtimeTTSError.missingFolderID
        }

        let targetRate = max(8_000, outputSampleRate)
        let config = RealtimeSessionConfig(
            provider: .yandexRealtime,
            apiKey: cleanKey,
            model: effectiveModel,
            voice: voice,
            endpointOverride: cleanEndpoint,
            outputSampleRate: targetRate,
            folderID: cleanFolder,
            voiceRole: role
        )

        let transport = customTransport ?? YandexRealtimeClient()
        do {
            try await transport.connect(config: config)
        } catch let err as RealtimeTransportError {
            switch err {
            case .missingAPIKey: throw YandexRealtimeTTSError.missingAPIKey
            case .missingFolderID: throw YandexRealtimeTTSError.missingFolderID
            case .invalidEndpoint: throw YandexRealtimeTTSError.invalidEndpoint
            case .disabled, .notConnected: throw YandexRealtimeTTSError.serverError(err.localizedDescription)
            }
        }

        let outcome: Result<AVAudioPCMBuffer, Error>
        do {
            let buffer = try await collectAudio(
                from: transport,
                text: cleanText,
                defaultSampleRate: targetRate,
                timeoutSeconds: timeoutSeconds
            )
            outcome = .success(buffer)
        } catch {
            outcome = .failure(error)
        }
        await transport.disconnect()
        return try outcome.get()
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var isTimedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }

    private static func collectAudio(
        from transport: any RealtimeVoiceTransport,
        text: String,
        defaultSampleRate: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> AVAudioPCMBuffer {
        let timeoutMs = max(100, Int((max(0.1, timeoutSeconds) * 1000).rounded()))
        let timeoutFlag = TimeoutFlag()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: AVAudioPCMBuffer.self) { group in
                group.addTask {
                    try await transport.sendTextTurn(text)
                    var chunks: [Data] = []
                    var resolvedSampleRate = defaultSampleRate

                    for await event in transport.events {
                        if timeoutFlag.isTimedOut {
                            throw YandexRealtimeTTSError.timedOut
                        }
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        switch event {
                        case .connected:
                            continue
                        case .audioPCM16(let pcm, let rate):
                            if rate > 0 { resolvedSampleRate = rate }
                            if !pcm.isEmpty { chunks.append(pcm) }
                        case .audioDone:
                            return try buildBuffer(chunks: chunks, sampleRate: resolvedSampleRate)
                        case .error(let msg):
                            throw YandexRealtimeTTSError.serverError(msg)
                        case .disconnected(let reason):
                            if timeoutFlag.isTimedOut {
                                throw YandexRealtimeTTSError.timedOut
                            }
                            if let reason, !reason.isEmpty {
                                throw YandexRealtimeTTSError.serverError(reason)
                            }
                            if !chunks.isEmpty {
                                return try buildBuffer(chunks: chunks, sampleRate: resolvedSampleRate)
                            }
                            throw YandexRealtimeTTSError.emptyAudio
                        default:
                            continue
                        }
                    }
                    if timeoutFlag.isTimedOut {
                        throw YandexRealtimeTTSError.timedOut
                    }
                    if !chunks.isEmpty {
                        return try buildBuffer(chunks: chunks, sampleRate: resolvedSampleRate)
                    }
                    throw YandexRealtimeTTSError.emptyAudio
                }

                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMs))
                    timeoutFlag.markTimedOut()
                    await transport.disconnect()
                    throw YandexRealtimeTTSError.timedOut
                }

                guard let buffer = try await group.next() else {
                    throw YandexRealtimeTTSError.emptyAudio
                }
                group.cancelAll()
                return buffer
            }
        } onCancel: {
            Task { await transport.disconnect() }
        }
    }

    private static func buildBuffer(chunks: [Data], sampleRate: Int) throws -> AVAudioPCMBuffer {
        let total = chunks.reduce(0) { $0 + $1.count }
        guard total >= MemoryLayout<Int16>.size else {
            throw YandexRealtimeTTSError.emptyAudio
        }
        var combined = Data()
        combined.reserveCapacity(total)
        for chunk in chunks {
            combined.append(chunk)
        }
        guard let buffer = RealtimeVoiceAudio.pcm16ToAudioBuffer(
            data: combined,
            sampleRate: Double(max(8_000, sampleRate))
        ) else {
            throw YandexRealtimeTTSError.emptyAudio
        }
        return buffer
    }
}
