import AVFoundation
import ConferenceCore
import Foundation
import MLXAudioCore
import MLXAudioTTS
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class IOSVoxCPM2ResilienceTests: XCTestCase {
    private final class SuiteBox {
        let name: String
        let defaults: UserDefaults

        init() {
            name = "ios.voxcpm2.resilience.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ initial: Value) {
            self.value = initial
        }

        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private func makeInstalledVoxStore(
        defaults: UserDefaults,
        foregroundActiveProvider: (@Sendable () -> Bool)? = nil,
        synthesizeOverride: (@Sendable (String, VoxVoice?, URL, @escaping @Sendable () -> Bool) async throws -> [Float])? = nil
    ) throws -> (store: IOSVoxCPM2Store, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxResilience-\(UUID().uuidString)", isDirectory: true)
        let store = IOSVoxCPM2Store(
            modelsDirectory: root,
            preferences: defaults,
            hardwareSupportedProvider: { true },
            freeDiskBytesProvider: { _ in 20_000_000_000 },
            foregroundActiveProvider: foregroundActiveProvider,
            synthesizeOverride: synthesizeOverride
        )
        for spec in IOSVoxCPM2Store.modelFiles {
            let fileURL = store.modelDirectory.appendingPathComponent(spec.relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: fileURL)
        }
        store.refreshInstallState()
        XCTAssertEqual(store.installState, .installed)

        let voice = VoxVoice(
            mode: .cloneContinuation,
            transcript: "Test sample",
            reference: [Float](repeating: 0.1, count: VoxVoice.patchValues),
            continuation: [Float](repeating: 0.2, count: VoxVoice.patchValues),
            patches: 1
        )
        try store.persistVoice(
            StoredClonedVoice(
                voice: voice,
                recordedAt: Date(timeIntervalSince1970: 1_750_000_000),
                seconds: 5.0
            )
        )
        return (store, root)
    }

    func testSwayScheduleMatchesFormulaAndBoundaries() {
        XCTAssertEqual(VoxCPM2Model.swaySchedule(nTimesteps: 0), [1.0, 0.0])

        let steps = 10
        let schedule = VoxCPM2Model.swaySchedule(nTimesteps: steps)
        XCTAssertEqual(schedule.count, steps + 1)
        XCTAssertEqual(schedule.first ?? -1, 1.0, accuracy: 1e-6)
        XCTAssertEqual(schedule.last ?? -1, 0.0, accuracy: 1e-6)

        for i in 0 ... steps {
            let u = 1.0 - Float(i) / Float(steps)
            let expected = 2.0 * u + cosf(Float.pi / 2.0 * u) - 1.0
            XCTAssertEqual(schedule[i], expected, accuracy: 1e-6, "step \(i)")
            if i < steps {
                XCTAssertGreaterThan(schedule[i], schedule[i + 1], "schedule must strictly decrease at \(i)")
            }
        }
    }

    func testErrorClassifierMapsAllowlistedReasons() {
        func nsError(_ message: String) -> NSError {
            NSError(domain: "VoxResilienceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let backgroundMetal = "[METAL] Command buffer execution failed: Execution of the command buffer was aborted due to an error during execution. Insufficient Permission (to submit GPU work from background) (00000006:kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)."
        XCTAssertEqual(IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError(backgroundMetal)), "background")
        XCTAssertEqual(
            IOSVoxCPM2ErrorClassifier.reasonCode(
                for: IOSVoiceSynthesisError.voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
            ),
            "background"
        )

        let oomMetal = "[METAL] Command buffer execution failed: Execution of the command buffer was aborted due to an error during execution. Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)."
        XCTAssertEqual(IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError(oomMetal)), "metal-oom")
        XCTAssertEqual(IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError("[malloc] Unable to allocate 67108864 bytes.")), "metal-oom")

        let timeoutMetal = "[METAL] Command buffer execution failed: Execution of the command buffer was aborted due to an error during execution. Caused GPU Timeout Error (00000002:kIOGPUCommandBufferCallbackErrorTimeout)."
        XCTAssertEqual(IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError(timeoutMetal)), "metal-timeout")

        let genericMetal = "[METAL] Command buffer execution failed: Execution of the command buffer was aborted due to an error during execution. Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)."
        XCTAssertEqual(IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError(genericMetal)), "metal-command-buffer")

        XCTAssertEqual(
            IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError("MLX Error: [eval] Attempting to eval an array without a primitive.")),
            "mlx-eval"
        )
        XCTAssertEqual(
            IOSVoxCPM2ErrorClassifier.reasonCode(for: AudioGenerationError.invalidInput("Speech exceeded the generation limit")),
            "context-limit"
        )
        XCTAssertEqual(IOSVoxCPM2ErrorClassifier.reasonCode(for: nsError("Unexpected error")), "other")
    }

    func testStoreSkipsSynthesisWhenBackgrounded() async throws {
        let suite = SuiteBox()
        let callCount = LockedBox(0)
        let (store, root) = try makeInstalledVoxStore(
            defaults: suite.defaults,
            foregroundActiveProvider: { false },
            synthesizeOverride: { _, _, _, _ in
                callCount.withLock { $0 += 1 }
                XCTFail("Synthesis should not start when app is backgrounded")
                return [0.1]
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for action: () async throws -> AVAudioPCMBuffer in [
            { try await store.speak("Hello world") },
            { try await store.speakPreset("Hello world", preset: .warmFemale) },
            { try await store.speakClonedForAssistant("Hello world") }
        ] {
            do {
                _ = try await action()
                XCTFail("Expected background refusal error")
            } catch let error as IOSVoiceSynthesisError {
                XCTAssertEqual(
                    error,
                    .voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
                )
            }
        }
        XCTAssertEqual(callCount.withLock { $0 }, 0)
    }

    func testStoreLifecycleNotificationsFlipForegroundGateMidSynthesis() async throws {
        let suite = SuiteBox()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        defer {
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        let observations = LockedBox<(calls: Int, transitions: [(Bool, Bool)])>((0, []))
        let (store, root) = try makeInstalledVoxStore(
            defaults: suite.defaults,
            foregroundActiveProvider: nil,
            synthesizeOverride: { _, _, _, shouldContinue in
                let callIndex = observations.withLock { state -> Int in
                    state.calls += 1
                    return state.calls
                }
                if callIndex == 1 {
                    let before = shouldContinue()
                    await MainActor.run {
                        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                    }
                    let after = shouldContinue()
                    observations.withLock { $0.transitions.append((before, after)) }
                    throw AudioGenerationError.generationFailed("GPU synthesis interrupted because app is no longer active")
                }
                XCTAssertTrue(shouldContinue())
                return [Float](repeating: 0.05, count: 480)
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Call 1 starts active, resigns mid-synthesis, and aborts cleanly.
        do {
            _ = try await store.speakPreset("First utterance", preset: .warmFemale)
            XCTFail("Expected interruption when app resigns active")
        } catch let error as IOSVoiceSynthesisError {
            guard case .voxRuntimeFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let snapshot = observations.withLock { $0 }
        XCTAssertEqual(snapshot.calls, 1)
        XCTAssertEqual(snapshot.transitions.count, 1)
        XCTAssertTrue(snapshot.transitions[0].0)
        XCTAssertFalse(snapshot.transitions[0].1)

        // While still inactive, a new synthesis call is rejected immediately before invoking runtime.
        do {
            _ = try await store.speakPreset("Blocked while inactive", preset: .warmFemale)
            XCTFail("Expected inactive refusal")
        } catch let error as IOSVoiceSynthesisError {
            XCTAssertEqual(
                error,
                .voxRuntimeFailed("App is not active for on-device GPU speech synthesis.")
            )
        }
        XCTAssertEqual(observations.withLock { $0.calls }, 1)

        // Becoming active again restores synthesis capability.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let buffer = try await store.speakPreset("Active again", preset: .warmFemale)
        XCTAssertEqual(buffer.frameLength, 480)
        XCTAssertEqual(observations.withLock { $0.calls }, 2)
    }

    func testAssistantResponseFallsBackToSystemVoiceOnVoxBackgroundOrMLXError() async throws {
        // 1. Backgrounded VoxCPM2 store triggers System Voice fallback instead of crashing.
        do {
            let suite = SuiteBox()
            let (voxStore, root) = try makeInstalledVoxStore(
                defaults: suite.defaults,
                foregroundActiveProvider: { false }
            )
            defer { try? FileManager.default.removeItem(at: root) }

            let voiceStore = IOSVoiceStore(preferences: suite.defaults, voxStore: voxStore)
            for voice in [AssistantAuditionVoiceSelection.voxPreset(.warmFemale), .clonedVoice] {
                voiceStore.assistantAuditionVoice = voice
                do {
                    let buffer = try await voiceStore.synthesizeAssistantResponse("Hello from assistant")
                    XCTAssertGreaterThan(buffer.frameLength, 0)
                } catch let error as IOSVoiceSynthesisError {
                    // Bare simulator images without TTS voices may fail with `.system`, never `.voxRuntimeFailed`.
                    XCTAssertEqual(error, .system)
                }
            }
        }

        // 2. Caught MLX/Metal error inside VoxCPM2 store also triggers System Voice fallback.
        do {
            let suite = SuiteBox()
            let (voxStore, root) = try makeInstalledVoxStore(
                defaults: suite.defaults,
                foregroundActiveProvider: { true },
                synthesizeOverride: { _, _, _, _ in
                    throw NSError(
                        domain: "MLX",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "MLX Error: [eval] Attempting to eval an array without a primitive."]
                    )
                }
            )
            defer { try? FileManager.default.removeItem(at: root) }

            let voiceStore = IOSVoiceStore(preferences: suite.defaults, voxStore: voxStore)
            for voice in [AssistantAuditionVoiceSelection.voxPreset(.calmAssistant), .clonedVoice] {
                voiceStore.assistantAuditionVoice = voice
                do {
                    let buffer = try await voiceStore.synthesizeAssistantResponse("Fallback test")
                    XCTAssertGreaterThan(buffer.frameLength, 0)
                } catch let error as IOSVoiceSynthesisError {
                    XCTAssertEqual(error, .system)
                }
            }
        }

        // 3. Genuine CancellationError must still propagate rather than falling back.
        do {
            let suite = SuiteBox()
            let (voxStore, root) = try makeInstalledVoxStore(
                defaults: suite.defaults,
                foregroundActiveProvider: { true },
                synthesizeOverride: { _, _, _, _ in
                    throw CancellationError()
                }
            )
            defer { try? FileManager.default.removeItem(at: root) }

            let voiceStore = IOSVoiceStore(preferences: suite.defaults, voxStore: voxStore)
            voiceStore.assistantAuditionVoice = .voxPreset(.warmFemale)
            do {
                _ = try await voiceStore.synthesizeAssistantResponse("Cancel test")
                XCTFail("Expected CancellationError to propagate")
            } catch is CancellationError {
                // Expected.
            }
        }
    }

    func testSerialGatePreventsConcurrentOverlapAndHandlesWaiterCancellation() async throws {
        let gate = IOSVoxSerialGate()
        let tracker = LockedBox<(active: Int, maxActive: Int, order: [Int])>((0, 0, []))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<4 {
                group.addTask {
                    try await gate.withExclusiveAccess {
                        tracker.withLock { state in
                            state.active += 1
                            state.maxActive = max(state.maxActive, state.active)
                            state.order.append(idx)
                        }
                        try await Task.sleep(for: .milliseconds(25))
                        tracker.withLock { state in
                            state.active -= 1
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        let summary = tracker.withLock { $0 }
        XCTAssertEqual(summary.maxActive, 1)
        XCTAssertEqual(summary.active, 0)
        XCTAssertEqual(summary.order.count, 4)

        // Verify cancelling a queued waiter throws CancellationError without deadlocking subsequent waiters.
        let holderStarted = LockedBox(false)
        let holderTask = Task {
            try await gate.withExclusiveAccess {
                holderStarted.withLock { $0 = true }
                try await Task.sleep(for: .milliseconds(120))
            }
        }

        while !holderStarted.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }

        let cancelledWaiter = Task {
            try await gate.withExclusiveAccess { "should-not-run" }
        }
        try await Task.sleep(for: .milliseconds(15))
        let trailingWaiter = Task {
            try await gate.withExclusiveAccess { "trailing-ok" }
        }
        try await Task.sleep(for: .milliseconds(15))
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected cancelled waiter to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        try await holderTask.value
        let trailingResult = try await trailingWaiter.value
        XCTAssertEqual(trailingResult, "trailing-ok")
        let stillBusy = await gate.isBusy
        XCTAssertFalse(stillBusy)
    }
}
