import Foundation
import XCTest
@testable import ConferenceCore

final class PortableOutcomeProviderTests: XCTestCase {
    func testOpenAISummaryUsesCurrentCompletionLimitWithoutSamplingOverride() {
        let body = PortableOutcomeService.requestBody(messages: [], model: "gpt-5.4-mini", provider: .openAI)
        XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 2_000)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])

        let custom = PortableOutcomeService.requestBody(messages: [], model: "custom-model", provider: .custom)
        XCTAssertEqual(custom["max_tokens"] as? Int, 2_000)
        XCTAssertNil(custom["max_completion_tokens"])
    }

    func testHTTPErrorKeepsOnlySafeProviderDetails() {
        let body = Data(#"{"error":{"code":"unsupported_parameter","param":"max_tokens","message":"secret meeting content"}}"#.utf8)
        let error = PortableOutcomeService.httpError(status: 400, data: body)
        XCTAssertEqual(error, .http(status: 400, code: "unsupported_parameter", parameter: "max_tokens"))
        XCTAssertFalse(error.localizedDescription.contains("secret meeting content"))

        let unsafe = Data(#"{"error":{"code":"secret-token","param":"secret-param"}}"#.utf8)
        XCTAssertEqual(
            PortableOutcomeService.httpError(status: 403, data: unsafe),
            .http(status: 403, code: "other", parameter: "other")
        )
    }

    func testModelsUseSelectedProvidersEndpointAndSharedRanking() async throws {
        let configuration = PortableOutcomeConfiguration(providerKind: .openAI, baseURL: "https://old.example.invalid/v1")
        XCTAssertEqual(configuration.endpoint?.absoluteString, "https://api.openai.com/v1/chat/completions")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CatalogFixture.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let models = try await ProviderModelCatalog.fetch(configuration: configuration, key: "fixture-key", session: session)
        XCTAssertEqual(models.map(\.id), ["gpt-5.4-mini", "audio-model"])
        XCTAssertEqual(models.first?.contextLength, 400_000)
        XCTAssertEqual(ProviderModelCatalog.filter(models, query: "MINI gpt").map(\.id), ["gpt-5.4-mini"])
    }

    func testReasoningExtractorStripsThinkAndExtractsReasoningJSON() throws {
        let afterThinkMsg: [String: Any] = [
            "role": "assistant",
            "content": NSNull(),
            "reasoning_content": "<think>analyze transcript</think>\n{\"summary\":\"Shipped.\",\"decisions\":[],\"tasks\":[],\"open_questions\":[]}",
        ]
        let afterThink = OpenAIChatResponseExtractor.extractContent(from: afterThinkMsg, finishReason: "stop", allowTrailingReasoningJSON: false)
        XCTAssertEqual(afterThink.fromReasoning, true)
        XCTAssertTrue(afterThink.text.contains("\"summary\":\"Shipped.\""))

        let constrainedMsg: [String: Any] = [
            "role": "assistant",
            "content": NSNull(),
            "reasoning_content": "<think>{\"summary\":\"Direct JSON.\",\"decisions\":[],\"tasks\":[],\"open_questions\":[]}",
        ]
        let constrained = OpenAIChatResponseExtractor.extractContent(from: constrainedMsg, finishReason: "stop", allowTrailingReasoningJSON: false)
        XCTAssertEqual(constrained.fromReasoning, true)
        XCTAssertTrue(constrained.text.hasPrefix("{"))

        let trailingProseMsg: [String: Any] = [
            "role": "assistant",
            "content": NSNull(),
            "reasoning": "Let me review the notes.\n```json\n{\"summary\":\"Trailing fenced.\",\"decisions\":[],\"tasks\":[],\"open_questions\":[]}\n```",
        ]
        let blocked = OpenAIChatResponseExtractor.extractContent(from: trailingProseMsg, finishReason: "stop", allowTrailingReasoningJSON: false)
        XCTAssertEqual(blocked.text, "")
        let allowed = OpenAIChatResponseExtractor.extractContent(from: trailingProseMsg, finishReason: "stop", allowTrailingReasoningJSON: true)
        XCTAssertEqual(allowed.fromReasoning, true)
        XCTAssertTrue(allowed.text.contains("\"summary\":\"Trailing fenced.\""))

        let bareTrailingMsg: [String: Any] = [
            "role": "assistant",
            "content": NSNull(),
            "reasoning_content": "Thought about {draft} then finalized:\n{\"summary\":\"Trailing bare.\",\"decisions\":[\"Go\"],\"tasks\":[],\"open_questions\":[]}",
        ]
        let bare = OpenAIChatResponseExtractor.extractContent(from: bareTrailingMsg, finishReason: "stop", allowTrailingReasoningJSON: true)
        XCTAssertEqual(bare.fromReasoning, true)
        XCTAssertTrue(bare.text.hasPrefix("{\"summary\":\"Trailing bare.\""))

        // Inline <think>...</think> with nothing after </think> or unclosed <think> prose must return empty.
        let inlineEmptyAfterThink: [String: Any] = [
            "role": "assistant",
            "content": "<think>Considering {L1} and {L2}</think>\n   ",
        ]
        XCTAssertEqual(OpenAIChatResponseExtractor.extractContent(from: inlineEmptyAfterThink, finishReason: "stop").text, "")

        let inlineUnclosedThinkProse: [String: Any] = [
            "role": "assistant",
            "content": "<think>Still thinking about {L1} when cut off",
        ]
        XCTAssertEqual(OpenAIChatResponseExtractor.extractContent(from: inlineUnclosedThinkProse, finishReason: "length").text, "")
        XCTAssertEqual(OpenAIChatResponseExtractor.extractPlainText(from: inlineUnclosedThinkProse, finishReason: "length"), "")

        let inlineUnclosedThinkJSON: [String: Any] = [
            "role": "assistant",
            "content": "<think>\n{\"summary\":\"Inline constrained.\"}",
        ]
        let inlineConstrained = OpenAIChatResponseExtractor.extractContent(from: inlineUnclosedThinkJSON, finishReason: "stop")
        XCTAssertTrue(inlineConstrained.fromReasoning)
        XCTAssertEqual(inlineConstrained.text, "{\"summary\":\"Inline constrained.\"}")

        let plainAfterThink: [String: Any] = [
            "role": "assistant",
            "content": "<think>Checking calendar</think>\nYou have two meetings today.",
        ]
        XCTAssertEqual(OpenAIChatResponseExtractor.extractPlainText(from: plainAfterThink, finishReason: "stop"), "You have two meetings today.")
    }

    func testPortableOutcomePromptKeepsGroundingWithCustomInstructionsAndRepairsJSON() throws {
        let events = [
            SyncedTranscriptEvent(id: "u1", kind: "transcript", occurredAt: Date(), speaker: "Vitalii", isOwn: true, text: "I will check", deviceID: "mac")
        ]
        let messages = PortableOutcomePrompt.messages(
            title: "Sync",
            endedAt: Date(),
            events: events,
            notes: "",
            language: "en",
            customInstructions: "Focus on engineering risks."
        )
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertTrue(system.contains("(the user)"))
        XCTAssertTrue(system.contains("[assistant]"))
        XCTAssertTrue(system.contains("Focus on engineering risks."))

        let thinkAndFence = """
        <think>check {braces}</think>
        ```json
        {"summary":"Done."}
        ```
        """
        XCTAssertEqual(try PortableOutcomePrompt.parse(thinkAndFence).summary, "Done.")
        let cut = #"{"summary":"Release moved.","decisions":["Ship"],"tasks":[{"text":"Update"#
        let repaired = try PortableOutcomePrompt.parse(cut)
        XCTAssertEqual(repaired.summary, "Release moved.")
        XCTAssertEqual(repaired.decisions, ["Ship"])
        XCTAssertTrue(repaired.tasks.isEmpty)
    }

    func testPortableOutcomeServiceHandlesReasoningContentAndFallbackRetries() async throws {
        let config = PortableOutcomeConfiguration(
            providerKind: .custom,
            baseURL: "https://litellm.example.test/v1",
            model: "cowork-pro"
        )
        let events = [
            SyncedTranscriptEvent(id: "1", kind: "transcript", occurredAt: Date(), speaker: "Anna", isOwn: false, text: "Ship tomorrow.", deviceID: "mac")
        ]

        // Case 1: JSON trapped inside reasoning_content succeeds on Attempt 0 (1 HTTP call).
        var case1Calls = 0
        let sessionConfig1 = URLSessionConfiguration.ephemeral
        sessionConfig1.protocolClasses = [OutcomeStubProtocol.self]
        let session1 = URLSession(configuration: sessionConfig1)
        defer { session1.invalidateAndCancel() }
        OutcomeStubProtocol.handler = { _ in
            case1Calls += 1
            let body = Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":null,"reasoning_content":"{\"summary\":\"Ship tomorrow.\",\"decisions\":[\"Ship\"],\"tasks\":[],\"open_questions\":[]}"}}]}"#.utf8)
            return (200, body)
        }
        let service1 = PortableOutcomeService(session: session1, apiKeyProvider: { _ in "test-key" })
        let result1 = try await service1.generateOutcome(
            title: "Release", endedAt: Date(), events: events, notes: "", language: "en", configuration: config
        )
        XCTAssertEqual(case1Calls, 1)
        XCTAssertEqual(result1.summary, "Ship tomorrow.")

        // Case 2: Attempt 0 empty content -> Attempt 1 strips response_format -> succeeds.
        var bodies2: [[String: Any]] = []
        OutcomeStubProtocol.handler = { request in
            if let parsed = try JSONSerialization.jsonObject(with: OutcomeStubProtocol.body(request)) as? [String: Any] {
                bodies2.append(parsed)
            }
            if bodies2.count == 1 {
                return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":null}}],"usage":{"completion_tokens":533,"completion_tokens_details":{"reasoning_tokens":532}}}"#.utf8))
            }
            return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\"summary\":\"Recovered on attempt 1.\",\"decisions\":[],\"tasks\":[],\"open_questions\":[]}"}}]}"#.utf8))
        }
        let result2 = try await service1.generateOutcome(
            title: "Release", endedAt: Date(), events: events, notes: "", language: "en", configuration: config
        )
        XCTAssertEqual(bodies2.count, 2)
        XCTAssertNotNil(bodies2[0]["response_format"])
        XCTAssertNil(bodies2[1]["response_format"])
        XCTAssertNil(bodies2[1]["chat_template_kwargs"])
        XCTAssertEqual(result2.summary, "Recovered on attempt 1.")

        // Case 3: Attempt 2 adds chat_template_kwargs; rejecting it with 400 maps to .invalidResponse.
        var bodies3: [[String: Any]] = []
        OutcomeStubProtocol.handler = { request in
            if let parsed = try JSONSerialization.jsonObject(with: OutcomeStubProtocol.body(request)) as? [String: Any] {
                bodies3.append(parsed)
            }
            if bodies3.count < 3 {
                return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":null}}]}"#.utf8))
            }
            return (400, Data(#"{"error":{"message":"Unrecognized request argument chat_template_kwargs"}}"#.utf8))
        }
        do {
            _ = try await service1.generateOutcome(
                title: "Release", endedAt: Date(), events: events, notes: "", language: "en", configuration: config
            )
            XCTFail("Expected invalidResponse")
        } catch let error as PortableOutcomeError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(bodies3.count, 3)
        XCTAssertEqual((bodies3[2]["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)

        // Case 4: Explicit refusal fails immediately on Attempt 0 without retrying.
        var refusalCalls = 0
        OutcomeStubProtocol.handler = { _ in
            refusalCalls += 1
            return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":null,"refusal":"Safety policy"}}]}"#.utf8))
        }
        do {
            _ = try await service1.generateOutcome(
                title: "Release", endedAt: Date(), events: events, notes: "", language: "en", configuration: config
            )
            XCTFail("Expected refusal invalidResponse")
        } catch let error as PortableOutcomeError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(refusalCalls, 1, "Refusals must not retry")

        // Case 5: Terminal HTTP 400 codes (context_length_exceeded, model_not_found, insufficient_quota) fail immediately without retrying.
        for terminalCode in ["context_length_exceeded", "model_not_found", "insufficient_quota"] {
            var terminalCalls = 0
            OutcomeStubProtocol.handler = { _ in
                terminalCalls += 1
                return (400, Data("{\"error\":{\"code\":\"\(terminalCode)\",\"message\":\"failed\"}}".utf8))
            }
            do {
                _ = try await service1.generateOutcome(
                    title: "Release", endedAt: Date(), events: events, notes: "", language: "en", configuration: config
                )
                XCTFail("Expected HTTP 400 for \(terminalCode)")
            } catch let error as PortableOutcomeError {
                XCTAssertEqual(error, .http(status: 400, code: terminalCode, parameter: nil))
            }
            XCTAssertEqual(terminalCalls, 1, "\(terminalCode) must not retry")
        }
    }
}

private final class OutcomeStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class CatalogFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.absoluteString == "https://api.openai.com/v1/models",
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Data(#"""
        {"data":[{"id":"audio-model","supported_parameters":[]},
                 {"id":"gpt-5.4-mini","context_length":400000,"supported_parameters":["response_format"]},
                 {"id":"gpt-5.4-mini"}]}
        """#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
