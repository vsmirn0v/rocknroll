import AVFoundation
import ConferenceCore
import Foundation
import NaturalLanguage

/// Which voice speaks a reply into a meeting.
enum VoiceEngine: String, Codable, CaseIterable, Sendable {
    /// The macOS system voice for the reply's language.
    case system
    /// Qwen3-TTS (or another speech model) served by a configured Rapid-MLX endpoint.
    case rapidMLX
    /// Yandex Cloud AI Studio LiveTTS over Realtime WebSocket (`speech-realtime-tts-live`).
    case yandexLiveTTS
    /// The Personal Voice you created in System Settings → Accessibility (macOS 14+).
    case personal
    /// Your voice, cloned from a short sample by VoxCPM2 on the Neural Engine (macOS 27+).
    case cloned
}

struct AssistantVoiceConfiguration: Equatable, Sendable {
    let engine: VoiceEngine
    let cloneRecordedAt: Date?
    private let baseURL: String
    private let model: String
    private let description: String
    private let yandexFolderID: String
    private let yandexVoice: String
    private let yandexRole: String
    private let yandexModel: String
    private let yandexEndpoint: String
    private let yandexAPIKey: String

    init(
        engine: VoiceEngine,
        baseURL: String,
        model: String,
        description: String,
        cloneRecordedAt: Date?,
        yandexFolderID: String = "",
        yandexVoice: String = YandexLiveTTSVoice.sofia.rawValue,
        yandexRole: String = "",
        yandexModel: String = YandexRealtimePreferences.defaultTTSModel,
        yandexEndpoint: String = "",
        yandexAPIKey: String = ""
    ) {
        self.engine = engine
        self.cloneRecordedAt = engine == .cloned ? cloneRecordedAt : nil
        self.baseURL = engine == .rapidMLX ? baseURL : ""
        self.model = engine == .rapidMLX ? model : ""
        self.description = engine == .rapidMLX ? description : ""
        self.yandexFolderID = engine == .yandexLiveTTS ? yandexFolderID : ""
        self.yandexVoice = engine == .yandexLiveTTS ? yandexVoice : ""
        self.yandexRole = engine == .yandexLiveTTS ? yandexRole : ""
        self.yandexModel = engine == .yandexLiveTTS ? yandexModel : ""
        self.yandexEndpoint = engine == .yandexLiveTTS ? yandexEndpoint : ""
        self.yandexAPIKey = engine == .yandexLiveTTS ? yandexAPIKey : ""
    }

    var title: String {
        switch engine {
        case .system: L("The macOS voice")
        case .personal: L("Your Personal Voice")
        case .cloned: L("Your voice, on the Neural Engine")
        case .rapidMLX: "Rapid-MLX · " + model
        case .yandexLiveTTS:
            L("Yandex LiveTTS") + " · " + (yandexVoice.trimmed.isEmpty ? YandexLiveTTSVoice.sofia.rawValue : yandexVoice.trimmed)
        }
    }

    var speechHost: String? {
        switch engine {
        case .rapidMLX:
            guard let url = URL(string: baseURL.trimmed), let host = url.host else { return nil }
            return url.port.map { "\(host):\($0)" } ?? host
        case .yandexLiveTTS:
            let raw = yandexEndpoint.trimmed.isEmpty ? RealtimeProviderKind.yandexRealtime.defaultEndpoint : yandexEndpoint.trimmed
            guard let url = URL(string: raw), let host = url.host else { return nil }
            return url.port.map { "\(host):\($0)" } ?? host
        case .system, .personal, .cloned:
            return nil
        }
    }

    func synthesize(_ text: String, language: String? = nil, session: URLSession = .shared,
                    cloneRequest: UUID = UUID(), cloneDeadline: Date? = nil) async throws -> AVAudioPCMBuffer {
        switch engine {
        case .system: return try await VoiceSynthesis.system(text, language: language)
        case .personal: return try await VoiceSynthesis.personal(text)
        case .cloned:
            guard let cloneRecordedAt else { throw VoiceSynthesisError.cloneVoiceMissing }
            return try await VoiceSynthesis.cloned(text, recordedAt: cloneRecordedAt, request: cloneRequest, expiresAt: cloneDeadline)
        case .rapidMLX:
            return try await VoiceSynthesis.rapidMLX(text, baseURL: baseURL, model: model, description: description, session: session)
        case .yandexLiveTTS:
            return try await VoiceSynthesis.yandexLiveTTS(
                text,
                apiKey: yandexAPIKey,
                folderID: yandexFolderID,
                model: yandexModel,
                voice: yandexVoice,
                role: yandexRole,
                endpointOverride: yandexEndpoint
            )
        }
    }
}

enum VoiceSynthesisError: LocalizedError, Equatable {
    case empty, system, server(Int, String?), transport, audio, personalUnsupported, personalDenied, personalMissing
    case yandexCredentialsMissing, yandexFolderIDMissing, yandexFailed(String)
    case cloneUnsupported, cloneModelMissing, cloneVoiceMissing, clonePreparing, clonePreparationFailed, clonePreviewWaiting, cloneTranscriptMissing
    case cloneSampleTooShort, cloneSampleTooLong, microphoneDenied
    var errorDescription: String? {
        switch self {
        case .empty: L("There is nothing to say.")
        case .system: L("The system voice could not speak this text.")
        case .server(let code, let message):
            L("The voice model answered with error %ld.", code) + (message.map { " " + L("Provider says: %@", String($0.prefix(240))) } ?? "")
        case .transport: L("The voice server could not be reached. Check its address and audio support.")
        case .audio: L("The voice model returned audio this Mac could not read.")
        case .personalUnsupported: L("Personal Voice needs macOS 14 or later.")
        case .personalDenied: L("Allow this app to use your Personal Voice in System Settings → Privacy & Security → Personal Voice.")
        case .personalMissing: L("No Personal Voice found. Create one in System Settings → Accessibility → Personal Voice.")
        case .yandexCredentialsMissing: L("Save your Yandex API key in Voice settings first.")
        case .yandexFolderIDMissing: L("Enter your Yandex Cloud Folder ID or a full gpt:// model URI first.")
        case .yandexFailed(let detail): L("Yandex LiveTTS failed: %@", detail)
        case .cloneUnsupported: L("Your cloned voice needs macOS 27 and a Mac with Apple silicon.")
        case .cloneModelMissing: L("Download the voice model in Settings → Assistant → Voice first.")
        case .cloneVoiceMissing: L("Record your voice in Settings → Assistant → Voice first.")
        case .clonePreparing: L("The voice model is still being prepared for this Mac's Neural Engine. Try again when Settings shows it is ready.")
        case .clonePreparationFailed: L("Voice preparation failed. Choose Try Again in Settings → Assistant → Voice.")
        case .clonePreviewWaiting: L("The cloned voice is still working. Try the preview again in a moment.")
        case .cloneTranscriptMissing: L("Enter the words you read in the recording.")
        case .cloneSampleTooShort: L("The recording is too short. Read for at least %ld seconds.", Int(VoiceSampleAudio.minimumSeconds))
        case .cloneSampleTooLong: L("The recording is too long. Keep it under %ld seconds.", Int(VoiceSampleAudio.maximumSeconds))
        case .microphoneDenied: L("Allow this app to use the microphone in System Settings → Privacy & Security → Microphone.")
        }
    }
}

/// Plays a synthesized reply on this Mac only, for trying a voice in Settings.
@MainActor final class VoicePreviewPlayer: ObservableObject {
    static let shared = VoicePreviewPlayer()
    @Published private(set) var isPlaying = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = UUID()
    private var completionHandler: (() -> Void)?
    private var streamFormat: AVAudioFormat?

    func play(_ buffer: AVAudioPCMBuffer, onComplete: (() -> Void)? = nil) throws {
        stop()
        let token = UUID()
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        try engine.start()
        generation = token
        completionHandler = onComplete
        isPlaying = true
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                let completion = self.completionHandler
                self.completionHandler = nil
                self.player = nil
                self.engine?.stop()
                self.engine = nil
                self.streamFormat = nil
                self.isPlaying = false
                completion?()
            }
        }
        player.play()
        self.engine = engine
        self.player = player
        self.streamFormat = buffer.format
    }

    @discardableResult
    func beginStreaming(format: AVAudioFormat, onComplete: (() -> Void)? = nil) throws -> UUID {
        stop()
        let token = UUID()
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        generation = token
        completionHandler = onComplete
        self.engine = engine
        self.player = player
        self.streamFormat = format
        isPlaying = true
        return token
    }

    func enqueueStreamBuffer(_ buffer: AVAudioPCMBuffer, sessionToken: UUID) {
        guard generation == sessionToken, let player, let streamFormat,
              buffer.format.sampleRate == streamFormat.sampleRate,
              buffer.format.channelCount == streamFormat.channelCount else { return }
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func finishStreaming(sessionToken: UUID) {
        guard generation == sessionToken, let player, let streamFormat,
              let sentinel = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: 1) else {
            return
        }
        sentinel.frameLength = 1
        if let channel = sentinel.floatChannelData?[0] {
            channel[0] = 0
        }
        player.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == sessionToken else { return }
                let completion = self.completionHandler
                self.completionHandler = nil
                self.player = nil
                self.engine?.stop()
                self.engine = nil
                self.streamFormat = nil
                self.isPlaying = false
                completion?()
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        generation = UUID()
        player?.stop()
        player = nil
        engine?.stop()
        engine = nil
        streamFormat = nil
        let hadCompletion = completionHandler
        completionHandler = nil
        isPlaying = false
        hadCompletion?()
    }
}

/// Bounds only the caller's wait, not the shared synthesis task. Core AI specialization
/// may ignore cancellation, so cancelling it and retrying could compile the same asset twice.
/// The lock also makes a late task result and the timeout race harmless: exactly one wins.
final class VoicePreviewWait<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, Error>?, Never>?
    private var result: Result<Value, Error>??
    private var finished = false

    static func result(of task: Task<Value, Error>, timeoutNanoseconds: UInt64) async -> Result<Value, Error>? {
        let wait = VoicePreviewWait<Value>()
        Task {
            do { wait.finish(.success(try await task.value)) }
            catch { wait.finish(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            wait.finish(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { wait.start($0) }
    }

    private func start(_ continuation: CheckedContinuation<Result<Value, Error>?, Never>) {
        lock.lock()
        if finished {
            let result = result ?? nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Value, Error>?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.result = .some(result)
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

enum VoiceSynthesis {
    /// The reply's language as a BCP-47 code, from the text itself.
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
    }

    /// The macOS voice for the text's language.
    static func system(_ text: String, language: String? = nil) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        let language = language ?? Self.language(of: clean) ?? Locale.preferredLanguages.first ?? "en-US"
        guard let buffer = await VoiceReplySample.make(text: clean, language: language) else { throw VoiceSynthesisError.system }
        return buffer
    }

    /// Your Personal Voice, after the system asks you once whether this app may use it.
    /// It speaks the language it was recorded in; a reply in another language still uses it.
    static func personal(_ text: String) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        guard #available(macOS 14.0, *) else { throw VoiceSynthesisError.personalUnsupported }
        var status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        if status == .notDetermined { status = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization() }
        guard status == .authorized else { throw VoiceSynthesisError.personalDenied }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let language = language(of: clean) ?? ""
        guard let voice = voices.first(where: { !language.isEmpty && $0.language.hasPrefix(language) }) ?? voices.first else {
            throw VoiceSynthesisError.personalMissing
        }
        guard let buffer = await VoiceReplySample.make(text: clean, voice: voice) else { throw VoiceSynthesisError.system }
        return buffer
    }

    /// Your cloned voice, generated on this Mac's Neural Engine.
    static func cloned(_ text: String, recordedAt: Date? = nil, request: UUID = UUID(), expiresAt: Date? = nil) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        let samples = try await VoiceCloneStore.shared.speak(clean, recordedAt: recordedAt, request: request, expiresAt: expiresAt)
        return try VoiceSampleAudio.buffer(samples, rate: 48_000)
    }

    /// OpenAI-style `/audio/speech` on Rapid-MLX: WAV back, read into one buffer.
    /// `description` steers a VoiceDesign model ("instructions"); others ignore it.
    static func rapidMLX(_ text: String, baseURL: String, model: String, description: String,
                         session: URLSession = .shared) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        guard let base = URL(string: baseURL.trimmed), base.host != nil else { throw VoiceSynthesisError.transport }
        var request = URLRequest(url: base.appendingPathComponent("audio/speech"), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model.trimmed, "input": clean, "response_format": "wav"]
        if !description.trimmed.isEmpty { body["instructions"] = description.trimmed }
        if let language = language(of: clean) { body["language"] = language }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw VoiceSynthesisError.transport }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? object?["detail"] as? String
            throw VoiceSynthesisError.server(status, message)
        }
        return try buffer(fromAudio: data)
    }

    static func yandexLiveTTS(
        _ text: String,
        apiKey: String,
        folderID: String,
        model: String = YandexRealtimePreferences.defaultTTSModel,
        voice: String = YandexLiveTTSVoice.sofia.rawValue,
        role: String = "",
        endpointOverride: String = "",
        customTransport: (any RealtimeVoiceTransport)? = nil
    ) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        do {
            return try await YandexRealtimeTTS.synthesize(
                text: clean,
                apiKey: apiKey,
                folderID: folderID,
                model: model,
                voice: voice,
                role: role,
                endpointOverride: endpointOverride,
                customTransport: customTransport
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as YandexRealtimeTTSError {
            switch err {
            case .emptyText: throw VoiceSynthesisError.empty
            case .missingAPIKey: throw VoiceSynthesisError.yandexCredentialsMissing
            case .missingFolderID: throw VoiceSynthesisError.yandexFolderIDMissing
            case .invalidEndpoint, .timedOut: throw VoiceSynthesisError.transport
            case .emptyAudio: throw VoiceSynthesisError.audio
            case .serverError(let detail): throw VoiceSynthesisError.yandexFailed(detail)
            }
        } catch {
            throw VoiceSynthesisError.transport
        }
    }

    struct AuditionSynthesisResult {
        let buffer: AVAudioPCMBuffer
        let usedSystemFallback: Bool
        let failureReason: String?
    }

    /// Synthesizes local audio for an Assistant response using the user's chosen audition voice
    /// (curated VoxCPM2 neural preset, cloned voice, Personal Voice, Yandex LiveTTS, or macOS system voice),
    /// falling back to the local macOS system voice if a neural/cloned/cloud voice is not ready yet.
    @MainActor
    static func audition(_ text: String, selection: AssistantAuditionVoiceSelection, store: AttentionStore? = nil) async throws -> AVAudioPCMBuffer {
        try await auditionWithStatus(text, selection: selection, store: store).buffer
    }

    @MainActor
    static func auditionWithStatus(_ text: String, selection: AssistantAuditionVoiceSelection, store: AttentionStore? = nil) async throws -> AuditionSynthesisResult {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        switch selection {
        case .voxPreset(let preset):
            do {
                let samples = try await VoiceCloneStore.shared.speakPreset(clean, preset: preset)
                let buffer = try VoiceSampleAudio.buffer(samples, rate: 48_000)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: false, failureReason: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let buffer = try await system(clean)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: true, failureReason: error.localizedDescription)
            }
        case .clonedVoice:
            do {
                let buffer = try await cloned(clean)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: false, failureReason: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let buffer = try await system(clean)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: true, failureReason: error.localizedDescription)
            }
        case .personalVoice:
            do {
                let buffer = try await personal(clean)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: false, failureReason: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let buffer = try await system(clean)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: true, failureReason: error.localizedDescription)
            }
        case .systemVoice(let identifier):
            if !identifier.isEmpty,
               let specific = AVSpeechSynthesisVoice(identifier: identifier),
               let specificBuffer = await VoiceReplySample.make(text: clean, voice: specific) {
                return AuditionSynthesisResult(buffer: specificBuffer, usedSystemFallback: false, failureReason: nil)
            }
            let buffer = try await system(clean)
            return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: false, failureReason: nil)
        case .yandexLiveTTS(let voice):
            let apiKey: String
            let folderID: String
            let role: String
            let model: String
            let endpoint: String
            if let store {
                apiKey = store.realtimeAPIKey(for: .yandexRealtime) ?? ""
                folderID = store.realtimeFolderID
                role = store.yandexTTSRole
                model = store.yandexTTSModel
                endpoint = store.yandexTTSEndpoint
            } else {
                var kc = AttentionKeychain()
                kc.account = "realtime-api-key." + RealtimeProviderKind.yandexRealtime.rawValue
                apiKey = kc.read()?.trimmed ?? ""
                let defaults = UserDefaults.standard
                folderID = defaults.string(forKey: YandexRealtimePreferences.folderIDKey) ?? ""
                role = defaults.string(forKey: YandexRealtimePreferences.ttsRoleKey) ?? ""
                model = defaults.string(forKey: YandexRealtimePreferences.ttsModelKey) ?? YandexRealtimePreferences.defaultTTSModel
                endpoint = defaults.string(forKey: YandexRealtimePreferences.ttsEndpointKey) ?? ""
            }
            do {
                let buffer = try await yandexLiveTTS(
                    clean,
                    apiKey: apiKey,
                    folderID: folderID,
                    model: model,
                    voice: voice,
                    role: role,
                    endpointOverride: endpoint
                )
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: false, failureReason: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let buffer = try await system(clean)
                return AuditionSynthesisResult(buffer: buffer, usedSystemFallback: true, failureReason: error.localizedDescription)
            }
        }
    }

    /// Parses uncompressed RIFF/WAVE in-memory without temp-file overhead, falling back to `AVAudioFile` for other formats.
    static func buffer(fromAudio data: Data) throws -> AVAudioPCMBuffer {
        let maxAudioBytes = 32 * 1024 * 1024
        guard !data.isEmpty, data.count <= maxAudioBytes else { throw VoiceSynthesisError.audio }
        if let parsed = parseWAVInMemory(data) {
            return parsed
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-reply-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            let maxFrames = Int64(max(1.0, file.processingFormat.sampleRate) * 120.0)
            guard file.length > 0, file.length <= maxFrames,
                  let frameCount = AVAudioFrameCount(exactly: file.length),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                throw VoiceSynthesisError.audio
            }
            try file.read(into: buffer)
            return buffer
        } catch let error as VoiceSynthesisError { throw error }
        catch { throw VoiceSynthesisError.audio }
    }

    private static func parseWAVInMemory(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count >= 44 else { return nil }
        func ascii(_ offset: Int, _ target: String) -> Bool {
            guard offset + 4 <= data.count else { return false }
            return Data(data[offset..<(offset + 4)]) == Data(target.utf8)
        }
        func u16(_ offset: Int) -> UInt16 {
            data.withUnsafeBytes { raw in UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
        }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard ascii(0, "RIFF"), ascii(8, "WAVE") else { return nil }
        var offset = 12
        var audioFormat: UInt16 = 0
        var channels: UInt16 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var dataRange: Range<Int>?

        while offset + 8 <= data.count {
            let chunkSize = Int(u32(offset + 4))
            let bodyStart = offset + 8
            guard chunkSize >= 0, bodyStart + chunkSize <= data.count else { break }
            if ascii(offset, "fmt ") && chunkSize >= 16 {
                audioFormat = u16(bodyStart)
                channels = u16(bodyStart + 2)
                sampleRate = u32(bodyStart + 4)
                bitsPerSample = u16(bodyStart + 14)
            } else if ascii(offset, "data") {
                dataRange = bodyStart..<(bodyStart + chunkSize)
                break
            }
            offset = bodyStart + chunkSize + (chunkSize & 1)
        }
        guard let dataRange, channels >= 1, channels <= 2, sampleRate >= 8_000 else { return nil }
        let bytesPerSample = Int(bitsPerSample) / 8
        let frameSize = bytesPerSample * Int(channels)
        guard frameSize > 0 else { return nil }
        let frameCount = dataRange.count / frameSize
        let maxFrames = Int(Double(sampleRate) * 120.0)
        guard frameCount > 0, frameCount <= maxFrames,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let out = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let chCount = Int(channels)
        if audioFormat == 1 && bitsPerSample == 16 {
            data.withUnsafeBytes { raw in
                let scale: Float = 1.0 / 32768.0
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    let frameBase = dataRange.lowerBound + frame * frameSize
                    for ch in 0..<chCount {
                        let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frameBase + ch * 2, as: Int16.self))
                        sum += Float(s) * scale
                    }
                    out[frame] = sum / Float(chCount)
                }
            }
            return buffer
        } else if audioFormat == 3 && bitsPerSample == 32 {
            data.withUnsafeBytes { raw in
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    let frameBase = dataRange.lowerBound + frame * frameSize
                    for ch in 0..<chCount {
                        let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: frameBase + ch * 4, as: UInt32.self))
                        sum += Float(bitPattern: bits)
                    }
                    out[frame] = sum / Float(chCount)
                }
            }
            return buffer
        }
        return nil
    }
}
