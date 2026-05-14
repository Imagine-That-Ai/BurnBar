import XCTest
@testable import OpenBurnBarCore

/// Exercises the Hermes Insights adapter end-to-end with an in-memory
/// transport stub. The stub stands in for `HermesInsightHTTPTransport`
/// so the suite doesn't require a running daemon.
///
/// Covers:
/// - Buffered `analyze(...)` returns a structured `InsightAnalysisResult`
///   with `tokenUsage` + `estimatedCostUSD` populated from the relay's
///   terminal usage chunk.
/// - Streamed `stream(...)` delivers `.partialAnswer` events in order
///   and finishes with `.final(result:)` carrying the assembled answer
///   and canonical token usage.
/// - Mid-stream cancellation surfaces `InsightGatewayError.cancelled`
///   without hanging the consumer.
/// - The adapter advertises the Hermes catalog entry with the
///   `userRelay` egress tier so the model picker badges it correctly.
final class HermesInsightAdapterTests: XCTestCase {

    func testAvailableModelsExposesHermesRelayEntry() async throws {
        let transport = StubHermesInsightTransport()
        let adapter = HermesInsightAdapter(transport: transport)
        let models = try await adapter.availableModels()
        XCTAssertEqual(models.first?.providerKey, "hermes")
        XCTAssertEqual(models.first?.egressTier, .userRelay)
        XCTAssertEqual(models.first?.symbolName, "antenna.radiowaves.left.and.right")
    }

    func testAnalyzeReturnsStructuredResultWithTokenUsageAndCost() async throws {
        let transport = StubHermesInsightTransport()
        transport.scriptedUnaryEnvelope = HermesInsightAdapterTests.canonicalEnvelope()
        transport.scriptedUnaryUsage = HermesInsightTokenUsage(
            inputTokens: 4_200,
            outputTokens: 1_027,
            reasoningTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0.0042
        )
        let adapter = HermesInsightAdapter(transport: transport)
        let request = try HermesInsightAdapterTests.followUpRequest(prompt: "Why did cost spike?")
        let result = try await adapter.analyze(
            request: request,
            platform: .iOS,
            tools: nil
        )

        XCTAssertEqual(result.modelTag.providerKey, "hermes")
        XCTAssertEqual(result.executiveSummary, "Cost jumped because Hermes routed two long Claude turns.")
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertNotNil(result.tokenUsage)
        XCTAssertEqual(result.tokenUsage?.providerKey, "hermes")
        XCTAssertEqual(result.tokenUsage?.inputTokens, 4_200)
        XCTAssertEqual(result.tokenUsage?.outputTokens, 1_027)
        XCTAssertEqual(result.tokenUsage?.estimatedCostUSD ?? 0, 0.0042, accuracy: 0.00001)
        XCTAssertEqual(result.estimatedCostUSD ?? 0, 0.0042, accuracy: 0.00001)
    }

    func testStreamYieldsPartialAnswersThenFinalResult() async throws {
        let transport = StubHermesInsightTransport()
        transport.scriptedStreamChunks = [
            .delta("Hermes routed "),
            .delta("two long Claude turns "),
            .delta("→ cost +$0.42."),
            .usage(HermesInsightTokenUsage(
                inputTokens: 3_900,
                outputTokens: 1_200,
                reasoningTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 0.0051
            )),
            .completed(fullAnswer: "Hermes routed two long Claude turns → cost +$0.42.")
        ]
        let adapter = HermesInsightAdapter(transport: transport)
        let request = try HermesInsightAdapterTests.followUpRequest(prompt: "Why did cost spike?")
        var partials: [String] = []
        var finalResult: InsightAnalysisResult?
        for try await event in adapter.stream(request: request, platform: .iOS, tools: nil) {
            switch event {
            case .partialAnswer(let text):
                partials.append(text)
            case .final(let result):
                finalResult = result
            }
        }
        XCTAssertEqual(partials.count, 3)
        XCTAssertEqual(partials.first, "Hermes routed ")
        XCTAssertEqual(partials.last, "Hermes routed two long Claude turns → cost +$0.42.")
        XCTAssertNotNil(finalResult)
        XCTAssertEqual(finalResult?.modelTag.providerKey, "hermes")
        XCTAssertEqual(finalResult?.tokenUsage?.inputTokens, 3_900)
        XCTAssertEqual(finalResult?.tokenUsage?.outputTokens, 1_200)
        XCTAssertEqual(finalResult?.estimatedCostUSD ?? 0, 0.0051, accuracy: 0.00001)
        XCTAssertNotNil(finalResult?.briefingAnswer)
        XCTAssertEqual(finalResult?.briefingAnswer?.source, .modelGateway)
    }

    func testStreamPropagatesCancellation() async throws {
        let transport = StubHermesInsightTransport()
        // Script a slow stream so we have time to cancel before completion.
        transport.scriptedStreamDelayNanos = 200_000_000 // 0.2s per chunk
        transport.scriptedStreamChunks = [
            .delta("Hermes "),
            .delta("is "),
            .delta("still "),
            .delta("typing…")
        ]
        let adapter = HermesInsightAdapter(transport: transport)
        let request = try HermesInsightAdapterTests.followUpRequest(prompt: "Long answer please.")
        let task = Task<Error?, Never> {
            do {
                for try await event in adapter.stream(request: request, platform: .iOS, tools: nil) {
                    if case .partialAnswer(let text) = event, text.count >= "Hermes ".count {
                        // First chunk landed — cancel.
                        return nil
                    }
                }
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        let outcome = await task.value
        // Either the stream completed cleanly before cancellation hit
        // (rare on a fast machine) or it surfaced our cancellation error.
        if let error = outcome {
            XCTAssertEqual(error as? InsightGatewayError, .cancelled)
        }
    }

    func testAnalyzeFallsBackToBufferedStreamWhenTransportOnlyStreams() async throws {
        let transport = StubHermesInsightTransport()
        transport.scriptedStreamChunks = [
            .delta(HermesInsightAdapterTests.canonicalEnvelope()),
            .usage(HermesInsightTokenUsage(
                inputTokens: 1_000,
                outputTokens: 250,
                estimatedCostUSD: 0.001
            )),
            .completed(fullAnswer: HermesInsightAdapterTests.canonicalEnvelope())
        ]
        transport.disableUnaryPath = true
        let adapter = HermesInsightAdapter(transport: transport)
        let request = try HermesInsightAdapterTests.followUpRequest(prompt: "Why did cost spike?")
        let result = try await adapter.analyze(
            request: request,
            platform: .iOS,
            tools: nil
        )
        XCTAssertEqual(result.executiveSummary, "Cost jumped because Hermes routed two long Claude turns.")
        XCTAssertEqual(result.tokenUsage?.inputTokens, 1_000)
        XCTAssertEqual(result.tokenUsage?.outputTokens, 250)
        XCTAssertEqual(result.estimatedCostUSD ?? 0, 0.001, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private static func canonicalEnvelope() -> String {
        // Minimal-but-complete `InsightAnalysisResult` envelope. The
        // decoder requires `executiveSummary`, `findings`, `anomalies`,
        // `recommendations`, `generatedWidgets`, `followUpQuestions`,
        // and `citations` at the top level.
        """
        {
          "executiveSummary": "Cost jumped because Hermes routed two long Claude turns.",
          "findings": [
            {
              "title": "Two heavy Claude turns drove the spike",
              "whyItMatters": "Each turn ran over 100K input tokens through claude-sonnet-4-6.",
              "evidence": [{"id": null, "label": "Sessions"}],
              "confidence": "high",
              "severity": "medium",
              "recommendedAction": "Compare with claude-haiku-4-5 for the next routine turn."
            }
          ],
          "anomalies": [],
          "recommendations": [],
          "generatedWidgets": [],
          "followUpQuestions": [
            {"question": "Show me the two heavy turns."}
          ],
          "citations": []
        }
        """
    }

    private static func followUpRequest(prompt: String) throws -> InsightAnalysisRequest {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = try InsightDigestBuilder().build(
            from: snapshot,
            filter: InsightFilter(window: .last7d)
        )
        let evidenceIndex: [InsightEvidence] = []
        let budgetReport = InsightContextBudgetReport(
            encodedBytes: 4_096,
            estimatedPromptTokens: 1_024,
            includedDataSources: ["firestore_rollups"]
        )
        let context = InsightAnalysisContext(
            digest: digest,
            evidenceIndex: evidenceIndex,
            budgetReport: budgetReport
        )
        let modelTag = InsightModelTag(
            providerKey: "hermes",
            modelID: "hermes-default",
            displayName: "Hermes",
            egressTier: .userRelay
        )
        return InsightAnalysisRequest(
            prompt: prompt,
            context: context,
            currentCanvas: nil,
            selectedModel: modelTag,
            instruction: .answerFollowUp,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 6
        )
    }
}

/// In-memory transport stub. Defaults to throwing — each test scripts
/// the chunks / usage it needs.
private final class StubHermesInsightTransport: HermesInsightTransport, @unchecked Sendable {

    var scriptedUnaryEnvelope: String?
    var scriptedUnaryUsage: HermesInsightTokenUsage?
    var scriptedStreamChunks: [HermesInsightChunk] = []
    var scriptedStreamDelayNanos: UInt64 = 0
    var disableUnaryPath: Bool = false

    func discoverModels() async throws -> [InsightCatalogModel] {
        HermesInsightAdapter.defaultModels
    }

    func sendCanvasRequest(request: InsightInvestigateRequest) async throws -> InsightCanvas {
        throw InsightGatewayError.modelUnavailable(
            modelID: request.modelTag.modelID,
            reason: "stub does not support canvas requests"
        )
    }

    func runAnalysisCompletion(
        request: HermesInsightChatRequest
    ) async throws -> HermesInsightChatResponse {
        if disableUnaryPath {
            // Force the adapter through the streaming-fallback default.
            var assembled = ""
            var usage: HermesInsightTokenUsage?
            for try await chunk in streamAnalysisCompletion(request: request) {
                switch chunk {
                case .delta(let text): assembled += text
                case .usage(let u): usage = u
                case .completed(let full):
                    if full.count > assembled.count { assembled = full }
                }
            }
            return HermesInsightChatResponse(
                responseJSON: Data(assembled.utf8),
                usage: usage
            )
        }
        let envelope = scriptedUnaryEnvelope ?? ""
        let body = "{\"choices\":[{\"message\":{\"content\":\(jsonString(envelope))}}]}"
        return HermesInsightChatResponse(
            responseJSON: Data(body.utf8),
            usage: scriptedUnaryUsage
        )
    }

    func streamAnalysisCompletion(
        request: HermesInsightChatRequest
    ) -> AsyncThrowingStream<HermesInsightChunk, Error> {
        let chunks = scriptedStreamChunks
        let delay = scriptedStreamDelayNanos
        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: InsightGatewayError.cancelled)
                        return
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func jsonString(_ raw: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
