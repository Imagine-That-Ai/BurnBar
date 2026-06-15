import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

/// Unit coverage for The Elder Wand model-fusion orchestrator, its tool-loop,
/// the web-tool backend, and the wire-contract decode — all driven by stub
/// closures so nothing touches the network or a live route.
final class ElderWandFusionOrchestratorTests: XCTestCase {
    // MARK: - Plugin contract decode

    func testFusionPluginDecodesSnakeCaseAndDefaults() throws {
        let json = """
        {
          "model": "openai/gpt-5",
          "plugins": [
            { "id": "fusion", "enabled": true,
              "analysis_models": ["a", "b", "c"],
              "model": "anthropic/claude",
              "max_tool_calls": 4 }
          ]
        }
        """
        let request = try JSONDecoder().decode(ChatCompletionsRequest.self, from: Data(json.utf8))
        let plugin = try XCTUnwrap(request.activeFusionPlugin)
        XCTAssertEqual(plugin.analysisModels, ["a", "b", "c"])
        XCTAssertEqual(plugin.model, "anthropic/claude")
        XCTAssertEqual(plugin.maxToolCalls, 4)
    }

    func testEnabledFalseBypassesFusion() throws {
        let json = """
        { "model": "m", "plugins": [{ "id": "fusion", "enabled": false, "analysis_models": ["a"] }] }
        """
        let request = try JSONDecoder().decode(ChatCompletionsRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.activeFusionPlugin, "enabled:false must bypass fusion for the request")
    }

    func testNoPluginsDecodesUnchanged() throws {
        let request = try JSONDecoder().decode(
            ChatCompletionsRequest.self,
            from: Data(#"{"model":"m","stream":true}"#.utf8)
        )
        XCTAssertNil(request.plugins)
        XCTAssertNil(request.activeFusionPlugin)
        XCTAssertEqual(request.stream, true)
    }

    // MARK: - Recursion guard

    func testRecursionMarkerDetection() {
        let withMarker = Data(#"{"model":"m","x_burnbar_fusion_depth":"1"}"#.utf8)
        let without = Data(#"{"model":"m"}"#.utf8)
        XCTAssertTrue(BurnBarHTTPGatewayServer.bodyCarriesFusionRecursionMarker(withMarker))
        XCTAssertFalse(BurnBarHTTPGatewayServer.bodyCarriesFusionRecursionMarker(without))
    }

    // MARK: - Tool-call clamping

    func testClampToolCalls() {
        XCTAssertEqual(ElderWandFusionOrchestrator.clampToolCalls(nil), ElderWandPreset.defaultMaxToolCalls)
        XCTAssertEqual(ElderWandFusionOrchestrator.clampToolCalls(0), 1)
        XCTAssertEqual(ElderWandFusionOrchestrator.clampToolCalls(99), 16)
        XCTAssertEqual(ElderWandFusionOrchestrator.clampToolCalls(5), 5)
    }

    // MARK: - Message extraction

    func testExtractMessagesAndLastUserText() throws {
        let body = Data("""
        {"model":"m","messages":[
          {"role":"system","content":"sys"},
          {"role":"user","content":"first"},
          {"role":"assistant","content":"reply"},
          {"role":"user","content":"latest"}
        ]}
        """.utf8)
        let extracted = try XCTUnwrap(ElderWandFusionOrchestrator.extractMessages(from: body))
        XCTAssertEqual(extracted.lastUserText, "latest")
        let roundTrip = try XCTUnwrap(
            JSONSerialization.jsonObject(with: extracted.messagesJSON) as? [[String: Any]]
        )
        XCTAssertEqual(roundTrip.count, 4)
    }

    func testExtractMessagesReturnsNilForEmpty() {
        XCTAssertNil(ElderWandFusionOrchestrator.extractMessages(from: Data(#"{"model":"m"}"#.utf8)))
        XCTAssertNil(ElderWandFusionOrchestrator.extractMessages(from: Data(#"{"model":"m","messages":[]}"#.utf8)))
    }

    // MARK: - Full pipeline with stub deps

    func testFusionPipelineRunsPanelJudgeAndSynthesis() async throws {
        let recorder = SubCallRecorder()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            // Every model resolves; every completion echoes the requested model
            // in the content so we can assert each stage ran.
            completion: { body in Self.echoCompletion(body: body) }
        )
        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["p1", "p2"], judge: "judge"),
            plugin: try Self.plugin(panel: ["p1", "p2"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )

        guard case .buffered(let buffered) = result else {
            return XCTFail("Expected buffered synthesis result, got \(result)")
        }
        XCTAssertEqual(buffered.status, 200)

        let records = await recorder.records
        // 2 panel + 1 judge + 1 synthesis = 4 successful sub-calls.
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records.allSatisfy { $0.succeeded })

        // All sub-calls share one parentRequestID.
        let parents = Set(records.map(\.parentRequestID))
        XCTAssertEqual(parents.count, 1, "all sub-calls must share one parentRequestID")

        // Each sub-call has a DISTINCT request signature → distinct idempotency key.
        let signatures = Set(records.map(\.requestSignature))
        XCTAssertEqual(signatures.count, records.count, "each sub-call needs a distinct signature")

        // Exactly one synthesis stage.
        let synthesisCount = records.filter {
            if case .synthesis = $0.stage { return true }
            return false
        }.count
        XCTAssertEqual(synthesisCount, 1)
    }

    func testPanelPartialFailureDegradesNotFails() async throws {
        let recorder = SubCallRecorder()
        // "bad" has no route; "good" succeeds. Pipeline must still synthesize.
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            resolve: { model in model == "bad" ? nil : Self.route(for: model) },
            completion: { body in Self.echoCompletion(body: body) }
        )
        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["good", "bad"], judge: "judge"),
            plugin: try Self.plugin(panel: ["good", "bad"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )
        guard case .buffered = result else {
            return XCTFail("One good panel member must still produce a synthesis, got \(result)")
        }
        let records = await recorder.records
        XCTAssertTrue(records.contains { !$0.succeeded }, "the dropped panel member must be recorded as a failure")
        XCTAssertTrue(records.contains { $0.succeeded }, "the good panel member must be recorded as a success")
    }

    func testAllPanelMembersFailReturnsError() async throws {
        let recorder = SubCallRecorder()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            resolve: { _ in nil } // nothing resolves → 0 panel successes
        )
        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["a", "b"], judge: "judge"),
            plugin: try Self.plugin(panel: ["a", "b"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )
        guard case .failed(let failure) = result else {
            return XCTFail("Zero panel successes must fail the request, got \(result)")
        }
        XCTAssertEqual(failure.status, 502)
    }

    func testStreamingSynthesisReturnsStreamingPlan() async throws {
        let recorder = SubCallRecorder()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            completion: { body in Self.echoCompletion(body: body) }
        )
        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["p1"], judge: "judge"),
            plugin: try Self.plugin(panel: ["p1"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: true
        )
        guard case .streaming(let streaming) = result else {
            return XCTFail("wantsStream:true must return a streaming plan, got \(result)")
        }
        XCTAssertEqual(streaming.route.wireModelSlug, "origin")
        XCTAssertFalse(streaming.parentRequestID.isEmpty)
        // The streaming body must not carry a fusion plugin (recursion guard).
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: streaming.requestBody) as? [String: Any])
        XCTAssertNil(body["plugins"], "synthesis body must omit plugins so it cannot re-trigger fusion")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: - Stub builders

    private func makeStubOrchestrator(
        recorder: SubCallRecorder,
        resolve: (@Sendable (String) -> ElderWandResolvedRoute?)? = nil,
        completion: (@Sendable (Data) -> BurnBarProviderProxyResponse)? = nil
    ) -> ElderWandFusionOrchestrator {
        let resolveClosure = resolve ?? { Self.route(for: $0) }
        let completionClosure = completion ?? { _ in Self.echoCompletion(body: Data()) }
        return ElderWandFusionOrchestrator(
            resolveRoute: { model in resolveClosure(model) },
            bufferedCompletion: { body, _ in completionClosure(body) },
            recordSubCall: { record in await recorder.append(record) },
            tools: ElderWandWebTools(searchBackend: .unavailable).makeTools(),
            recursionMarkerKey: BurnBarHTTPGatewayServer.fusionRecursionMarkerKey,
            recursionMarkerValue: BurnBarHTTPGatewayServer.fusionRecursionMarkerValue
        )
    }

    private static func route(for model: String) -> ElderWandResolvedRoute {
        ElderWandResolvedRoute(
            route: BurnBarProviderRoute(
                providerID: "stub",
                providerDisplayName: "Stub",
                baseURL: "https://example.com",
                requestedModel: model,
                resolvedModelID: model,
                canonicalModelID: model,
                apiKey: "k",
                pricing: .defaultFallback
            ),
            formatFamily: .openaiCompat
        )
    }

    /// A completion that returns no tool calls and echoes assistant content, so
    /// the tool loop terminates on the first turn.
    private static func echoCompletion(body: Data) -> BurnBarProviderProxyResponse {
        let response = """
        {"choices":[{"message":{"role":"assistant","content":"answer"}}],
         "usage":{"prompt_tokens":3,"completion_tokens":5}}
        """
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: Data(response.utf8),
            usage: BurnBarProviderProxyUsage(
                inputTokens: 3,
                outputTokens: 5,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0,
                confidence: .exact
            )
        )
    }

    private static func plugin(panel: [String], judge: String) throws -> FusionPluginConfig {
        // Decode through the real wire shape so the test exercises CodingKeys.
        let analysis = panel.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"id":"fusion","enabled":true,"analysis_models":[\(analysis)],"model":"\(judge)","max_tool_calls":2}
        """
        return try JSONDecoder().decode(FusionPluginConfig.self, from: Data(json.utf8))
    }

    private static func fusionBody(panel: [String], judge: String) -> Data {
        Data("""
        {"model":"origin","messages":[{"role":"user","content":"hello"}]}
        """.utf8)
    }
}

/// Thread-safe collector for sub-call accounting records.
private actor SubCallRecorder {
    private(set) var records: [ElderWandSubCallRecord] = []
    func append(_ record: ElderWandSubCallRecord) { records.append(record) }
}

// MARK: - Tool loop + web tools

final class ElderWandToolLoopTests: XCTestCase {
    func testLoopRunsToolThenFinishes() async throws {
        // Turn 1 asks for web_search; turn 2 returns the final answer.
        let turns = TurnScript(responses: [
            """
            {"choices":[{"message":{"role":"assistant","content":null,
              "tool_calls":[{"id":"c1","type":"function",
                "function":{"name":"web_search","arguments":"{\\"query\\":\\"q\\"}"}}]}}],
             "usage":{"prompt_tokens":2,"completion_tokens":2}}
            """,
            """
            {"choices":[{"message":{"role":"assistant","content":"final answer"}}],
             "usage":{"prompt_tokens":4,"completion_tokens":6}}
            """
        ])
        let loop = ElderWandToolLoop(
            tools: ElderWandWebTools(searchBackend: .unavailable).makeTools(),
            recursionMarkerKey: "x",
            recursionMarkerValue: "1"
        )
        let result = try await loop.run(
            model: "m",
            systemPrompt: "sys",
            userMessagesJSON: Data("""
            [{"role":"user","content":"hi"}]
            """.utf8),
            maxToolCalls: 4,
            chat: { body in await turns.next(for: body) }
        )
        XCTAssertEqual(result.text, "final answer")
        XCTAssertEqual(result.toolCallsExecuted, 1)
        // Usage summed across both turns: 2+4 in, 2+6 out.
        XCTAssertEqual(result.usage?.inputTokens, 6)
        XCTAssertEqual(result.usage?.outputTokens, 8)
    }

    func testWebSearchUnavailableDegradesGracefully() async {
        let tools = ElderWandWebTools(searchBackend: .unavailable).makeTools()
        let search = try? XCTUnwrap(tools.first { $0.name == "web_search" })
        let output = await search?.invoke(#"{"query":"anything"}"#)
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.contains("unavailable") == true, "no key configured must degrade, never crash")
    }

    func testWebFetchRejectsBlockedHost() async {
        let tools = ElderWandWebTools(searchBackend: .unavailable).makeTools()
        let fetch = try? XCTUnwrap(tools.first { $0.name == "web_fetch" })
        let output = await fetch?.invoke(#"{"url":"http://169.254.169.254/latest/meta-data"}"#)
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.lowercased().contains("error") == true, "metadata host must be refused (SSRF)")
    }

    func testSearchBackendResolvesFromEnvironment() {
        XCTAssertEqual(
            ElderWandSearchBackend.resolve(environment: ["BURNBAR_BRAVE_SEARCH_API_KEY": "x"]),
            .brave(apiKey: "x")
        )
        XCTAssertEqual(
            ElderWandSearchBackend.resolve(environment: ["TAVILY_API_KEY": "y"]),
            .tavily(apiKey: "y")
        )
        XCTAssertEqual(ElderWandSearchBackend.resolve(environment: [:]), .unavailable)
    }
}

/// Serves a scripted sequence of completion responses to the tool loop.
private actor TurnScript {
    private var responses: [String]
    private var index = 0
    init(responses: [String]) { self.responses = responses }

    func next(for body: Data) -> BurnBarProviderProxyResponse {
        let payload = index < responses.count ? responses[index] : responses.last ?? "{}"
        index += 1
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: Data(payload.utf8),
            usage: Self.usage(from: payload)
        )
    }

    private static func usage(from payload: String) -> BurnBarProviderProxyUsage? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }
        return BurnBarProviderProxyUsage(
            inputTokens: usage["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage["completion_tokens"] as? Int ?? 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: .exact
        )
    }
}

// MARK: - Local Codex provider executor

final class BurnBarCodexProviderExecutorTests: XCTestCase {
    func testCodexArgumentsPreserveReadOnlyConsentGate() {
        let arguments = BurnBarCodexProviderExecutor.codexArguments(
            model: "  gpt-5-codex  ",
            prompt: "answer this"
        )

        XCTAssertEqual(arguments.first, "exec")
        XCTAssertTrue(arguments.contains("--json"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--skip-git-repo-check"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(arguments.last, "answer this")

        guard let sandboxIndex = arguments.firstIndex(of: "--sandbox") else {
            return XCTFail("Codex arguments must include a sandbox flag")
        }
        XCTAssertEqual(arguments[sandboxIndex + 1], "read-only")

        guard let modelIndex = arguments.firstIndex(of: "-m") else {
            return XCTFail("Codex arguments must include a model flag")
        }
        XCTAssertEqual(arguments[modelIndex + 1], "gpt-5-codex")
    }

    func testSanitizedEnvironmentUsesAllowlistAndOptionalApiKey() {
        let environment = BurnBarCodexProviderExecutor.sanitizedEnvironment(apiKey: "  sk-test  ")
        let allowedKeys: Set<String> = [
            "PATH",
            "LANG",
            "LC_ALL",
            "TERM",
            "TMPDIR",
            "HOME",
            "OPENAI_API_KEY"
        ]

        XCTAssertTrue(Set(environment.keys).isSubset(of: allowedKeys))
        XCTAssertEqual(environment["HOME"], NSHomeDirectory())
        XCTAssertEqual(environment["OPENAI_API_KEY"], "sk-test")
        XCTAssertNil(environment["GITHUB_TOKEN"])
        XCTAssertNil(environment["GOOGLE_APPLICATION_CREDENTIALS"])
        XCTAssertNil(environment["FIREBASE_CONFIG"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
    }

    func testExtractAgentMessageUsesLatestJSONLAgentMessage() {
        let jsonl = """
        {"type":"session.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"first answer"}}
        {"type":"item.completed","item":{"type":"tool_call","text":"ignored"}}
        {"message":{"text":"fallback message"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"final answer"}}
        """

        XCTAssertEqual(
            BurnBarCodexProviderExecutor.extractAgentMessage(fromJSONL: jsonl),
            "final answer"
        )
    }

    func testChatCompletionPromptFlattensMessagesAndJsonMode() throws {
        let body = Data("""
        {
          "stream": true,
          "response_format": { "type": "json_object" },
          "messages": [
            { "role": "system", "content": "system note" },
            { "role": "user", "content": [
              { "type": "text", "text": "first line" },
              { "type": "text", "text": "second line" }
            ] }
          ]
        }
        """.utf8)

        let request = try BurnBarCodexProviderExecutor.chatCompletionPrompt(from: body)

        XCTAssertTrue(request.stream)
        XCTAssertTrue(request.prompt.contains("Do not inspect or modify files"))
        XCTAssertTrue(request.prompt.contains("System:\nsystem note"))
        XCTAssertTrue(request.prompt.contains("User:\nfirst line\nsecond line"))
        XCTAssertTrue(request.prompt.contains("Return valid JSON only."))
    }
}
