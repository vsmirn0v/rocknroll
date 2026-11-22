import Accelerate
import AVFoundation
import Combine
import ConferenceCore
import Foundation
import NaturalLanguage
import UIKit

enum IOSVoiceEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case personal
    case voxCPM2
    case rapidMLX
    case yandexLiveTTS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("iPhone system voice")
        case .personal: return L("Personal Voice")
        case .voxCPM2: return L("VoxCPM2 (On-Device Neural)")
        case .rapidMLX: return L("Rapid-MLX Server")
        case .yandexLiveTTS: return L("Yandex LiveTTS (Realtime)")
        }
    }
}

enum IOSVoiceSynthesisError: LocalizedError, Equatable {
    case empty
    case system
    case server(Int, String?)
    case transport
    case remoteVoicePermissionRequired
    case audio
    case yandexCredentialsMissing
    case yandexFolderIDMissing
    case yandexFailed(String)
    case personalUnsupported
    case personalDenied
    case personalMissing
    case voxUnsupportedDevice(String)
    case voxModelNotInstalled
    case voxVoiceNotRecorded
    case voxSampleTooShort(Int)
    case voxSampleTooLong(Int)
    case voxTranscriptMissing
    case voxCallActiveDuringRecording
    case microphoneDenied
    case voxNotEnoughDiskSpace
    case voxRuntimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return L("Enter text to speak first.")
        case .system:
            return L("The iPhone voice could not synthesize this text.")
        case .server(let code, let message):
            let base = L("The voice server answered with error %ld.", code)
            if let message, !message.isEmpty {
                return base + " " + L("Provider says: %@", String(message.prefix(240)))
            }
            return base
        case .remoteVoicePermissionRequired:
            return L("Allow this server to generate speech in Transcription & voice settings first.")
        case .transport:
            return L("The voice server could not be reached. Check its address and network access.")
        case .audio:
            return L("The voice server returned audio this iPhone could not read.")
        case .yandexCredentialsMissing:
            return L("Save your Yandex API key in Voice settings first.")
        case .yandexFolderIDMissing:
            return L("Enter your Yandex Cloud Folder ID or a full gpt:// model URI first.")
        case .yandexFailed(let detail):
            return L("Yandex LiveTTS failed: %@", detail)
        case .personalUnsupported:
            return L("Personal Voice requires iOS 17 or later.")
        case .personalDenied:
            return L("Allow this app to use your Personal Voice in Settings → Privacy & Security → Personal Voice.")
        case .personalMissing:
            return L("No Personal Voice found. Create one in Settings → Accessibility → Personal Voice.")
        case .voxUnsupportedDevice(let detail):
            return detail
        case .voxModelNotInstalled:
            return L("Download the VoxCPM2 model in Transcription & voice settings first.")
        case .voxVoiceNotRecorded:
            return L("Record or import a voice sample first, or turn off Use my cloned voice for zero-shot speech.")
        case .voxSampleTooShort(let minSeconds):
            return L("The voice recording is too short. Speak for at least %ld seconds.", minSeconds)
        case .voxSampleTooLong(let maxSeconds):
            return L("The voice recording is too long. Keep it under %ld seconds.", maxSeconds)
        case .voxTranscriptMissing:
            return L("Enter the words you spoke in the recording.")
        case .voxCallActiveDuringRecording:
            return L("Leave the active meeting call before recording a voice sample.")
        case .microphoneDenied:
            return L("Allow Microphone access in Settings to record your voice sample.")
        case .voxNotEnoughDiskSpace:
            return L("Free up at least 3.5 GB of storage on this iPhone to download VoxCPM2.")
        case .voxRuntimeFailed(let detail):
            return L("VoxCPM2 synthesis failed: %@", detail)
        }
    }
}

/// Synthesizes a reply buffer via `AVSpeechSynthesizer.write` with a hard timeout
/// so missing voices or withdrawn Personal Voice authorization never stall a call.
enum VoiceReplySample {
    @MainActor
    static func make(
        text: String,
        language: String = Locale.preferredLanguages.first ?? "en-US",
        voice: AVSpeechSynthesisVoice? = nil,
        timeout: TimeInterval = 30
    ) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
            ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let synthesizer = AVSpeechSynthesizer()
        let collected = Collected()
        return await bounded(timeout: timeout, cancel: { synthesizer.stopSpeaking(at: .immediate) }) { finish in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finish(collected.joined())
                    _ = synthesizer
                    return
                }
                collected.append(pcm)
            }
        }
    }

    @MainActor
    static func bounded(
        timeout: TimeInterval,
        cancel: @escaping @MainActor () -> Void = {},
        _ start: (@escaping (AVAudioPCMBuffer?) -> Void) -> Void
    ) async -> AVAudioPCMBuffer? {
        let once = Once()
        guard !Task.isCancelled, timeout.isFinite, timeout > 0 else { return nil }
        let timer = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout))
                if once.resume(nil) { cancel() }
            } catch {}
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard once.install(continuation) else { return }
                start { once.resume($0) }
            }
        } onCancel: {
            Task { @MainActor in
                if once.resume(nil) { cancel() }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AVAudioPCMBuffer?, Never>?
        private var finished = false

        func install(_ continuation: CheckedContinuation<AVAudioPCMBuffer?, Never>) -> Bool {
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(returning: nil)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        @discardableResult
        func resume(_ value: AVAudioPCMBuffer?) -> Bool {
            lock.lock()
            if finished {
                lock.unlock()
                return false
            }
            finished = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return true
        }
    }

    private final class Collected: @unchecked Sendable {
        private var buffers: [AVAudioPCMBuffer] = []
        private let lock = NSLock()

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(source, target) {
                guard let input = from.mData, let output = to.mData else { continue }
                memcpy(output, input, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
            lock.lock()
            buffers.append(copy)
            lock.unlock()
        }

        func joined() -> AVAudioPCMBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard let first = buffers.first else { return nil }
            let total = buffers.filter { $0.format == first.format }.reduce(0) { $0 + Int($1.frameLength) }
            let frameBytes = Int(first.format.streamDescription.pointee.mBytesPerFrame)
            guard total > 0, frameBytes > 0, let frameCount = AVAudioFrameCount(exactly: total),
                  let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: frameCount) else {
                return nil
            }
            for buffer in buffers where buffer.format == first.format {
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                for (from, to) in zip(source, target) {
                    guard let input = from.mData, let base = to.mData else { continue }
                    memcpy(base.advanced(by: Int(output.frameLength) * frameBytes), input, Int(buffer.frameLength) * frameBytes)
                }
                output.frameLength += buffer.frameLength
            }
            return output
        }
    }
}

enum IOSVoiceSynthesis {
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
    }

    static func system(
        _ text: String,
        language: String? = nil,
        voiceIdentifier: String? = nil
    ) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        let resolvedVoice = voiceIdentifier.flatMap { id -> AVSpeechSynthesisVoice? in
            id.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: id)
        }
        let resolvedLang = language ?? Self.language(of: clean) ?? Locale.preferredLanguages.first ?? "en-US"
        guard let buffer = await VoiceReplySample.make(text: clean, language: resolvedLang, voice: resolvedVoice) else {
            throw IOSVoiceSynthesisError.system
        }
        return buffer
    }

    static func personal(_ text: String) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard #available(iOS 17.0, *) else { throw IOSVoiceSynthesisError.personalUnsupported }
        var status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        if status == .notDetermined {
            status = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
        }
        guard status == .authorized else { throw IOSVoiceSynthesisError.personalDenied }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let detected = language(of: clean) ?? ""
        guard let voice = voices.first(where: { !detected.isEmpty && $0.language.hasPrefix(detected) }) ?? voices.first else {
            throw IOSVoiceSynthesisError.personalMissing
        }
        guard let buffer = await VoiceReplySample.make(text: clean, voice: voice) else {
            throw IOSVoiceSynthesisError.system
        }
        return buffer
    }

    static func rapidMLXEndpoint(for baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.query == nil, let base = components.url else { return nil }
        return base.appendingPathComponent("audio/speech")
    }

    static func rapidMLX(
        _ text: String,
        baseURL: String,
        approvedEndpoint: String?,
        model: String,
        description: String,
        session: URLSession = .shared
    ) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard let endpoint = rapidMLXEndpoint(for: baseURL) else { throw IOSVoiceSynthesisError.transport }
        guard endpoint.absoluteString == approvedEndpoint else { throw IOSVoiceSynthesisError.remoteVoicePermissionRequired }
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "input": clean,
            "response_format": "wav"
        ]
        let cleanDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDesc.isEmpty {
            body["instructions"] = cleanDesc
        }
        if let lang = language(of: clean) {
            body["language"] = lang
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await MeetingAITransfer.send(request, using: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IOSVoiceSynthesisError.transport
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? object?["detail"] as? String
            throw IOSVoiceSynthesisError.server(status, message)
        }
        return try buffer(fromAudio: data)
    }

    static func yandexTTSEndpointURL(for override: String) -> URL? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? RealtimeProviderKind.yandexRealtime.defaultEndpoint : trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            return nil
        }
        return components.url
    }

    static func yandexLiveTTS(
        _ text: String,
        apiKey: String,
        folderID: String,
        model: String,
        voice: String,
        role: String,
        endpointOverride: String,
        approvedEndpoint: String?,
        customTransport: (any RealtimeVoiceTransport)? = nil
    ) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard let endpoint = yandexTTSEndpointURL(for: endpointOverride) else {
            throw IOSVoiceSynthesisError.transport
        }
        guard endpoint.absoluteString == approvedEndpoint else {
            throw IOSVoiceSynthesisError.remoteVoicePermissionRequired
        }
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
            case .emptyText: throw IOSVoiceSynthesisError.empty
            case .missingAPIKey: throw IOSVoiceSynthesisError.yandexCredentialsMissing
            case .missingFolderID: throw IOSVoiceSynthesisError.yandexFolderIDMissing
            case .invalidEndpoint, .timedOut: throw IOSVoiceSynthesisError.transport
            case .emptyAudio: throw IOSVoiceSynthesisError.audio
            case .serverError(let detail): throw IOSVoiceSynthesisError.yandexFailed(detail)
            }
        } catch {
            throw IOSVoiceSynthesisError.transport
        }
    }

    static func buffer(fromAudio data: Data) throws -> AVAudioPCMBuffer {
        if let fastBuffer = parseWAVInMemory(data) {
            return fastBuffer
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-voice-reply-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            let maxFrames: Int64 = 48_000 * 600
            guard file.length > 0,
                  file.length <= maxFrames,
                  let frameCount = AVAudioFrameCount(exactly: file.length),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: frameCount
                  ) else {
                throw IOSVoiceSynthesisError.audio
            }
            try file.read(into: buffer)
            return buffer
        } catch let error as IOSVoiceSynthesisError {
            throw error
        } catch {
            throw IOSVoiceSynthesisError.audio
        }
    }

    /// Fast-path in-memory RIFF/WAVE 16-bit PCM decoder so synthesized WAV bytes skip temp-file disk I/O.
    private static func parseWAVInMemory(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count >= 44 else { return nil }
        return data.withUnsafeBytes { raw -> AVAudioPCMBuffer? in
            guard let base = raw.baseAddress else { return nil }
            func fourCC(_ offset: Int) -> UInt32 {
                var value: UInt32 = 0
                memcpy(&value, base.advanced(by: offset), 4)
                return value.bigEndian
            }
            func le16(_ offset: Int) -> UInt16 {
                var value: UInt16 = 0
                memcpy(&value, base.advanced(by: offset), 2)
                return UInt16(littleEndian: value)
            }
            func le32(_ offset: Int) -> UInt32 {
                var value: UInt32 = 0
                memcpy(&value, base.advanced(by: offset), 4)
                return UInt32(littleEndian: value)
            }

            guard fourCC(0) == 0x52494646, fourCC(8) == 0x57415645 else { return nil } // RIFF / WAVE
            var offset = 12
            var audioFormat: UInt16 = 0
            var channels: UInt16 = 0
            var sampleRate: UInt32 = 0
            var bitsPerSample: UInt16 = 0
            var pcmRange: Range<Int>?

            while offset + 8 <= data.count {
                let chunkID = fourCC(offset)
                let chunkSize = Int(le32(offset + 4))
                let payloadStart = offset + 8
                guard chunkSize >= 0, payloadStart + chunkSize <= data.count else { break }
                if chunkID == 0x666D7420, chunkSize >= 16 { // "fmt "
                    audioFormat = le16(payloadStart)
                    channels = le16(payloadStart + 2)
                    sampleRate = le32(payloadStart + 4)
                    bitsPerSample = le16(payloadStart + 14)
                } else if chunkID == 0x64617461 { // "data"
                    pcmRange = payloadStart..<(payloadStart + chunkSize)
                }
                let paddedSize = chunkSize + (chunkSize & 1)
                offset = payloadStart + paddedSize
            }

            guard audioFormat == 1,
                  bitsPerSample == 16,
                  channels == 1 || channels == 2,
                  sampleRate > 0,
                  let pcmRange else {
                return nil
            }
            let bytesPerFrame = Int(channels) * 2
            let frameCount = pcmRange.count / bytesPerFrame
            guard frameCount > 0,
                  frameCount <= 48_000 * 600,
                  let avFrameCount = AVAudioFrameCount(exactly: frameCount),
                  let format = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: Double(sampleRate),
                      channels: AVAudioChannelCount(channels),
                      interleaved: false
                  ),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: avFrameCount),
                  let channelData = buffer.floatChannelData else {
                return nil
            }
            buffer.frameLength = avFrameCount
            let srcBytes = base.advanced(by: pcmRange.lowerBound)
            var scale: Float = 1.0 / 32768.0
            if channels == 1 {
                let dst = channelData[0]
                if Int(bitPattern: srcBytes) & 1 == 0 {
                    let src16 = srcBytes.assumingMemoryBound(to: Int16.self)
                    vDSP_vflt16(src16, 1, dst, 1, vDSP_Length(frameCount))
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
                } else {
                    for i in 0..<frameCount {
                        var s: Int16 = 0
                        memcpy(&s, srcBytes.advanced(by: i * 2), 2)
                        dst[i] = Float(Int16(littleEndian: s)) * scale
                    }
                }
            } else {
                let dstL = channelData[0]
                let dstR = channelData[1]
                for i in 0..<frameCount {
                    var l: Int16 = 0
                    var r: Int16 = 0
                    memcpy(&l, srcBytes.advanced(by: i * 4), 2)
                    memcpy(&r, srcBytes.advanced(by: i * 4 + 2), 2)
                    dstL[i] = Float(Int16(littleEndian: l)) * scale
                    dstR[i] = Float(Int16(littleEndian: r)) * scale
                }
            }
            return buffer
        }
    }
}

@MainActor
final class IOSVoicePreviewPlayer: ObservableObject {
    static let shared = IOSVoicePreviewPlayer()

    @Published private(set) var isPlaying = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = UUID()
    private var completionHandler: (() -> Void)?
    private var activatedPlaybackSession = false
    private var scheduledStreamBuffers = 0
    private var streamFinishing = false
    private var streamFormat: AVAudioFormat?

    func play(_ buffer: AVAudioPCMBuffer, onComplete: (() -> Void)? = nil) throws {
        let token = try startPlaybackGraph(format: buffer.format, onComplete: onComplete)
        guard let player else { return }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
            }
        }
        player.play()
    }

    func beginStreaming(format: AVAudioFormat, onFinish: (() -> Void)? = nil) throws -> UUID {
        let token = try startPlaybackGraph(format: format, onComplete: onFinish)
        player?.play()
        return token
    }

    func enqueueStreamBuffer(_ buffer: AVAudioPCMBuffer, token: UUID) {
        guard generation == token, let player, let streamFormat,
              buffer.format.sampleRate == streamFormat.sampleRate,
              buffer.format.channelCount == streamFormat.channelCount else { return }
        scheduledStreamBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.scheduledStreamBuffers = max(0, self.scheduledStreamBuffers - 1)
                if self.streamFinishing && self.scheduledStreamBuffers == 0 {
                    self.stop()
                }
            }
        }
    }

    func finishStreaming(token: UUID) {
        guard generation == token else { return }
        streamFinishing = true
        if scheduledStreamBuffers == 0 {
            stop()
        }
    }

    private func startPlaybackGraph(format: AVAudioFormat, onComplete: (() -> Void)?) throws -> UUID {
        stop()
        let token = UUID()
        let session = AVAudioSession.sharedInstance()
        let inCall = session.mode == .voiceChat || session.mode == .videoChat ||
            (IOSWorkspaceAudioCoordinator.sharedForVoiceCheck?.activeSessionCount ?? 0) > 0
        if !inCall {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
            activatedPlaybackSession = true
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            if activatedPlaybackSession {
                activatedPlaybackSession = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw error
        }
        generation = token
        completionHandler = onComplete
        scheduledStreamBuffers = 0
        streamFinishing = false
        streamFormat = format
        self.engine = engine
        self.player = player
        isPlaying = true
        return token
    }

    func stop() {
        generation = UUID()
        scheduledStreamBuffers = 0
        streamFinishing = false
        streamFormat = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isPlaying = false
        if activatedPlaybackSession {
            activatedPlaybackSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        let completion = completionHandler
        completionHandler = nil
        completion?()
    }
}

@MainActor
final class IOSVoiceStore: ObservableObject {
    static let shared = IOSVoiceStore()

    private enum Keys {
        static let engine = "ios.voice.engine"
        static let systemVoiceID = "ios.voice.systemVoiceID"
        static let rapidMLXBaseURL = "ios.voice.rapidMLX.baseURL"
        static let approvedRapidMLXEndpoint = "ios.voice.rapidMLX.approvedEndpoint"
        static let rapidMLXModel = "ios.voice.rapidMLX.model"
        static let rapidMLXDescription = "ios.voice.rapidMLX.description"
        static let approvedYandexEndpoint = "ios.voice.yandexLiveTTS.approvedEndpoint"
    }

    @Published var engine: IOSVoiceEngine {
        didSet { preferences.set(engine.rawValue, forKey: Keys.engine) }
    }
    @Published var systemVoiceIdentifier: String {
        didSet { preferences.set(systemVoiceIdentifier, forKey: Keys.systemVoiceID) }
    }
    @Published var rapidMLXBaseURL: String {
        didSet {
            preferences.set(rapidMLXBaseURL, forKey: Keys.rapidMLXBaseURL)
            if approvedRapidMLXEndpoint != rapidMLXEndpoint?.absoluteString {
                setRapidMLXConsent(false)
            }
        }
    }
    @Published var rapidMLXModel: String {
        didSet { preferences.set(rapidMLXModel, forKey: Keys.rapidMLXModel) }
    }
    @Published var rapidMLXDescription: String {
        didSet { preferences.set(rapidMLXDescription, forKey: Keys.rapidMLXDescription) }
    }
    @Published var yandexFolderID: String {
        didSet {
            guard oldValue != yandexFolderID else { return }
            preferences.set(yandexFolderID, forKey: YandexRealtimePreferences.folderIDKey)
            if !suppressCredentialBroadcast {
                NotificationCenter.default.post(
                    name: YandexRealtimePreferences.credentialsChangedNotification,
                    object: self,
                    userInfo: ["isStandard": preferences === UserDefaults.standard]
                )
            }
        }
    }
    @Published var yandexVoice: String {
        didSet { preferences.set(yandexVoice, forKey: YandexRealtimePreferences.ttsVoiceKey) }
    }
    @Published var yandexRole: String {
        didSet { preferences.set(yandexRole, forKey: YandexRealtimePreferences.ttsRoleKey) }
    }
    @Published var yandexModel: String {
        didSet { preferences.set(yandexModel, forKey: YandexRealtimePreferences.ttsModelKey) }
    }
    @Published var yandexEndpoint: String {
        didSet {
            preferences.set(yandexEndpoint, forKey: YandexRealtimePreferences.ttsEndpointKey)
            if approvedYandexEndpoint != yandexEndpointURL?.absoluteString {
                setYandexConsent(false)
            }
        }
    }
    @Published private(set) var hasYandexAPIKey = false
    @Published var wakeWordEnabled: Bool {
        didSet { preferences.set(wakeWordEnabled, forKey: AssistantVoicePreferences.wakeWordEnabledKey) }
    }
    @Published var assistantAuditionVoice: AssistantAuditionVoiceSelection {
        didSet { AssistantVoicePreferences.saveAuditionVoice(assistantAuditionVoice, to: preferences) }
    }
    @Published var autoAuditionVoiceReplies: Bool {
        didSet { preferences.set(autoAuditionVoiceReplies, forKey: AssistantVoicePreferences.autoSpeakVoiceRepliesKey) }
    }
    @Published var autoAuditionTypedReplies: Bool {
        didSet { preferences.set(autoAuditionTypedReplies, forKey: AssistantVoicePreferences.autoSpeakTypedRepliesKey) }
    }

    @Published private var approvedRapidMLXEndpoint: String?
    @Published private var approvedYandexEndpoint: String?
    private let preferences: UserDefaults
    private let keychain: WorkspaceAPIKeychain
    private var suppressCredentialBroadcast = false
    private var credentialObserver: NSObjectProtocol?
    var customYandexTransportFactory: (@Sendable () -> any RealtimeVoiceTransport)?

    var rapidMLXEndpoint: URL? { IOSVoiceSynthesis.rapidMLXEndpoint(for: rapidMLXBaseURL) }

    var hasRapidMLXConsent: Bool {
        guard let endpoint = rapidMLXEndpoint else { return false }
        return approvedRapidMLXEndpoint == endpoint.absoluteString
    }

    func setRapidMLXConsent(_ allowed: Bool) {
        approvedRapidMLXEndpoint = allowed ? rapidMLXEndpoint?.absoluteString : nil
        preferences.set(approvedRapidMLXEndpoint, forKey: Keys.approvedRapidMLXEndpoint)
    }

    var yandexEndpointURL: URL? { IOSVoiceSynthesis.yandexTTSEndpointURL(for: yandexEndpoint) }

    var hasYandexConsent: Bool {
        guard let endpoint = yandexEndpointURL else { return false }
        return approvedYandexEndpoint == endpoint.absoluteString
    }

    func setYandexConsent(_ allowed: Bool) {
        approvedYandexEndpoint = allowed ? yandexEndpointURL?.absoluteString : nil
        preferences.set(approvedYandexEndpoint, forKey: Keys.approvedYandexEndpoint)
    }

    func yandexAPIKey() -> String {
        keychain.readRealtime(provider: .yandexRealtime)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @discardableResult
    func setYandexAPIKey(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = clean.isEmpty
            ? keychain.deleteRealtime(provider: .yandexRealtime)
            : keychain.writeRealtime(clean, provider: .yandexRealtime)
        hasYandexAPIKey = !yandexAPIKey().isEmpty
        if saved && !suppressCredentialBroadcast {
            NotificationCenter.default.post(
                name: YandexRealtimePreferences.credentialsChangedNotification,
                object: self,
                userInfo: ["isStandard": preferences === UserDefaults.standard]
            )
        }
        return saved
    }

    init(preferences: UserDefaults = .standard, keychain: WorkspaceAPIKeychain = WorkspaceAPIKeychain()) {
        self.preferences = preferences
        self.keychain = keychain
        self.engine = preferences.string(forKey: Keys.engine).flatMap(IOSVoiceEngine.init(rawValue:)) ?? .system
        self.systemVoiceIdentifier = preferences.string(forKey: Keys.systemVoiceID) ?? ""
        self.approvedRapidMLXEndpoint = preferences.string(forKey: Keys.approvedRapidMLXEndpoint)
        self.rapidMLXBaseURL = preferences.string(forKey: Keys.rapidMLXBaseURL) ?? ""
        self.rapidMLXModel = preferences.string(forKey: Keys.rapidMLXModel) ?? "Qwen/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        self.rapidMLXDescription = preferences.string(forKey: Keys.rapidMLXDescription) ?? ""
        self.approvedYandexEndpoint = preferences.string(forKey: Keys.approvedYandexEndpoint)
        self.yandexFolderID = preferences.string(forKey: YandexRealtimePreferences.folderIDKey) ?? ""
        self.yandexVoice = preferences.string(forKey: YandexRealtimePreferences.ttsVoiceKey) ?? YandexLiveTTSVoice.sofia.rawValue
        self.yandexRole = preferences.string(forKey: YandexRealtimePreferences.ttsRoleKey) ?? ""
        self.yandexModel = preferences.string(forKey: YandexRealtimePreferences.ttsModelKey) ?? YandexRealtimePreferences.defaultTTSModel
        self.yandexEndpoint = preferences.string(forKey: YandexRealtimePreferences.ttsEndpointKey) ?? ""
        self.wakeWordEnabled = AssistantVoicePreferences.loadWakeWordEnabled(from: preferences)
        self.assistantAuditionVoice = AssistantVoicePreferences.loadAuditionVoice(from: preferences)
        self.autoAuditionVoiceReplies = AssistantVoicePreferences.loadAutoSpeakVoiceReplies(from: preferences)
        self.autoAuditionTypedReplies = AssistantVoicePreferences.loadAutoSpeakTypedReplies(from: preferences)
        self.hasYandexAPIKey = !(keychain.readRealtime(provider: .yandexRealtime)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        self.credentialObserver = NotificationCenter.default.addObserver(
            forName: YandexRealtimePreferences.credentialsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let posterIsStandard = (note.userInfo?["isStandard"] as? Bool) ?? false
            let posterObject = note.object as AnyObject?
            Task { @MainActor [weak self] in
                guard let self, posterObject !== self else { return }
                guard self.preferences === UserDefaults.standard && posterIsStandard else { return }
                self.suppressCredentialBroadcast = true
                defer { self.suppressCredentialBroadcast = false }
                let latestFolder = self.preferences.string(forKey: YandexRealtimePreferences.folderIDKey) ?? ""
                if self.yandexFolderID != latestFolder {
                    self.yandexFolderID = latestFolder
                }
                self.hasYandexAPIKey = !self.yandexAPIKey().isEmpty
            }
        }
    }

    deinit {
        if let credentialObserver {
            NotificationCenter.default.removeObserver(credentialObserver)
        }
    }

    func synthesizeAssistantResponse(_ text: String) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        let fallbackVoiceID = systemVoiceIdentifier.isEmpty ? nil : systemVoiceIdentifier
        let engineName: String
        let providerName: String
        switch assistantAuditionVoice {
        case .voxPreset:
            engineName = "voxPreset"
            providerName = "local"
        case .clonedVoice:
            engineName = "clonedVoice"
            providerName = "local"
        case .personalVoice:
            engineName = "personalVoice"
            providerName = "apple"
        case .systemVoice:
            engineName = "systemVoice"
            providerName = "apple"
        case .yandexLiveTTS:
            engineName = "yandexLiveTTS"
            providerName = "yandex"
        }
        AppDiagnostics.log("voice-synthesis-start", [
            "engine": engineName,
            "provider": providerName
        ])
        let startedAt = ProcessInfo.processInfo.systemUptime

        func logReady(_ buffer: AVAudioPCMBuffer, engine: String) -> AVAudioPCMBuffer {
            let elapsedMs = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
            AppDiagnostics.log("voice-synthesis-ready", [
                "engine": engine,
                "ms": elapsedMs,
                "frames": Int(buffer.frameLength),
                "sampleRate": Int(buffer.format.sampleRate)
            ])
            return buffer
        }

        func fallbackToSystem(from sourceEngine: String, error: Error) async throws -> AVAudioPCMBuffer {
            let ns = error as NSError
            AppDiagnostics.log("voice-synthesis-error", [
                "engine": sourceEngine,
                "errorType": String(describing: type(of: error)),
                "errorCode": ns.code
            ])
            AppDiagnostics.log("voice-synthesis-fallback", [
                "from": sourceEngine,
                "to": "systemVoice",
                "reason": String(describing: type(of: error))
            ])
            let buf = try await IOSVoiceSynthesis.system(clean, voiceIdentifier: fallbackVoiceID)
            return logReady(buf, engine: "systemVoice")
        }

        switch assistantAuditionVoice {
        case .voxPreset(let preset):
            do {
                return logReady(try await IOSVoxCPM2Store.shared.speakPreset(clean, preset: preset), engine: engineName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await fallbackToSystem(from: engineName, error: error)
            }
        case .clonedVoice:
            do {
                return logReady(try await IOSVoxCPM2Store.shared.speakClonedForAssistant(clean), engine: engineName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await fallbackToSystem(from: engineName, error: error)
            }
        case .personalVoice:
            do {
                return logReady(try await IOSVoiceSynthesis.personal(clean), engine: engineName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await fallbackToSystem(from: engineName, error: error)
            }
        case .systemVoice(let identifier):
            let resolvedID = identifier.isEmpty ? fallbackVoiceID : identifier
            do {
                return logReady(try await IOSVoiceSynthesis.system(clean, voiceIdentifier: resolvedID), engine: engineName)
            } catch {
                let ns = error as NSError
                AppDiagnostics.log("voice-synthesis-error", [
                    "engine": engineName,
                    "errorType": String(describing: type(of: error)),
                    "errorCode": ns.code
                ])
                throw error
            }
        case .yandexLiveTTS(let voice):
            do {
                let buf = try await IOSVoiceSynthesis.yandexLiveTTS(
                    clean,
                    apiKey: yandexAPIKey(),
                    folderID: yandexFolderID,
                    model: yandexModel,
                    voice: voice,
                    role: yandexRole,
                    endpointOverride: yandexEndpoint,
                    approvedEndpoint: approvedYandexEndpoint,
                    customTransport: customYandexTransportFactory?()
                )
                return logReady(buf, engine: engineName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await fallbackToSystem(from: engineName, error: error)
            }
        }
    }

    func synthesize(_ text: String, session: URLSession = .shared) async throws -> AVAudioPCMBuffer {
        let providerName = engine == .yandexLiveTTS ? "yandex" : (engine == .rapidMLX ? "rapidMLX" : (engine == .voxCPM2 ? "local" : "apple"))
        AppDiagnostics.log("voice-synthesis-start", [
            "engine": engine.rawValue,
            "provider": providerName
        ])
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let buffer: AVAudioPCMBuffer
            switch engine {
            case .system:
                buffer = try await IOSVoiceSynthesis.system(
                    text,
                    voiceIdentifier: systemVoiceIdentifier.isEmpty ? nil : systemVoiceIdentifier
                )
            case .personal:
                buffer = try await IOSVoiceSynthesis.personal(text)
            case .voxCPM2:
                buffer = try await IOSVoxCPM2Store.shared.speak(text)
            case .rapidMLX:
                buffer = try await IOSVoiceSynthesis.rapidMLX(
                    text,
                    baseURL: rapidMLXBaseURL,
                    approvedEndpoint: approvedRapidMLXEndpoint,
                    model: rapidMLXModel,
                    description: rapidMLXDescription,
                    session: session
                )
            case .yandexLiveTTS:
                buffer = try await IOSVoiceSynthesis.yandexLiveTTS(
                    text,
                    apiKey: yandexAPIKey(),
                    folderID: yandexFolderID,
                    model: yandexModel,
                    voice: yandexVoice,
                    role: yandexRole,
                    endpointOverride: yandexEndpoint,
                    approvedEndpoint: approvedYandexEndpoint,
                    customTransport: customYandexTransportFactory?()
                )
            }
            let elapsedMs = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
            AppDiagnostics.log("voice-synthesis-ready", [
                "engine": engine.rawValue,
                "ms": elapsedMs,
                "frames": Int(buffer.frameLength),
                "sampleRate": Int(buffer.format.sampleRate)
            ])
            return buffer
        } catch {
            let ns = error as NSError
            AppDiagnostics.log("voice-synthesis-error", [
                "engine": engine.rawValue,
                "errorType": String(describing: type(of: error)),
                "errorCode": ns.code
            ])
            throw error
        }
    }

    private static var cachedSystemVoices: (key: String, voices: [AVSpeechSynthesisVoice])?
    private static let foregroundCacheInvalidator: NSObjectProtocol = {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                cachedSystemVoices = nil
            }
        }
    }()

    static func availableSystemVoices() -> [AVSpeechSynthesisVoice] {
        _ = foregroundCacheInvalidator
        let localizations = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        let key = localizations.joined(separator: ",")
        if let cachedSystemVoices, cachedSystemVoices.key == key {
            return cachedSystemVoices.voices
        }
        var preferredLanguages: [String] = []
        for lang in localizations {
            let prefix = String(lang.split(separator: "-").first ?? Substring(lang)).lowercased()
            if !prefix.isEmpty && !preferredLanguages.contains(prefix) {
                preferredLanguages.append(prefix)
            }
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                if #available(iOS 17.0, *) {
                    return !voice.voiceTraits.contains(.isPersonalVoice)
                }
                return true
            }
            .sorted { a, b in
                let aRank = preferredLanguages.firstIndex(where: { a.language.lowercased().hasPrefix($0) }) ?? Int.max
                let bRank = preferredLanguages.firstIndex(where: { b.language.lowercased().hasPrefix($0) }) ?? Int.max
                if aRank != bRank { return aRank < bRank }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if a.language != b.language { return a.language < b.language }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        cachedSystemVoices = (key, voices)
        return voices
    }
}
