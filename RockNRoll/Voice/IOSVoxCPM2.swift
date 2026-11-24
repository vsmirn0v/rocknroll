import AVFoundation
import Combine
import ConferenceCore
import Foundation
import MLXAudioTTS
import UIKit

/// A cloned VoxCPM2 prompt encoded as 16 kHz AudioVAE latents in 4-frame patches (`P * 4 * 64`).
struct VoxVoice: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case clone
        case continuation
        case cloneContinuation = "clone_continuation"
    }

    static let revision = "32279effe8c19989596f05d353d1447f51d9e915"
    var revision = VoxVoice.revision
    var mode: Mode
    var transcript: String
    var reference: [Float]?
    var continuation: [Float]?
    var patches: Int

    static let patchValues = 4 * 64
}

struct StoredClonedVoice: Codable, Equatable, Sendable {
    var voice: VoxVoice
    var recordedAt: Date
    var seconds: Double
}

/// Offline Llama-style BPE tokenizer matching VoxCPM2 `tokenizer.json`.
struct IOSVoxTokenizer {
    private let vocab: [String: Int]
    private let tokens: [Int: String]
    private let merges: [UInt64: (rank: Int, id: Int)]
    private let chineseWords: Set<String>
    private let unknown: Int

    init(url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = root["model"] as? [String: Any],
              model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Int] else {
            throw IOSVoiceSynthesisError.voxRuntimeFailed("tokenizer.json is not a BPE tokenizer")
        }
        guard model["byte_fallback"] as? Bool == true,
              root["pre_tokenizer"] is NSNull || root["pre_tokenizer"] == nil,
              let normalizer = root["normalizer"] as? [String: Any],
              normalizer["type"] as? String == "Sequence",
              let steps = normalizer["normalizers"] as? [[String: Any]],
              steps.count == 2,
              steps[0]["type"] as? String == "Prepend",
              steps[0]["prepend"] as? String == "\u{2581}",
              steps[1]["type"] as? String == "Replace",
              steps[1]["content"] as? String == "\u{2581}",
              (steps[1]["pattern"] as? [String: Any])?["String"] as? String == " " else {
            throw IOSVoiceSynthesisError.voxRuntimeFailed("tokenizer layout differs from VoxCPM2")
        }

        var all = vocab
        for added in root["added_tokens"] as? [[String: Any]] ?? [] {
            if let content = added["content"] as? String, let id = added["id"] as? Int {
                all[content] = id
            }
        }
        self.vocab = all
        self.tokens = Dictionary(all.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        self.unknown = all[model["unk_token"] as? String ?? "<unk>"] ?? 0

        var table: [UInt64: (rank: Int, id: Int)] = [:]
        let lines = model["merges"] as? [Any] ?? []
        table.reserveCapacity(lines.count)
        for (rank, line) in lines.enumerated() {
            var pair: (String, String)?
            if let parts = line as? [String], parts.count == 2 {
                pair = (parts[0], parts[1])
            } else if let text = line as? String {
                var index = text.startIndex
                while let space = text[index...].firstIndex(of: " ") {
                    let left = String(text[..<space])
                    let right = String(text[text.index(after: space)...])
                    if all[left] != nil, all[right] != nil, all[left + right] != nil {
                        pair = (left, right)
                        break
                    }
                    index = text.index(after: space)
                }
            }
            guard let pair, let a = all[pair.0], let b = all[pair.1], let merged = all[pair.0 + pair.1] else {
                throw IOSVoiceSynthesisError.voxRuntimeFailed("tokenizer merge \(rank) is invalid")
            }
            let key = UInt64(UInt32(a)) << 32 | UInt64(UInt32(b))
            if table[key] == nil {
                table[key] = (rank, merged)
            }
        }
        self.merges = table
        self.chineseWords = Set(vocab.keys.filter { word in
            word.unicodeScalars.count >= 2 && word.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        })
    }

    func encode(_ text: String) -> [Int] {
        let normalized = "\u{2581}" + text.replacingOccurrences(of: " ", with: "\u{2581}")
        var symbols: [Int] = []
        symbols.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            let character = String(scalar)
            if let id = vocab[character] {
                symbols.append(id)
            } else {
                let bytes = character.utf8.map { vocab[String(format: "<0x%02X>", $0)] }
                if bytes.allSatisfy({ $0 != nil }) {
                    symbols += bytes.map { $0! }
                } else {
                    symbols.append(unknown)
                }
            }
        }
        while symbols.count > 1 {
            var best: (index: Int, rank: Int, id: Int)?
            for index in 0..<(symbols.count - 1) {
                let key = UInt64(UInt32(symbols[index])) << 32 | UInt64(UInt32(symbols[index + 1]))
                if let merge = merges[key], merge.rank < (best?.rank ?? .max) {
                    best = (index, merge.rank, merge.id)
                }
            }
            guard let best else { break }
            symbols[best.index] = best.id
            symbols.remove(at: best.index + 1)
        }
        var ids: [Int] = []
        ids.reserveCapacity(symbols.count)
        for id in symbols {
            let word = tokens[id].map { $0.replacingOccurrences(of: "\u{2581}", with: "") } ?? ""
            if chineseWords.contains(word) {
                ids += word.unicodeScalars.map { vocab[String($0)] ?? unknown }
            } else {
                ids.append(id)
            }
        }
        return ids
    }
}

/// Audio conversion, transient cleanup, silence trimming, and normalization for VoxCPM2 samples.
enum IOSVoiceSampleAudio {
    static let minimumSeconds = 4.0
    static let maximumSeconds = 30.0
    static let encodeSampleRate = 16_000
    static let outputSampleRate = 48_000

    static func monoSamples(from url: URL, rate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw IOSVoiceSynthesisError.audio
        }
        try file.read(into: input)
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * rate / max(1, file.processingFormat.sampleRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw IOSVoiceSynthesisError.audio
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied {
                state.pointee = .endOfStream
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil, let channel = output.floatChannelData else {
            throw IOSVoiceSynthesisError.audio
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    static func suppressEdgeTransients(_ samples: [Float], rate: Int) -> [Float] {
        guard samples.count >= Int(Double(rate) * 1.5) else { return samples }
        let leadCount = min(Int(0.20 * Double(rate)), samples.count / 6)
        let tailCount = min(Int(0.30 * Double(rate)), samples.count / 6)
        let interiorEnd = samples.count - tailCount
        guard leadCount < interiorEnd else { return samples }

        let chunk = 256
        var chunkPeaks: [Float] = []
        chunkPeaks.reserveCapacity((interiorEnd - leadCount) / chunk + 1)
        var index = leadCount
        while index < interiorEnd {
            let chunkEnd = min(index + chunk, interiorEnd)
            var peak: Float = 0
            for pos in index..<chunkEnd {
                let mag = abs(samples[pos])
                if mag > peak { peak = mag }
            }
            chunkPeaks.append(peak)
            index = chunkEnd
        }
        guard !chunkPeaks.isEmpty else { return samples }
        chunkPeaks.sort()
        let refPeak = chunkPeaks[Int(Double(chunkPeaks.count - 1) * 0.95)]
        guard refPeak > 1e-5 else { return samples }

        var cleaned = samples
        let cap = refPeak * 2.5

        var leadMax: Float = 0
        for i in 0..<leadCount {
            let mag = abs(cleaned[i])
            if mag > leadMax { leadMax = mag }
        }
        if leadMax > cap {
            for i in 0..<leadCount where abs(cleaned[i]) > refPeak {
                cleaned[i] = 0
            }
        }

        let tailStart = interiorEnd
        var tailMax: Float = 0
        for i in tailStart..<cleaned.count {
            let mag = abs(cleaned[i])
            if mag > tailMax { tailMax = mag }
        }
        if tailMax > cap, let tapOnset = (tailStart..<cleaned.count).first(where: { abs(cleaned[$0]) > cap }) {
            let wipeFrom = max(tailStart, tapOnset - Int(0.02 * Double(rate)))
            for i in wipeFrom..<cleaned.count {
                cleaned[i] = 0
            }
        }
        return cleaned
    }

    static func trimSilence(_ input: [Float], rate: Int, topDecibels: Float = 28, margin: Double = 0.2) -> [Float] {
        let (cleaned, range) = trimSpeechRange(input, rate: rate, topDecibels: topDecibels, margin: margin)
        guard !range.isEmpty else { return [] }
        return Array(cleaned[range])
    }

    static func normalizeSpeech(_ samples: [Float], targetPeak: Float = 0.75, maxGain: Float = 25.0) -> [Float] {
        guard let peak = samples.map(abs).max(), peak > 1e-4 else { return samples }
        let gain = min(maxGain, targetPeak / peak)
        if abs(gain - 1.0) < 0.05 { return samples }
        return samples.map { max(-0.98, min(0.98, $0 * gain)) }
    }

    static func prepareEnrollmentSamples(_ raw: [Float], rate: Int) throws -> (samples: [Float], duration: Double) {
        let (cleaned, range) = trimSpeechRange(raw, rate: rate)
        let rawDuration = Double(raw.count) / Double(rate)
        let trimmedDuration = Double(range.count) / Double(rate)

        let finalSamples: [Float]
        if trimmedDuration < minimumSeconds {
            guard rawDuration >= minimumSeconds, trimmedDuration >= 3.2 else {
                throw IOSVoiceSynthesisError.voxSampleTooShort(Int(minimumSeconds))
            }
            let targetCount = min(cleaned.count, Int((minimumSeconds * Double(rate)).rounded(.up)))
            let mid = (range.lowerBound + range.upperBound) / 2
            var lower = max(0, mid - targetCount / 2)
            let upper = min(cleaned.count, lower + targetCount)
            if upper - lower < targetCount {
                lower = max(0, upper - targetCount)
            }
            finalSamples = Array(cleaned[lower..<upper])
        } else {
            finalSamples = Array(cleaned[range])
        }

        let finalDuration = Double(finalSamples.count) / Double(rate)
        guard finalDuration >= minimumSeconds else {
            throw IOSVoiceSynthesisError.voxSampleTooShort(Int(minimumSeconds))
        }
        guard finalDuration <= maximumSeconds else {
            throw IOSVoiceSynthesisError.voxSampleTooLong(Int(maximumSeconds))
        }
        return (normalizeSpeech(finalSamples), finalDuration)
    }

    private static func trimSpeechRange(
        _ input: [Float],
        rate: Int,
        topDecibels: Float = 28,
        margin: Double = 0.2
    ) -> (cleaned: [Float], range: Range<Int>) {
        let samples = suppressEdgeTransients(input, rate: rate)
        let frame = min(1024, max(256, rate / 16))
        let hop = max(128, frame / 4)
        guard samples.count > frame else { return (samples, 0..<samples.count) }

        var rmsValues: [Float] = []
        rmsValues.reserveCapacity((samples.count - frame) / hop + 1)
        var start = 0
        while start + frame <= samples.count {
            var energy: Float = 0
            for index in start..<(start + frame) {
                energy += samples[index] * samples[index]
            }
            rmsValues.append((energy / Float(frame)).squareRoot())
            start += hop
        }

        let nonZero = rmsValues.filter { $0 > 1e-5 }.sorted()
        guard let maxRMS = nonZero.last, maxRMS > 1e-4 else {
            return (samples, 0..<0)
        }
        let refRMS = nonZero[Int(Double(nonZero.count - 1) * 0.95)]
        let threshold = max(1e-4, refRMS * pow(10, -topDecibels / 20))

        let minRun = rmsValues.count >= 6 ? 2 : 1
        var firstFrame: Int?
        var lastFrame: Int?
        var run = 0
        for (index, rms) in rmsValues.enumerated() {
            if rms >= threshold {
                run += 1
                if run >= minRun {
                    if firstFrame == nil {
                        firstFrame = index - (minRun - 1)
                    }
                    lastFrame = index
                }
            } else {
                run = 0
            }
        }

        guard let firstFrame, let lastFrame else {
            return (samples, 0..<0)
        }
        let pad = Int(margin * Double(rate))
        let lower = max(0, firstFrame * hop - pad)
        let upper = min(samples.count, lastFrame * hop + frame + pad)
        return (samples, lower..<upper)
    }

    static func buffer(_ samples: [Float], rate: Double) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else {
            throw IOSVoiceSynthesisError.audio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// Records a 4-30s voice sample outside active meeting calls.
@MainActor
final class IOSVoiceSampleRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var file: URL?

    private let isCallActive: () -> Bool
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var inputMuteLease: UUID?
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ios-voice-sample-\(UUID().uuidString).caf")

    init(isCallActive: @escaping () -> Bool = {
        let mode = AVAudioSession.sharedInstance().mode
        return mode == .voiceChat || mode == .videoChat
    }) {
        self.isCallActive = isCallActive
    }

    deinit {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: url)
    }

    func start() async throws {
        guard !isCallActive() else {
            throw IOSVoiceSynthesisError.voxCallActiveDuringRecording
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw IOSVoiceSynthesisError.microphoneDenied
        }
        stop()
        let lease = ApplicationMicrophoneMute.privateCaptureBridge?.beginPrivateCapture()
        inputMuteLease = lease
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: IOSVoiceSampleAudio.maximumSeconds) else {
                throw IOSVoiceSynthesisError.audio
            }
            self.recorder = recorder
            self.file = nil
            self.seconds = 0
            self.recording = true
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        } catch {
            if let lease {
                inputMuteLease = nil
                ApplicationMicrophoneMute.privateCaptureBridge?.endPrivateCapture(lease)
            }
            if !isCallActive() {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw error
        }
    }

    func stop() {
        let activeRecorder = recorder
        let finalDuration = max(seconds, activeRecorder?.currentTime ?? 0)
        activeRecorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recording = false
        level = 0
        seconds = finalDuration
        if finalDuration > 0, FileManager.default.fileExists(atPath: url.path) {
            file = url
        }
        if let lease = inputMuteLease {
            inputMuteLease = nil
            ApplicationMicrophoneMute.privateCaptureBridge?.endPrivateCapture(lease)
        }
        if activeRecorder != nil, !isCallActive() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func tick() {
        guard let recorder else { return }
        if !recorder.isRecording {
            stop()
            return
        }
        recorder.updateMeters()
        seconds = recorder.currentTime
        level = pow(10, recorder.averagePower(forChannel: 0) / 40)
    }
}

/// Thread-safe foreground state gate polled from background MLX GPU loops to avoid iOS Metal background-execution aborts.
final class IOSVoxForegroundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Bool

    init(isActive: Bool = true) {
        self.active = isActive
    }

    var isActive: Bool {
        lock.withLock { active }
    }

    func setActive(_ value: Bool) {
        lock.withLock { active = value }
    }
}

/// Maps MLX/Metal and VoxCPM2 runtime errors into privacy-safe allowlisted diagnostic reason codes.
enum IOSVoxCPM2ErrorClassifier {
    static func reasonCode(for error: Error) -> String {
        let text = "\(error.localizedDescription)\n\(String(describing: error))".lowercased()
        if text.contains("backgroundexecutionnotpermitted")
            || text.contains("insufficient permission")
            || text.contains("no longer active")
            || text.contains("not active for on-device gpu") {
            return "background"
        }
        if text.contains("outofmemory")
            || text.contains("insufficient memory")
            || text.contains("unable to allocate")
            || text.contains("resource limit") {
            return "metal-oom"
        }
        if text.contains("timeout") {
            return "metal-timeout"
        }
        if text.contains("command buffer execution failed") || text.contains("[metal]") {
            return "metal-command-buffer"
        }
        if text.contains("[eval]") || text.contains("[async_eval]") || text.contains("mlx error:") {
            return "mlx-eval"
        }
        if text.contains("exceed") || text.contains("no generation space") {
            return "context-limit"
        }
        return "other"
    }
}

/// FIFO cancellation-safe gate serializing GPU access across async suspension points.
actor IOSVoxSerialGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    var isBusy: Bool { busy }

    func withExclusiveAccess<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func tryIfIdle<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T? {
        guard !busy else { return nil }
        busy = true
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !busy {
                    busy = true
                    continuation.resume()
                    return
                }
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            busy = false
        }
    }
}

/// Manages in-process MLX GPU lifecycle for `VoxCPM2Model` with strict cache caps, serialization, and idle/memory-pressure unloading.
private actor IOSVoxCPM2Runtime {
    private var loadedDirectory: URL?
    private var loadedModel: VoxCPM2Model?
    private var loadedTokenizer: IOSVoxTokenizer?
    private let gate = IOSVoxSerialGate()
    private var idleUnloadTask: Task<Void, Never>?

    func encodeVoice(
        samples16k: [Float],
        transcript: String,
        mode: VoxVoice.Mode,
        in directory: URL,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async throws -> VoxVoice {
#if targetEnvironment(simulator)
        throw IOSVoiceSynthesisError.voxUnsupportedDevice(IOSVoxCPM2Store.sharedUnsupportedMessage)
#else
        return try await gate.withExclusiveAccess {
            guard shouldContinue() else {
                throw IOSVoiceSynthesisError.voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
            }
            await self.cancelIdleUnload()
            do {
                let (model, _) = try await self.ensureLoaded(directory: directory)
                let encoded = try model.encodeVoicePromptLatents(
                    samples16k: samples16k,
                    includeReference: mode != .continuation,
                    includeContinuation: mode != .clone,
                    shouldContinue: shouldContinue
                )
                VoxCPM2Model.clearMemoryCache()
                await self.scheduleIdleUnload()
                return VoxVoice(
                    mode: mode,
                    transcript: transcript,
                    reference: encoded.reference,
                    continuation: encoded.continuation,
                    patches: encoded.patches
                )
            } catch {
                await self.handleFailure(error)
                throw error
            }
        }
#endif
    }

    func clearSavedVoiceCache() {
        loadedModel?.clearSavedVoiceCache()
    }

    func synthesize(
        text: String,
        voice: VoxVoice?,
        in directory: URL,
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        onAudioChunk: (@Sendable ([Float]) -> Void)? = nil
    ) async throws -> [Float] {
#if targetEnvironment(simulator)
        throw IOSVoiceSynthesisError.voxUnsupportedDevice(IOSVoxCPM2Store.sharedUnsupportedMessage)
#else
        return try await gate.withExclusiveAccess {
            guard shouldContinue() else {
                throw IOSVoiceSynthesisError.voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
            }
            let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }

            await self.cancelIdleUnload()
            do {
                let (model, tokenizer) = try await self.ensureLoaded(directory: directory)
                let samples: [Float]
                if let voice {
                    guard voice.revision == VoxVoice.revision else {
                        throw IOSVoiceSynthesisError.voxRuntimeFailed("Saved voice revision differs from model.")
                    }
                    let prefix = voice.continuation != nil ? voice.transcript : ""
                    let ids = tokenizer.encode(prefix + clean)
                    samples = try await model.synthesizeSavedVoiceSamples(
                        text: clean,
                        transcript: voice.transcript,
                        patches: voice.patches,
                        reference: voice.reference,
                        continuation: voice.continuation,
                        tokenIDs: ids,
                        maxTokens: 256,
                        shouldContinue: shouldContinue,
                        onAudioChunk: onAudioChunk
                    )
                } else {
                    let ids = tokenizer.encode(clean)
                    samples = try await model.synthesizeZeroShotSamples(
                        text: clean,
                        tokenIDs: ids,
                        maxTokens: 256,
                        shouldContinue: shouldContinue,
                        onAudioChunk: onAudioChunk
                    )
                }
                VoxCPM2Model.clearMemoryCache()
                await self.scheduleIdleUnload()
                return samples
            } catch {
                await self.handleFailure(error)
                throw error
            }
        }
#endif
    }

    func streamSynthesize(
        text: String,
        voice: VoxVoice?,
        in directory: URL,
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        onChunk: @escaping @Sendable ([Float]) -> Void
    ) async throws -> [Float] {
        try await synthesize(
            text: text,
            voice: voice,
            in: directory,
            shouldContinue: shouldContinue,
            onAudioChunk: onChunk
        )
    }

    func unloadIfIdle() async {
        await gate.tryIfIdle {
            await self.performUnload()
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func handleFailure(_ error: Error) {
        if !(error is CancellationError) && (error as? IOSVoiceSynthesisError) != .empty {
            performUnload()
        } else {
            #if !targetEnvironment(simulator)
            VoxCPM2Model.clearMemoryCache()
            #endif
            scheduleIdleUnload()
        }
    }

    private func performUnload() {
        let hadModel = loadedModel != nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        loadedModel?.clearSavedVoiceCache()
        loadedModel = nil
        loadedTokenizer = nil
        loadedDirectory = nil
        #if !targetEnvironment(simulator)
        if hadModel {
            VoxCPM2Model.clearMemoryCache()
        }
        #else
        _ = hadModel
        #endif
    }

    private func ensureLoaded(directory: URL) async throws -> (VoxCPM2Model, IOSVoxTokenizer) {
        if let model = loadedModel, let tokenizer = loadedTokenizer, loadedDirectory == directory {
            return (model, tokenizer)
        }
        #if !targetEnvironment(simulator)
        VoxCPM2Model.configureMemoryLimit(cacheBytes: 256 * 1024 * 1024)
        #endif
        let model = try await VoxCPM2Model.fromModelDirectory(directory, hfToken: nil, loadTokenizer: false)
        let tokenizer = try IOSVoxTokenizer(url: directory.appendingPathComponent("tokenizer.json"))
        self.loadedModel = model
        self.loadedTokenizer = tokenizer
        self.loadedDirectory = directory
        return (model, tokenizer)
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(180))
                await self?.unloadIfIdle()
            } catch {}
        }
    }
}

@MainActor
final class IOSVoxCPM2Store: ObservableObject {
    static let shared = IOSVoxCPM2Store()

    private enum Keys {
        static let useClonedVoice = "ios.voxcpm2.useClonedVoice"
    }

    static let minimumPhysicalMemoryBytes: UInt64 = 7_000_000_000
    static let minimumFreeDiskBytes: Int64 = 3_500_000_000
    static let revision = "dc9e5c187858da5f4a13dc4c247e297339216381"
    static let repository = "mlx-community/VoxCPM2-4bit"

    static let modelFiles: [PinnedModelFile] = {
        let base = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/")!
        let entries: [(String, Int64, String)] = [
            ("config.json", 5_332, "91bff6db1be27bc0f4f2a287cca7a8fbb8b1d7a0b026a5dc4a71bc5f2f1ddcfb"),
            ("model.safetensors", 2_297_215_329, "25bddc99a7cc6d28214f12dd676ed0afa9b0a805d6477f85c275bb113cb8acee"),
            ("special_tokens_map.json", 1_632, "068594063e37662c02b21acf42ebb334ef6a74fb810e68a2368f88f08351de76"),
            ("tokenizer.json", 3_676_772, "f8984687e4a92a3503d521396d454b7d68e9fdaab2a0288eb3536c7c1aa4bc20"),
            ("tokenizer_config.json", 4_952, "466575c55f0cf49530666c2e46ed14f26237dbd227ba7f4bb3bbec93df90edfc")
        ]
        return entries.map { name, size, sha in
            PinnedModelFile(relativePath: name, byteCount: size, sha256Hex: sha, url: base.appendingPathComponent(name))
        }
    }()

    static var isDeviceSupportedByHardware: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return ProcessInfo.processInfo.physicalMemory >= minimumPhysicalMemoryBytes
        #endif
    }

    var isDeviceSupported: Bool {
        hardwareSupportedProvider()
    }

    nonisolated static var sharedUnsupportedMessage: String {
        #if targetEnvironment(simulator)
        return L("VoxCPM2 requires a physical iPhone or iPad with Metal GPU and at least 8 GB of RAM.")
        #else
        return L("VoxCPM2 requires a device with at least 8 GB of RAM (iPhone 15 Pro / 16 / 17 or newer).")
        #endif
    }

    var unsupportedReason: String {
        Self.sharedUnsupportedMessage
    }

    @Published private(set) var installState: IOSModelInstallState = .notInstalled
    @Published private(set) var storedVoice: StoredClonedVoice?
    @Published var useClonedVoice: Bool {
        didSet { preferences.set(useClonedVoice, forKey: Keys.useClonedVoice) }
    }
    @Published private(set) var isWorking = false

    var modelDirectory: URL {
        modelsDirectory.appendingPathComponent("voxcpm2-mlx-4bit", isDirectory: true)
    }

    private var savedVoiceURL: URL {
        modelsDirectory.appendingPathComponent("voxcpm2-saved-voice.json")
    }

    private let modelsDirectory: URL
    private let preferences: UserDefaults
    private let downloader: IOSListenModelStore.FileDownloader
    private let hardwareSupportedProvider: () -> Bool
    private let freeDiskBytesProvider: (URL) -> Int64?
    private let foregroundActiveProvider: (@Sendable () -> Bool)?
    private let synthesizeOverride: (@Sendable (String, VoxVoice?, URL, @escaping @Sendable () -> Bool) async throws -> [Float])?
    private let streamSynthesizeOverride: (@Sendable (String, VoxVoice?, URL, @escaping @Sendable () -> Bool, @escaping @Sendable ([Float]) -> Void) async throws -> [Float])?
    private let runtime = IOSVoxCPM2Runtime()
    private let foregroundGate: IOSVoxForegroundGate
    private var downloadTask: Task<Void, Never>?
    private var activeWorkCount = 0
    private var memoryObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        modelsDirectory: URL? = nil,
        preferences: UserDefaults = .standard,
        downloader: IOSListenModelStore.FileDownloader? = nil,
        hardwareSupportedProvider: (() -> Bool)? = nil,
        freeDiskBytesProvider: ((URL) -> Int64?)? = nil,
        foregroundActiveProvider: (@Sendable () -> Bool)? = nil,
        synthesizeOverride: (@Sendable (String, VoxVoice?, URL, @escaping @Sendable () -> Bool) async throws -> [Float])? = nil,
        streamSynthesizeOverride: (@Sendable (String, VoxVoice?, URL, @escaping @Sendable () -> Bool, @escaping @Sendable ([Float]) -> Void) async throws -> [Float])? = nil
    ) {
        self.modelsDirectory = modelsDirectory ?? IOSListenModelStore.defaultModelsDirectory
        self.preferences = preferences
        self.downloader = downloader ?? IOSListenModelStore.streamDownload
        self.hardwareSupportedProvider = hardwareSupportedProvider ?? { Self.isDeviceSupportedByHardware }
        self.freeDiskBytesProvider = freeDiskBytesProvider ?? Self.defaultFreeDiskBytes
        self.foregroundActiveProvider = foregroundActiveProvider
        self.synthesizeOverride = synthesizeOverride
        self.streamSynthesizeOverride = streamSynthesizeOverride
        self.foregroundGate = IOSVoxForegroundGate(isActive: UIApplication.shared.applicationState == .active)

        if preferences.object(forKey: Keys.useClonedVoice) != nil {
            self.useClonedVoice = preferences.bool(forKey: Keys.useClonedVoice)
        } else {
            self.useClonedVoice = true
        }

        loadStoredVoice()
        refreshInstallState()
        let center = NotificationCenter.default
        let runtime = self.runtime
        let gate = self.foregroundGate
        self.memoryObserver = center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await runtime.unloadIfIdle() }
        }
        self.lifecycleObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
                gate.setActive(false)
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                gate.setActive(false)
                Task { await runtime.unloadIfIdle() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                gate.setActive(true)
            }
        ]
    }

    deinit {
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var currentForegroundCheck: @Sendable () -> Bool {
        foregroundActiveProvider ?? { [foregroundGate] in foregroundGate.isActive }
    }

    static func hasAllFilesInstalled(in directory: URL) -> Bool {
        for spec in modelFiles {
            let fileURL = directory.appendingPathComponent(spec.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return false
            }
        }
        return true
    }

    func refreshInstallState() {
        if case .downloading = installState { return }
        installState = Self.hasAllFilesInstalled(in: modelDirectory) ? .installed : .notInstalled
    }

    func downloadModel() {
        guard isDeviceSupported else {
            installState = .failed(unsupportedReason)
            return
        }
        guard downloadTask == nil else { return }
        if let freeBytes = freeDiskBytesProvider(modelsDirectory), freeBytes < Self.minimumFreeDiskBytes {
            installState = .failed(IOSVoiceSynthesisError.voxNotEnoughDiskSpace.localizedDescription)
            return
        }

        installState = .downloading(progress: 0)
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                try await self.performDownload()
                self.installState = .installed
            } catch is CancellationError {
                self.refreshInstallState()
            } catch {
                self.installState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshInstallState()
    }

    func deleteModel(voiceStore: IOSVoiceStore? = nil) {
        downloadTask?.cancel()
        downloadTask = nil
        Task { await runtime.unloadIfIdle() }
        try? FileManager.default.removeItem(at: modelDirectory)
        installState = .notInstalled
        if let voiceStore, voiceStore.engine == .voxCPM2 {
            voiceStore.engine = .system
        }
    }

    func enrollVoice(from audioURL: URL, transcript: String, mode: VoxVoice.Mode = .cloneContinuation) async throws {
        guard isDeviceSupported else {
            throw IOSVoiceSynthesisError.voxUnsupportedDevice(unsupportedReason)
        }
        guard Self.hasAllFilesInstalled(in: modelDirectory) else {
            throw IOSVoiceSynthesisError.voxModelNotInstalled
        }
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranscript.isEmpty else {
            throw IOSVoiceSynthesisError.voxTranscriptMissing
        }
        let shouldContinue = currentForegroundCheck
        guard shouldContinue() else {
            AppDiagnostics.log("voxcpm2-synthesis-skipped", ["reason": "background", "stage": "enroll"])
            throw IOSVoiceSynthesisError.voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
        }

        activeWorkCount += 1
        isWorking = true
        defer {
            activeWorkCount = max(0, activeWorkCount - 1)
            isWorking = activeWorkCount > 0
        }

        do {
            let (samples, seconds) = try await Task.detached(priority: .userInitiated) { () throws -> ([Float], Double) in
                let rate = IOSVoiceSampleAudio.encodeSampleRate
                let raw = try IOSVoiceSampleAudio.monoSamples(from: audioURL, rate: Double(rate))
                return try IOSVoiceSampleAudio.prepareEnrollmentSamples(raw, rate: rate)
            }.value

            let voice = try await runtime.encodeVoice(
                samples16k: samples,
                transcript: cleanTranscript,
                mode: mode,
                in: modelDirectory,
                shouldContinue: shouldContinue
            )
            let saved = StoredClonedVoice(voice: voice, recordedAt: Date(), seconds: seconds)
            try persistVoice(saved)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppDiagnostics.log("voxcpm2-synthesis-failed", [
                "reason": IOSVoxCPM2ErrorClassifier.reasonCode(for: error),
                "stage": "enroll",
                "foreground": shouldContinue()
            ])
            throw error
        }
    }

    func persistVoice(_ value: StoredClonedVoice) throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        IOSListenModelStore.excludeFromBackup(modelsDirectory)
        let data = try JSONEncoder().encode(value)
        try data.write(to: savedVoiceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        IOSListenModelStore.excludeFromBackup(savedVoiceURL)
        storedVoice = value
        Task { await runtime.clearSavedVoiceCache() }
    }

    func deleteSavedVoice() {
        try? FileManager.default.removeItem(at: savedVoiceURL)
        storedVoice = nil
        Task { await runtime.clearSavedVoiceCache() }
    }

    func speak(_ text: String) async throws -> AVAudioPCMBuffer {
        let (clean, activeVoice) = try validateSpeakRequest(text)
        return try await synthesizeAudioBuffer(text: clean, voice: activeVoice, stage: "speak")
    }

    func streamSpeak(_ text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        do {
            let (clean, activeVoice) = try validateSpeakRequest(text)
            return streamAudioBuffer(text: clean, voice: activeVoice, stage: "speak")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func speakPreset(_ text: String, preset: AssistantVoxVoicePreset) async throws -> AVAudioPCMBuffer {
        let prompt = try validatePresetRequest(text, preset: preset)
        return try await synthesizeAudioBuffer(text: prompt, voice: nil, stage: "preset")
    }

    func streamSpeakPreset(_ text: String, preset: AssistantVoxVoicePreset) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        do {
            let prompt = try validatePresetRequest(text, preset: preset)
            return streamAudioBuffer(text: prompt, voice: nil, stage: "preset")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func speakClonedForAssistant(_ text: String) async throws -> AVAudioPCMBuffer {
        let (clean, voice) = try validateClonedAssistantRequest(text)
        return try await synthesizeAudioBuffer(text: clean, voice: voice, stage: "cloned")
    }

    func streamSpeakClonedForAssistant(_ text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        do {
            let (clean, voice) = try validateClonedAssistantRequest(text)
            return streamAudioBuffer(text: clean, voice: voice, stage: "cloned")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    private func validateSpeakRequest(_ text: String) throws -> (String, VoxVoice?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard isDeviceSupported else {
            throw IOSVoiceSynthesisError.voxUnsupportedDevice(unsupportedReason)
        }
        guard Self.hasAllFilesInstalled(in: modelDirectory) else {
            throw IOSVoiceSynthesisError.voxModelNotInstalled
        }
        if useClonedVoice && storedVoice == nil {
            throw IOSVoiceSynthesisError.voxVoiceNotRecorded
        }
        return (clean, useClonedVoice ? storedVoice?.voice : nil)
    }

    private func validatePresetRequest(_ text: String, preset: AssistantVoxVoicePreset) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard isDeviceSupported else {
            throw IOSVoiceSynthesisError.voxUnsupportedDevice(unsupportedReason)
        }
        guard Self.hasAllFilesInstalled(in: modelDirectory) else {
            throw IOSVoiceSynthesisError.voxModelNotInstalled
        }
        let prompt = preset.formattedPrompt(for: clean)
        guard !prompt.isEmpty else { throw IOSVoiceSynthesisError.empty }
        return prompt
    }

    private func validateClonedAssistantRequest(_ text: String) throws -> (String, VoxVoice) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard isDeviceSupported else {
            throw IOSVoiceSynthesisError.voxUnsupportedDevice(unsupportedReason)
        }
        guard Self.hasAllFilesInstalled(in: modelDirectory) else {
            throw IOSVoiceSynthesisError.voxModelNotInstalled
        }
        guard let voice = storedVoice?.voice else {
            throw IOSVoiceSynthesisError.voxVoiceNotRecorded
        }
        return (clean, voice)
    }

    private final class StreamChunkTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var emitted = false
        private var cancelled = false
        func markEmitted() {
            lock.lock()
            emitted = true
            lock.unlock()
        }
        var didEmit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return emitted
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private func streamAudioBuffer(text: String, voice: VoxVoice?, stage: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let shouldContinueBase = currentForegroundCheck
        guard shouldContinueBase() else {
            AppDiagnostics.log("voxcpm2-synthesis-skipped", ["reason": "background", "stage": stage])
            return AsyncThrowingStream {
                $0.finish(throwing: IOSVoiceSynthesisError.voxRuntimeFailed("App is not active for on-device GPU speech synthesis."))
            }
        }
        if streamSynthesizeOverride == nil, synthesizeOverride != nil {
            return AsyncThrowingStream { continuation in
                let producer = Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    do {
                        let buffer = try await self.synthesizeAudioBuffer(text: text, voice: voice, stage: stage)
                        continuation.yield(buffer)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { termination in
                    if case .cancelled = termination { producer.cancel() }
                }
            }
        }

        let directory = modelDirectory
        let runtime = self.runtime
        let streamOverride = self.streamSynthesizeOverride
        let rate = Double(IOSVoiceSampleAudio.outputSampleRate)
        let tracker = StreamChunkTracker()
        return AsyncThrowingStream { continuation in
            let producer = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                self.activeWorkCount += 1
                self.isWorking = true
                defer {
                    self.activeWorkCount = max(0, self.activeWorkCount - 1)
                    self.isWorking = self.activeWorkCount > 0
                }
                let guardedShouldContinue: @Sendable () -> Bool = {
                    !tracker.isCancelled && shouldContinueBase()
                }
                do {
                    let onChunk: @Sendable ([Float]) -> Void = { chunkSamples in
                        guard !chunkSamples.isEmpty,
                              let buffer = try? IOSVoiceSampleAudio.buffer(chunkSamples, rate: rate) else { return }
                        tracker.markEmitted()
                        continuation.yield(buffer)
                    }
                    let samples: [Float]
                    if let streamOverride {
                        samples = try await streamOverride(text, voice, directory, guardedShouldContinue, onChunk)
                    } else {
                        samples = try await runtime.streamSynthesize(
                            text: text,
                            voice: voice,
                            in: directory,
                            shouldContinue: guardedShouldContinue,
                            onChunk: onChunk
                        )
                    }
                    if !tracker.didEmit {
                        let full = try IOSVoiceSampleAudio.buffer(samples, rate: rate)
                        continuation.yield(full)
                    }
                    continuation.finish()
                } catch let error as IOSVoiceSynthesisError {
                    AppDiagnostics.log("voxcpm2-synthesis-failed", [
                        "reason": IOSVoxCPM2ErrorClassifier.reasonCode(for: error),
                        "stage": stage,
                        "foreground": shouldContinueBase()
                    ])
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    AppDiagnostics.log("voxcpm2-synthesis-failed", [
                        "reason": IOSVoxCPM2ErrorClassifier.reasonCode(for: error),
                        "stage": stage,
                        "foreground": shouldContinueBase()
                    ])
                    continuation.finish(throwing: IOSVoiceSynthesisError.voxRuntimeFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    tracker.cancel()
                    producer.cancel()
                }
            }
        }
    }

    private func synthesizeAudioBuffer(text: String, voice: VoxVoice?, stage: String) async throws -> AVAudioPCMBuffer {
        let shouldContinue = currentForegroundCheck
        guard shouldContinue() else {
            AppDiagnostics.log("voxcpm2-synthesis-skipped", ["reason": "background", "stage": stage])
            throw IOSVoiceSynthesisError.voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
        }

        activeWorkCount += 1
        isWorking = true
        defer {
            activeWorkCount = max(0, activeWorkCount - 1)
            isWorking = activeWorkCount > 0
        }

        do {
            let samples: [Float]
            if let synthesizeOverride {
                samples = try await synthesizeOverride(text, voice, modelDirectory, shouldContinue)
            } else {
                samples = try await runtime.synthesize(
                    text: text,
                    voice: voice,
                    in: modelDirectory,
                    shouldContinue: shouldContinue
                )
            }
            return try IOSVoiceSampleAudio.buffer(samples, rate: Double(IOSVoiceSampleAudio.outputSampleRate))
        } catch let error as IOSVoiceSynthesisError {
            AppDiagnostics.log("voxcpm2-synthesis-failed", [
                "reason": IOSVoxCPM2ErrorClassifier.reasonCode(for: error),
                "stage": stage,
                "foreground": shouldContinue()
            ])
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppDiagnostics.log("voxcpm2-synthesis-failed", [
                "reason": IOSVoxCPM2ErrorClassifier.reasonCode(for: error),
                "stage": stage,
                "foreground": shouldContinue()
            ])
            throw IOSVoiceSynthesisError.voxRuntimeFailed(error.localizedDescription)
        }
    }

    func unloadModelFromMemory() {
        Task { await runtime.unloadIfIdle() }
    }

    private func loadStoredVoice() {
        guard let data = try? Data(contentsOf: savedVoiceURL),
              let saved = try? JSONDecoder().decode(StoredClonedVoice.self, from: data),
              saved.voice.revision == VoxVoice.revision else {
            storedVoice = nil
            return
        }
        storedVoice = saved
    }

    private func performDownload() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        IOSListenModelStore.excludeFromBackup(modelsDirectory)

        let staging = modelsDirectory.appendingPathComponent(".staging-voxcpm2-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let totalBytes = Double(Self.modelFiles.reduce(Int64(0)) { $0 + $1.byteCount })
        var completedBytes: Int64 = 0

        for spec in Self.modelFiles {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(spec.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let baseDone = completedBytes
            try await downloader(spec.url, dest) { [weak self] written in
                let fraction = min(0.99, Double(baseDone + written) / max(1, totalBytes))
                Task { @MainActor [weak self] in
                    self?.installState = .downloading(progress: fraction)
                }
            }
            try Task.checkCancellation()
            try await IOSListenModelStore.verifyFileAsync(at: dest, expectedBytes: spec.byteCount, expectedSHA256: spec.sha256Hex)
            completedBytes += spec.byteCount
            installState = .downloading(progress: min(0.99, Double(completedBytes) / max(1, totalBytes)))
        }

        let target = modelDirectory
        let backup = modelsDirectory.appendingPathComponent(".backup-voxcpm2-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: staging, to: target)
            IOSListenModelStore.excludeFromBackup(target)
            try? fm.removeItem(at: backup)
        } catch {
            if fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    private static func defaultFreeDiskBytes(for url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }
}
