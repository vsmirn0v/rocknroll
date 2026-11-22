import Foundation

/// Optional low-latency WebSocket voice model provider for live assistant turns.
/// Standard STT → LLM → TTS works independently whenever `.disabled` or unavailable.
public enum RealtimeProviderKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case disabled
    case openAIRealtime = "openai_realtime"
    case geminiLive = "gemini_live"
    case yandexRealtime = "yandex_realtime"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled: return L("Off (Standard local/chat pipeline)")
        case .openAIRealtime: return "OpenAI Realtime (gpt-live)"
        case .geminiLive: return "Gemini Live"
        case .yandexRealtime: return "Yandex Realtime (LiveTTS)"
        }
    }

    public var defaultModel: String {
        switch self {
        case .disabled: return ""
        case .openAIRealtime: return "gpt-realtime"
        case .geminiLive: return "gemini-2.5-flash-native-audio-preview"
        case .yandexRealtime: return "speech-realtime-max-tts-live"
        }
    }

    public var defaultVoice: String {
        switch self {
        case .disabled: return ""
        case .openAIRealtime: return "alloy"
        case .geminiLive: return "Aoede"
        case .yandexRealtime: return "sofia"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .disabled: return ""
        case .openAIRealtime: return "wss://api.openai.com/v1/realtime"
        case .geminiLive: return "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.BidiGenerateContent"
        case .yandexRealtime: return "wss://ai.api.cloud.yandex.net/v1/realtime/openai"
        }
    }

    public var defaultInputSampleRate: Int {
        switch self {
        case .openAIRealtime, .yandexRealtime: return 24_000
        case .geminiLive, .disabled: return 16_000
        }
    }

    public var defaultOutputSampleRate: Int {
        switch self {
        case .yandexRealtime: return 44_100
        case .openAIRealtime, .geminiLive, .disabled: return 24_000
        }
    }
}

public enum YandexLiveTTSVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case sofia
    case vera

    public var id: String { rawValue }

    public var displayTitle: String {
        Self.displayTitle(for: rawValue)
    }

    public static func displayTitle(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "sofia", "": return "Sofia"
        case "vera": return "Vera"
        default: return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
    }
}

public enum YandexLiveTTSRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaultRole = ""
    case casual
    case support

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defaultRole: return L("Default")
        case .casual: return L("Casual")
        case .support: return L("Support")
        }
    }
}

public enum YandexRealtimePreferences {
    public static let folderIDKey = "yandex.realtime.folderID"
    public static let voiceRoleKey = "yandex.realtime.voiceRole"
    public static let ttsVoiceKey = "yandex.realtime.ttsVoice"
    public static let ttsRoleKey = "yandex.realtime.ttsRole"
    public static let ttsModelKey = "yandex.realtime.ttsModel"
    public static let ttsEndpointKey = "yandex.realtime.ttsEndpoint"
    public static let defaultTTSModel = "speech-realtime-tts-live"
    public static let credentialsChangedNotification = Notification.Name("ConferenceCore.yandexRealtimeCredentialsChanged")
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
    public var folderID: String
    public var voiceRole: String

    public init(
        provider: RealtimeProviderKind,
        apiKey: String,
        model: String = "",
        voice: String = "",
        endpointOverride: String = "",
        systemInstructions: String = "",
        inputSampleRate: Int = 0,
        outputSampleRate: Int = 0,
        tools: [RealtimeToolDeclaration] = [],
        folderID: String = "",
        voiceRole: String = ""
    ) {
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = cleanModel.isEmpty ? provider.defaultModel : cleanModel
        let cleanVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = cleanVoice.isEmpty ? provider.defaultVoice : cleanVoice
        self.endpointOverride = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        self.systemInstructions = systemInstructions
        self.inputSampleRate = inputSampleRate > 0 ? inputSampleRate : provider.defaultInputSampleRate
        self.outputSampleRate = outputSampleRate > 0 ? outputSampleRate : provider.defaultOutputSampleRate
        self.tools = tools
        self.folderID = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceRole = voiceRole.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case missingFolderID
    case invalidEndpoint
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .disabled: return L("Realtime model is disabled.")
        case .missingAPIKey: return L("Realtime API key is missing.")
        case .missingFolderID: return L("Yandex Cloud Folder ID is missing.")
        case .invalidEndpoint: return L("Realtime endpoint URL is invalid.")
        case .notConnected: return L("Realtime session is not connected.")
        }
    }
}

/// Transport-agnostic WebSocket client interface implemented by OpenAI Realtime, Gemini Live, and Yandex Realtime.
public protocol RealtimeVoiceTransport: Sendable {
    var events: AsyncStream<RealtimeVoiceEvent> { get }
    func connect(config: RealtimeSessionConfig) async throws
    func sendAudioPCM16(_ data: Data) async throws
    func sendTextTurn(_ text: String) async throws
    func sendToolResult(callID: String, name: String, jsonOutput: String) async throws
    func updateInstructions(_ instructions: String) async throws
    func disconnect() async
}
