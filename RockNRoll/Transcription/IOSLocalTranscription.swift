import Accelerate
import AVFoundation
import Combine
import ConferenceCore
import Foundation
import MeetingEngine
import Speech

/// Ordered speaker timeline for attributing local transcription bursts by timestamp.
struct IOSSpeakingTimeline {
    struct Turn: Equatable {
        let speaker: String?
        let timestamp: Date
    }

    private(set) var turns: [Turn] = []
    private let maxTurns = 128

    mutating func record(speaker: String?, at date: Date = Date()) {
        let clean = speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = clean?.isEmpty == false ? clean : nil
        if turns.last?.speaker == normalized { return }
        turns.append(Turn(speaker: normalized, timestamp: date))
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    func speaker(near date: Date) -> String? {
        turns.last(where: { $0.timestamp <= date.addingTimeInterval(0.35) })?.speaker ?? turns.last?.speaker
    }

    mutating func reset() {
        turns.removeAll()
    }
}

/// Converts arbitrary PCM buffers to `16 kHz` mono `Float` samples without locking audio threads.
final class IOSPCM16kConverter {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var sourceFormatKey: String?
    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        if format.sampleRate == 16_000,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        let key = "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
        if key != sourceFormatKey || converter == nil {
            sourceFormatKey = key
            converter = AVAudioConverter(from: format, to: Self.targetFormat)
        }
        guard let converter else { return [] }

        let ratio = Self.targetFormat.sampleRate / max(1, format.sampleRate)
        let capacity = AVAudioFrameCount(max(64, Int(ceil(Double(frameCount) * ratio)) + 32))
        let converted: AVAudioPCMBuffer
        if let existing = outputBuffer, existing.frameCapacity >= capacity {
            existing.frameLength = 0
            converted = existing
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
                return []
            }
            outputBuffer = created
            converted = created
        }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil,
              converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

enum IOSTranscriptionState: Equatable {
    case off
    case starting
    case active(IOSListenModel)
    case paused(String)
    case unavailable(String)

    var isRunning: Bool {
        switch self {
        case .starting, .active: return true
        default: return false
        }
    }
}

/// Owns off-main-thread PCM routing and recognition pipelines so high-frequency audio frames
/// never hop onto `@MainActor` before entering `workerQueue`.
private final class AudioIngressRouter: @unchecked Sendable {
    private let workerQueue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.ios-transcription", autoreleaseFrequency: .workItem)
    private let lock = NSLock()

    private var running = false
    private var audioTapOnly = false
    private var localMicOnly = false
    private var backend: IOSListenModel = .appleSpeech
    private var language: IOSTranscriptionLanguage = .english
    private var gigaam: (any IOSGigaAMTranscribing)?
    private var localSpeaker = ""
    private var speakerNames: [String: String] = [:]
    private var pendingWorkCount = 0
    private var audibleTailUntil: [String: TimeInterval] = [:]
    private var lastSilentSweepScheduleUptime: TimeInterval = 0
    private static let maxPendingWorkCount = 64
    private static let audiblePeakThreshold: Float = 1e-4
    private static let silenceHangoverSeconds: TimeInterval = 1.2
    private static let idlePipelineTTLSeconds: TimeInterval = 60
    private static let idleSweepIntervalSeconds: TimeInterval = 15

    // Worker-queue-only state
    private var pipelines: [String: SpeakerPipeline] = [:]
    private var rawConverters: [String: IOSPCM16kConverter] = [:]
    private var timeline = IOSSpeakingTimeline()
    private var lastIdleSweepUptime: TimeInterval = 0

    var onText: (@Sendable (String, String?, String, Bool, Date) -> Void)?
    private var onPCM16Audio: (@Sendable (String, Data) -> Void)?

    init() {}

    static func hasAudibleSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return false }
        let format = buffer.format
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            for ab in audioBuffers {
                let expected = frames * max(1, Int(ab.mNumberChannels))
                let count = min(expected, Int(ab.mDataByteSize) / MemoryLayout<Float>.size)
                guard count > 0, let ptr = ab.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var peak: Float = 0
                vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(count))
                if peak >= audiblePeakThreshold { return true }
            }
            return false
        case .pcmFormatInt16:
            let intThreshold = Int16(max(4, Int((audiblePeakThreshold * 32768.0).rounded())))
            for ab in audioBuffers {
                let expected = frames * max(1, Int(ab.mNumberChannels))
                let count = min(expected, Int(ab.mDataByteSize) / MemoryLayout<Int16>.size)
                guard count > 0, let ptr = ab.mData?.assumingMemoryBound(to: Int16.self) else { continue }
                for i in 0..<count {
                    let s = ptr[i]
                    let mag = s == .min ? Int16.max : abs(s)
                    if mag >= intThreshold { return true }
                }
            }
            return false
        case .pcmFormatInt32:
            let intThreshold = Int32(max(256, Int64((Double(audiblePeakThreshold) * 2_147_483_648.0).rounded())))
            for ab in audioBuffers {
                let expected = frames * max(1, Int(ab.mNumberChannels))
                let count = min(expected, Int(ab.mDataByteSize) / MemoryLayout<Int32>.size)
                guard count > 0, let ptr = ab.mData?.assumingMemoryBound(to: Int32.self) else { continue }
                for i in 0..<count {
                    let s = ptr[i]
                    let mag = s == .min ? Int32.max : abs(s)
                    if mag >= intThreshold { return true }
                }
            }
            return false
        default:
            return true
        }
    }

    func setPCM16AudioHandler(_ handler: (@Sendable (String, Data) -> Void)?) {
        lock.withLock { onPCM16Audio = handler }
    }

    func updateMetadata(
        running: Bool,
        audioTapOnly: Bool = false,
        localMicOnly: Bool = false,
        backend: IOSListenModel,
        language: IOSTranscriptionLanguage,
        gigaam: (any IOSGigaAMTranscribing)?,
        localSpeaker: String,
        speakerNames: [String: String]
    ) {
        lock.withLock {
            self.running = running
            self.audioTapOnly = audioTapOnly
            self.localMicOnly = localMicOnly
            self.backend = backend
            self.language = language
            self.gigaam = gigaam
            self.localSpeaker = localSpeaker
            self.speakerNames = speakerNames
            if localMicOnly && onPCM16Audio == nil {
                let localTail = audibleTailUntil["local"]
                audibleTailUntil.removeAll()
                if let localTail { audibleTailUntil["local"] = localTail }
            }
        }
        workerQueue.async { [self] in
            if !audioTapOnly {
                self.rawConverters.removeAll()
            }
            if localMicOnly {
                for id in Array(self.pipelines.keys) where id != "local" {
                    self.pipelines.removeValue(forKey: id)?.stop()
                }
            }
            for (id, pipeline) in self.pipelines {
                if id == "local" {
                    pipeline.setSpeakerOnWorker(localSpeaker)
                } else if let name = speakerNames[id] {
                    pipeline.setSpeakerOnWorker(name)
                }
            }
        }
    }

    private func scheduleSilentSweepIfNeeded(now: TimeInterval) {
        let shouldDispatch = lock.withLock { () -> Bool in
            guard running, now - lastSilentSweepScheduleUptime >= Self.idleSweepIntervalSeconds else { return false }
            lastSilentSweepScheduleUptime = now
            return true
        }
        guard shouldDispatch else { return }
        workerQueue.async { [self] in
            self.sweepIdlePipelinesIfNeeded(nowUptime: now)
        }
    }

    /// Evaluates capacity and fast peak-amplitude gating on the borrowed buffer before copying PCM
    /// or dispatching onto `workerQueue`.
    func shouldAcceptLocal(_ borrowed: AVAudioPCMBuffer) -> (accept: Bool, isAudible: Bool) {
        let gateState: (canRun: Bool, needsSilenceGate: Bool) = lock.withLock {
            guard running, pendingWorkCount < Self.maxPendingWorkCount else { return (false, false) }
            if audioTapOnly && onPCM16Audio == nil { return (false, false) }
            return (true, onPCM16Audio == nil)
        }
        guard gateState.canRun else { return (false, false) }
        guard gateState.needsSilenceGate else { return (true, true) }

        let audible = Self.hasAudibleSignal(borrowed)
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = lock.withLock { () -> Bool in
            guard running, pendingWorkCount < Self.maxPendingWorkCount else { return false }
            if audible {
                audibleTailUntil["local"] = now + Self.silenceHangoverSeconds
                return true
            }
            guard let until = audibleTailUntil["local"], now < until else { return false }
            return true
        }
        if !accepted { scheduleSilentSweepIfNeeded(now: now) }
        return (accepted, audible)
    }

    /// Evaluates capacity and fast peak-amplitude gating on the borrowed remote WebRTC buffer
    /// so muted/silent participants allocate zero `AVAudioPCMBuffer` copies, `AVAudioConverter`s,
    /// or `SpeakerPipeline`s.
    func shouldAcceptRemote(streamID: String, borrowed: AVAudioPCMBuffer) -> (accept: Bool, isAudible: Bool) {
        let gateState: (canRun: Bool, needsSilenceGate: Bool) = lock.withLock {
            guard running, pendingWorkCount < Self.maxPendingWorkCount else { return (false, false) }
            let effectiveTapOnly = audioTapOnly || localMicOnly
            if effectiveTapOnly && onPCM16Audio == nil { return (false, false) }
            return (true, onPCM16Audio == nil)
        }
        guard gateState.canRun else { return (false, false) }
        guard gateState.needsSilenceGate else { return (true, true) }

        let audible = Self.hasAudibleSignal(borrowed)
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = lock.withLock { () -> Bool in
            guard running, pendingWorkCount < Self.maxPendingWorkCount else { return false }
            let effectiveTapOnly = audioTapOnly || localMicOnly
            if effectiveTapOnly && onPCM16Audio == nil { return false }
            if audible {
                audibleTailUntil[streamID] = now + Self.silenceHangoverSeconds
                return true
            }
            guard let until = audibleTailUntil[streamID], now < until else { return false }
            return true
        }
        if !accepted { scheduleSilentSweepIfNeeded(now: now) }
        return (accepted, audible)
    }

    func enqueueLocal(_ buffer: AVAudioPCMBuffer, isAudible: Bool = true) {
        let state: (running: Bool, tapOnly: Bool, backend: IOSListenModel, language: IOSTranscriptionLanguage, gigaam: (any IOSGigaAMTranscribing)?, speaker: String)? = lock.withLock {
            guard running, pendingWorkCount < Self.maxPendingWorkCount else { return nil }
            pendingWorkCount += 1
            return (running, audioTapOnly, backend, language, gigaam, localSpeaker)
        }
        guard let state else { return }
        workerQueue.async { [self] in
            defer {
                self.lock.withLock {
                    if self.pendingWorkCount > 0 { self.pendingWorkCount -= 1 }
                }
            }
            self.processOnWorker(
                streamID: "local",
                speakerName: state.speaker,
                tapOnly: state.tapOnly,
                backend: state.backend,
                language: state.language,
                gigaam: state.gigaam,
                buffer: buffer,
                isAudible: isAudible
            )
        }
    }

    func enqueueRemote(streamID: String, buffer: AVAudioPCMBuffer, isAudible: Bool = true) {
        let state: (running: Bool, tapOnly: Bool, backend: IOSListenModel, language: IOSTranscriptionLanguage, gigaam: (any IOSGigaAMTranscribing)?, speaker: String?)? = lock.withLock {
            guard running, pendingWorkCount < Self.maxPendingWorkCount else { return nil }
            let effectiveTapOnly = audioTapOnly || localMicOnly
            if effectiveTapOnly && onPCM16Audio == nil {
                return nil
            }
            pendingWorkCount += 1
            return (running, effectiveTapOnly, backend, language, gigaam, speakerNames[streamID])
        }
        guard let state else { return }
        workerQueue.async { [self] in
            defer {
                self.lock.withLock {
                    if self.pendingWorkCount > 0 { self.pendingWorkCount -= 1 }
                }
            }
            self.processOnWorker(
                streamID: streamID,
                speakerName: state.speaker,
                tapOnly: state.tapOnly,
                backend: state.backend,
                language: state.language,
                gigaam: state.gigaam,
                buffer: buffer,
                isAudible: isAudible
            )
        }
    }

    func finishStream(id: String) {
        lock.withLock {
            _ = audibleTailUntil.removeValue(forKey: id)
        }
        workerQueue.async { [self] in
            let closing = self.pipelines.removeValue(forKey: id)
            closing?.finishAndFlush()
            self.rawConverters.removeValue(forKey: id)
        }
    }

    func discardLocalSpeechBuffers() {
        lock.withLock {
            _ = audibleTailUntil.removeValue(forKey: "local")
        }
        workerQueue.async { [self] in
            self.pipelines["local"]?.discardPendingSpeech()
        }
    }

    func stopASRKeepAudioTap() {
        lock.withLock {
            self.running = true
            self.audioTapOnly = true
            self.gigaam = nil
            self.audibleTailUntil.removeAll()
        }
        workerQueue.async { [self] in
            let active = self.pipelines.values
            self.pipelines.removeAll()
            for pipeline in active {
                pipeline.stop()
            }
        }
    }

    func stopAll(resetTimeline: Bool = false) {
        lock.withLock {
            self.running = false
            self.audioTapOnly = false
            self.gigaam = nil
            self.audibleTailUntil.removeAll()
        }
        workerQueue.async { [self] in
            let active = self.pipelines.values
            self.pipelines.removeAll()
            self.rawConverters.removeAll()
            for pipeline in active {
                pipeline.stop()
            }
            if resetTimeline {
                self.timeline.reset()
            }
        }
    }

    func activePipelineCountForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            workerQueue.async { [self] in
                continuation.resume(returning: self.pipelines.count)
            }
        }
    }

    private func sweepIdlePipelinesIfNeeded(nowUptime: TimeInterval) {
        guard nowUptime - lastIdleSweepUptime >= Self.idleSweepIntervalSeconds else { return }
        lastIdleSweepUptime = nowUptime
        guard !pipelines.isEmpty else { return }
        for (id, pipeline) in Array(pipelines) {
            if (nowUptime - pipeline.lastAudibleUptime) >= Self.idlePipelineTTLSeconds {
                pipelines.removeValue(forKey: id)?.finishAndFlush()
            }
        }
    }

    private func processOnWorker(
        streamID: String,
        speakerName: String?,
        tapOnly: Bool,
        backend: IOSListenModel,
        language: IOSTranscriptionLanguage,
        gigaam: (any IOSGigaAMTranscribing)?,
        buffer: AVAudioPCMBuffer,
        isAudible: Bool
    ) {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let isTapOnly = lock.withLock { self.audioTapOnly } || tapOnly
        if isTapOnly {
            let converter = rawConverters[streamID] ?? {
                let created = IOSPCM16kConverter()
                rawConverters[streamID] = created
                return created
            }()
            let samples = converter.convert(buffer)
            if let handler = lock.withLock({ onPCM16Audio }), !samples.isEmpty {
                let pcmData = RealtimeVoiceAudio.floatSamplesToPCM16Data(samples)
                if !pcmData.isEmpty {
                    handler(streamID, pcmData)
                }
            }
            return
        }
        sweepIdlePipelinesIfNeeded(nowUptime: nowUptime)
        let pipeline: SpeakerPipeline
        if let existing = pipelines[streamID] {
            pipeline = existing
            pipeline.setSpeakerOnWorker(speakerName)
        } else {
            if !isAudible && lock.withLock({ onPCM16Audio == nil }) {
                return
            }
            AppDiagnostics.log("local-transcription-audio", ["source": streamID == "local" ? "microphone" : "remote", "backend": backend.rawValue])
            pipeline = SpeakerPipeline(
                streamID: streamID,
                speakerName: speakerName,
                backend: backend,
                language: language,
                gigaam: gigaam,
                workerQueue: workerQueue,
                onSamples16k: { [weak self] stream, samples in
                    guard let self else { return }
                    guard let handler = self.lock.withLock({ self.onPCM16Audio }),
                          !samples.isEmpty else { return }
                    let pcmData = RealtimeVoiceAudio.floatSamplesToPCM16Data(samples)
                    if !pcmData.isEmpty {
                        handler(stream, pcmData)
                    }
                }
            ) { [weak self] stream, speaker, text, isFinal, spokenAt in
                guard let self else { return }
                let resolvedSpeaker = speaker ?? self.timeline.speaker(near: spokenAt)
                self.onText?(stream, resolvedSpeaker, text, isFinal, spokenAt)
            }
            pipelines[streamID] = pipeline
        }
        if isAudible, let speakerName, !speakerName.isEmpty {
            timeline.record(speaker: speakerName)
        }
        pipeline.append(buffer, isAudible: isAudible, nowUptime: nowUptime)
    }
}

private final class SharedGigaAMLeaseBox: @unchecked Sendable {
    enum Lease: Equatable {
        case v3(URL)
        case v4(URL)
    }

    private let lock = NSLock()
    private var lease: Lease?

    func replace(with newLease: Lease?) {
        let previous: Lease? = lock.withLock {
            let old = lease
            lease = newLease
            return old
        }
        switch previous {
        case .v3(let dir):
            CoreMLGigaAMRecognizer.releaseShared(directory: dir)
        case .v4(let dir):
            CoreMLGigaAMV4Recognizer.releaseShared(directory: dir)
        case nil:
            break
        }
    }

    func release() {
        replace(with: nil)
    }

    deinit {
        release()
    }
}

/// Manages real-time speech transcription for one iOS meeting session across remote participants and local microphone input.
@MainActor
final class IOSMeetingTranscriber: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var state: IOSTranscriptionState = .off
    @Published private(set) var isAudioTapOnly = false
    @Published private(set) var isLocalMicrophoneOnly = false

    var isCapturingAudio: Bool { running || isAudioTapOnly }
    var canStartWithoutPermissionPrompt: Bool {
        switch modelStore.effectiveBackend() {
        case .gigaamV4CoreMLInt8:
            return modelStore.installedGigaAMV4DirectoryIfReady() != nil
        case .gigaamV3CoreML:
            return modelStore.installedGigaAMDirectoryIfReady() != nil
        case .appleSpeech:
            return SFSpeechRecognizer.authorizationStatus() == .authorized && localAppleSpeechAvailable()
        }
    }

    var onSegmentsChanged: (([TranscriptSegment]) -> Void)?

    private let modelStore: IOSListenModelStore
    private let localDisplayName: () -> String
    private let participantNameLookup: (String) -> String?
    private let setOutputDemand: (Bool) async -> Bool
    private let gigaamLoader: @Sendable (URL) async throws -> CoreMLGigaAMRecognizer
    private let gigaamV4Loader: @Sendable (URL) async throws -> CoreMLGigaAMV4Recognizer
    private let usesSharedGigaAMLease: Bool
    private let sharedGigaAMLease = SharedGigaAMLeaseBox()
    private let speechAuthorization: @MainActor () async -> Bool
    private let localAppleSpeechAvailable: @MainActor () -> Bool

    private var remoteSources: [MeetingAudioSource] = []
    private var taps: [String: (source: MeetingAudioSource, sink: MeetingAudioSink)] = [:]
    nonisolated private let router = AudioIngressRouter()
    private var currentBackend: IOSListenModel?
    private var gigaamRecognizer: (any IOSGigaAMTranscribing)?
    private var activeRun: UUID?
    private var running: Bool { activeRun != nil }
    private var segmentOrder = 0
    private var activeUtteranceByStream: [String: TranscriptSegment] = [:]
    private var partialPublishTask: Task<Void, Never>?
    var partialSegmentIDs: [String] { activeUtteranceByStream.values.map(\.id) }
    private var finalizedSegments: [TranscriptSegment] = []

    init(
        modelStore: IOSListenModelStore = .shared,
        localDisplayName: @escaping () -> String,
        participantNameLookup: @escaping (String) -> String?,
        setOutputDemand: @escaping (Bool) async -> Bool,
        gigaamLoader: (@Sendable (URL) async throws -> CoreMLGigaAMRecognizer)? = nil,
        speechAuthorization: (@MainActor () async -> Bool)? = nil,
        localAppleSpeechAvailable: (@MainActor () -> Bool)? = nil,
        gigaamV4Loader: (@Sendable (URL) async throws -> CoreMLGigaAMV4Recognizer)? = nil
    ) {
        self.modelStore = modelStore
        self.localDisplayName = localDisplayName
        self.participantNameLookup = participantNameLookup
        self.setOutputDemand = setOutputDemand
        self.usesSharedGigaAMLease = (gigaamLoader == nil && gigaamV4Loader == nil)
        self.speechAuthorization = speechAuthorization ?? Self.requestSpeechAuthorization
        self.localAppleSpeechAvailable = localAppleSpeechAvailable ?? modelStore.appleSpeechAvailableOnDevice
        self.gigaamLoader = gigaamLoader ?? { dir in
            try await CoreMLGigaAMRecognizer.acquireShared(directory: dir)
        }
        self.gigaamV4Loader = gigaamV4Loader ?? { dir in
            try await CoreMLGigaAMV4Recognizer.acquireShared(directory: dir)
        }
        self.router.onText = { [weak self] stream, speaker, text, isFinal, spokenAt in
            Task { @MainActor [weak self] in
                self?.handleRecognition(
                    streamID: stream,
                    speaker: speaker,
                    text: text,
                    isFinal: isFinal,
                    spokenAt: spokenAt
                )
            }
        }
    }

    func setPCM16AudioHandler(_ handler: (@Sendable (String, Data) -> Void)?) {
        router.setPCM16AudioHandler(handler)
    }

    func updateRemoteSources(_ sources: [MeetingAudioSource]) {
        remoteSources = sources
        // Tracks can arrive while the selected recognizer is loading. Bind them after startup
        // so their first PCM buffer cannot create a pipeline using the fallback backend.
        guard isCapturingAudio, isAudioTapOnly || currentBackend != nil else { return }
        syncTaps()
    }

    nonisolated func enqueueLocalAudio(_ buffer: AVAudioPCMBuffer) {
        let decision = router.shouldAcceptLocal(buffer)
        guard decision.accept, let copy = MeetingAudioSink.copy(buffer) else { return }
        router.enqueueLocal(copy, isAudible: decision.isAudible)
    }

    func receiveLocalAudio(_ buffer: AVAudioPCMBuffer) {
        guard isCapturingAudio else { return }
        let decision = router.shouldAcceptLocal(buffer)
        guard decision.accept, let copy = MeetingAudioSink.copy(buffer) else { return }
        pushRouterMetadata()
        router.enqueueLocal(copy, isAudible: decision.isAudible)
    }

    func activePipelineCountForTesting() async -> Int {
        await router.activePipelineCountForTesting()
    }

    /// Streams raw 16 kHz PCM16 audio to Realtime voice providers without running
    /// on-device speech recognition or producing duplicate local transcript lines.
    func startAudioTapOnly() async -> Bool {
        if running || isAudioTapOnly { return true }
        isAudioTapOnly = true
        pushRouterMetadata()
        _ = await setOutputDemand(true)
        guard isAudioTapOnly, !running else { return running || isAudioTapOnly }
        syncTaps()
        return true
    }

    func stopAudioTapOnly() async {
        guard isAudioTapOnly, !running else { return }
        isAudioTapOnly = false
        detachAllTaps()
        router.stopAll(resetTimeline: false)
        _ = await setOutputDemand(false)
    }

    func start() async -> Bool {
        guard !running else { return true }
        isAudioTapOnly = false
        let run = UUID()
        activeRun = run
        state = .starting
        let startedAt = ProcessInfo.processInfo.systemUptime
        let backend = modelStore.effectiveBackend()
        AppDiagnostics.log("local-transcription-start", ["backend": backend.rawValue])

        enum CoreMLStartOutcome {
            case ready
            case cancelled
            case fallbackNeeded
        }

        func attemptCoreML(
            model: IOSListenModel,
            directory: URL,
            lease: SharedGigaAMLeaseBox.Lease,
            load: @Sendable (URL) async throws -> any IOSGigaAMTranscribing,
            release: @Sendable (URL) -> Void
        ) async -> CoreMLStartOutcome {
            do {
                let recognizer = try await load(directory)
                guard activeRun == run else {
                    if usesSharedGigaAMLease { release(directory) }
                    return .cancelled
                }
                if usesSharedGigaAMLease {
                    sharedGigaAMLease.replace(with: lease)
                }
                self.gigaamRecognizer = recognizer
                self.currentBackend = model
                state = .active(model)
                let ms = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
                AppDiagnostics.log("local-transcription-ready", ["backend": model.rawValue, "ms": ms])
                return .ready
            } catch is CancellationError {
                guard activeRun == run else { return .cancelled }
                self.gigaamRecognizer = nil
                sharedGigaAMLease.release()
                activeRun = nil
                if case .starting = state { state = .off }
                return .cancelled
            } catch {
                guard activeRun == run else { return .cancelled }
                modelStore.refreshInstallState()
                return .fallbackNeeded
            }
        }

        var ready = false
        if backend == .gigaamV4CoreMLInt8, let dirV4 = modelStore.installedGigaAMV4DirectoryIfReady() {
            let outcome = await attemptCoreML(
                model: .gigaamV4CoreMLInt8,
                directory: dirV4,
                lease: .v4(dirV4),
                load: gigaamV4Loader,
                release: { CoreMLGigaAMV4Recognizer.releaseShared(directory: $0) }
            )
            switch outcome {
            case .ready: ready = true
            case .cancelled: return false
            case .fallbackNeeded:
                if let dirV3 = modelStore.installedGigaAMDirectoryIfReady() {
                    AppDiagnostics.log("local-transcription-fallback", [
                        "from": IOSListenModel.gigaamV4CoreMLInt8.rawValue,
                        "to": IOSListenModel.gigaamV3CoreML.rawValue
                    ])
                    let v3Outcome = await attemptCoreML(
                        model: .gigaamV3CoreML,
                        directory: dirV3,
                        lease: .v3(dirV3),
                        load: gigaamLoader,
                        release: { CoreMLGigaAMRecognizer.releaseShared(directory: $0) }
                    )
                    switch v3Outcome {
                    case .ready: ready = true
                    case .cancelled: return false
                    case .fallbackNeeded: break
                    }
                }
            }
        } else if backend == .gigaamV3CoreML, let dirV3 = modelStore.installedGigaAMDirectoryIfReady() {
            let outcome = await attemptCoreML(
                model: .gigaamV3CoreML,
                directory: dirV3,
                lease: .v3(dirV3),
                load: gigaamLoader,
                release: { CoreMLGigaAMRecognizer.releaseShared(directory: $0) }
            )
            switch outcome {
            case .ready: ready = true
            case .cancelled: return false
            case .fallbackNeeded: break
            }
        }

        if !ready {
            if backend != .appleSpeech {
                AppDiagnostics.log("local-transcription-fallback", [
                    "from": backend.rawValue,
                    "to": IOSListenModel.appleSpeech.rawValue
                ])
            }
            self.gigaamRecognizer = nil
            sharedGigaAMLease.release()
            guard await startAppleSpeech(for: run) else { return false }
            let ms = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
            AppDiagnostics.log("local-transcription-ready", ["backend": IOSListenModel.appleSpeech.rawValue, "ms": ms])
        }

        guard activeRun == run else { return false }
        pushRouterMetadata()
        _ = await setOutputDemand(true)
        guard activeRun == run else { return false }
        syncTaps()
        return true
    }

    func stop(keepAudioTap: Bool = false) async {
        partialPublishTask?.cancel()
        partialPublishTask = nil
        if keepAudioTap {
            guard running || state != .off else {
                _ = await startAudioTapOnly()
                return
            }
            activeRun = nil
            activeUtteranceByStream.removeAll()
            currentBackend = nil
            gigaamRecognizer = nil
            sharedGigaAMLease.release()
            state = .off
            isAudioTapOnly = true
            router.stopASRKeepAudioTap()
            syncTaps()
            return
        }
        guard running || isAudioTapOnly || state != .off else { return }
        activeRun = nil
        isAudioTapOnly = false
        isLocalMicrophoneOnly = false
        detachAllTaps()
        router.stopAll(resetTimeline: false)
        activeUtteranceByStream.removeAll()
        currentBackend = nil
        gigaamRecognizer = nil
        sharedGigaAMLease.release()
        state = .off
        _ = await setOutputDemand(false)
    }

    func reset() async {
        await stop()
        router.setPCM16AudioHandler(nil)
        router.stopAll(resetTimeline: true)
        finalizedSegments.removeAll()
        activeUtteranceByStream.removeAll()
        segments = []
        onSegmentsChanged?([])
    }

    func discardPendingLocalAudio() {
        router.discardLocalSpeechBuffers()
        if activeUtteranceByStream.removeValue(forKey: "local") != nil {
            publishSegments()
        }
    }

    func setLocalMicrophoneOnly(_ enabled: Bool) {
        guard isLocalMicrophoneOnly != enabled else { return }
        isLocalMicrophoneOnly = enabled
        pushRouterMetadata()
    }

    private func pushRouterMetadata() {
        let rawLocal = localDisplayName().trimmingCharacters(in: .whitespacesAndNewlines)
        let localSpeaker = rawLocal.isEmpty ? L("You") : rawLocal
        var names: [String: String] = [:]
        for source in remoteSources {
            if let resolved = resolvedSpeakerName(for: source), !resolved.isEmpty {
                names[source.id] = resolved
            }
        }
        router.updateMetadata(
            running: (running && currentBackend != nil) || isAudioTapOnly,
            audioTapOnly: isAudioTapOnly && !running,
            localMicOnly: isLocalMicrophoneOnly,
            backend: currentBackend ?? .appleSpeech,
            language: modelStore.language,
            gigaam: gigaamRecognizer,
            localSpeaker: localSpeaker,
            speakerNames: names
        )
    }

    private func startAppleSpeech(for run: UUID) async -> Bool {
        guard activeRun == run else { return false }
        let authorized = await speechAuthorization()
        guard activeRun == run else { return false }
        guard authorized else {
            activeRun = nil
            state = .unavailable(L("Allow Speech Recognition in Settings to transcribe speech on this iPhone."))
            return false
        }
        guard localAppleSpeechAvailable() else {
            activeRun = nil
            state = .unavailable(L("On-device speech recognition is unavailable for %@.", modelStore.language.title))
            return false
        }
        self.currentBackend = .appleSpeech
        state = .active(.appleSpeech)
        return true
    }

    private static func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private func syncTaps() {
        let validIDs = Set(remoteSources.map(\.id))
        for (id, entry) in taps where !validIDs.contains(id) {
            entry.source.detach(entry.sink)
            taps.removeValue(forKey: id)
            router.finishStream(id: id)
        }
        let audioRouter = router
        for source in remoteSources where taps[source.id] == nil {
            let sink = MeetingAudioSink(borrowingBuffersFor: source.id) { id, borrowed in
                let decision = audioRouter.shouldAcceptRemote(streamID: id, borrowed: borrowed)
                guard decision.accept,
                      let copy = MeetingAudioSink.copy(borrowed) else { return }
                audioRouter.enqueueRemote(streamID: id, buffer: copy, isAudible: decision.isAudible)
            }
            source.attach(sink)
            taps[source.id] = (source, sink)
        }
        pushRouterMetadata()
    }

    private func detachAllTaps() {
        for (_, entry) in taps {
            entry.source.detach(entry.sink)
        }
        taps.removeAll()
    }

    private func resolvedSpeakerName(for source: MeetingAudioSource) -> String? {
        if let identity = source.participantIdentity {
            if let mapped = participantNameLookup(identity), !mapped.isEmpty {
                return mapped
            }
            return identity
        }
        return nil
    }

    private func handleRecognition(
        streamID: String,
        speaker: String?,
        text: String,
        isFinal: Bool,
        spokenAt: Date
    ) {
        guard running else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if isFinal {
                activeUtteranceByStream.removeValue(forKey: streamID)
                partialPublishTask?.cancel()
                partialPublishTask = nil
                publishSegments()
            }
            return
        }

        let attributedSpeaker = speaker ?? L("Participant")
        let stableID: String
        let effectiveTime: Date
        if let active = activeUtteranceByStream[streamID] {
            stableID = active.id
            effectiveTime = active.spokenAt ?? spokenAt
        } else {
            segmentOrder += 1
            stableID = "local-\(streamID)-\(segmentOrder)"
            effectiveTime = spokenAt
        }

        let segment = TranscriptSegment(
            id: stableID,
            speaker: attributedSpeaker,
            text: clean,
            spokenAt: effectiveTime,
            isOwn: streamID == "local",
            speakerRole: streamID == "local" ? AssistantSpeechLedger.speakerRoleUser : AssistantSpeechLedger.speakerRoleParticipant
        )

        if isFinal {
            activeUtteranceByStream.removeValue(forKey: streamID)
            if let existingIndex = finalizedSegments.firstIndex(where: { $0.id == stableID }) {
                finalizedSegments[existingIndex] = segment
            } else {
                finalizedSegments.append(segment)
                if finalizedSegments.count > 400 {
                    finalizedSegments.removeFirst(finalizedSegments.count - 400)
                }
            }
            partialPublishTask?.cancel()
            partialPublishTask = nil
            publishSegments()
        } else {
            activeUtteranceByStream[streamID] = segment
            if partialPublishTask == nil {
                partialPublishTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self, !Task.isCancelled, self.running else { return }
                    self.partialPublishTask = nil
                    self.publishSegments()
                }
            }
        }
    }

    private func publishSegments() {
        var combined = finalizedSegments
        for partial in activeUtteranceByStream.values.sorted(by: { ($0.spokenAt ?? .distantFuture) < ($1.spokenAt ?? .distantFuture) }) {
            combined.append(partial)
        }
        segments = combined
        onSegmentsChanged?(combined)
    }
}

private final class SpeakerPipeline {
    private let streamID: String
    private var speakerName: String?
    private let backend: IOSListenModel
    private let language: IOSTranscriptionLanguage
    private let gigaam: (any IOSGigaAMTranscribing)?
    private let workerQueue: DispatchQueue
    private let onSamples16k: (@Sendable (String, [Float]) -> Void)?
    private let onText: (String, String?, String, Bool, Date) -> Void

    private let converter = IOSPCM16kConverter()
    private let vad = IOSVoiceActivityDetector()
    private var stopped = false
    private(set) var lastAudibleUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    var isSpeechActive: Bool {
        vad.isSpeechActive || appleTask != nil
    }

    // Apple Speech state (accessed on workerQueue)
    private var speechRecognizer: SFSpeechRecognizer?
    private var appleRequest: SFSpeechAudioBufferRecognitionRequest?
    private var appleTask: SFSpeechRecognitionTask?
    private var appleTaskStartedAt: Date?
    private var lastAppleText = ""

    // CoreML partial throttling
    private var lastPartialAt = Date.distantPast
    private var speechStartedAt: Date?

    init(
        streamID: String,
        speakerName: String?,
        backend: IOSListenModel,
        language: IOSTranscriptionLanguage,
        gigaam: (any IOSGigaAMTranscribing)?,
        workerQueue: DispatchQueue,
        onSamples16k: (@Sendable (String, [Float]) -> Void)? = nil,
        onText: @escaping (String, String?, String, Bool, Date) -> Void
    ) {
        self.streamID = streamID
        self.speakerName = speakerName
        self.backend = backend
        self.language = language
        self.gigaam = gigaam
        self.workerQueue = workerQueue
        self.onSamples16k = onSamples16k
        self.onText = onText
        if backend == .appleSpeech {
            let recognizer = SFSpeechRecognizer(locale: language.locale)
            self.speechRecognizer = recognizer
        }
    }

    func setSpeakerOnWorker(_ name: String?) {
        if let name, !name.isEmpty {
            self.speakerName = name
        }
    }

    func updateSpeaker(_ name: String?) {
        workerQueue.async {
            self.setSpeakerOnWorker(name)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, isAudible: Bool = true, nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !stopped else { return }
        if isAudible {
            lastAudibleUptime = nowUptime
            vad.primePreRollIfNeeded()
        }
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }
        onSamples16k?(streamID, samples)

        if backend == .appleSpeech {
            processAppleSpeech(samples16k: samples, originalBuffer: buffer)
        } else {
            processCoreMLGigaAM(samples16k: samples)
        }
    }

    func finishAndFlush() {
        guard !stopped else { return }
        stopped = true
        if backend == .appleSpeech {
            finalizeAppleTask()
        } else if let recognizer = gigaam {
            for seg in vad.flush() {
                if let text = try? recognizer.transcribe(samples16k: seg.samples), !text.isEmpty {
                    onText(streamID, speakerName, text, true, speechStartedAt ?? Date())
                }
            }
            speechStartedAt = nil
        }
    }

    func stop() {
        stopped = true
        appleTask?.cancel()
        appleTask = nil
        appleRequest?.endAudio()
        appleRequest = nil
        vad.resetState()
    }

    func discardPendingSpeech() {
        guard !stopped else { return }
        vad.resetState()
        appleTask?.cancel()
        appleTask = nil
        appleRequest?.endAudio()
        appleRequest = nil
        appleTaskStartedAt = nil
        lastAppleText = ""
        speechStartedAt = nil
    }

    private func processAppleSpeech(samples16k: [Float], originalBuffer: AVAudioPCMBuffer) {
        let completed = vad.append(samples16k)
        if vad.isSpeechActive {
            if appleRequest == nil {
                startAppleRequest()
            }
            if let appleRequest, let floatBuffer = make16kBuffer(from: samples16k) {
                appleRequest.append(floatBuffer)
            } else if let appleRequest {
                appleRequest.append(originalBuffer)
            }
            if let started = appleTaskStartedAt, Date().timeIntervalSince(started) > 40 {
                rotateAppleRequest()
            }
        } else if !completed.isEmpty {
            // Utterance boundary detected by VAD -> rotate cleanly so final segment is committed.
            if let tailBuffer = make16kBuffer(from: samples16k) {
                appleRequest?.append(tailBuffer)
            }
            finalizeAppleTask()
        }
    }

    private func startAppleRequest() {
        guard let speechRecognizer, speechRecognizer.isAvailable, speechRecognizer.supportsOnDeviceRecognition else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            req.addsPunctuation = true
        }
        let startedAt = Date()
        appleRequest = req
        appleTaskStartedAt = startedAt
        lastAppleText = ""

        appleTask = speechRecognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.workerQueue.async {
                guard !self.stopped else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.lastAppleText = transcript
                    self.onText(self.streamID, self.speakerName, transcript, result.isFinal, startedAt)
                    if result.isFinal {
                        self.appleTask = nil
                        self.appleRequest = nil
                        self.appleTaskStartedAt = nil
                        self.lastAppleText = ""
                    }
                } else if error != nil {
                    self.appleTask = nil
                    self.appleRequest = nil
                    self.appleTaskStartedAt = nil
                }
            }
        }
    }

    private func rotateAppleRequest() {
        finalizeAppleTask()
        startAppleRequest()
    }

    private func finalizeAppleTask() {
        appleRequest?.endAudio()
        if appleTask != nil && !lastAppleText.isEmpty {
            onText(streamID, speakerName, lastAppleText, true, appleTaskStartedAt ?? Date())
            lastAppleText = ""
        }
        appleRequest = nil
        appleTask?.finish()
        appleTask = nil
        appleTaskStartedAt = nil
    }

    private func processCoreMLGigaAM(samples16k: [Float]) {
        guard let gigaam else { return }
        let wasActive = vad.isSpeechActive
        let completed = vad.append(samples16k)
        if !wasActive && vad.isSpeechActive {
            speechStartedAt = Date()
        }
        for segment in completed {
            let spokenAt = speechStartedAt ?? Date()
            speechStartedAt = vad.isSpeechActive ? Date() : nil
            if let text = try? gigaam.transcribe(samples16k: segment.samples), !text.isEmpty {
                onText(streamID, speakerName, text, true, spokenAt)
            }
        }
        if vad.isSpeechActive,
           Date().timeIntervalSince(lastPartialAt) >= 2.2,
           let partialSamples = vad.snapshotActiveSamples() {
            lastPartialAt = Date()
            let spokenAt = speechStartedAt ?? Date()
            if let text = try? gigaam.transcribe(samples16k: partialSamples), !text.isEmpty {
                onText(streamID, speakerName, text, false, spokenAt)
            }
        }
    }

    private func make16kBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: IOSPCM16kConverter.targetFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            dst.initialize(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
