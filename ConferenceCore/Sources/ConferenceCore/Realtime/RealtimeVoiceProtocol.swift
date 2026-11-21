import Foundation

/// Optional low-latency WebSocket voice model provider for live assistant turns.
/// Standard STT → LLM → TTS works independently whenever `.disabled` or unavailable.
public enum RealtimeProviderKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case disabled
    case openAIRealtime = "openai_realtime"
    case geminiLive = "gemini_live"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled: return L("Off (Standard local/chat pipeline)")
        case .openAIRealtime: return "OpenAI Realtime (gpt-live)"
        case .geminiLive: return "Gemini Live"
        }
    }

    public var defaultModel: String {
        switch self {
        case .disabled: return ""
        case .openAIRealtime: return "gpt-realtime"
        case .geminiLive: return "gemini-2.5-flash-native-audio-preview"
        }
    }

    public var defaultVoice: String {
        switch self {
        case .disabled: return ""
        case .openAIRealtime: return "alloy"
        case .geminiLive: return "Aoede"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .disabled: return ""
        case .openAIRealtime: return "wss://api.openai.com/v1/realtime"
        case .geminiLive: return "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.BidiGenerateContent"
        }
    }
}

public struct RealtimeToolDeclaration: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parametersJSONString: String

    public init(name: String, description: String, parametersJSONString: String = "{}") {
        self.name = name
        self.description = description
        self.parametersJSONString = parametersJSONString
    }

    public init(name: String, description: String, parametersJSONSchema: [String: Any]) {
        self.name = name
        self.description = description
        if let data = try? JSONSerialization.data(withJSONObject: parametersJSONSchema, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            self.parametersJSONString = json
        } else {
            self.parametersJSONString = "{\"type\":\"object\",\"properties\":{}}"
        }
    }

    public func parametersDictionary() -> [String: Any] {
        guard let data = parametersJSONString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["type": "object", "properties": [:]]
        }
        return dict
    }
}

public struct RealtimeSessionConfig: Equatable, Sendable {
    public var provider: RealtimeProviderKind
    public var apiKey: String
    public var model: String
    public var voice: String
    public var endpointOverride: String
    public var systemInstructions: String
    public var inputSampleRate: Int
    public var outputSampleRate: Int
    public var tools: [RealtimeToolDeclaration]

    public init(
        provider: RealtimeProviderKind,
        apiKey: String,
        model: String = "",
        voice: String = "",
        endpointOverride: String = "",
        systemInstructions: String = "",
        inputSampleRate: Int = 16_000,
        outputSampleRate: Int = 24_000,
        tools: [RealtimeToolDeclaration] = []
    ) {
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultModel : model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultVoice : voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpointOverride = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        self.systemInstructions = systemInstructions
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.tools = tools
    }
}

public enum RealtimeVoiceEvent: Sendable {
    case connected
    case userTranscript(String)
    case assistantTranscriptDelta(String)
    case assistantTranscriptDone(String)
    case audioPCM16(Data, sampleRate: Int)
    case audioDone
    case toolCall(callID: String, name: String, argumentsJSON: String)
    case error(String)
    case disconnected(String?)
}

public enum RealtimeTransportError: LocalizedError, Equatable, Sendable {
    case disabled
    case missingAPIKey
    case invalidEndpoint
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .disabled: return L("Realtime model is disabled.")
        case .missingAPIKey: return L("Realtime API key is missing.")
        case .invalidEndpoint: return L("Realtime endpoint URL is invalid.")
        case .notConnected: return L("Realtime session is not connected.")
        }
    }
}

/// Transport-agnostic WebSocket client interface implemented by OpenAI Realtime and Gemini Live.
public protocol RealtimeVoiceTransport: Sendable {
    var events: AsyncStream<RealtimeVoiceEvent> { get }
    func connect(config: RealtimeSessionConfig) async throws
    func sendAudioPCM16(_ data: Data) async throws
    func sendTextTurn(_ text: String) async throws
    func sendToolResult(callID: String, name: String, jsonOutput: String) async throws
    func updateInstructions(_ instructions: String) async throws
    func disconnect() async
}
