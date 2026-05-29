import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarDaemon

final class ClaudeInteractiveSessionExecutorTests: XCTestCase {

    private func makeRoute(
        providerID: String = "anthropic",
        apiKey: String,
        formatFamily: BurnBarProviderFormatFamily = .anthropic,
        model: String = "claude-opus-4-20250514"
    ) -> BurnBarProviderRoute {
        BurnBarProviderRoute(
            providerID: providerID,
            providerDisplayName: providerID,
            baseURL: "https://api.anthropic.com",
            requestedModel: model,
            resolvedModelID: model,
            apiKey: apiKey,
            pricing: BurnBarModelPricing(inputPerMToken: 0, outputPerMToken: 0, cacheReadPerMToken: 0),
            formatFamily: formatFamily
        )
    }

    // MARK: - Opt-in gate

    func test_isOptedIn_defaultsOff() {
        XCTAssertFalse(ClaudeInteractiveSessionExecutor.isOptedIn(environment: [:]))
        XCTAssertFalse(ClaudeInteractiveSessionExecutor.isOptedIn(
            environment: ["OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE": "0"]
        ))
        XCTAssertFalse(ClaudeInteractiveSessionExecutor.isOptedIn(
            environment: ["OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE": "off"]
        ))
    }

    func test_isOptedIn_truthyValues() {
        for value in ["1", "true", "TRUE", "yes", "on"] {
            XCTAssertTrue(
                ClaudeInteractiveSessionExecutor.isOptedIn(
                    environment: ["OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE": value]
                ),
                "expected \(value) to opt in"
            )
        }
    }

    func test_makeIfEnabled_nilWhenNotOptedIn() {
        XCTAssertNil(ClaudeInteractiveSessionExecutor.makeIfEnabled(environment: [:]))
    }

    func test_makeIfEnabled_nonNilWhenOptedIn() {
        let executor = ClaudeInteractiveSessionExecutor.makeIfEnabled(
            environment: ["OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE": "1"]
        )
        XCTAssertNotNil(executor)
    }

    // MARK: - Eligibility

    func test_isEligible_anthropicOAuthToken() {
        let route = makeRoute(apiKey: "sk-ant-oat01-abc123")
        XCTAssertTrue(ClaudeInteractiveSessionExecutor.isEligible(route: route))
    }

    func test_isEligible_rejectsConsoleKey() {
        let route = makeRoute(apiKey: "sk-ant-api03-abc123")
        XCTAssertFalse(ClaudeInteractiveSessionExecutor.isEligible(route: route))
    }

    func test_isEligible_rejectsNonAnthropicFamily() {
        let route = makeRoute(
            providerID: "openai",
            apiKey: "sk-ant-oat01-abc",
            formatFamily: .openaiCompat
        )
        XCTAssertFalse(ClaudeInteractiveSessionExecutor.isEligible(route: route))
    }

    // MARK: - Prompt parsing

    func test_chatCompletionPrompt_joinsMessages() throws {
        let body = #"{"messages":[{"role":"system","content":"be terse"},{"role":"user","content":"hi"}],"stream":true}"#
            .data(using: .utf8)!
        let parsed = try ClaudeInteractiveSessionExecutor.chatCompletionPrompt(from: body)
        XCTAssertTrue(parsed.prompt.contains("System: be terse"))
        XCTAssertTrue(parsed.prompt.contains("hi"))
        XCTAssertTrue(parsed.stream)
    }

    func test_anthropicPrompt_includesSystemAndContentBlocks() throws {
        let body = #"{"system":"guard","messages":[{"role":"user","content":[{"type":"text","text":"ping"}]}]}"#
            .data(using: .utf8)!
        let parsed = try ClaudeInteractiveSessionExecutor.anthropicPrompt(from: body)
        XCTAssertTrue(parsed.prompt.contains("guard"))
        XCTAssertTrue(parsed.prompt.contains("ping"))
        XCTAssertFalse(parsed.stream)
    }

    func test_responsesPrompt_usesInstructionsAndInput() throws {
        let body = #"{"instructions":"sys","input":"do the thing"}"#.data(using: .utf8)!
        let parsed = try ClaudeInteractiveSessionExecutor.responsesPrompt(from: body)
        XCTAssertTrue(parsed.prompt.contains("sys"))
        XCTAssertTrue(parsed.prompt.contains("do the thing"))
    }

    func test_chatCompletionPrompt_emptyMessages_throws() {
        let body = #"{"messages":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeInteractiveSessionExecutor.chatCompletionPrompt(from: body))
    }

    // MARK: - JSONL extraction

    func test_parseLatestAssistantTurn_extractsTextAndUsage() {
        let jsonl = [
            #"{"message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
            #"{"message":{"role":"assistant","content":[{"type":"text","text":"PONG"}],"usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":5}}}"#
        ].joined(separator: "\n")
        let turn = ClaudeInteractiveSessionExecutor.parseLatestAssistantTurn(jsonlContent: jsonl)
        XCTAssertEqual(turn?.text, "PONG")
        XCTAssertEqual(turn?.inputTokens, 12 + 5)
        XCTAssertEqual(turn?.outputTokens, 3)
    }

    func test_parseLatestAssistantTurn_returnsLastAssistantMessage() {
        let jsonl = [
            #"{"message":{"role":"assistant","content":[{"type":"text","text":"first"}],"usage":{"output_tokens":1}}}"#,
            #"{"message":{"role":"assistant","content":[{"type":"text","text":"second"}],"usage":{"output_tokens":2}}}"#
        ].joined(separator: "\n")
        let turn = ClaudeInteractiveSessionExecutor.parseLatestAssistantTurn(jsonlContent: jsonl)
        XCTAssertEqual(turn?.text, "second")
        XCTAssertEqual(turn?.outputTokens, 2)
    }

    func test_parseLatestAssistantTurn_noAssistant_returnsNil() {
        let jsonl = #"{"message":{"role":"user","content":[{"type":"text","text":"only user"}]}}"#
        XCTAssertNil(ClaudeInteractiveSessionExecutor.parseLatestAssistantTurn(jsonlContent: jsonl))
    }

    // MARK: - ANSI transcript scraping (fallback)

    func test_scrapeAssistantText_dropsPromptEchoAndChrome() {
        let transcript = """
        ╭──────────────╮
        │ > say PONG   │
        ╰──────────────╯
        say PONG
        PONG
        ? for shortcuts
        """
        let scraped = ClaudeInteractiveSessionExecutor.scrapeAssistantText(
            fromTranscript: transcript,
            prompt: "say PONG"
        )
        XCTAssertEqual(scraped, "PONG")
    }

    // MARK: - Response synthesis

    func test_chatCompletionResponseBody_nonStream_carriesContent() throws {
        let data = try ClaudeInteractiveSessionExecutor.chatCompletionResponseBody(
            modelID: "claude-opus-4-20250514",
            output: "hello world",
            stream: false,
            outputTokens: 7
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        XCTAssertEqual(message?["content"] as? String, "hello world")
        let usage = object?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["completion_tokens"] as? Int, 7)
    }

    func test_anthropicResponseBody_shape() throws {
        let data = try ClaudeInteractiveSessionExecutor.anthropicResponseBody(
            modelID: "claude-opus-4-20250514",
            output: "answer",
            inputTokens: 10,
            outputTokens: 4
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "message")
        let content = object?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "answer")
        let usage = object?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["input_tokens"] as? Int, 10)
        XCTAssertEqual(usage?["output_tokens"] as? Int, 4)
    }

    func test_chatCompletionResponseBody_stream_isSSE() throws {
        let data = try ClaudeInteractiveSessionExecutor.chatCompletionResponseBody(
            modelID: "m",
            output: "x",
            stream: true,
            outputTokens: nil
        )
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("data: "))
        XCTAssertTrue(text.contains("[DONE]"))
    }

    // MARK: - claude arguments

    func test_claudeArguments_neverIncludePrintFlag() {
        let args = ClaudeInteractiveSessionExecutor.claudeArguments(model: "claude-opus-4-20250514")
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("--print"))
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("--append-system-prompt"))
    }

    // MARK: - AsyncSemaphore

    func test_asyncSemaphore_boundsConcurrency() async {
        let semaphore = AsyncSemaphore(value: 2)
        await semaphore.wait()
        await semaphore.wait()

        let resumed = Locked(false)
        let task = Task {
            await semaphore.wait()
            resumed.withLock { $0 = true }
        }
        // Third waiter should be parked until a signal arrives.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(resumed.read())

        await semaphore.signal()
        _ = await task.value
        XCTAssertTrue(resumed.read())
        await semaphore.signal()
        await semaphore.signal()
    }
}
