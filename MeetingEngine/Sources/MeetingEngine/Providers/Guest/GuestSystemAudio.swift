import Accelerate
import AVFoundation
import Foundation
import LiveKitWebRTC

/// A track sink, not a second capture or playout path. Only aggregate energy is retained.
final class GuestPCMMeter: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var measured = GuestAudioSnapshot()
    private var bufferCount = 0
    private var lastLevel: Float?
    private var lastSampleTime: TimeInterval = 0
    private var callback = GuestStartupAudioCallback()
#if DEBUG
    private var diagnosticPCMObserver: ((AVAudioPCMBuffer) -> Void)?
    /// Sink on the existing renderer; never creates an additional audio consumer.
    func setPCMObserverForTesting(_ observer: ((AVAudioPCMBuffer) -> Void)?) {
        locked { diagnosticPCMObserver = observer }
    }
#endif
    var callbackSnapshot: GuestStartupAudioCallback { locked { callback } }
#if DEBUG
    var callbackEvidence: [String: Any] { callbackSnapshot.evidence }
#endif
    var snapshot: GuestAudioSnapshot { locked { measured } }
    var buffers: Int { locked { bufferCount } }
    var level: Float? { locked { ProcessInfo.processInfo.systemUptime - lastSampleTime < 0.5 ? lastLevel : nil } }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func reset() { locked { measured = GuestAudioSnapshot(); bufferCount = 0; lastLevel = nil; lastSampleTime = 0; callback = .init() } }

    static func bufferEnergy(_ pcmBuffer: AVAudioPCMBuffer) -> (samples: Int, energy: Double) {
        var samples = 0, energy = 0.0
        let format = pcmBuffer.format
        for buffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            guard let data = buffer.mData else { continue }
            let expected = Int(pcmBuffer.frameLength) * Int(buffer.mNumberChannels)
            switch format.commonFormat {
            case .pcmFormatFloat32:
                let count = min(expected, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                guard count > 0 else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                var sumSq: Float = 0
                vDSP_svesq(ptr, 1, &sumSq, vDSP_Length(count))
                if sumSq.isFinite {
                    energy += Double(sumSq)
                    samples += count
                } else {
                    for index in 0..<count {
                        let value = Double(ptr[index])
                        if value.isFinite { energy += value * value; samples += 1 }
                    }
                }
            case .pcmFormatFloat64:
                let count = min(expected, Int(buffer.mDataByteSize) / MemoryLayout<Double>.size)
                let ptr = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count {
                    let value = ptr[index]
                    if value.isFinite { energy += value * value; samples += 1 }
                }
            case .pcmFormatInt16:
                let count = min(expected, Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size)
                let ptr = data.assumingMemoryBound(to: Int16.self)
                var intEnergy: Double = 0
                for index in 0..<count {
                    let v = Double(ptr[index])
                    intEnergy += v * v
                }
                energy += intEnergy / (32768.0 * 32768.0)
                samples += count
            case .pcmFormatInt32:
                let count = min(expected, Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size)
                let ptr = data.assumingMemoryBound(to: Int32.self)
                var intEnergy: Double = 0
                for index in 0..<count {
                    let v = Double(ptr[index])
                    intEnergy += v * v
                }
                energy += intEnergy / (2147483648.0 * 2147483648.0)
                samples += count
            default: break
            }
        }
        return (samples, energy)
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        let format = pcmBuffer.format
        let deliveredFormat = withExtendedLifetime(format) { GuestStartupAudioCallback.Format(format.streamDescription.pointee) }
        let (samples, energy) = Self.bufferEnergy(pcmBuffer)
        locked {
            callback.recordDelivery(frames: Int(pcmBuffer.frameLength), format: deliveredFormat, at: receivedUptime)
            measured.record(samples: samples, energy: energy, at: receivedUptime); bufferCount += 1
            lastLevel = samples > 0 ? Float(sqrt(energy / Double(samples))) : nil
            lastSampleTime = receivedUptime
        }
#if DEBUG
        let observer = locked { diagnosticPCMObserver }
        observer?(pcmBuffer)
#endif
    }
}

public enum GuestSystemAudioError: LocalizedError {
    case microphonePermissionRequired, setupFailedOrTimedOut, physicalOwnerBusy
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionRequired: "Allow microphone access in System Settings before checking or unmuting."
        case .setupFailedOrTimedOut: "Microphone setup did not finish. Stop the check or leave the meeting before trying again."
        case .physicalOwnerBusy: "The active meeting already owns the microphone. Open its Camera & sound panel to check it."
        }
    }
    static func microphoneActivationFailure(authorization: AVAuthorizationStatus) -> Self {
        switch authorization {
        case .denied, .restricted: .microphonePermissionRequired
        default: .setupFailedOrTimedOut
        }
    }
}

/// Native recording startup may reset the SDK's mixer state. Re-establish the
/// privacy barrier after startup and require its affirmative readback.
enum GuestMutedInputPreparation {
    static func start(mute: () -> Bool, makeAvailable: () -> Bool,
                      startRecording: () -> Bool, isMuted: () -> Bool) -> Bool {
        guard mute() else { return false }
        let available = makeAvailable()
        let started = available && startRecording()
        // A failing native start can still have partially changed mixer state.
        let restored = mute(), confirmed = isMuted()
        return available && started && restored && confirmed
    }
}

/// The shared VPIO owner needs its silent output leg to keep physical input
/// running. Sound remains a separate intent, enforced by the output gain gate.
struct GuestPhysicalAudioAvailability: Equatable {
    let input, output: Bool
    /// Local transcription keeps output running while sound is off: WebRTC decodes
    /// remote audio only when playout pulls it. The mixer is then silenced (or the
    /// shared gate is closed), so nothing is heard.
    init(input: Bool, playoutRequested: Bool, sharedNativeOwner: Bool, transcription: Bool = false) {
        self.input = input
        output = playoutRequested || (sharedNativeOwner && input) || transcription
    }
}

/// Positive writes and logical state changes share MainActor. Native graph
/// callbacks can only silence/bind weak nodes; they never restore positive gain.
public final class GuestSharedPlayoutGate: @unchecked Sendable {
    private struct Target {
        let identity: ObjectIdentifier
        let setGain: (Double) -> Bool
    }
    private let enabled: Bool
    private let lock = NSLock()
    private var epoch = UUID(), revision: UInt64 = 0
    private var target: Target?
    private var sound = false, ready = false, retired = false
    private var lastGain: Double = 0
    /// Meeting volume applied while sound is on; mute stays an exact zero.
    private var positiveGain: Double = 1
    private var lastPositiveUptime: TimeInterval?
    private var lastWriteSucceeded = true
    init(enabled: Bool) { self.enabled = enabled }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var currentEpoch: UUID? { enabled ? locked { epoch } : nil }
    func matches(_ expected: UUID?) -> Bool { !enabled || locked { expected == epoch && !retired } }
    var evidence: [String: Any] {
        locked { ["enabled": enabled, "epoch": enabled ? epoch.uuidString : "", "soundRequested": sound,
                  "ready": ready, "retired": retired, "mixerBound": target != nil,
                  "lastGain": lastGain, "lastWriteSucceeded": lastWriteSucceeded,
                  "lastPositiveUptime": lastPositiveUptime.map { $0 as Any } ?? NSNull()] }
    }
    func bind(identity: ObjectIdentifier, setGain: @escaping (Double) -> Bool) -> Bool {
        guard enabled else { return true }
        let muted = setGain(0)
        locked {
            target = muted ? Target(identity: identity, setGain: setGain) : nil; revision &+= 1
            lastGain = 0; lastWriteSucceeded = muted
            if !muted { ready = false }
        }
        if locked({ ready && sound && !retired }) {
            Task { @MainActor [weak self] in _ = self?.reconcile() }
        }
        return muted
    }
    func remove(identity: ObjectIdentifier) {
        guard enabled else { return }
        let removed: Target? = locked {
            guard target?.identity == identity else { return nil }
            let old = target; target = nil; revision &+= 1; return old
        }
        _ = removed?.setGain(0)
    }
    @MainActor func reset(sound: Bool) -> Bool {
        guard enabled else { return true }
        locked { epoch = UUID(); ready = false; retired = false; self.sound = sound; revision &+= 1 }
        return reconcile()
    }
    @MainActor func setSound(_ sound: Bool, expected: UUID?) -> Bool {
        guard enabled else { return true }
        guard matches(expected) else { return false }
        locked {
            self.sound = sound
            if sound && target == nil { ready = false }
            revision &+= 1
        }
        return reconcile()
    }
    /// Changes only the level of an open gate; it never opens or closes sound.
    @MainActor func setVolume(_ volume: Double) -> Bool {
        guard enabled else { return true }
        let value = volume.isFinite ? min(1, max(0, volume)) : 1
        locked { positiveGain = value; revision &+= 1 }
        return reconcile()
    }
    @MainActor func close(expected: UUID? = nil, retire: Bool = false) -> Bool {
        guard enabled else { return true }
        if let expected, !matches(expected) { return true }
        locked {
            ready = false
            if retire { epoch = UUID(); sound = false; retired = true }
            revision &+= 1
        }
        return reconcile()
    }
    @MainActor func open(expected: UUID?) -> Bool {
        guard enabled else { return true }
        guard matches(expected), locked({ sound && target != nil }) else { return false }
        locked { ready = true; revision &+= 1 }
        guard reconcile() else { _ = close(expected: expected); return false }
        return isOpen(expected: expected)
    }
    @MainActor func isOpen(expected: UUID?) -> Bool {
        !enabled || locked { expected == epoch && !retired && sound && ready && target != nil &&
            lastGain == positiveGain && lastWriteSucceeded }
    }
#if DEBUG
    @MainActor func permitsSoundOffProof(expected: UUID?) -> Bool {
        enabled && locked { expected == epoch && !retired && ready && !sound && target != nil &&
            lastGain == 0 && lastWriteSucceeded }
    }
#endif
    @MainActor private func reconcile() -> Bool {
        guard enabled else { return true }
        for _ in 0..<3 {
            let state = locked { (target, revision, !retired && ready && sound ? positiveGain : 0.0, !retired && ready && sound) }
            guard let current = state.0 else { return state.2 == 0 }
            let success = current.setGain(state.2) // No AV/SDK calls under the metadata lock.
            let unchanged = locked { () -> Bool in
                guard revision == state.1 else { return false }
                if success && state.3 && state.2 > 0 && lastGain == 0 { lastPositiveUptime = ProcessInfo.processInfo.systemUptime }
                lastGain = state.2; lastWriteSucceeded = success; return true
            }
            if unchanged { return success }
        }
        let fallback = locked { () -> (Target?, UInt64) in ready = false; revision &+= 1; return (target, revision) }
        let muted = fallback.0?.setGain(0) ?? true
        locked { if revision == fallback.1 { lastGain = 0; lastWriteSucceeded = muted } }
        return false
    }
}

/// Cached timing only: inspecting a stalled operation never calls the ADM worker.
final class GuestAudioOperationTrace: @unchecked Sendable {
    private struct Entry {
        let id: Int, name: String
        let queuedAt: TimeInterval, deadlineAt: TimeInterval
        var startedAt: TimeInterval?, finishedAt: TimeInterval?, timedOutAt: TimeInterval?
        var succeeded: Bool?
        var nativeCall: String?, nativeStartedAt: TimeInterval?, nativeFinishedAt: TimeInterval?
        var nativeResult: String?
        var nativeCalls: [[String: Any]] = []
        func evidence(at now: TimeInterval) -> [String: Any] {
            var value: [String: Any] = ["id": id, "name": name, "queuedAt": queuedAt,
                "deadlineAt": deadlineAt, "callerTimedOut": timedOutAt != nil,
                "stage": finishedAt != nil ? "finished" : startedAt == nil ? "queued" :
                    nativeStartedAt != nil && nativeFinishedAt == nil ? "native-call" : "running"]
            if let startedAt { value["startedAt"] = startedAt; value["queueSeconds"] = startedAt - queuedAt }
            if let finishedAt { value["finishedAt"] = finishedAt }
            if let timedOutAt { value["timedOutAt"] = timedOutAt }
            if let succeeded { value["succeeded"] = succeeded }
            if let nativeCall { value["nativeCall"] = nativeCall }
            if let nativeStartedAt {
                value["nativeStartedAt"] = nativeStartedAt
                value["nativeSeconds"] = (nativeFinishedAt ?? now) - nativeStartedAt
            }
            if let nativeResult { value["nativeResult"] = nativeResult }
            value["nativeCalls"] = nativeCalls
            if let startedAt { value["runSeconds"] = (finishedAt ?? now) - startedAt }
            return value
        }
    }
    private let lock = NSLock()
    private var nextID = 0
    private var entries: [Entry] = []
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func enqueue(_ name: String, timeout: TimeInterval, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        locked {
            nextID += 1
            entries.removeAll { $0.finishedAt != nil && $0.id < nextID - 16 }
            entries.append(Entry(id: nextID, name: name, queuedAt: now, deadlineAt: now + max(0.01, timeout)))
            return nextID
        }
    }
    func start(_ id: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked { if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].startedAt = now } }
    }
    func timedOut(_ id: Int, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked { if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].timedOutAt = now } }
    }
    func finish(_ id: Int, succeeded: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].finishedAt = now; entries[index].succeeded = succeeded
            }
        }
    }
    func beginNativeCall(_ name: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked {
            if let index = entries.firstIndex(where: { $0.startedAt != nil && $0.finishedAt == nil }) {
                entries[index].nativeCall = name; entries[index].nativeStartedAt = now
                entries[index].nativeFinishedAt = nil; entries[index].nativeResult = nil
            }
        }
    }
    func endNativeCall(result: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked {
            if let index = entries.firstIndex(where: { $0.startedAt != nil && $0.finishedAt == nil }) {
                entries[index].nativeFinishedAt = now; entries[index].nativeResult = result
                if let name = entries[index].nativeCall, let startedAt = entries[index].nativeStartedAt {
                    entries[index].nativeCalls.append(["name": name, "startedAt": startedAt,
                        "seconds": now - startedAt, "result": result])
                    entries[index].nativeCalls = Array(entries[index].nativeCalls.suffix(16))
                }
            }
        }
    }
    func snapshot(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        locked {
            ["audioOperations": entries.map { $0.evidence(at: now) },
             "audioQueuedOperations": entries.filter { $0.startedAt == nil && $0.finishedAt == nil }.count,
             "audioActiveOperation": entries.first { $0.startedAt != nil && $0.finishedAt == nil }?.evidence(at: now) ?? [:]]
        }
    }
    /// The running operation's name and native call, if any (cheap; for lifecycle events).
    func activeSummary() -> [String: Any] {
        locked {
            guard let entry = entries.first(where: { $0.startedAt != nil && $0.finishedAt == nil }) else { return [:] }
            var value: [String: Any] = ["activeOperation": entry.name]
            if let call = entry.nativeCall, entry.nativeFinishedAt == nil { value["activeNativeCall"] = call }
            return value
        }
    }
}

/// This owner belongs only to the native probe process. Availability is an explicit privacy gate.
/// Native ADM calls can block internally, so none run on the main actor and every caller has a deadline.
/// Detects sustained exact-zero PCM from `AVAudioEngine.inputNode` while the microphone is
/// logically unmuted and the send gate is open, firing at most once per engine generation.
public struct GuestInputSilenceWatchdog: Sendable {
    public let minimumCallbacks: UInt64
    public let minimumSeconds: TimeInterval
    public private(set) var totalNonSilentCallbacks: UInt64 = 0
    public private(set) var lastNonSilentUptime: TimeInterval?
    public private(set) var engineGeneration: UInt64 = 0
    public private(set) var engineCallbacks: UInt64 = 0
    public private(set) var engineNonSilentCallbacks: UInt64 = 0
    public private(set) var consecutiveSilentCallbacks: UInt64 = 0
    public private(set) var silentSinceUptime: TimeInterval?
    public private(set) var unmutedSilentCallbacks: UInt64 = 0
    public private(set) var unmutedSilentSinceUptime: TimeInterval?
    private var reportedGeneration: UInt64?

    public init(minimumCallbacks: UInt64 = 20, minimumSeconds: TimeInterval = 2.0) {
        self.minimumCallbacks = minimumCallbacks
        self.minimumSeconds = minimumSeconds
    }

    public mutating func resetEngine() {
        engineGeneration &+= 1
        engineCallbacks = 0
        engineNonSilentCallbacks = 0
        consecutiveSilentCallbacks = 0
        silentSinceUptime = nil
        unmutedSilentCallbacks = 0
        unmutedSilentSinceUptime = nil
        reportedGeneration = nil
    }

    public mutating func resetUnmutedStreak() {
        unmutedSilentCallbacks = 0
        unmutedSilentSinceUptime = nil
    }

    public mutating func observe(samples: Int, energy: Double, unmuted: Bool, gateOpen: Bool, at now: TimeInterval) -> Bool {
        guard samples > 0, now.isFinite else { return false }
        engineCallbacks &+= 1
        if energy.isFinite && energy > 0 {
            totalNonSilentCallbacks &+= 1
            engineNonSilentCallbacks &+= 1
            lastNonSilentUptime = now
            consecutiveSilentCallbacks = 0
            silentSinceUptime = nil
            unmutedSilentCallbacks = 0
            unmutedSilentSinceUptime = nil
            return false
        }
        consecutiveSilentCallbacks &+= 1
        if silentSinceUptime == nil { silentSinceUptime = now }
        if unmuted && gateOpen {
            unmutedSilentCallbacks &+= 1
            let since = unmutedSilentSinceUptime ?? now
            if unmutedSilentSinceUptime == nil { unmutedSilentSinceUptime = now }
            if reportedGeneration != engineGeneration,
               unmutedSilentCallbacks >= minimumCallbacks,
               now - since >= minimumSeconds {
                reportedGeneration = engineGeneration
                return true
            }
        } else {
            unmutedSilentCallbacks = 0
            unmutedSilentSinceUptime = nil
        }
        return false
    }

    public func diagnosticFields(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        [
            "inputNonSilentCallbacks": totalNonSilentCallbacks,
            "engineInputCallbacks": engineCallbacks,
            "engineInputNonSilentCallbacks": engineNonSilentCallbacks,
            "consecutiveSilentInputCallbacks": consecutiveSilentCallbacks,
            "unmutedSilentInputCallbacks": unmutedSilentCallbacks,
            "engineInputGeneration": engineGeneration,
            "lastInputNonSilentAgeMs": lastNonSilentUptime.map { max(0, now - $0) * 1000 } ?? TimeInterval(-1),
            "unmutedSilentSeconds": unmutedSilentSinceUptime.map { max(0, now - $0) } ?? TimeInterval(0),
        ]
    }
}

/// An engine stop or start the owner did not ask for (device or route change, sleep).
public enum GuestEngineChange: Sendable { case stopped, started }

public final class GuestSystemAudio: NSObject, LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
    private static let quarantineLock = NSLock()
    private static var quarantined: [ObjectIdentifier: GuestSystemAudio] = [:]
    private static func retainFailedOwner(_ owner: GuestSystemAudio) {
        quarantineLock.lock(); defer { quarantineLock.unlock() }
        quarantined[ObjectIdentifier(owner)] = owner
    }
    private let audioQueue = DispatchQueue(label: "NativeGuest.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private let inputCallbackLock = NSLock()
    private let operationTrace = GuestAudioOperationTrace()
    private var microphoneOptIn: Bool
    private var inputActivation: GuestInputActivationPolicy
    private let sharedNativeOwner: Bool
    private let sharedInputOutputDependency: Bool
    private let bypassVoiceProcessingWhenMuted: Bool
    private var keepVoiceProcessingWhenMuted = false
    private let sharedPlayoutGate: GuestSharedPlayoutGate
    public let profile: GuestAudioProfile
    private var ownerLease: GuestAudioOwnerLease?
    private let inputMeter = GuestPCMMeter()
    private let participationInputMeter = GuestPCMMeter()
    private var participationInputMeterEnabled = false
    private let playoutMeter = GuestPCMMeter()
    private var inputCallback = GuestStartupAudioCallback()
    private var inputSilenceWatchdog = GuestInputSilenceWatchdog()
    private var watchdogInputUnmuted = false
    private var watchdogGateOpen = true
    private var silentInputHandler: (([String: Any]) -> Void)?
    private var inputMeterEnabled = false
    /// Local transcription of your own microphone: a copy of each input buffer.
    private var inputTranscriptionSink: ((AVAudioPCMBuffer) -> Void)?
    /// Called off the audio thread when `AVAudioEngine.inputNode` delivers sustained exact-zero
    /// PCM while logically unmuted and the send gate is open.
    public var onSilentInputDetected: (([String: Any]) -> Void)? {
        get { inputCallbackLock.lock(); defer { inputCallbackLock.unlock() }; return silentInputHandler }
        set { inputCallbackLock.lock(); silentInputHandler = newValue; inputCallbackLock.unlock() }
    }
    private func setWatchdogInputUnmuted(_ unmuted: Bool) {
        inputCallbackLock.lock()
        if watchdogInputUnmuted != unmuted {
            watchdogInputUnmuted = unmuted
            inputSilenceWatchdog.resetUnmutedStreak()
        }
        inputCallbackLock.unlock()
    }
    private func setWatchdogGateOpen(_ open: Bool) {
        inputCallbackLock.lock()
        if watchdogGateOpen != open {
            watchdogGateOpen = open
            inputSilenceWatchdog.resetUnmutedStreak()
        }
        inputCallbackLock.unlock()
    }
    private func inputSilenceWatchdogSnapshot() -> GuestInputSilenceWatchdog {
        inputCallbackLock.lock(); defer { inputCallbackLock.unlock() }
        return inputSilenceWatchdog
    }
    /// Voice replies are available whenever the meeting's audio route supports them.
    /// The assistant's own controls decide when a reply is spoken.
    public static var voiceRepliesEnabled: Bool {
#if DEBUG
        if let voiceRepliesOverrideForTesting { return voiceRepliesOverrideForTesting }
#endif
        return true
    }
#if DEBUG
    public nonisolated(unsafe) static var voiceRepliesOverrideForTesting: Bool?
#endif
    private var voiceReply: GuestVoiceReplyGraph?
    private weak var participationPlayoutMixer: AVAudioMixerNode?
    private weak var participationPlayoutEngine: AVAudioEngine?
    private var participationPlayoutFormat: AVAudioFormat?
    /// Tests only (manual rendering): set once at creation, before any native work.
    private var manualRenderingMode = false
    /// Native work this owner runs itself; engine stops/starts outside it come from the
    /// system (device or route change, sleep) and are reported to `onSpontaneousEngineChange`.
    private var operationDepth = 0
    private var spontaneousChangeHandler: ((GuestEngineChange) -> Void)?
    /// Called on the native audio worker; the handler must return at once.
    public var onSpontaneousEngineChange: ((GuestEngineChange) -> Void)? {
        get { locked { spontaneousChangeHandler } }
        set { locked { spontaneousChangeHandler = newValue } }
    }
    private func reportSpontaneous(_ change: GuestEngineChange) {
        let handler = locked { operationDepth == 0 ? spontaneousChangeHandler : nil }
        handler?(change)
    }
    private static let lifecycleCounters = ["enginesCreated", "engineStarts", "engineStops", "enginesReleased", "deviceUpdates"]
    /// One timestamped event per device update and engine create/start/stop/release, so a
    /// diagnostics bundle shows how many rebuilds a route change caused and in what order
    /// (beta 84: a Bluetooth → built-in switch gave several dropouts, but only counters
    /// were kept). Runs on the native worker: cached values only; the route is read off
    /// it, bounded, and only for device updates.
    private func logLifecycle(_ kind: String, _ extra: [String: Any] = [:]) {
        var fields = locked { () -> [String: Any] in
            var value: [String: Any] = ["kind": kind, "ownOperation": operationDepth > 0]
            for key in Self.lifecycleCounters { value[key] = cached[key] as? Int ?? 0 }
            return value
        }
        fields.merge(operationTrace.activeSummary()) { current, _ in current }
        fields.merge(extra) { current, _ in current }
        probeLog("audio-engine-lifecycle", probeSafe(fields) as? [String: Any] ?? fields)
        guard kind == "device-update" else { return }
        let update = fields["deviceUpdates"] as? Int ?? 0, at = ProcessInfo.processInfo.systemUptime
        Task.detached(priority: .utility) {
            let route = await GuestAcousticEnvironment.boundedRoute(timeout: 1)
            probeLog("audio-device-route", ["deviceUpdates": update, "requestedAt": at, "route": probeSafe(route)])
        }
    }
    /// Microphone permission as every check here sees it (debug tests may override it,
    /// together with manual rendering, to run without the test host's permission).
    public static var microphoneAuthorized: Bool {
#if DEBUG
        if let microphoneAuthorizationOverrideForTesting { return microphoneAuthorizationOverrideForTesting }
#endif
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
#if DEBUG
    public nonisolated(unsafe) static var microphoneAuthorizationOverrideForTesting: Bool?
#endif
    /// R4: another observer of this module (LiveKit's, when its factory is shared) receives
    /// every module event first. While set, that observer wires the input graph, so this
    /// owner only taps it and builds no voice-reply graph of its own.
    private weak var forwardObserverStorage: LKRTCAudioDeviceModuleDelegate?
    private var forwardObserver: LKRTCAudioDeviceModuleDelegate? { locked { forwardObserverStorage } }
    private var forwardObserverInstallationPending = false
    public var hasForwardObserver: Bool { forwardObserver != nil }
    private var createdAudioEngines: Set<ObjectIdentifier> = []
    private var forwardedAudioEngines: Set<ObjectIdentifier> = []
    private var forwardedInputRoutes: Set<ObjectIdentifier> = []
    public struct ForwardedVoiceReplyController {
        public let setGateOpen: (Bool) -> Bool
        public let isGateOpen: () -> Bool
        public let setMonitorGain: (Float) -> Void
        public let play: @MainActor (AVAudioPCMBuffer, Float?, @escaping @MainActor @Sendable () -> Bool) async -> Bool
        public init(setGateOpen: @escaping (Bool) -> Bool, isGateOpen: @escaping () -> Bool,
                    setMonitorGain: @escaping (Float) -> Void,
                    play: @escaping @MainActor (AVAudioPCMBuffer, Float?, @escaping @MainActor @Sendable () -> Bool) async -> Bool) {
            self.setGateOpen = setGateOpen; self.isGateOpen = isGateOpen
            self.setMonitorGain = setMonitorGain; self.play = play
        }
    }

    public typealias InputRouteProof = (AVAudioEngine, AVAudioNode?, AVAudioNode) -> Bool
    private var proveForwardedInput: InputRouteProof?
    private var forwardedVoiceController: ForwardedVoiceReplyController?
    private var startedRecordingForPrivateCheck = false
    public var hasCreatedAudioEngines: Bool { locked { !createdAudioEngines.isEmpty } }
#if DEBUG
    // A synthetic source on the test's manual legacy ADM, never a device route.
    private weak var manualLegacyInputFixture: LKRTCAudioDeviceModuleDelegate?
    func setManualLegacyInputFixtureForTesting(_ fixture: LKRTCAudioDeviceModuleDelegate?) {
        locked { manualLegacyInputFixture = fixture }
    }
#endif
    var hasForwardedInputRoute: Bool { locked { !forwardedInputRoutes.isEmpty } }
    var waitingForForwardedInputRoute: Bool {
        locked { forwardedInputRoutes.isEmpty && !createdAudioEngines.isSubset(of: forwardedAudioEngines) }
    }

    public enum ForwardObserverInstallation: Error {
        case installed, factoryUnavailable, assistantGateHeld, observerUnavailable
    }

    private func forwardObserver(for engine: AVAudioEngine) -> LKRTCAudioDeviceModuleDelegate? {
        locked { forwardedAudioEngines.contains(ObjectIdentifier(engine)) ? forwardObserverStorage : nil }
    }

    /// Reserve the open gate while LiveKit adopts the factory and constructs
    /// its observer. Both SDK calls run outside the owner's state lock.
    public func installForwardObserver(installFactory: (LKRTCPeerConnectionFactory) -> Bool,
                                makeObserver: () -> LKRTCAudioDeviceModuleDelegate?,
                                proveInput: @escaping InputRouteProof,
                                voiceController: ForwardedVoiceReplyController? = nil) -> ForwardObserverInstallation {
        let reservation = locked { () -> Result<LKRTCPeerConnectionFactory, ForwardObserverInstallation> in
            guard microphoneGateOpen, !forwardObserverInstallationPending else { return .failure(.assistantGateHeld) }
            guard let ownedFactory else { return .failure(.factoryUnavailable) }
            forwardObserverInstallationPending = true
            return .success(ownedFactory)
        }
        let factory: LKRTCPeerConnectionFactory
        switch reservation {
        case .success(let reserved): factory = reserved
        case .failure(let reason): return reason
        }
        defer { locked { forwardObserverInstallationPending = false } }
        guard installFactory(factory) else { return .factoryUnavailable }
        guard let observer = makeObserver() else { return .observerUnavailable }
        locked {
            forwardObserverStorage = observer
            proveForwardedInput = proveInput
            forwardedVoiceController = voiceController
        }
        return .installed
    }
    /// Survives engine rebuilds: a graph built during a reply starts closed.
    private var microphoneGateOpen = true
    private var ownedFactory: LKRTCPeerConnectionFactory?
    private var cached: [String: Any]
    private var deviceCountsDirty = true
    private var cachedInputDeviceCount = 0
    private var cachedOutputDeviceCount = 0
    // The following fields are confined to audioQueue.
    private var playoutEnabled: Bool
#if os(iOS)
    private var meetingPlayoutReserved = false
#endif
    private var closed = false
    private var mediaContext: LKRTCPeerConnection?
    // Simultaneous meetings: only the talk meeting may hold physical input. A
    // withdrawn permit releases input; activation requested meanwhile is deferred
    // to the next permitted unmute. Mirrored into `cached` for readers.
    private var inputPermitted = true
    private var deferredActivation = false
    private var tappedInput: AVAudioNode?
    private weak var tappedEngine: AVAudioEngine?
    private var tappedPlayout: AVAudioNode?
    private weak var tappedPlayoutEngine: AVAudioEngine?
    // Meeting volume for owners without the shared gate; read under the state lock.
    private var meetingVolume: Double = 1
    private weak var volumeMixer: AVAudioMixerNode?
    /// Sound is off: the mixer stays at exactly zero even while output runs for transcription.
    private var outputSilenced = false
    // Confined to audioQueue: output runs while sound is off for local transcription.
    private var transcriptionOutput = false
    private var handoffPreparedRecording = false
    private var attemptHandoffActive = false

    /// App-only meeting level (0...1). macOS output volume is never changed;
    /// mute and sound-on intent remain separate.
    @MainActor public func setMeetingVolume(_ volume: Double) -> Bool {
        let value = volume.isFinite ? min(1, max(0, volume)) : 1
        if sharedNativeOwner { return sharedPlayoutGate.setVolume(value) }
        let (mixer, silenced) = locked { () -> (AVAudioMixerNode?, Bool) in meetingVolume = value; return (volumeMixer, outputSilenced) }
        mixer?.outputVolume = silenced ? 0 : Float(value)
        return true
    }
    /// Keeps output running while sound is off so remote audio is decoded for
    /// local transcription. Sound stays off: the mixer or shared gate is at zero.
    public func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval = 2) async -> Bool {
        await perform("transcription-output", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            self.transcriptionOutput = keep
            self.update(["transcriptionOutput": keep])
            let success = self.applyAvailability(module)
            self.readSnapshot(module)
            return success
        }
    }

    public var factory: LKRTCPeerConnectionFactory {
        locked {
            guard let ownedFactory else { preconditionFailure("System audio factory is unavailable") }
            return ownedFactory
        }
    }
    /// Cached only: reading diagnostics never calls the native worker or accesses a device.
    public var isMicrophoneMuted: Bool {
        locked { cached["microphoneMuted"] as? Bool != false }
    }
    public var snapshot: [String: Any] {
        let inputCount = inputCallbackSnapshot().count
        let watchdog = inputSilenceWatchdogSnapshot().diagnosticFields()
        return locked { cached }
            .merging(["inputCallbacks": inputCount], uniquingKeysWith: { _, value in value })
            .merging(watchdog, uniquingKeysWith: { _, value in value })
            .merging(operationTrace.snapshot()) { _, value in value }
            .merging(["sharedPlayoutGate": sharedPlayoutGate.evidence]) { _, value in value }
    }
    private func inputCallbackSnapshot() -> GuestStartupAudioCallback {
        inputCallbackLock.lock(); defer { inputCallbackLock.unlock() }
        return inputCallback
    }
    public var playoutEpoch: UUID? { sharedPlayoutGate.currentEpoch }
    @MainActor public func openSharedPlayout(expected: UUID?) -> Bool { sharedPlayoutGate.open(expected: expected) }
    @MainActor public func setSharedSoundIntent(_ sound: Bool, expected: UUID?) -> Bool {
        sharedPlayoutGate.setSound(sound, expected: expected)
    }
    @MainActor public func closeSharedPlayout(expected: UUID?) -> Bool {
        if sharedNativeOwner && expected == nil { return true }
        return sharedPlayoutGate.close(expected: expected)
    }
    @MainActor public func sharedPlayoutIsOpen(expected: UUID?) -> Bool { sharedPlayoutGate.isOpen(expected: expected) }
    public var canUnmuteMicrophone: Bool {
        let value = snapshot
        return value["inputPermitted"] as? Bool != false &&
            (value["microphoneOptIn"] as? Bool == true || value["deferredActivation"] as? Bool == true) &&
            GuestSystemAudio.microphoneAuthorized
    }
    public var privateInputLevel: Float? {
        inputCallbackLock.lock()
        let enabled = inputMeterEnabled
        inputCallbackLock.unlock()
        return enabled ? inputMeter.level : nil
    }
    public var privateInputMeterEvidence: [String: Any] {
        inputCallbackLock.lock()
        let enabled = inputMeterEnabled
        inputCallbackLock.unlock()
        return meterEvidence(inputMeter).merging(["enabled": enabled]) { _, new in new }
    }
    public var playoutMeterEvidence: [String: Any] { meterEvidence(playoutMeter) }
#if DEBUG
    public var sharedPlayoutGateForTesting: GuestSharedPlayoutGate { sharedPlayoutGate }
    public var startupCallbackEvidence: [String: Any] {
        ["input": inputCallbackSnapshot().evidence, "output": playoutMeter.callbackEvidence]
    }
    /// Passive stubs at this revision: the CoreAudio/private-input experiments these
    /// counters describe are not in the tree. The harness reports "no data" for empty.
    var microphoneStartupEvidenceForTesting: [String: Any] { [:] }
    var privateInputGraphEvidenceForTesting: [String: Any] { [:] }
#endif
    public var startupAudioObservation: GuestStartupAudioObservation {
        let value = snapshot
        let input = inputCallbackSnapshot(), output = playoutMeter.callbackSnapshot
        return .init(snapshot: value, inputCallbacks: input.count, outputCallbacks: output.count,
            inputCallback: input, outputCallback: output)
    }
    private func meterEvidence(_ meter: GuestPCMMeter) -> [String: Any] {
        let value = meter.snapshot
        return ["buffers": meter.buffers, "samples": value.samples, "energy": value.energy, "rms": value.rms,
                "callbacks": value.callbacks, "nonSilentCallbacks": value.nonSilentCallbacks,
                "firstCallbackUptime": value.firstCallbackUptime as Any? ?? NSNull(),
                "lastCallbackUptime": value.lastCallbackUptime as Any? ?? NSNull(),
                "firstNonSilentUptime": value.firstNonSilentUptime as Any? ?? NSNull(),
                "lastNonSilentUptime": value.lastNonSilentUptime as Any? ?? NSNull(),
                "recentLevel": meter.level.map { $0 as Any } ?? NSNull()]
    }
    public func setPrivateInputMeterEnabled(_ enabled: Bool) {
        inputCallbackLock.lock()
        inputMeterEnabled = enabled
        inputCallbackLock.unlock()
        inputMeter.reset()
    }
    /// Receives your microphone's buffers on the audio thread; the sink must copy
    /// and return at once. Whether the meeting is unmuted is the caller's gate.
    public func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        inputCallbackLock.lock()
        inputTranscriptionSink = sink
        inputCallbackLock.unlock()
    }
    /// Closing is acknowledged only when this owner has the active input graph.
    public func setMicrophoneGate(open: Bool) -> Bool {
        let state = locked { () -> (graph: GuestVoiceReplyGraph?, forwarded: ForwardedVoiceReplyController?, previousGateOpen: Bool) in
            let prev = microphoneGateOpen
            if !forwardObserverInstallationPending, let voiceReply, let engine = voiceReply.engine,
               !forwardedAudioEngines.contains(ObjectIdentifier(engine)) {
                // Latch before touching the graph, so a concurrent rebuild also closes
                // its gate and a forwarding observer cannot adopt this owner's input.
                if !open { microphoneGateOpen = false }
                return (voiceReply, nil, prev)
            }
            if !forwardObserverInstallationPending, let forwardedVoiceController,
               !forwardedInputRoutes.isEmpty, createdAudioEngines.isSubset(of: forwardedAudioEngines) {
                if !open { microphoneGateOpen = false }
                return (nil, forwardedVoiceController, prev)
            }
            if open { microphoneGateOpen = true }
            return (nil, nil, prev)
        }
        if let graph = state.graph {
            guard (open || graph.isConnected), graph.setGate(open: open), locked({
                guard voiceReply === graph, let engine = graph.engine,
                      !forwardedAudioEngines.contains(ObjectIdentifier(engine)) else { return false }
                microphoneGateOpen = open
                return true
            }) else {
                locked { microphoneGateOpen = state.previousGateOpen }
                return false
            }
            setWatchdogGateOpen(open)
            update(["microphoneGateOpen": open])
#if DEBUG
            update(["voiceReplyTopology": graph.evidence])
#endif
            return true
        }
        if let controller = state.forwarded {
            guard controller.setGateOpen(open), locked({
                guard !forwardedInputRoutes.isEmpty, createdAudioEngines.isSubset(of: forwardedAudioEngines) else { return false }
                microphoneGateOpen = open
                return true
            }) else {
                locked { microphoneGateOpen = state.previousGateOpen }
                return false
            }
            setWatchdogGateOpen(open)
            update(["microphoneGateOpen": open, "voiceReplyGraph": true])
            return true
        }
        if open { setWatchdogGateOpen(true) }
        return open
    }

    /// Plays one reply in the room and on the existing local output route.
    public func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
        await playVoiceReply(buffer, localGain: 1)
    }
    public func playVoiceReply(_ buffer: AVAudioPCMBuffer, localGain: Float) async -> Bool {
        if let graph = assistantVoiceGraph(), !graph.gateOpen {
            return await graph.play(buffer, localGain: localGain)
        }
        guard let controller = forwardedAssistantVoiceController(), !controller.isGateOpen() else { return false }
        let effectiveGain: Float? = (locked({ manualRenderingMode }) || localGain <= 0) ? nil : localGain
        return await controller.play(buffer, effectiveGain) { [weak self] in
            guard let self, let active = self.forwardedAssistantVoiceController() else { return false }
            return !active.isGateOpen()
        }
    }
    public func playVoiceReplyStream(_ chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async -> Bool {
        await playVoiceReplyStream(chunks, localGain: 1)
    }
    public func playVoiceReplyStream(_ chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>, localGain: Float) async -> Bool {
        if let graph = assistantVoiceGraph(), !graph.gateOpen {
            return await graph.playStream(chunks, localGain: localGain)
        }
        guard forwardedAssistantVoiceController().map({ !$0.isGateOpen() }) == true else { return false }
        var collected: [AVAudioPCMBuffer] = []
        do {
            for try await chunk in chunks {
                if chunk.frameLength > 0 { collected.append(chunk) }
            }
        } catch {
            return false
        }
        guard !Task.isCancelled, let buffer = GuestVoiceReplyGraph.combine(collected) else { return false }
        guard let activeController = forwardedAssistantVoiceController(), !activeController.isGateOpen() else {
            return false
        }
        let effectiveGain: Float? = (locked({ manualRenderingMode }) || localGain <= 0) ? nil : localGain
        return await activeController.play(buffer, effectiveGain) { [weak self] in
            guard let self, let active = self.forwardedAssistantVoiceController() else { return false }
            return !active.isGateOpen()
        }
    }
    public func setVoiceReplyMonitorGain(_ gain: Float) {
        if let graph = assistantVoiceGraph() {
            graph.setApprovedLocalGain(gain)
        } else {
            locked { forwardedVoiceController }?.setMonitorGain(gain)
        }
    }

    private func assistantVoiceGraph() -> GuestVoiceReplyGraph? {
        locked {
            guard !forwardObserverInstallationPending, let voiceReply, let engine = voiceReply.engine,
                  !forwardedAudioEngines.contains(ObjectIdentifier(engine)) else { return nil }
            return voiceReply
        }
    }

    private func forwardedAssistantVoiceController() -> ForwardedVoiceReplyController? {
        locked {
            guard !forwardObserverInstallationPending, let controller = forwardedVoiceController,
                  !forwardedInputRoutes.isEmpty, createdAudioEngines.isSubset(of: forwardedAudioEngines) else { return nil }
            return controller
        }
    }

    @MainActor public var hasParticipationVoiceGraph: Bool {
        assistantVoiceGraph()?.isConnected == true || forwardedAssistantVoiceController() != nil
    }
    @MainActor public var participationVoiceGateClosed: Bool {
        if let graph = assistantVoiceGraph() {
            return graph.isConnected && !graph.gateOpen
        }
        if let controller = forwardedAssistantVoiceController() {
            return !controller.isGateOpen()
        }
        return false
    }
    @MainActor public var participationSenderPhysicallyMuted: Bool { snapshot["microphoneMuted"] as? Bool == true }

    @MainActor public func setParticipationSenderMuted(_ muted: Bool, permit: GuestAutonomousVoicePlayback) async -> Bool {
        if muted { return await setMicrophoneMuted(true) }
        guard permit.canStart, participationVoiceGateClosed, canUnmuteMicrophone else { return false }
        guard await setMicrophoneMuted(false), permit.canStart, participationVoiceGateClosed else {
            suppressMicrophone()
            return false
        }
        return true
    }

    @MainActor public func playParticipationVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                                  canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                                                  onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        await playParticipationWithGuard(permit: permit, onGraph: { graph, meter in
            await graph.playAutonomous(buffer, permit: permit, canStart: {
                self.assistantVoiceGraph() === graph && graph.isConnected && !graph.gateOpen
                    && (self.snapshot["microphoneMuted"] as? Bool) == false
                    && (meter.level.map { $0 < 0.025 } ?? false) && canStart()
            }, localGain: localGain, captureReady: { LKRTCApplicationCaptureMuted() == 0 }, onStarted: {
                probeLog("participation-voice-capture", ["stage": "playback-started",
                    "processMuted": LKRTCApplicationCaptureMuted() != 0, "voiceProcessing": self.snapshot["voiceProcessingActive"] as? Bool == true])
                onStarted()
            })
        }, onForwarded: { forwarded, meter in
            await self.playParticipationForwarded(buffer, forwarded: forwarded, meter: meter, permit: permit, canStart: canStart, localGain: localGain, onStarted: onStarted)
        })
    }

    @MainActor public func playParticipationVoiceStream(
        firstChunk: AVAudioPCMBuffer,
        remainingChunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
        maxSeconds: TimeInterval,
        permit: GuestAutonomousVoicePlayback,
        canStart: @escaping @MainActor () -> Bool,
        localGain: @escaping @MainActor () -> Float?,
        onStarted: @escaping @MainActor () -> Void
    ) async -> GuestAutonomousVoicePlayback.Outcome {
        await playParticipationWithGuard(permit: permit, onGraph: { graph, meter in
            await graph.playAutonomousStream(firstChunk: firstChunk, remainingChunks: remainingChunks, maxSeconds: maxSeconds, permit: permit, canStart: {
                self.assistantVoiceGraph() === graph && graph.isConnected && !graph.gateOpen
                    && (self.snapshot["microphoneMuted"] as? Bool) == false
                    && (meter.level.map { $0 < 0.025 } ?? false) && canStart()
            }, localGain: localGain, captureReady: { LKRTCApplicationCaptureMuted() == 0 }, onStarted: {
                probeLog("participation-voice-capture", ["stage": "playback-started",
                    "processMuted": LKRTCApplicationCaptureMuted() != 0, "voiceProcessing": self.snapshot["voiceProcessingActive"] as? Bool == true])
                onStarted()
            })
        }, onForwarded: { forwarded, meter in
            var collected: [AVAudioPCMBuffer] = [firstChunk]
            do {
                for try await chunk in remainingChunks {
                    if !permit.canStart || Task.isCancelled { return .notStarted }
                    if chunk.frameLength > 0 { collected.append(chunk) }
                }
            } catch {
                return .notStarted
            }
            guard let combined = GuestVoiceReplyGraph.combine(collected),
                  Double(combined.frameLength) / combined.format.sampleRate <= maxSeconds else { return .notStarted }
            return await self.playParticipationForwarded(combined, forwarded: forwarded, meter: meter, permit: permit, canStart: canStart, localGain: localGain, onStarted: onStarted)
        })
    }

    @MainActor private func playParticipationWithGuard(
        permit: GuestAutonomousVoicePlayback,
        onGraph: @MainActor (GuestVoiceReplyGraph, GuestPCMMeter) async -> GuestAutonomousVoicePlayback.Outcome,
        onForwarded: @MainActor (ForwardedVoiceReplyController, GuestPCMMeter) async -> GuestAutonomousVoicePlayback.Outcome
    ) async -> GuestAutonomousVoicePlayback.Outcome {
        let graph = assistantVoiceGraph()
        let forwarded = graph == nil ? forwardedAssistantVoiceController() : nil
        if let graph {
            guard graph.isConnected, !graph.gateOpen, permit.canStart else { return .notStarted }
        } else if let forwarded {
            guard !forwarded.isGateOpen(), permit.canStart else { return .notStarted }
        } else {
            return .notStarted
        }
        // This tap is upstream of the injection and microphone gate. A local
        // participant's outgoing WebRTC level includes the assistant itself.
        let meter = participationInputMeter
        meter.reset()
        setParticipationInputMeterEnabled(true)
        defer { setParticipationInputMeterEnabled(false) }
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return .notStarted }
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                let routeReady: Bool
                if let graph {
                    routeReady = self.assistantVoiceGraph() === graph && graph.isConnected && !graph.gateOpen
                } else if let forwarded {
                    routeReady = self.forwardedAssistantVoiceController() != nil && !forwarded.isGateOpen()
                } else {
                    routeReady = false
                }
                guard routeReady,
                      !permit.started || (permit.captureIsOpen && LKRTCApplicationCaptureMuted() == 0),
                      let level = meter.level, level < 0.025 else {
                    permit.cancel()
                    return
                }
            }
        }
        defer { monitor.cancel() }
        if let graph {
            return await onGraph(graph, meter)
        }
        guard let forwarded else { return .notStarted }
        return await onForwarded(forwarded, meter)
    }

    private func setParticipationInputMeterEnabled(_ enabled: Bool) {
        inputCallbackLock.lock()
        participationInputMeterEnabled = enabled
        inputCallbackLock.unlock()
    }

    @MainActor private func playParticipationForwarded(
        _ buffer: AVAudioPCMBuffer,
        forwarded: ForwardedVoiceReplyController,
        meter: GuestPCMMeter,
        permit: GuestAutonomousVoicePlayback,
        canStart: @escaping @MainActor () -> Bool,
        localGain: @escaping @MainActor () -> Float?,
        onStarted: @escaping @MainActor () -> Void
    ) async -> GuestAutonomousVoicePlayback.Outcome {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, permit.canStart,
                      self.forwardedAssistantVoiceController() != nil, !forwarded.isGateOpen(),
                      (self.snapshot["microphoneMuted"] as? Bool) == false,
                      (meter.level.map { $0 < 0.025 } ?? false), canStart() else {
                    continuation.resume(returning: .notStarted)
                    return
                }
                let requestedGain = localGain()
                let effectiveGain: Float? = (self.locked({ self.manualRenderingMode }) || (requestedGain ?? 0) <= 0) ? nil : requestedGain
                guard permit.openCapture(), LKRTCApplicationCaptureMuted() == 0 else {
                    permit.cancel()
                    continuation.resume(returning: .notStarted)
                    return
                }
                var playTask: Task<Void, Never>?
                permit.start(stop: { playTask?.cancel() }, localGain: { forwarded.setMonitorGain(max(0, $0)) }) { outcome in
                    continuation.resume(returning: outcome)
                }
                playTask = Task { @MainActor in
                    let completed = await forwarded.play(buffer, effectiveGain) {
                        guard permit.canStart,
                              self.forwardedAssistantVoiceController() != nil, !forwarded.isGateOpen(),
                              (self.snapshot["microphoneMuted"] as? Bool) == false,
                              (meter.level.map { $0 < 0.025 } ?? false), canStart() else {
                            return false
                        }
                        probeLog("participation-voice-capture", ["stage": "playback-started",
                            "processMuted": LKRTCApplicationCaptureMuted() != 0,
                            "voiceProcessing": self.snapshot["voiceProcessingActive"] as? Bool == true])
                        onStarted()
                        return true
                    }
                    let outcome: GuestAutonomousVoicePlayback.Outcome = !permit.captureIsOpen || Task.isCancelled ? .interrupted : (completed ? .completed : .interrupted)
                    permit.finish(outcome, stopping: false)
                }
            }
        } onCancel: {
            Task { @MainActor in permit.cancel() }
        }
    }

    private init(microphoneEnabled: Bool, playoutEnabled: Bool, profile: GuestAudioProfile,
                 lease: GuestAudioOwnerLease, sharedNativeOwner: Bool,
                 sharedInputOutputDependency: Bool = false,
                 bypassVoiceProcessingWhenMuted: Bool = false) {
        microphoneOptIn = microphoneEnabled
        inputActivation = .init(persistent: microphoneEnabled)
        self.profile = profile; ownerLease = lease
        self.sharedNativeOwner = sharedNativeOwner
        self.sharedInputOutputDependency = sharedNativeOwner || sharedInputOutputDependency
        self.bypassVoiceProcessingWhenMuted = bypassVoiceProcessingWhenMuted
        sharedPlayoutGate = GuestSharedPlayoutGate(enabled: sharedNativeOwner)
        self.playoutEnabled = playoutEnabled
        cached = ["mode": "system", "module": "audioEngine", "ownerLeaseID": lease.diagnosticID,
                  "ownerGeneration": UUID().uuidString, "microphoneOptIn": microphoneEnabled,
                  "playoutOptIn": playoutEnabled, "microphoneMutedRequested": !microphoneEnabled,
                  "playoutEnabledRequested": playoutEnabled, "cleanupSucceeded": false,
                  "sharedInputOutputDependency": self.sharedInputOutputDependency,
                  "microphoneAvailabilityPolicy": "explicit-authorized-activation-until-shutdown",
                  "pcmEvidence": "track-renderer-energy-separate-from-hardware-state"]
        super.init()
        GuestAudioEngineGate.shared.register(ObjectIdentifier(self)) { [weak self] in self?.drainNativeWorker() }
    }

    /// Blocks until this owner's native audio worker has run what was queued
    /// before the call (module reads are blocking calls on that worker).
    private func drainNativeWorker() {
        guard let module = currentModule else { return }
        _ = module.engineState; _ = module.isEngineRunning
    }

    deinit {
        let id = ObjectIdentifier(self)
        GuestAudioEngineGate.shared.unregister(id)
        // Even an incompletely constructed/failed owner releases its native factory off the UI thread,
        // and inside the gate, since releasing it tears down its audio engine.
        var remaining: (LKRTCPeerConnectionFactory, GuestAudioOwnerLease?, LKRTCPeerConnection?)? =
            ownedFactory.map { ($0, ownerLease, mediaContext) }
        ownedFactory = nil
        ownerLease = nil
        mediaContext = nil
        if remaining != nil {
            let release = { () -> Void in remaining?.2?.close(); remaining = nil }
            audioQueue.async { GuestAudioEngineGate.shared.run(for: id, release) }
        }
    }

    public static func create(microphoneEnabled: Bool, playoutEnabled: Bool,
                              voiceProcessingEnabled: Bool = true, profile: GuestAudioProfile = .speech,
                              privateCheckOnly: Bool = false, exclusive: Bool = false, concurrent: Bool = false,
                              manualRendering: Bool = false, keepOutputAvailableWithInput: Bool = false,
                              bypassVoiceProcessingWhenMuted: Bool = false,
                              makeFactory: ((_ voiceProcessing: Bool) -> LKRTCPeerConnectionFactory)? = nil,
                              timeout: TimeInterval = 3) async throws -> GuestSystemAudio {
        NativeScreenEncoderQuality.prepare()
        if exclusive || concurrent { _ = LKRTCInitializeSSL() }
        if microphoneEnabled && !GuestSystemAudio.microphoneAuthorized {
            throw GuestSystemAudioError.microphonePermissionRequired
        }
        guard let lease = GuestAudioOwnerLease(privateCheck: privateCheckOnly, exclusive: exclusive,
                                               concurrent: concurrent) else { throw GuestSystemAudioError.physicalOwnerBusy }
        let owner = GuestSystemAudio(microphoneEnabled: microphoneEnabled, playoutEnabled: playoutEnabled,
            profile: profile, lease: lease, sharedNativeOwner: exclusive,
            sharedInputOutputDependency: exclusive || keepOutputAvailableWithInput,
            bypassVoiceProcessingWhenMuted: bypassVoiceProcessingWhenMuted)
        // Manual rendering (tests) has no device for the platform's voice processing to run on.
        let voiceProcessingEnabled = voiceProcessingEnabled && profile.usesPlatformVoiceProcessing && !manualRendering
        let success = await owner.perform("create", timeout: timeout) {
            let factory = owner.nativeCall("create-factory") {
                makeFactory?(voiceProcessingEnabled) ?? LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                    bypassVoiceProcessing: !voiceProcessingEnabled, encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                    decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioProcessingModule: nil)
            }
            owner.locked { owner.ownedFactory = factory }
            owner.update(["factoryGeneration": UUID().uuidString])
            if exclusive || concurrent {
                // The first media peer initializes WebRtcVoiceEngine and binds
                // its audio transport. Doing this after manual recording starts
                // fails RegisterAudioCallback while the SDK buffer is active.
                // This peer has no media, descriptions, data channels or ICE pool.
                let configuration = LKRTCConfiguration()
                configuration.sdpSemantics = .unifiedPlan
                configuration.iceServers = []
                configuration.iceCandidatePoolSize = 0
                let context = owner.nativeCall("prepare-media-context") {
                    factory.peerConnection(with: configuration,
                        constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)
                }
                owner.mediaContext = context
                guard let context, context.localDescription == nil, context.remoteDescription == nil,
                      context.senders.isEmpty, context.receivers.isEmpty, context.transceivers.isEmpty,
                      context.iceGatheringState == .new else { return false }
                owner.update(["mediaContextPrepared": true, "mediaContextGeneration": UUID().uuidString,
                    "mediaContextSenders": 0, "mediaContextReceivers": 0, "mediaContextTransceivers": 0,
                    "mediaContextGatheringNew": true])
            }
            let module = factory.audioDeviceModule
            owner.update(["audioModuleGeneration": UUID().uuidString])
            owner.nativeCall("set-observer") { module.observer = owner }
            if manualRendering {
                // Tests only: the engine renders offline, so no device is opened. Its render
                // thread pulls the output side, which therefore always stays available.
                guard owner.nativeCall("set-manual-rendering", { module.setManualRenderingMode(true) }) == 0 else { return false }
                owner.manualRenderingMode = true
                owner.update(["manualRendering": true])
            }
            guard owner.nativeCall("set-platform-processing", { module.setPlatformVoiceProcessingAllowed(voiceProcessingEnabled && !manualRendering) }) == 0 else { return false }
            owner.update(["voiceProcessingRequested": voiceProcessingEnabled])
            let prepared = owner.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muteMode = owner.nativeCall("set-mute-mode", { module.setMuteMode(.inputMixer) }) == 0
            if microphoneEnabled { owner.syncMutedVoiceProcessingBypass(module, muted: false) }
            let muted = owner.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(!microphoneEnabled) }) == 0
            if !microphoneEnabled { owner.syncMutedVoiceProcessingBypass(module, muted: true) }
            let available = owner.applyAvailability(module)
            owner.readSnapshot(module)
            return prepared && muteMode && muted && available
        }
        guard success else {
            probeLog("physical-audio-setup-failed", owner.snapshot)
            _ = await owner.shutdown(timeout: timeout)
            throw GuestSystemAudioError.setupFailedOrTimedOut
        }
        return owner
    }

    /// Only a prejoin private owner calls this. There is no room, sender or audio track.
    /// A raw-input tap measures aggregate energy before the muted input mixer.
    public func startStandalonePrivateInputCheck(timeout: TimeInterval = 8) async -> Bool {
        setPrivateInputMeterEnabled(true)
        let success = await perform("private-input-check", timeout: timeout) {
            guard !self.closed, self.ownerLease?.privateCheck == true, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.inputActivation.beginCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = GuestMutedInputPreparation.start(
                mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                makeAvailable: { self.applyAvailability(module) },
                startRecording: { self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                isMuted: { module.isMicrophoneMuted })
            self.readSnapshot(module)
            return success
        }
        if !success { setPrivateInputMeterEnabled(false) }
        return success
    }

    /// Borrows this owner's input; never changes its sender or mute intent.
    public func beginPrivateInputCheck(timeout: TimeInterval? = nil) async -> Bool {
        let success = await perform("private-input-borrow", timeout: timeout ?? inputStartupBudget) {
            guard !self.closed, self.inputPermitted, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.inputActivation.beginCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let shouldStartRecording = !module.isRecording && (self.mediaContext != nil || self.manualRenderingMode)
            let success: Bool
            if shouldStartRecording {
                success = GuestMutedInputPreparation.start(
                    mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                    makeAvailable: { self.applyAvailability(module) },
                    startRecording: { module.isRecording || self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                    isMuted: { module.isMicrophoneMuted })
                self.startedRecordingForPrivateCheck = success
            } else {
                self.startedRecordingForPrivateCheck = false
                success = self.applyAvailability(module)
            }
            if !success {
                self.startedRecordingForPrivateCheck = false
                self.inputActivation.endCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable; _ = self.applyAvailability(module)
            }
            self.readSnapshot(module)
            return success
        }
        if success { setPrivateInputMeterEnabled(true) }
        return success
    }

    /// App readiness owns this same ADM and its inert software context, with no
    /// room sender or publishable track.
    /// Explicit recording demand retains the muted physical graph for adoption.
    public func prepareIdleInput(timeout: TimeInterval = 8) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        setPrivateInputMeterEnabled(false)
        setWatchdogInputUnmuted(false)
        if sharedNativeOwner, !(await sharedPlayoutGate.reset(sound: false)) { _ = await shutdown(); return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return await perform("foreground-input-prepare", timeout: remaining) {
            guard !self.closed, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.startedRecordingForPrivateCheck = false
            self.inputPermitted = true
            self.inputActivation = .init(persistent: true); self.microphoneOptIn = true
            self.deferredActivation = false
            self.playoutEnabled = false
            self.update(["inputPermitted": true, "inputKeptWarm": false, "deferredActivation": false,
                         "microphoneOptIn": true, "playoutEnabledRequested": false])
            let success = GuestMutedInputPreparation.start(
                mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                makeAvailable: { self.applyAvailability(module) },
                startRecording: { module.isRecording || self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                isMuted: { module.isMicrophoneMuted })
            if success { self.syncMutedVoiceProcessingBypass(module, muted: true) }
            self.readSnapshot(module)
            return success
        }
    }

    /// Releases muted physical capture for an active talk meeting after an idle cooldown when
    /// microphone readiness is off, leaving playout intact and re-arming deferred activation.
    public func releaseMutedTalkInput(timeout: TimeInterval = 8) async -> Bool {
        setWatchdogInputUnmuted(false)
        return await perform("muted-talk-input-release", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return true }
            guard (self.microphoneOptIn || module.isRecording),
                  self.inputPermitted, module.isMicrophoneMuted,
                  !self.startedRecordingForPrivateCheck,
                  self.locked({ self.microphoneGateOpen }) else {
                self.readSnapshot(module)
                return true
            }
            self.locked {
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
            }
            let clearedPrepared = !module.isRecordingAlwaysPreparedMode ||
                self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            self.deferredActivation = self.deferredActivation || self.microphoneOptIn
            self.inputActivation = .init(persistent: false)
            self.microphoneOptIn = false
            let available = self.applyAvailability(module)
            let stoppedRecording = !module.isRecording ||
                self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            self.update(["deferredActivation": self.deferredActivation, "microphoneOptIn": false])
            self.readSnapshot(module)
            return clearedPrepared && muted && module.isMicrophoneMuted && available && stoppedRecording
        }
    }

    public func setKeepVoiceProcessingWhenMuted(_ keep: Bool) {
        locked { keepVoiceProcessingWhenMuted = keep }
        audioQueue.async {
            guard !self.closed, let module = self.currentModule else { return }
            GuestAudioEngineGate.shared.run(for: ObjectIdentifier(self)) {
                self.syncMutedVoiceProcessingBypass(module, muted: module.isMicrophoneMuted)
                self.readSnapshot(module)
            }
        }
    }

    private func syncMutedVoiceProcessingBypass(_ module: LKRTCAudioDeviceModule, muted: Bool) {
        guard bypassVoiceProcessingWhenMuted,
              !manualRenderingMode,
              snapshot["voiceProcessingRequested"] as? Bool == true else { return }
        let shouldBypass = muted && !locked({ keepVoiceProcessingWhenMuted })
        let activeMismatch = !shouldBypass && module.platformAudioProcessingState.isVoiceProcessingBypassedActive
        if module.isVoiceProcessingBypassed != shouldBypass || activeMismatch {
            nativeCall(shouldBypass ? "bypass-vpio-muted" : "restore-vpio-unmuted") {
                module.isVoiceProcessingBypassed = shouldBypass
            }
        }
    }

    /// Releases idle foreground input when no meetings are attached while the shared factory stays
    /// pinned, stopping recording cleanly so the next prepare restarts via `initAndStartRecording`.
    public func releaseIdleInput(timeout: TimeInterval = 8) async -> Bool {
        setPrivateInputMeterEnabled(false)
        setWatchdogInputUnmuted(false)
        return await perform("idle-input-release", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return true }
            self.locked {
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
            }
            self.startedRecordingForPrivateCheck = false
            self.deferredActivation = false
            self.inputPermitted = false
            self.inputActivation = .init(persistent: false); self.microphoneOptIn = false
            self.playoutEnabled = false
            self.transcriptionOutput = false
            self.update(["microphoneMutedRequested": true, "playoutEnabledRequested": false,
                         "transcriptionOutput": false,
                         "inputPermitted": false, "inputKeptWarm": false,
                         "deferredActivation": false, "microphoneOptIn": false])
            let clearedPrepared = !module.isRecordingAlwaysPreparedMode ||
                self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            let available = self.applyAvailability(module)
            let stoppedRecording = !module.isRecording || self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            self.readSnapshot(module)
            return clearedPrepared && muted && module.isMicrophoneMuted && available && stoppedRecording
        }
    }

    /// Recycles a wedged `AVAudioEngine` / VPIO graph while muted when sustained exact-zero
    /// input PCM is observed during an unmuted send session. Caller restores senders and unmute.
    public func recoverSilentInput(timeout: TimeInterval = 8) async -> Bool {
        setWatchdogInputUnmuted(false)
        return await perform("silent-input-recover", timeout: timeout) {
            guard !self.closed, let module = self.currentModule,
                  self.inputPermitted, self.microphoneOptIn,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            self.locked {
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
            }
            self.update(["microphoneMutedRequested": true])
            let clearedPrepared = !module.isRecordingAlwaysPreparedMode ||
                self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            var unavailable = LKRTCAudioEngineAvailability()
            unavailable.isInputAvailable = false; unavailable.isOutputAvailable = false
            let gated = self.nativeCall("set-engine-unavailable", { module.setEngineAvailability(unavailable) }) == 0
            let stoppedRecording = !module.isRecording || self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            let restarted = GuestMutedInputPreparation.start(
                mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                makeAvailable: { self.applyAvailability(module) },
                startRecording: { module.isRecording || self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                isMuted: { module.isMicrophoneMuted })
            if restarted { self.syncMutedVoiceProcessingBypass(module, muted: true) }
            self.readSnapshot(module)
            return clearedPrepared && muted && gated && stoppedRecording && restarted
        }
    }

    /// Starts or confirms muted microphone recording while keeping playout, gates, and senders unchanged.
    public func ensureAssistantMutedInput(timeout: TimeInterval = 8) async -> Bool {
        await perform("assistant-muted-input", timeout: timeout) {
            guard !self.closed, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized, module.isMicrophoneMuted else { return false }
            if module.isRecording {
                self.syncMutedVoiceProcessingBypass(module, muted: true)
                self.readSnapshot(module)
                return module.isMicrophoneMuted
            }
            guard self.inputPermitted else { return false }
            let wasActivated = self.inputActivation
            self.inputActivation.activate()
            self.microphoneOptIn = self.inputActivation.inputAvailable
            let success = GuestMutedInputPreparation.start(
                mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                makeAvailable: { self.applyAvailability(module) },
                startRecording: { module.isRecording || self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                isMuted: { module.isMicrophoneMuted })
            if success {
                self.syncMutedVoiceProcessingBypass(module, muted: true)
            } else {
                self.inputActivation = wasActivated
                self.microphoneOptIn = self.inputActivation.inputAvailable
                _ = self.applyAvailability(module)
            }
            self.update(["microphoneOptIn": self.microphoneOptIn])
            self.readSnapshot(module)
            return success && module.isRecording && module.isMicrophoneMuted
        }
    }

    /// Peers are detached before this privacy barrier. A room never inherits
    /// another room's activation or unmute choice.
    public func resetForRoom(playout: Bool, preparedInput: Bool) async -> Bool {
        setPrivateInputMeterEnabled(false)
        if sharedNativeOwner, !(await sharedPlayoutGate.reset(sound: playout)) { _ = await shutdown(); return false }
        return await perform("room-audio-reset", timeout: 8) {
            guard !self.closed, let module = self.currentModule else { return false }
            self.locked {
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
            }
            self.startedRecordingForPrivateCheck = false
            // A new room or recovery attempt starts permitted; the meeting reapplies
            // its own withdrawal before any session can activate input.
            self.inputPermitted = true
            let input = preparedInput && GuestSystemAudio.microphoneAuthorized
            self.inputActivation = .init(persistent: input); self.microphoneOptIn = input
            self.deferredActivation = false; self.update(["deferredActivation": false, "inputPermitted": true])
            self.playoutEnabled = playout
            let clearedPrepared = !module.isRecordingAlwaysPreparedMode ||
                self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            let available = self.applyAvailability(module)
            let recording = input || self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            let restored = self.nativeCall("restore-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            self.readSnapshot(module)
            return clearedPrepared && muted && restored && module.isMicrophoneMuted && available && recording
        }
    }

    /// Holds the underlying audio engine across peer teardown during non-terminal
    /// recovery so Bluetooth HFP does not tear down and rebuild before reconnect.
    public func prepareAttemptHandoff(timeout: TimeInterval = 2) async -> Bool {
        setWatchdogInputUnmuted(false)
        return await perform("attempt-handoff-prepare", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return true }
            self.locked { self.attemptHandoffActive = true }
            self.update(["microphoneMutedRequested": true])
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 && module.isMicrophoneMuted
            if self.inputPermitted, self.microphoneOptIn, GuestSystemAudio.microphoneAuthorized,
               module.isRecording || module.isEngineRunning {
                let prepared = self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(true) }) == 0
                self.locked { self.handoffPreparedRecording = prepared }
            } else {
                self.locked { self.handoffPreparedRecording = false }
            }
            self.readSnapshot(module)
            return muted
        }
    }

    /// Re-establishes muted recording on the retained engine after peer teardown
    /// and clears persistent recording-prepared mode.
    public func completeAttemptHandoff(timeout: TimeInterval = 8) async -> Bool {
        setWatchdogInputUnmuted(false)
        return await perform("attempt-handoff-complete", timeout: timeout) {
            let wasPrepared = self.locked {
                let value = self.handoffPreparedRecording
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
                return value
            }
            guard !self.closed, let module = self.currentModule else { return true }
            guard wasPrepared else { return true }
            if self.inputPermitted, self.microphoneOptIn, GuestSystemAudio.microphoneAuthorized,
               self.mediaContext != nil || self.manualRenderingMode {
                let started = GuestMutedInputPreparation.start(
                    mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                    makeAvailable: { self.applyAvailability(module) },
                    startRecording: { module.isRecording || self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                    isMuted: { module.isMicrophoneMuted })
                if started { self.syncMutedVoiceProcessingBypass(module, muted: true) }
                let cleared = self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
                self.readSnapshot(module)
                return started && cleared
            }
            let cleared = self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            self.readSnapshot(module)
            return cleared
        }
    }

    /// Restores capture-off only when the check was the sole activation reason.
    public func endPrivateInputCheck(timeout: TimeInterval = 2) async -> Bool {
        setPrivateInputMeterEnabled(false)
        return await perform("private-input-release", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return true }
            self.inputActivation.endCheck(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let available = self.applyAvailability(module)
            let stoppedRecording: Bool
            if self.startedRecordingForPrivateCheck, !self.microphoneOptIn {
                self.startedRecordingForPrivateCheck = false
                stoppedRecording = self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            } else {
                self.startedRecordingForPrivateCheck = false
                stoppedRecording = true
            }
            self.readSnapshot(module)
            return available && stoppedRecording
        }
    }

    /// The UI calls this only after an explicit, authorized microphone action.
    /// Availability changes while InputMixer remains muted; activation alone sends no input.
    private var inputStartupBudget: TimeInterval {
        // First input activation also initializes the system voice-processing unit.
        // That asynchronous work is separate from an already-running mute change.
        snapshot["inputAvailable"] as? Bool == true ? 2 : 8
    }
    public func activateMicrophone(timeout: TimeInterval? = nil) async -> Bool {
        await perform("microphone-activate", timeout: timeout ?? inputStartupBudget) {
            guard !self.closed, let module = self.currentModule,
                  GuestSystemAudio.microphoneAuthorized else {
                self.update(["lastRejectedOperation": "microphone-not-authorized"]); return false
            }
            // Another meeting holds the microphone: remember the request without input.
            guard self.inputPermitted else {
                self.deferredActivation = true; self.update(["deferredActivation": true]); return true
            }
            let wasActivated = self.inputActivation
            self.inputActivation.activate(); self.microphoneOptIn = self.inputActivation.inputAvailable
            let success: Bool
            if !module.isRecording, self.mediaContext != nil || self.manualRenderingMode {
                let wasMuted = module.isMicrophoneMuted
                if !wasMuted { self.syncMutedVoiceProcessingBypass(module, muted: false) }
                success = GuestMutedInputPreparation.start(
                    mute: { self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 },
                    makeAvailable: { self.applyAvailability(module) },
                    startRecording: { module.isRecording || self.nativeCall("start-recording", { module.initAndStartRecording(audioProcessingOptions: nil) }) == 0 },
                    isMuted: { module.isMicrophoneMuted }) &&
                    (wasMuted || self.nativeCall("restore-microphone-unmuted", { module.setMicrophoneMuted(false) }) == 0)
                if success { self.syncMutedVoiceProcessingBypass(module, muted: wasMuted) }
            } else {
                success = self.applyAvailability(module)
                if success { self.syncMutedVoiceProcessingBypass(module, muted: module.isMicrophoneMuted) }
            }
            if !success { self.inputActivation = wasActivated; self.microphoneOptIn = self.inputActivation.inputAvailable; _ = self.applyAvailability(module) }
            self.update(["microphoneOptIn": self.microphoneOptIn])
            self.readSnapshot(module)
            return success
        }
    }

    /// Enqueue the privacy barrier immediately, before a later unmute can enqueue.
    /// The sender track is suppressed synchronously by the engine as well.
    public func suppressMicrophone() {
        setWatchdogInputUnmuted(false)
        audioQueue.async {
            guard !self.closed, let module = self.currentModule else { return }
            GuestAudioEngineGate.shared.run(for: ObjectIdentifier(self)) {
                self.update(["microphoneMutedRequested": true])
                let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 && module.isMicrophoneMuted
                if muted { self.syncMutedVoiceProcessingBypass(module, muted: true) }
                self.readSnapshot(module)
                self.update(["lastCompletedOperation": "microphone-suppress", "lastOperationSucceeded": muted])
            }
        }
    }

    /// Only opted-in capture remains available while muted. InputMixer avoids restarting playout.
    public func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval = 2) async -> Bool {
        if muted { setWatchdogInputUnmuted(false) }
        // Re-activating released input first initializes the voice-processing unit again.
        let reactivates = !muted && snapshot["deferredActivation"] as? Bool == true
        return await perform("microphone-mute", timeout: reactivates ? max(timeout, 8) : timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            guard muted || self.inputPermitted else {
                self.update(["lastRejectedOperation": "microphone-input-not-permitted"]); return false
            }
            if !muted, !self.microphoneOptIn, self.deferredActivation,
               GuestSystemAudio.microphoneAuthorized {
                let wasActivated = self.inputActivation
                self.inputActivation.activate(); self.microphoneOptIn = self.inputActivation.inputAvailable
                guard self.applyAvailability(module) else {
                    self.inputActivation = wasActivated; self.microphoneOptIn = self.inputActivation.inputAvailable
                    _ = self.applyAvailability(module); self.readSnapshot(module); return false
                }
                self.deferredActivation = false
                self.update(["deferredActivation": false, "microphoneOptIn": self.microphoneOptIn])
            }
            guard muted || (self.microphoneOptIn && GuestSystemAudio.microphoneAuthorized) else {
                self.update(["lastRejectedOperation": "microphone-not-authorized"]); return false
            }
            if !muted, !self.locked({ self.microphoneGateOpen }) {
                let hasConnectedGate: Bool
                if let graph = self.assistantVoiceGraph() {
                    hasConnectedGate = graph.isConnected && !graph.gateOpen
                } else if let controller = self.forwardedAssistantVoiceController() {
                    hasConnectedGate = !controller.isGateOpen()
                } else {
                    hasConnectedGate = false
                }
                guard hasConnectedGate else {
                    self.update(["lastRejectedOperation": "assistant-microphone-gate-unavailable"])
                    return false
                }
            }
            self.update(["microphoneMutedRequested": muted])
            if !muted { self.syncMutedVoiceProcessingBypass(module, muted: false) }
            let changed = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(muted) }) == 0
            let success = changed && module.isMicrophoneMuted == muted
            if muted && success { self.syncMutedVoiceProcessingBypass(module, muted: true) }
            else if !muted && !success && module.isMicrophoneMuted { self.syncMutedVoiceProcessingBypass(module, muted: true) }
            self.readSnapshot(module)
            return success
        }
    }

    /// Withdrawing the permit mutes and makes physical input unavailable;
    /// granting it starts nothing. A later unmute re-activates input explicitly.
    /// With `keepWarm` the permit is withdrawn and the microphone muted, but the
    /// device and voice processing keep running, so moving back skips their
    /// restart. Unmuting is refused until the permit returns, as without it.
    public func setInputPermitted(_ permitted: Bool, keepWarm: Bool = false, timeout: TimeInterval = 8) async -> Bool {
        if !permitted { setPrivateInputMeterEnabled(false); setWatchdogInputUnmuted(false) }
        return await perform(permitted ? "input-permit" : keepWarm ? "input-release-warm" : "input-release", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return !permitted }
            guard !permitted else {
                self.inputPermitted = true; self.update(["inputPermitted": true, "inputKeptWarm": false]); return true
            }
            if keepWarm {
                self.inputPermitted = false
                self.update(["microphoneMutedRequested": true])
                let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
                self.update(["inputPermitted": false, "inputKeptWarm": true])
                self.readSnapshot(module)
                return muted && module.isMicrophoneMuted
            }
            self.locked {
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
            }
            self.deferredActivation = self.deferredActivation || self.microphoneOptIn
            self.inputPermitted = false
            self.update(["microphoneMutedRequested": true])
            let clearedPrepared = !module.isRecordingAlwaysPreparedMode ||
                self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0
            self.inputActivation = .init(persistent: false); self.microphoneOptIn = false
            // Unavailable input releases the device, as a finished private check does.
            // WebRTC's recording demand stays, so a later activation resumes sending.
            let available = self.applyAvailability(module)
            self.update(["inputPermitted": false, "deferredActivation": self.deferredActivation, "microphoneOptIn": false])
            self.readSnapshot(module)
            return clearedPrepared && muted && module.isMicrophoneMuted && available
        }
    }

    /// Experimental warm microphone for a meeting without the talk role: starts the
    /// device and voice processing muted, the state a warm release leaves, so the
    /// first move here skips that startup. The permit stays withdrawn, so nothing
    /// can be unmuted or sent until the talk role moves here.
    public func prewarmInput(timeout: TimeInterval = 8) async -> Bool {
        await perform("input-prewarm", timeout: timeout) {
            guard !self.closed, let module = self.currentModule, !self.inputPermitted,
                  GuestSystemAudio.microphoneAuthorized else { return false }
            if self.microphoneOptIn { return module.isMicrophoneMuted }
            self.update(["microphoneMutedRequested": true])
            guard self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0,
                  module.isMicrophoneMuted else { self.readSnapshot(module); return false }
            let wasActivated = self.inputActivation
            self.inputActivation.activate(); self.microphoneOptIn = self.inputActivation.inputAvailable
            guard self.applyAvailability(module) else {
                self.inputActivation = wasActivated; self.microphoneOptIn = self.inputActivation.inputAvailable
                _ = self.applyAvailability(module); self.readSnapshot(module); return false
            }
            self.deferredActivation = false
            self.syncMutedVoiceProcessingBypass(module, muted: true)
            self.update(["inputKeptWarm": true, "deferredActivation": false, "microphoneOptIn": self.microphoneOptIn])
            self.readSnapshot(module)
            return module.isMicrophoneMuted
        }
    }

    public func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval = 2, expectedEpoch: UUID? = nil) async -> Bool {
        if sharedNativeOwner {
            guard await sharedPlayoutGate.setSound(enabled, expected: expectedEpoch) else {
                if sharedPlayoutGate.matches(expectedEpoch) { _ = await shutdown() }
                return false
            }
        }
        let success = await perform("playout", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            guard self.sharedPlayoutGate.matches(expectedEpoch) else { return false }
            self.playoutEnabled = enabled
            self.update(["playoutEnabledRequested": enabled])
            let success = self.applyAvailability(module)
            self.readSnapshot(module)
            return success
        }
        if sharedNativeOwner, !success, !(await sharedPlayoutGate.close(expected: expectedEpoch)) { _ = await shutdown() }
        return success
    }

    /// Explicit acoustic comparison only. The native knob couples AEC, NS and AGC.
    /// Ordinary duplex runs never call this; failures are followed by mute/Leave.
    func setVoiceProcessingBypassedForTesting(_ bypassed: Bool) async -> Bool {
        await perform("diagnostic-processing-bypass", timeout: 2) {
            guard !self.closed, let module = self.currentModule,
                  self.snapshot["voiceProcessingRequested"] as? Bool == true else { return false }
            self.nativeCall("set-processing-bypass") { module.isVoiceProcessingBypassed = bypassed }
            self.readSnapshot(module)
            let state = self.snapshot
            return state["voiceProcessingActive"] as? Bool == true &&
                state["voiceProcessingBypassedActive"] as? Bool == bypassed &&
                state["echoCancellationActive"] as? Bool == !bypassed
        }
    }

    @discardableResult
    public func refreshSnapshot(timeout: TimeInterval = 2) async -> Bool {
        await perform("snapshot", timeout: timeout) {
            guard !self.closed, let module = self.currentModule else { return false }
            self.readSnapshot(module); return true
        }
    }

    /// Close peers and remove track renderers first. A false result means cleanup is unproven.
    public func shutdown(timeout: TimeInterval = 2) async -> Bool {
        setWatchdogInputUnmuted(false)
        if sharedNativeOwner { _ = await sharedPlayoutGate.close(retire: true) }
        let success = await perform("shutdown", timeout: timeout) {
            self.locked {
                self.handoffPreparedRecording = false
                self.attemptHandoffActive = false
            }
            if self.closed { return self.snapshot["cleanupSucceeded"] as? Bool == true }
            self.closed = true
            guard let module = self.currentModule else { self.update(["cleanupSucceeded": true]); return true }
            self.playoutEnabled = false
            let muted = self.nativeCall("set-microphone-muted", { module.setMicrophoneMuted(true) }) == 0 && module.isMicrophoneMuted
            var unavailable = LKRTCAudioEngineAvailability()
            unavailable.isInputAvailable = false; unavailable.isOutputAvailable = false
            let gated = self.nativeCall("set-engine-unavailable", { module.setEngineAvailability(unavailable) }) == 0
            let recording = self.nativeCall("stop-recording", { module.stopRecording() }) == 0
            let playout = self.nativeCall("stop-playout", { module.stopPlayout() }) == 0
            let prepared = self.nativeCall("set-recording-prepared", { module.setRecordingAlwaysPreparedMode(false) }) == 0
            let stopped = self.nativeCall("verify-stopped") { !module.isEngineRunning && !module.isRecording && !module.isPlaying }
            guard muted && gated && recording && playout && prepared && stopped else {
                self.readSnapshot(module)
                self.update(["cleanupSucceeded": false, "mediaContextClosed": false,
                             "microphoneMutedRequested": true, "playoutEnabledRequested": false])
                // The AudioState owns the installed AudioTransport callback.
                // Dropping it while a buffer may remain active is unsafe.
                return false
            }
            // Release the last software media reference only after both native
            // buffers stop, so transport deregistration cannot race capture.
            self.nativeCall("close-media-context") { self.mediaContext?.close(); self.mediaContext = nil }
            let contextClosed = self.mediaContext == nil
            self.readSnapshot(module)
            self.nativeCall("remove-observer") { module.observer = nil }
            let retiredFactory = self.locked {
                let retired = self.ownedFactory; self.ownedFactory = nil; return retired
            }
            let success = muted && gated && recording && playout && prepared && stopped && contextClosed
            self.update(["cleanupSucceeded": success, "mediaContextClosed": contextClosed,
                         "microphoneMutedRequested": true, "playoutEnabledRequested": false])
            withExtendedLifetime(retiredFactory) {}
            if success { self.ownerLease = nil }
            return success
        }
        if !success {
            GuestAudioOwnerLease.reportFailedStop()
            // A timed-out creator can lose its last caller while native work
            // is still pending. Keep its observer, context, factory and lease
            // alive until process exit rather than leaving a dangling callback.
            Self.retainFailedOwner(self)
        }
        return success
    }

    private var currentModule: LKRTCAudioDeviceModule? { locked { ownedFactory?.audioDeviceModule } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func update(_ values: [String: Any]) { locked { cached.merge(values) { _, value in value } } }

    private func applyAvailability(_ module: LKRTCAudioDeviceModule) -> Bool {
        // Silence before output can become available; unsilence only with sound on.
        if !sharedNativeOwner {
            let (mixer, volume) = locked { () -> (AVAudioMixerNode?, Double) in
                outputSilenced = !playoutEnabled; return (volumeMixer, playoutEnabled ? meetingVolume : 0)
            }
            mixer?.outputVolume = Float(volume)
        }
        let physical = GuestPhysicalAudioAvailability(input: microphoneOptIn,
            playoutRequested: playoutEnabled, sharedNativeOwner: sharedInputOutputDependency, transcription: transcriptionOutput)
        var availability = LKRTCAudioEngineAvailability()
        availability.isInputAvailable = ObjCBool(physical.input)
        availability.isOutputAvailable = ObjCBool(physical.output || manualRenderingMode)
        guard nativeCall("set-engine-availability", { module.setEngineAvailability(availability) }) == 0 else { return false }
#if os(iOS)
        // Availability permits output. An empty room has no WebRTC receiver to start it.
        // The shared meeting owner already has a registered audio transport on its media context.
        if wantsMeetingPlayout {
            meetingPlayoutReserved = true
            return ensureMeetingPlayout(module)
        }
        if meetingPlayoutReserved {
            guard nativeCall("release-meeting-playout", { module.stopPlayout() }) == 0 else { return false }
            meetingPlayoutReserved = false
        }
#endif
        return true
    }

#if os(iOS)
    private var wantsMeetingPlayout: Bool { !manualRenderingMode && mediaContext != nil && (playoutEnabled || transcriptionOutput) }

    private func ensureMeetingPlayout(_ module: LKRTCAudioDeviceModule) -> Bool {
        guard module.isPlayoutInitialized || nativeCall("init-meeting-playout", { module.initPlayout() }) == 0 else { return false }
        return module.isPlaying || nativeCall("start-meeting-playout", { module.startPlayout() }) == 0
    }

    // WebRTC may withdraw playout when its last receiver leaves. Wait for the native
    // callback to return, then check the current room intent and the committed ADM state.
    private func restoreMeetingPlayoutIfNeeded() {
        audioQueue.async {
            guard !self.closed, self.meetingPlayoutReserved, self.wantsMeetingPlayout, let module = self.currentModule,
                  !module.isPlayoutInitialized || !module.isPlaying else { return }
            let restored = GuestAudioEngineGate.shared.run(for: ObjectIdentifier(self)) {
                self.ensureMeetingPlayout(module)
            }
            self.update(["meetingPlayoutRestored": restored])
        }
    }
#endif

    private func readSnapshot(_ module: LKRTCAudioDeviceModule) {
        operationTrace.beginNativeCall("read-native-snapshot")
        defer { operationTrace.endNativeCall(result: "complete") }
        // input/outputRunning and isRecording/isPlaying are raw WebRTC demand.
        // Availability and actual engine state are reported separately.
        let state = module.engineState, availability = module.engineAvailability
        let processing = module.platformAudioProcessingState
        let refreshDevices = locked { () -> Bool in
            guard deviceCountsDirty else { return false }
            deviceCountsDirty = false
            return true
        }
        let (inputDevices, outputDevices): (Int, Int)
        if refreshDevices {
            let inputs = module.inputDevices.count
            let outputs = module.outputDevices.count
            locked {
                cachedInputDeviceCount = inputs
                cachedOutputDeviceCount = outputs
            }
            (inputDevices, outputDevices) = (inputs, outputs)
        } else {
            (inputDevices, outputDevices) = locked { (cachedInputDeviceCount, cachedOutputDeviceCount) }
        }
        let micMuted = module.isMicrophoneMuted
        setWatchdogInputUnmuted(!micMuted)
        update(["inputAvailable": availability.isInputAvailable.boolValue, "outputAvailable": availability.isOutputAvailable.boolValue,
                "inputEnabled": state.inputEnabled.boolValue, "inputRunning": state.inputRunning.boolValue,
                "outputEnabled": state.outputEnabled.boolValue, "outputRunning": state.outputRunning.boolValue,
                "microphoneMuted": micMuted, "muteMode": state.muteMode.rawValue,
                "engineRunning": module.isEngineRunning, "recording": module.isRecording, "playing": module.isPlaying,
                "inputDeviceCount": inputDevices, "outputDeviceCount": outputDevices,
                "recordingAlwaysPrepared": module.isRecordingAlwaysPreparedMode,
                "voiceProcessingActive": processing.isVoiceProcessingEnabledActive,
                "voiceProcessingBypassedActive": processing.isVoiceProcessingBypassedActive,
                "echoCancellationActive": processing.echoCancellation.isActive,
                "snapshotUptime": ProcessInfo.processInfo.systemUptime])
    }

    private func nativeCall<Result>(_ name: String, _ body: () -> Result) -> Result {
        operationTrace.beginNativeCall(name)
        let result = body()
        // Factories are recorded by stage only; native status calls retain their exact result.
        operationTrace.endNativeCall(result: result is LKRTCPeerConnectionFactory ? "created" : String(describing: result))
        return result
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ result: Bool, beforeResume: () -> Void = {}) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            if let pending { beforeResume(); pending.resume(returning: result) }
        }
    }

    private func perform(_ name: String, timeout: TimeInterval, _ body: @escaping @Sendable () -> Bool) async -> Bool {
        let operationID = operationTrace.enqueue(name, timeout: timeout)
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.01, timeout)) {
                completion.finish(false) {
                    self.operationTrace.timedOut(operationID)
                    self.update(["lastTimedOutOperation": name, "cleanupSucceeded": false])
                    probeLog("physical-audio-operation-timeout", self.snapshot)
                }
            }
            audioQueue.async {
                self.operationTrace.start(operationID)
                // One owner's native audio work at a time, after others' queued work.
                self.locked { self.operationDepth += 1 }
                let result = GuestAudioEngineGate.shared.run(for: ObjectIdentifier(self), body)
                self.locked { self.operationDepth -= 1 }
                self.operationTrace.finish(operationID, succeeded: result)
                self.update(["lastCompletedOperation": name, "lastOperationSucceeded": result])
                if !result { probeLog("physical-audio-operation-failed", self.snapshot) }
                completion.finish(result)
            }
        }
    }

    // Observer callbacks run on the native audio worker. They only update small cached values;
    // they must not call the blocking ADM API or synchronously dispatch to audioQueue.
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent) {
        forwardObserver?.audioDeviceModule(audioDeviceModule, didReceiveSpeechActivityEvent: event)
        update(["speechActivityEvent": event.rawValue])
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        let id = ObjectIdentifier(engine)
        let forwarding = locked { () -> LKRTCAudioDeviceModuleDelegate? in
            createdAudioEngines.insert(id)
            return forwardObserverInstallationPending ? nil : forwardObserverStorage
        }
        let forwarded = forwarding?.audioDeviceModule(audioDeviceModule, didCreateEngine: engine) ?? 0
        locked {
            // Existing engines never acquire an observer partway through their lifecycle.
            if forwarding != nil, forwarded == 0 { forwardedAudioEngines.insert(id) }
            cached["enginesCreated"] = (cached["enginesCreated"] as? Int ?? 0) + 1
        }
        logLifecycle("engine-created"); return forwarded
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                                  isPlayoutEnabled: Bool, isRecordingEnabled: Bool, isVoiceProcessingEnabled: Bool) -> Int {
        let forwarded = forwardObserver(for: engine)?.audioDeviceModule?(audioDeviceModule, willEnableEngine: engine, isPlayoutEnabled: isPlayoutEnabled,
            isRecordingEnabled: isRecordingEnabled, isVoiceProcessingEnabled: isVoiceProcessingEnabled) ?? 0
        update(["voiceProcessingEnabled": isVoiceProcessingEnabled]); return forwarded
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                                  isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        interruptVoiceReply(on: engine)
        let forwarded = forwardObserver(for: engine)?.audioDeviceModule(audioDeviceModule, willStartEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
        locked { cached["engineStarts"] = (cached["engineStarts"] as? Int ?? 0) + 1 }
        logLifecycle("engine-start", ["playout": isPlayoutEnabled, "recording": isRecordingEnabled])
        reportSpontaneous(.started); return forwarded
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                                  isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        interruptVoiceReply(on: engine)
        let forwarded = forwardObserver(for: engine)?.audioDeviceModule(audioDeviceModule, didStopEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
        locked { cached["engineStops"] = (cached["engineStops"] as? Int ?? 0) + 1 }
        logLifecycle("engine-stop", ["playout": isPlayoutEnabled, "recording": isRecordingEnabled])
        if !locked({ attemptHandoffActive || (handoffPreparedRecording && isRecordingEnabled) }) {
            reportSpontaneous(.stopped)
        }
#if os(iOS)
        if isPlayoutEnabled { restoreMeetingPlayoutIfNeeded() }
#endif
        return forwarded
    }
    private func interruptVoiceReply(on engine: AVAudioEngine) {
        let graph = locked { voiceReply }
        if graph?.engine === engine { graph?.stop() }
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                                  isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        if !isRecordingEnabled { locked { _ = forwardedInputRoutes.remove(ObjectIdentifier(engine)) } }
#if os(iOS)
        if !isPlayoutEnabled { restoreMeetingPlayoutIfNeeded() }
#endif
        return forwardObserver(for: engine)?.audioDeviceModule(audioDeviceModule, didDisableEngine: engine,
            isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        let id = ObjectIdentifier(engine)
        let forwarding = locked { () -> LKRTCAudioDeviceModuleDelegate? in
            forwardedInputRoutes.remove(id)
            return forwardedAudioEngines.contains(id) ? forwardObserverStorage : nil
        }
        let forwarded = forwarding?.audioDeviceModule(audioDeviceModule, willReleaseEngine: engine) ?? 0
        if let tappedInput, tappedEngine === engine {
            tappedInput.removeTap(onBus: 0); self.tappedInput = nil; tappedEngine = nil
            inputCallbackLock.lock()
            inputSilenceWatchdog.resetEngine()
            inputCallbackLock.unlock()
        }
        if let tappedPlayout, tappedPlayoutEngine === engine {
            sharedPlayoutGate.remove(identity: ObjectIdentifier(tappedPlayout))
            tappedPlayout.removeTap(onBus: 0); self.tappedPlayout = nil; tappedPlayoutEngine = nil
        }
        // A reply in progress ends with its engine; the gate state is kept for the next one.
        let graph = locked { () -> GuestVoiceReplyGraph? in
            if participationPlayoutEngine === engine {
                participationPlayoutMixer = nil; participationPlayoutEngine = nil; participationPlayoutFormat = nil
            }
            guard let current = voiceReply, current.engine === engine else { return nil }
            voiceReply = nil; return current
        }
        graph?.detach()
        locked {
            createdAudioEngines.remove(id)
            forwardedAudioEngines.remove(id)
            cached["enginesReleased"] = (cached["enginesReleased"] as? Int ?? 0) + 1
        }
        logLifecycle("engine-released")
        if !locked({ attemptHandoffActive }) {
            reportSpontaneous(.stopped)
        }
        return forwarded
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                                  configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
                                  format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        // The other observer wires the input first; this owner then only taps the source.
        let id = ObjectIdentifier(engine)
        let forwarding = forwardObserver(for: engine)
        if let forwarding {
            let (gateOpen, controller) = locked { () -> (Bool, ForwardedVoiceReplyController?) in
                forwardedInputRoutes.remove(id)
                return (microphoneGateOpen, forwardedVoiceController)
            }
            // A replacement SDK graph may not bypass a held Guest gate.
            let inputMixer = engine.isInManualRenderingMode ? engine.mainMixerNode :
                context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode
            guard let inputMixer, controller != nil || gateOpen else { return -1 }
            let result = forwarding.audioDeviceModule(audioDeviceModule, engine: engine, configureInputFromSource: source,
                toDestination: destination, format: format, context: context)
            guard result == 0 else { return result }
            let prove = locked { proveForwardedInput }
            guard prove?(engine, source, inputMixer) == true else { return -1 }
            if let controller {
                guard controller.setGateOpen(gateOpen) else { return -1 }
                setWatchdogGateOpen(gateOpen)
                update(["voiceReplyGraph": true, "microphoneGateOpen": gateOpen])
            }
            locked { _ = forwardedInputRoutes.insert(id) }
        }
        update(["inputSampleRate": format.sampleRate, "inputChannels": Int(format.channelCount), "inputASBD": Self.signature(format)])
        if let source, source !== tappedInput, format.sampleRate > 0, format.channelCount > 0 {
            tappedInput?.removeTap(onBus: 0)
            tappedInput = source; tappedEngine = engine
            inputCallbackLock.lock()
            inputSilenceWatchdog.resetEngine()
            inputCallbackLock.unlock()
            source.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let receivedUptime = ProcessInfo.processInfo.systemUptime, deliveredFormat = buffer.format
                let signature = withExtendedLifetime(deliveredFormat) { GuestStartupAudioCallback.Format(deliveredFormat.streamDescription.pointee) }
                let measured = GuestPCMMeter.bufferEnergy(buffer)
                self.inputCallbackLock.lock()
                self.inputCallback = .init(count: self.inputCallback.count + 1, frames: Int(buffer.frameLength),
                    format: signature, uptime: receivedUptime)
                let triggered = self.inputSilenceWatchdog.observe(
                    samples: measured.samples,
                    energy: measured.energy,
                    unmuted: !self.manualRenderingMode && self.watchdogInputUnmuted && LKRTCApplicationCaptureMuted() == 0,
                    gateOpen: self.watchdogGateOpen,
                    at: receivedUptime
                )
                let silentCallback: (([String: Any]) -> Void)?
                let silentEvidence: [String: Any]?
                if triggered {
                    silentCallback = self.silentInputHandler
                    silentEvidence = self.inputSilenceWatchdog.diagnosticFields(at: receivedUptime)
                } else {
                    silentCallback = nil
                    silentEvidence = nil
                }
                let metering = self.inputMeterEnabled
                let participationMetering = self.participationInputMeterEnabled
                let sink = self.inputTranscriptionSink
                self.inputCallbackLock.unlock()
                sink?(buffer)
                if metering { self.inputMeter.render(pcmBuffer: buffer) }
                if participationMetering { self.participationInputMeter.render(pcmBuffer: buffer) }
                if let silentCallback, let silentEvidence {
                    DispatchQueue.global(qos: .utility).async {
                        silentCallback(silentEvidence)
                    }
                }
            }
        }
        // Voice replies: microphone → gate → input mixer ← player.
        let needsGate = locked { !microphoneGateOpen }
        if forwarding == nil, Self.voiceRepliesEnabled || needsGate,
           let inputMixer = context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode {
            let graph: GuestVoiceReplyGraph = locked {
                if let existing = voiceReply, existing.engine === engine { return existing }
                let created = GuestVoiceReplyGraph(engine: engine, gateOpen: microphoneGateOpen)
                voiceReply = created; return created
            }
            let connected = graph.connect(source: source, inputMixer: inputMixer, format: format)
            if let output = locked({ participationMonitorRoute(for: engine) }) {
                graph.connectMonitor(to: output.mixer, format: output.format)
            }
            setWatchdogGateOpen(graph.gateOpen)
            update(["voiceReplyGraph": connected, "microphoneGateOpen": graph.gateOpen])
            if connected { return 0 }
        }
        // An unwired callback lets the ADM fall back to its default raw input.
        guard (forwarding != nil && locked({ forwardedVoiceController != nil })) || locked({ microphoneGateOpen }) else { return -1 }
#if DEBUG
        if forwarding == nil, engine.isInManualRenderingMode, let fixture = locked({ manualLegacyInputFixture }) {
            return fixture.audioDeviceModule(audioDeviceModule, engine: engine, configureInputFromSource: source,
                toDestination: destination, format: format, context: context)
        }
#endif
        return 0
    }
    public func audioDeviceModule(_ audioDeviceModule: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                                  configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
                                  format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        let forwarding = forwardObserver(for: engine)
        let forwarded = forwarding?.audioDeviceModule(audioDeviceModule, engine: engine, configureOutputFromSource: source,
            toDestination: destination, format: format, context: context) ?? 0
        guard forwarded == 0 else { return forwarded }
        if destination != nil, forwarding == nil, Self.voiceRepliesEnabled,
           let mixer = source as? AVAudioMixerNode {
            let graph = locked { () -> GuestVoiceReplyGraph? in
                participationPlayoutMixer = mixer; participationPlayoutEngine = engine; participationPlayoutFormat = format
                return voiceReply?.engine === engine ? voiceReply : nil
            }
            graph?.connectMonitor(to: mixer, format: format)
        }
        if sharedNativeOwner {
            guard let mixer = source as? AVAudioMixerNode,
                  sharedPlayoutGate.bind(identity: ObjectIdentifier(mixer), setGain: { [weak mixer] value in
                      guard let mixer else { return value == 0 }
                      mixer.outputVolume = Float(value)
                      return mixer.outputVolume == Float(value)
                  }) else { return -1 }
        } else if let mixer = source as? AVAudioMixerNode {
            let volume = locked { () -> Double in volumeMixer = mixer; return outputSilenced ? 0 : meetingVolume }
            mixer.outputVolume = Float(volume)
        }
        update(["outputSampleRate": format.sampleRate, "outputChannels": Int(format.channelCount), "outputASBD": Self.signature(format)])
        // Hardware's existing output pull drives this aggregate meter. No
        // recorder, second engine, audio-file storage or monitoring route exists.
        if destination != nil, source !== tappedPlayout, format.sampleRate > 0, format.channelCount > 0 {
            tappedPlayout?.removeTap(onBus: 0)
            tappedPlayout = source; tappedPlayoutEngine = engine
            source.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.playoutMeter.render(pcmBuffer: buffer)
            }
        }
        return 0
    }
    private func participationMonitorRoute(for engine: AVAudioEngine) -> (mixer: AVAudioMixerNode, format: AVAudioFormat)? {
        guard participationPlayoutEngine === engine, let participationPlayoutMixer, let participationPlayoutFormat else { return nil }
        return (participationPlayoutMixer, participationPlayoutFormat)
    }
    public func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: LKRTCAudioDeviceModule) {
        forwardObserver?.audioDeviceModuleDidUpdateDevices(audioDeviceModule)
        locked {
            deviceCountsDirty = true
            cached["deviceUpdates"] = (cached["deviceUpdates"] as? Int ?? 0) + 1
        }
        logLifecycle("device-update")
    }
    private static func signature(_ format: AVAudioFormat) -> [Double] {
        let s = format.streamDescription.pointee
        return [s.mSampleRate, Double(s.mFormatID), Double(s.mFormatFlags), Double(s.mBytesPerPacket),
            Double(s.mFramesPerPacket), Double(s.mBytesPerFrame), Double(s.mChannelsPerFrame), Double(s.mBitsPerChannel), Double(s.mReserved)]
    }
}
