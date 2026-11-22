import Foundation
import XCTest
@testable import ConferenceCore

final class RealtimeVoiceProtocolTests: XCTestCase {
    func testOpenAIRealtimeWirePayloadsAndParsing() throws {
        let url = try XCTUnwrap(OpenAIRealtimeClient.makeEndpointURL(base: "wss://api.openai.com/v1/realtime", model: "gpt-realtime"))
        XCTAssertTrue(url.absoluteString.contains("model=gpt-realtime"))

        let tool = RealtimeToolDeclaration(
            name: "rocknroll_create_task",
            description: "Create a task",
            parametersJSONSchema: [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ]
        )
        let config = RealtimeSessionConfig(
            provider: .openAIRealtime,
            apiKey: "sk-test",
            systemInstructions: "Act as Scrum Master.",
            tools: [tool]
        )
        let update = OpenAIRealtimeClient.sessionUpdatePayload(config: config)
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["voice"] as? String, "alloy")
        XCTAssertEqual((session["tools"] as? [[String: Any]])?.count, 1)

        let audioChunk = Data([0x01, 0x02, 0x03, 0x04])
        let deltaData = try JSONSerialization.data(withJSONObject: [
            "type": "response.output_audio.delta",
            "delta": audioChunk.base64EncodedString(),
        ])
        let events = try XCTUnwrap(OpenAIRealtimeClient.parseServerEvent(deltaData))
        guard case .audioPCM16(let pcm, let rate) = events.first else {
            return XCTFail("Expected audioPCM16 event")
        }
        XCTAssertEqual(pcm, audioChunk)
        XCTAssertEqual(rate, 24_000)

        let fnData = try JSONSerialization.data(withJSONObject: [
            "type": "response.function_call_arguments.done",
            "call_id": "call_99",
            "name": "rocknroll_create_task",
            "arguments": "{\"text\":\"Fix crash\"}",
        ])
        let fnEvents = try XCTUnwrap(OpenAIRealtimeClient.parseServerEvent(fnData))
        guard case .toolCall(let cid, let name, let args) = fnEvents.first else {
            return XCTFail("Expected toolCall event")
        }
        XCTAssertEqual(cid, "call_99")
        XCTAssertEqual(name, "rocknroll_create_task")
        XCTAssertEqual(args, "{\"text\":\"Fix crash\"}")
    }

    func testGeminiLiveWirePayloadsAndParsing() throws {
        let url = try XCTUnwrap(GeminiLiveClient.makeEndpointURL(
            base: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.BidiGenerateContent",
            apiKey: "gm-key"
        ))
        XCTAssertTrue(url.absoluteString.contains("key=gm-key"))

        let config = RealtimeSessionConfig(
            provider: .geminiLive,
            apiKey: "gm-key",
            systemInstructions: "Facilitate retro.",
            tools: [RealtimeToolDeclaration(name: "rocknroll_list_tasks", description: "List tasks")]
        )
        let setup = GeminiLiveClient.setupPayload(config: config)
        let inner = try XCTUnwrap(setup["setup"] as? [String: Any])
        XCTAssertEqual(inner["model"] as? String, "models/gemini-2.5-flash-native-audio-preview")

        let pcm = Data([0x10, 0x20, 0x30, 0x40])
        let serverJSON: [String: Any] = [
            "toolCall": [
                "functionCalls": [[
                    "id": "g-call-1",
                    "name": "rocknroll_list_tasks",
                    "args": ["done": false],
                ]]
            ],
            "serverContent": [
                "modelTurn": [
                    "parts": [[
                        "inlineData": [
                            "mimeType": "audio/pcm;rate=24000",
                            "data": pcm.base64EncodedString(),
                        ]
                    ]]
                ],
                "turnComplete": true,
            ],
        ]
        let serverData = try JSONSerialization.data(withJSONObject: serverJSON)
        let parsed = try XCTUnwrap(GeminiLiveClient.parseServerMessage(serverData))
        XCTAssertEqual(parsed.count, 3)
        guard case .toolCall(let callID, let name, _) = parsed[0],
              case .audioPCM16(let audio, _) = parsed[1],
              case .audioDone = parsed[2] else {
            return XCTFail("Unexpected Gemini parsed event sequence")
        }
        XCTAssertEqual(callID, "g-call-1")
        XCTAssertEqual(name, "rocknroll_list_tasks")
        XCTAssertEqual(audio, pcm)
    }

    func testRealtimeVoiceRouterFallsBackWhenDisabledAndExecutesToolCalls() async {
        final class FakeTransport: @unchecked Sendable, RealtimeVoiceTransport {
            private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
            let events: AsyncStream<RealtimeVoiceEvent>
            var sentToolResults: [(String, String, String)] = []

            init() {
                var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
                self.events = AsyncStream { cont = $0 }
                self.continuation = cont
            }

            func connect(config: RealtimeSessionConfig) async throws {
                continuation.yield(.connected)
            }
            func emit(_ event: RealtimeVoiceEvent) { continuation.yield(event) }
            func sendAudioPCM16(_ data: Data) async throws {}
            func sendTextTurn(_ text: String) async throws {}
            func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {
                sentToolResults.append((callID, name, jsonOutput))
            }
            func updateInstructions(_ instructions: String) async throws {}
            func disconnect() async { continuation.yield(.disconnected(nil)) }
        }

        let router = RealtimeVoiceRouter()
        await router.start(
            config: RealtimeSessionConfig(provider: .disabled, apiKey: ""),
            executeTool: { _, _ in "{}" },
            onEvent: { _ in }
        )
        let fallbackInitial = await router.shouldFallbackToStandardPipeline
        XCTAssertTrue(fallbackInitial)

        let fake = FakeTransport()
        let toolDone = expectation(description: "tool result sent")
        await router.start(
            config: RealtimeSessionConfig(provider: .openAIRealtime, apiKey: "sk-test"),
            customTransport: fake,
            executeTool: { name, _ in
                XCTAssertEqual(name, "rocknroll_create_task")
                return "{\"status\":\"created\"}"
            },
            onEvent: { event in
                if case .toolCall = event {
                    // Tool result follows asynchronously; fulfill after short delay below
                }
            }
        )
        let connected = await router.isRealtimeConnected
        XCTAssertTrue(connected)

        fake.emit(.toolCall(callID: "c1", name: "rocknroll_create_task", argumentsJSON: "{}"))
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            toolDone.fulfill()
        }
        await fulfillment(of: [toolDone], timeout: 2.0)
        XCTAssertEqual(fake.sentToolResults.count, 1)
        XCTAssertEqual(fake.sentToolResults.first?.2, "{\"status\":\"created\"}")

        fake.emit(.disconnected("socket closed"))
        try? await Task.sleep(for: .milliseconds(50))
        let shouldFallbackAfterClose = await router.shouldFallbackToStandardPipeline
        XCTAssertTrue(shouldFallbackAfterClose)
    }

    func testRealtimeAudioResamplingMixingAndCoalescer() async throws {
        var tone16k = Data()
        for idx in 0..<160 {
            let value = Int16((sin(Double(idx) * 2.0 * .pi * 440.0 / 16_000.0) * 12_000.0).rounded())
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { tone16k.append(contentsOf: $0) }
        }
        XCTAssertEqual(RealtimeVoiceAudio.resamplePCM16Mono(data: tone16k, fromRate: 16_000, toRate: 16_000), tone16k)

        let upsampled24k = RealtimeVoiceAudio.resamplePCM16Mono(data: tone16k, fromRate: 16_000, toRate: 24_000)
        XCTAssertEqual(upsampled24k.count, 240 * 2)
        XCTAssertTrue(upsampled24k.contains { $0 != 0 })

        var hotA = Data()
        var hotB = Data()
        for sampleA: Int16 in [25_000, -25_000, 1_000] {
            var le = sampleA.littleEndian
            withUnsafeBytes(of: &le) { hotA.append(contentsOf: $0) }
        }
        for sampleB: Int16 in [25_000, -25_000, 2_000] {
            var le = sampleB.littleEndian
            withUnsafeBytes(of: &le) { hotB.append(contentsOf: $0) }
        }
        let mixed = RealtimeVoiceAudio.mixPCM16Mono([hotA, hotB])
        let mixedSamples: [Int16] = mixed.withUnsafeBytes { raw in
            (0..<3).map { i in Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) }
        }
        XCTAssertEqual(mixedSamples, [Int16.max, Int16.min, 3_000])

        let coalescer = RealtimeAudioCoalescer(inputSampleRate: 16_000, targetSampleRate: 24_000, windowMs: 30)
        for _ in 0..<3 {
            coalescer.append(trackID: "local", pcm16: tone16k)
            coalescer.append(trackID: "remote", pcm16: tone16k)
        }
        var batches: [Data] = []
        for await batch in coalescer.stream {
            batches.append(batch)
            if batches.count == 1 {
                coalescer.finish()
            }
        }
        let firstBatch = try XCTUnwrap(batches.first)
        XCTAssertEqual(firstBatch.count % 2, 0)
        XCTAssertEqual(firstBatch.count, upsampled24k.count * 3)
    }

    private final class FakeRealtimeTransport: @unchecked Sendable, RealtimeVoiceTransport {
        private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
        let events: AsyncStream<RealtimeVoiceEvent>
        var sentToolResults: [(String, String, String)] = []

        init() {
            var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
            self.events = AsyncStream { cont = $0 }
            self.continuation = cont
        }

        func connect(config: RealtimeSessionConfig) async throws {
            continuation.yield(.connected)
        }
        func emit(_ event: RealtimeVoiceEvent) { continuation.yield(event) }
        func sendAudioPCM16(_ data: Data) async throws {}
        func sendTextTurn(_ text: String) async throws {}
        func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {
            sentToolResults.append((callID, name, jsonOutput))
        }
        func updateInstructions(_ instructions: String) async throws {}
        func disconnect() async { continuation.yield(.disconnected(nil)) }
    }

    private final class AsyncGateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if released {
                    lock.unlock()
                    cont.resume()
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume()
        }
    }

    func testNonBlockingRealtimeRouterToolCalls() async {
        let fake = FakeRealtimeTransport()
        let gate = AsyncGateBox()
        let toolStarted = expectation(description: "tool started")
        let audioDeliveredEarly = expectation(description: "audio delivered while tool suspended")
        let toolCompleted = expectation(description: "tool completed after release")
        let router = RealtimeVoiceRouter()

        await router.start(
            config: RealtimeSessionConfig(provider: .openAIRealtime, apiKey: "sk-test"),
            customTransport: fake,
            executeTool: { name, _ in
                toolStarted.fulfill()
                await gate.wait()
                toolCompleted.fulfill()
                return "{\"ok\":true,\"tool\":\"\(name)\"}"
            },
            onEvent: { event in
                if case .audioPCM16(let bytes, _) = event, bytes == Data([1, 2, 3, 4]) {
                    audioDeliveredEarly.fulfill()
                }
            }
        )

        fake.emit(.toolCall(callID: "slow-1", name: "rocknroll_search", argumentsJSON: "{}"))
        await fulfillment(of: [toolStarted], timeout: 2.0)

        fake.emit(.audioPCM16(Data([1, 2, 3, 4]), sampleRate: 24_000))
        await fulfillment(of: [audioDeliveredEarly], timeout: 2.0)

        gate.release()
        await fulfillment(of: [toolCompleted], timeout: 2.0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.sentToolResults.count, 1)
        XCTAssertEqual(fake.sentToolResults.first?.0, "slow-1")
        await router.stop()
    }

    func testFloatSamplesToPCM16HandlesNonFiniteSamples() {
        let data = RealtimeVoiceAudio.floatSamplesToPCM16Data([.nan, .infinity, -.infinity, 0.5])
        XCTAssertEqual(data.count, 8)
        let samples: [Int16] = (0..<4).map { idx in
            let low = UInt16(data[idx * 2])
            let high = UInt16(data[idx * 2 + 1]) << 8
            return Int16(bitPattern: low | high)
        }
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0)
        XCTAssertEqual(samples[2], 0)
        XCTAssertEqual(samples[3], Int16((0.5 * Float(Int16.max)).rounded()))
    }

    func testWaitForPendingToolCallsHonorsTimeoutWhenToolHangs() async {
        let fake = FakeRealtimeTransport()
        let gate = AsyncGateBox()
        let toolStarted = expectation(description: "hanging tool started")
        let router = RealtimeVoiceRouter()

        await router.start(
            config: RealtimeSessionConfig(provider: .openAIRealtime, apiKey: "sk-test"),
            customTransport: fake,
            executeTool: { _, _ in
                toolStarted.fulfill()
                await gate.wait()
                return "{\"ok\":true}"
            },
            onEvent: { _ in }
        )

        fake.emit(.toolCall(callID: "hang-1", name: "rocknroll_search", argumentsJSON: "{}"))
        await fulfillment(of: [toolStarted], timeout: 2.0)

        let startedAt = ContinuousClock.now
        await router.waitForPendingToolCalls(timeoutSeconds: 0.15)
        let elapsed = ContinuousClock.now - startedAt
        XCTAssertLessThan(elapsed, .seconds(1))

        gate.release()
        await router.stop()
    }

    func testYandexRealtimeWirePayloadsAuthAndParsing() throws {
        // 1. Model URI & Folder ID resolution
        let shortResolved = try XCTUnwrap(YandexRealtimeClient.resolveModelURI(model: "speech-realtime-max-tts-live", folderID: "b1g123"))
        XCTAssertEqual(shortResolved.uri, "gpt://b1g123/speech-realtime-max-tts-live/latest")
        XCTAssertEqual(shortResolved.folderID, "b1g123")

        let versionedResolved = try XCTUnwrap(YandexRealtimeClient.resolveModelURI(model: "speech-realtime-tts-live/rc", folderID: "b1g123"))
        XCTAssertEqual(versionedResolved.uri, "gpt://b1g123/speech-realtime-tts-live/rc")
        XCTAssertEqual(versionedResolved.folderID, "b1g123")

        let fullURIResolved = try XCTUnwrap(YandexRealtimeClient.resolveModelURI(model: "gpt://b1g999/speech-realtime-tts-live", folderID: ""))
        XCTAssertEqual(fullURIResolved.uri, "gpt://b1g999/speech-realtime-tts-live/latest")
        XCTAssertEqual(fullURIResolved.folderID, "b1g999")

        XCTAssertNil(YandexRealtimeClient.resolveModelURI(model: "speech-realtime-max-tts-live", folderID: "   "))

        let endpointURL = try XCTUnwrap(YandexRealtimeClient.makeEndpointURL(
            base: RealtimeProviderKind.yandexRealtime.defaultEndpoint,
            modelURI: shortResolved.uri
        ))
        XCTAssertTrue(endpointURL.absoluteString.hasPrefix("wss://ai.api.cloud.yandex.net/v1/realtime/openai?model="))
        XCTAssertNil(YandexRealtimeClient.makeEndpointURL(
            base: "wss://user:pass@ai.api.cloud.yandex.net/v1/realtime/openai",
            modelURI: shortResolved.uri
        ))

        // 2. Authorization headers
        XCTAssertEqual(YandexRealtimeClient.authorizationHeaderValue(for: "AQVN-secret"), "Api-Key AQVN-secret")
        XCTAssertEqual(YandexRealtimeClient.authorizationHeaderValue(for: "t1.9euelZq-iam"), "Bearer t1.9euelZq-iam")
        XCTAssertEqual(YandexRealtimeClient.authorizationHeaderValue(for: "Api-Key already-prefixed"), "Api-Key already-prefixed")
        XCTAssertEqual(YandexRealtimeClient.authorizationHeaderValue(for: "Bearer already-bearer"), "Bearer already-bearer")

        // 3. Conversational Realtime session.update (speech-realtime-max-tts-live)
        let tool = RealtimeToolDeclaration(
            name: "rocknroll_create_task",
            description: "Create a task",
            parametersJSONSchema: ["type": "object", "properties": ["title": ["type": "string"]]]
        )
        let maxConfig = RealtimeSessionConfig(
            provider: .yandexRealtime,
            apiKey: "AQVN-secret",
            model: "speech-realtime-max-tts-live",
            voice: "sofia",
            systemInstructions: "Facilitate standup.",
            tools: [tool],
            folderID: "b1g123",
            voiceRole: "casual"
        )
        XCTAssertEqual(maxConfig.inputSampleRate, 24_000)
        XCTAssertEqual(maxConfig.outputSampleRate, 44_100)
        XCTAssertFalse(YandexRealtimeClient.isTTSOnlyModel(maxConfig.model))

        let maxPayload = YandexRealtimeClient.sessionUpdatePayload(config: maxConfig, isTTSOnly: false)
        XCTAssertEqual(maxPayload["type"] as? String, "session.update")
        let maxSession = try XCTUnwrap(maxPayload["session"] as? [String: Any])
        XCTAssertEqual(maxSession["type"] as? String, "realtime")
        XCTAssertEqual(maxSession["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual(maxSession["instructions"] as? String, "Facilitate standup.")
        XCTAssertEqual(maxSession["tool_choice"] as? String, "auto")
        XCTAssertEqual((maxSession["tools"] as? [[String: Any]])?.count, 1)
        let maxAudio = try XCTUnwrap(maxSession["audio"] as? [String: Any])
        let maxInput = try XCTUnwrap(maxAudio["input"] as? [String: Any])
        XCTAssertEqual((maxInput["format"] as? [String: Any])?["rate"] as? Int, 24_000)
        XCTAssertEqual((maxInput["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")
        let maxOutput = try XCTUnwrap(maxAudio["output"] as? [String: Any])
        XCTAssertEqual((maxOutput["format"] as? [String: Any])?["type"] as? String, "audio/pcm")
        XCTAssertEqual((maxOutput["format"] as? [String: Any])?["rate"] as? Int, 44_100)
        XCTAssertEqual(maxOutput["voice"] as? String, "sofia")
        XCTAssertEqual(maxOutput["role"] as? String, "casual")

        // 4. Pure TTS-only session.update (speech-realtime-tts-live) with voice:role splitting
        let ttsConfig = RealtimeSessionConfig(
            provider: .yandexRealtime,
            apiKey: "AQVN-secret",
            model: YandexRealtimePreferences.defaultTTSModel,
            voice: "sofia:support",
            systemInstructions: "Ignored for TTS-only",
            tools: [tool],
            folderID: "b1g123"
        )
        XCTAssertTrue(YandexRealtimeClient.isTTSOnlyModel(ttsConfig.model))
        let ttsPayload = YandexRealtimeClient.sessionUpdatePayload(config: ttsConfig, isTTSOnly: true)
        let ttsSession = try XCTUnwrap(ttsPayload["session"] as? [String: Any])
        XCTAssertNil(ttsSession["instructions"])
        XCTAssertNil(ttsSession["tools"])
        let ttsAudio = try XCTUnwrap(ttsSession["audio"] as? [String: Any])
        XCTAssertNil(ttsAudio["input"])
        let ttsOutput = try XCTUnwrap(ttsAudio["output"] as? [String: Any])
        XCTAssertEqual(ttsOutput["voice"] as? String, "sofia")
        XCTAssertEqual(ttsOutput["role"] as? String, "support")
        XCTAssertEqual((ttsOutput["format"] as? [String: Any])?["rate"] as? Int, 44_100)

        // 5. Server event parsing (44.1 kHz PCM16 + response.output_audio.done + response.done + failed response.done)
        let pcm = Data([0x11, 0x22, 0x33, 0x44])
        let deltaData = try JSONSerialization.data(withJSONObject: [
            "type": "response.output_audio.delta",
            "delta": pcm.base64EncodedString(),
        ])
        let parsedDelta = try XCTUnwrap(YandexRealtimeClient.parseServerEvent(deltaData, outputSampleRate: 44_100))
        guard case .audioPCM16(let parsedBytes, let parsedRate) = parsedDelta.events.first else {
            return XCTFail("Expected audioPCM16 event")
        }
        XCTAssertEqual(parsedBytes, pcm)
        XCTAssertEqual(parsedRate, 44_100)

        let audioDoneData = try JSONSerialization.data(withJSONObject: ["type": "response.output_audio.done"])
        let parsedAudioDone = try XCTUnwrap(YandexRealtimeClient.parseServerEvent(audioDoneData))
        XCTAssertFalse(parsedAudioDone.isTerminalResponseDone)
        guard case .audioDone = parsedAudioDone.events.first else {
            return XCTFail("Expected audioDone")
        }

        let responseDoneData = try JSONSerialization.data(withJSONObject: ["type": "response.done"])
        let parsedResponseDone = try XCTUnwrap(YandexRealtimeClient.parseServerEvent(responseDoneData))
        XCTAssertTrue(parsedResponseDone.isTerminalResponseDone)

        let failedDoneData = try JSONSerialization.data(withJSONObject: [
            "type": "response.done",
            "response": [
                "status": "failed",
                "status_details": ["error": ["message": "Invalid voice for model"]],
            ],
        ])
        let parsedFailed = try XCTUnwrap(YandexRealtimeClient.parseServerEvent(failedDoneData))
        guard case .error(let errMsg) = parsedFailed.events.first else {
            return XCTFail("Expected error event for failed response.done")
        }
        XCTAssertEqual(errMsg, "Invalid voice for model")
    }

    func testYandexRealtimeTTSSynthesizeBuildsAudioBuffer() async throws {
        final class FakeTTSTransport: @unchecked Sendable, RealtimeVoiceTransport {
            private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
            let events: AsyncStream<RealtimeVoiceEvent>
            var lastConfig: RealtimeSessionConfig?
            var disconnected = false

            init() {
                var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
                self.events = AsyncStream { cont = $0 }
                self.continuation = cont
            }

            func connect(config: RealtimeSessionConfig) async throws {
                lastConfig = config
                continuation.yield(.connected)
            }
            func sendAudioPCM16(_ data: Data) async throws {}
            func sendTextTurn(_ text: String) async throws {
                let pcm = RealtimeVoiceAudio.floatSamplesToPCM16Data([0.2, -0.2, 0.4, -0.4])
                continuation.yield(.audioPCM16(pcm, sampleRate: 44_100))
                continuation.yield(.audioDone)
            }
            func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {}
            func updateInstructions(_ instructions: String) async throws {}
            func disconnect() async {
                disconnected = true
                continuation.yield(.disconnected(nil))
            }
        }

        do {
            _ = try await YandexRealtimeTTS.synthesize(
                text: "Привет!",
                apiKey: "AQVN-key",
                folderID: ""
            )
            XCTFail("Expected missingFolderID error")
        } catch let error as YandexRealtimeTTSError {
            XCTAssertEqual(error, .missingFolderID)
        }

        let fake = FakeTTSTransport()
        let buffer = try await YandexRealtimeTTS.synthesize(
            text: "Привет! Чем я могу помочь?",
            apiKey: "AQVN-key",
            folderID: "b1g123",
            voice: "vera",
            role: "support",
            customTransport: fake
        )
        XCTAssertEqual(buffer.format.sampleRate, 44_100, accuracy: 1)
        XCTAssertEqual(buffer.frameLength, 4)
        XCTAssertEqual(fake.lastConfig?.model, YandexRealtimePreferences.defaultTTSModel)
        XCTAssertEqual(fake.lastConfig?.folderID, "b1g123")
        XCTAssertEqual(fake.lastConfig?.voice, "vera")
        XCTAssertEqual(fake.lastConfig?.voiceRole, "support")
        XCTAssertTrue(fake.disconnected)
    }

    func testYandexRealtimeTTSSynthesizeTimesOutAndDisconnects() async throws {
        final class HangingTTSTransport: @unchecked Sendable, RealtimeVoiceTransport {
            private let continuation: AsyncStream<RealtimeVoiceEvent>.Continuation
            let events: AsyncStream<RealtimeVoiceEvent>
            var disconnected = false

            init() {
                var cont: AsyncStream<RealtimeVoiceEvent>.Continuation!
                self.events = AsyncStream { cont = $0 }
                self.continuation = cont
            }

            func connect(config: RealtimeSessionConfig) async throws {
                continuation.yield(.connected)
            }
            func sendAudioPCM16(_ data: Data) async throws {}
            func sendTextTurn(_ text: String) async throws {}
            func sendToolResult(callID: String, name: String, jsonOutput: String) async throws {}
            func updateInstructions(_ instructions: String) async throws {}
            func disconnect() async {
                disconnected = true
                continuation.yield(.disconnected(nil))
            }
        }

        let hanging = HangingTTSTransport()
        let started = ContinuousClock.now
        do {
            _ = try await YandexRealtimeTTS.synthesize(
                text: "Привет!",
                apiKey: "AQVN-key",
                folderID: "b1g123",
                customTransport: hanging,
                timeoutSeconds: 0.15
            )
            XCTFail("Expected timeout error")
        } catch let error as YandexRealtimeTTSError {
            XCTAssertEqual(error, .timedOut)
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(hanging.disconnected)
    }
}
