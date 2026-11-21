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
}
