import OpenBurnBarEngine
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
        XCTAssertEqual(request.stream, true as Bool?)
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
            XCTFail("Expected buffered synthesis result, got \(result)")
            return
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

    func testPanelCallsSharingCredentialAreSerialized() async throws {
        let recorder = SubCallRecorder()
        let probe = PanelConcurrencyProbe(panelModels: ["p1", "p2"])
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            resolve: { Self.route(for: $0, slotID: "shared-account") },
            completion: { body in
                try await probe.observe(body: body)
                return Self.echoCompletion(body: body)
            }
        )

        _ = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["p1", "p2"], judge: "judge"),
            plugin: try Self.plugin(panel: ["p1", "p2"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )

        let maximumConcurrentCalls = await probe.maximumConcurrentCalls()
        XCTAssertEqual(maximumConcurrentCalls, 1)
    }

    func testPanelCallsOnDifferentCredentialsRemainParallel() async throws {
        let recorder = SubCallRecorder()
        let probe = PanelConcurrencyProbe(panelModels: ["p1", "p2"])
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            resolve: { Self.route(for: $0, slotID: "account-\($0)") },
            completion: { body in
                try await probe.observe(body: body)
                return Self.echoCompletion(body: body)
            }
        )

        _ = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["p1", "p2"], judge: "judge"),
            plugin: try Self.plugin(panel: ["p1", "p2"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )

        let maximumConcurrentCalls = await probe.maximumConcurrentCalls()
        XCTAssertEqual(maximumConcurrentCalls, 2)
    }

    func testDuplicatePanelModelsAreExecutedOnce() async throws {
        let recorder = SubCallRecorder()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            completion: { body in Self.echoCompletion(body: body) }
        )

        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["same", "same"], judge: "judge"),
            plugin: try Self.plugin(panel: ["same", "same"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )

        guard case .buffered = result else {
            XCTFail("A duplicate-free panel should still synthesize, got \(result)")
            return
        }
        let panelRecords = await recorder.records.filter {
            if case .panel = $0.stage { return true }
            return false
        }
        XCTAssertEqual(panelRecords.count, 1, "duplicate model IDs must not duplicate latency or spend")
    }

    func testMalformedJudgeVerdictFallsBackBeforeSynthesis() async throws {
        let recorder = SubCallRecorder()
        let synthesisBodies = DataBodyRecorder()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            completion: { body in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let model = try XCTUnwrap(object["model"] as? String)
                switch model {
                case "judge":
                    return Self.completion(content: "not a five-field verdict")
                case "origin":
                    await synthesisBodies.append(body)
                    return Self.completion(content: "final")
                default:
                    return Self.completion(content: "panel answer")
                }
            }
        )

        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["panel"], judge: "judge"),
            plugin: try Self.plugin(panel: ["panel"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )

        guard case .buffered = result else {
            XCTFail("Malformed judge output should degrade to raw panel evidence, got \(result)")
            return
        }
        let recordedSynthesisBody = await synthesisBodies.last()
        let synthesisBody = try XCTUnwrap(recordedSynthesisBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: synthesisBody) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let synthesisPrompt = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(synthesisPrompt.contains("judge unavailable"))
        XCTAssertTrue(synthesisPrompt.contains("panel answer"))
        XCTAssertFalse(synthesisPrompt.contains("not a five-field verdict"))
    }

    func testJudgeVerdictRequiresExactlyFiveStringFields() {
        let valid = #"{"consensus":"c","contradictions":"x","partial_coverage":"p","unique_insights":"u","blind_spots":"b"}"#
        let missing = #"{"consensus":"c","contradictions":"x","partial_coverage":"p","unique_insights":"u"}"#
        let extra = #"{"consensus":"c","contradictions":"x","partial_coverage":"p","unique_insights":"u","blind_spots":"b","score":"1"}"#
        let wrongType = #"{"consensus":"c","contradictions":[],"partial_coverage":"p","unique_insights":"u","blind_spots":"b"}"#

        XCTAssertEqual(ElderWandFusionOrchestrator.validatedJudgeVerdict(valid), valid)
        XCTAssertNil(ElderWandFusionOrchestrator.validatedJudgeVerdict(missing))
        XCTAssertNil(ElderWandFusionOrchestrator.validatedJudgeVerdict(extra))
        XCTAssertNil(ElderWandFusionOrchestrator.validatedJudgeVerdict(wrongType))
        XCTAssertNil(ElderWandFusionOrchestrator.validatedJudgeVerdict("not json"))
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
            XCTFail("One good panel member must still produce a synthesis, got \(result)")
            return
        }
        let records = await recorder.records
        XCTAssertTrue(records.contains { !$0.succeeded }, "the dropped panel member must be recorded as a failure")
        XCTAssertTrue(records.contains { $0.succeeded }, "the good panel member must be recorded as a success")
    }

    func testTimedOutPanelMemberDegradesWhenAnotherSucceeds() async throws {
        let recorder = SubCallRecorder()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            completion: { body in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if object["model"] as? String == "timed-out" {
                    throw URLError(.timedOut)
                }
                return Self.echoCompletion(body: body)
            }
        )

        let result = await orchestrator.run(
            bodyData: Self.fusionBody(panel: ["timed-out", "good"], judge: "judge"),
            plugin: try Self.plugin(panel: ["timed-out", "good"], judge: "judge"),
            originatingModel: "origin",
            wantsStream: false
        )

        guard case .buffered = result else {
            XCTFail("One timed-out panel member should not discard a successful answer, got \(result)")
            return
        }
        let failures = await recorder.records.filter { !$0.succeeded }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.modelSlug, "timed-out")
    }

    func testCancellationDuringPanelStopsBeforeJudgeAndSynthesis() async throws {
        let recorder = SubCallRecorder()
        let probe = CancellationProbe()
        let orchestrator = makeStubOrchestrator(
            recorder: recorder,
            completion: { body in try await probe.completion(for: body) }
        )

        let plugin = try Self.plugin(panel: ["panel"], judge: "judge")
        let task = Task {
            await orchestrator.run(
                bodyData: Self.fusionBody(panel: ["panel"], judge: "judge"),
                plugin: plugin,
                originatingModel: "origin",
                wantsStream: false
            )
        }
        await probe.waitUntilStarted()
        task.cancel()
        let result = await task.value

        guard case .failed(let failure) = result else {
            XCTFail("Cancellation should be terminal, got \(result)")
            return
        }
        let attemptedModels = await probe.models()
        let records = await recorder.records
        XCTAssertEqual(failure.status, 499)
        XCTAssertEqual(attemptedModels, ["panel"])
        XCTAssertTrue(records.isEmpty, "Cancelled calls must not be recorded as provider failures.")
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
            XCTFail("Zero panel successes must fail the request, got \(result)")
            return
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
            XCTFail("wantsStream:true must return a streaming plan, got \(result)")
            return
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
        completion: (@Sendable (Data) async throws -> BurnBarProviderProxyResponse)? = nil
    ) -> ElderWandFusionOrchestrator {
        let resolveClosure = resolve ?? { Self.route(for: $0) }
        let completionClosure: @Sendable (Data) async throws -> BurnBarProviderProxyResponse =
            completion ?? { _ in Self.echoCompletion(body: Data()) }
        return ElderWandFusionOrchestrator(
            resolveRoute: { model in resolveClosure(model) },
            bufferedCompletion: { body, _ in try await completionClosure(body) },
            recordSubCall: { record in await recorder.append(record) },
            tools: ElderWandWebTools(searchBackend: .unavailable).makeTools(),
            recursionMarkerKey: BurnBarHTTPGatewayServer.fusionRecursionMarkerKey,
            recursionMarkerValue: BurnBarHTTPGatewayServer.fusionRecursionMarkerValue
        )
    }

    private static func route(for model: String, slotID: String? = nil) -> ElderWandResolvedRoute {
        ElderWandResolvedRoute(
            route: BurnBarProviderRoute(
                providerID: "stub",
                providerDisplayName: "Stub",
                credentialSlotID: slotID,
                credentialSlotLabel: slotID,
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
        completion(content: "answer")
    }

    private static func completion(content: String) -> BurnBarProviderProxyResponse {
        let response = """
        {"choices":[{"message":{"role":"assistant","content":\(String(reflecting: content))}}],
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

private actor PanelConcurrencyProbe {
    private let panelModels: Set<String>
    private var activeCalls = 0
    private var maximumCalls = 0

    init(panelModels: Set<String>) {
        self.panelModels = panelModels
    }

    func observe(body: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = object["model"] as? String,
              panelModels.contains(model) else {
            return
        }
        activeCalls += 1
        maximumCalls = max(maximumCalls, activeCalls)
        do {
            try await Task.sleep(nanoseconds: 100_000_000)
        } catch {
            activeCalls -= 1
            throw error
        }
        activeCalls -= 1
    }

    func maximumConcurrentCalls() -> Int {
        maximumCalls
    }
}

/// Thread-safe collector for sub-call accounting records.
private actor SubCallRecorder {
    private(set) var records: [ElderWandSubCallRecord] = []
    func append(_ record: ElderWandSubCallRecord) { records.append(record) }
}

private actor DataBodyRecorder {
    private var bodies: [Data] = []
    func append(_ body: Data) { bodies.append(body) }
    func last() -> Data? { bodies.last }
}

private actor CancellationProbe {
    private var started = false
    private var attemptedModels: [String] = []

    func completion(for body: Data) async throws -> BurnBarProviderProxyResponse {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let model = try XCTUnwrap(object["model"] as? String)
        attemptedModels.append(model)
        started = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: Data(#"{"choices":[{"message":{"role":"assistant","content":"late"}}]}"#.utf8),
            usage: nil
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func models() -> [String] { attemptedModels }
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
    func first() -> URLRequest? { requests.first }
    func urls() -> [URL] { requests.compactMap(\.url) }
}

private actor URLRecorder {
    private var recordedURLs: [URL] = []
    func append(_ url: URL) { recordedURLs.append(url) }
    func urls() -> [URL] { recordedURLs }
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

    func testToolBudgetExhaustionStillAnswersEveryRequestedToolCall() async throws {
        let turns = StrictToolProtocolScript()
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
            maxToolCalls: 1,
            chat: { body in try await turns.next(for: body) }
        )

        XCTAssertEqual(result.text, "final answer")
        XCTAssertEqual(result.toolCallsExecuted, 1)
    }

    func testWebSearchUnavailableDegradesGracefully() async {
        let tools = ElderWandWebTools(searchBackend: .unavailable).makeTools()
        let search = try? XCTUnwrap(tools.first { $0.name == "web_search" })
        let output = await search?.invoke(#"{"query":"anything"}"#)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.contains("unavailable"), true, "no key configured must degrade, never crash")
    }

    func testHostedSearchCallableUsesFirebaseHeadersAndCallableEnvelope() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/performElderWandHostedSearch"))
        let hosted = ElderWandHostedSearchConfig(
            endpoint: endpoint,
            firebaseAuthorization: "Bearer firebase-id-token",
            appCheckToken: "app-check-token"
        )
        let recorder = RequestRecorder()
        let tools = ElderWandWebTools(
            hostedSearch: hosted,
            searchBackend: .perplexity(apiKey: "local-key"),
            runID: "fusion-run-1",
            searchRunner: { request in
                await recorder.append(request)
                let body = """
                {"result":{"provider":"perplexity","results":[{"title":"Hosted","url":"https://example.com/hosted","snippet":"fresh"}],"quota":{"remaining":99}}}
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        ).makeTools()
        let search = try XCTUnwrap(tools.first { $0.name == "web_search" })

        let output = await search.invoke(#"{"query":"latest BurnBar"}"#)

        let recordedRequest = await recorder.first()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check-token")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["query"] as? String, "latest BurnBar")
        XCTAssertEqual(data["runId"] as? String, "fusion-run-1")
        XCTAssertEqual(data["maxResults"] as? Int, 5)
        XCTAssertTrue(output.contains("hosted results via perplexity"))
        XCTAssertTrue(output.contains("99 hosted Fusion searches remaining"))
    }

    func testHostedSearchQuotaFailureDoesNotFallBackToLocalProvider() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/performElderWandHostedSearch"))
        let hosted = ElderWandHostedSearchConfig(
            endpoint: endpoint,
            firebaseAuthorization: "Bearer firebase-id-token",
            appCheckToken: nil
        )
        let recorder = RequestRecorder()
        let tools = ElderWandWebTools(
            hostedSearch: hosted,
            searchBackend: .perplexity(apiKey: "local-key"),
            runID: "fusion-run-2",
            searchRunner: { request in
                await recorder.append(request)
                let body = """
                {"error":{"status":"RESOURCE_EXHAUSTED","message":"Fusion hosted search quota is exhausted."}}
                """
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                )
            }
        ).makeTools()
        let search = try XCTUnwrap(tools.first { $0.name == "web_search" })

        let output = await search.invoke(#"{"query":"latest BurnBar"}"#)

        let requestedURLs = await recorder.urls()
        XCTAssertEqual(requestedURLs, [endpoint])
        XCTAssertTrue(output.contains("quota is exhausted or unavailable"))
        XCTAssertFalse(output.contains("local-key"))
    }

    func testWebFetchRejectsBlockedHost() async {
        let tools = ElderWandWebTools(searchBackend: .unavailable).makeTools()
        let fetch = try? XCTUnwrap(tools.first { $0.name == "web_fetch" })
        let output = await fetch?.invoke(#"{"url":"http://169.254.169.254/latest/meta-data"}"#)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.lowercased().contains("error"), true, "metadata host must be refused (SSRF)")
    }

    func testWebFetchRejectsResolvedPrivateHostBeforeFetcherDispatch() async throws {
        let recorder = URLRecorder()
        let tools = ElderWandWebTools(
            searchBackend: .unavailable,
            hostResolver: { _ in ["10.0.0.8"] },
            fetcher: { url in
                await recorder.append(url)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("<html><body>unsafe</body></html>".utf8), response)
            }
        ).makeTools()
        let fetch = try XCTUnwrap(tools.first { $0.name == "web_fetch" })

        let output = await fetch.invoke(#"{"url":"https://public-looking.example/report"}"#)

        let recordedURLs = await recorder.urls()
        XCTAssertTrue(output.contains("anti-rebind"), "DNS-resolved private targets must be refused")
        XCTAssertEqual(recordedURLs, [], "blocked DNS targets must not reach the fetcher")
    }

    func testWebFetchAllowsPublicResolvedHostAndDispatchesFetcher() async throws {
        let recorder = URLRecorder()
        let tools = ElderWandWebTools(
            searchBackend: .unavailable,
            hostResolver: { _ in ["93.184.216.34"] },
            fetcher: { url in
                await recorder.append(url)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("<html><title>Example</title><body>Readable page</body></html>".utf8), response)
            }
        ).makeTools()
        let fetch = try XCTUnwrap(tools.first { $0.name == "web_fetch" })

        let output = await fetch.invoke(#"{"url":"https://example.com/report"}"#)

        let recordedURLs = await recorder.urls()
        XCTAssertTrue(output.contains("Title: Example"))
        XCTAssertTrue(output.contains("Readable page"))
        XCTAssertEqual(recordedURLs, [URL(string: "https://example.com/report")!])
    }

    func testSearchBackendResolvesFromEnvironment() {
        XCTAssertEqual(
            ElderWandSearchBackend.resolve(environment: [
                "BURNBAR_PERPLEXITY_SEARCH_API_KEY": "x",
                "TAVILY_API_KEY": "y"
            ]),
            .perplexity(apiKey: "x")
        )
        XCTAssertEqual(
            ElderWandSearchBackend.resolveAll(environment: [
                "PERPLEXITY_API_KEY": "x",
                "TAVILY_API_KEY": "y"
            ]),
            [.perplexity(apiKey: "x"), .tavily(apiKey: "y")]
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

private actor StrictToolProtocolScript {
    private var turn = 0

    func next(for body: Data) throws -> BurnBarProviderProxyResponse {
        defer { turn += 1 }
        if turn == 0 {
            return Self.response(
                """
                {"choices":[{"message":{"role":"assistant","content":null,
                  "tool_calls":[
                    {"id":"c1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"one\\"}"}},
                    {"id":"c2","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"two\\"}"}}
                  ]}}]}
                """
            )
        }

        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        let assistant = messages.last { ($0["role"] as? String) == "assistant" }
        let calls = assistant?["tool_calls"] as? [[String: Any]] ?? []
        let requestedIDs = Set(calls.compactMap { $0["id"] as? String })
        let answeredIDs = Set(messages.compactMap { message -> String? in
            guard (message["role"] as? String) == "tool" else { return nil }
            return message["tool_call_id"] as? String
        })
        guard requestedIDs.isSubset(of: answeredIDs) else {
            throw ToolProtocolError.unansweredCalls(requestedIDs.subtracting(answeredIDs).sorted())
        }
        return Self.response(
            """
            {"choices":[{"message":{"role":"assistant","content":"final answer"}}]}
            """
        )
    }

    private static func response(_ payload: String) -> BurnBarProviderProxyResponse {
        BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: Data(payload.utf8),
            usage: nil
        )
    }
}

private enum ToolProtocolError: Error {
    case unansweredCalls([String])
}
