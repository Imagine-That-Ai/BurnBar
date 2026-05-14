import Foundation

/// Adapter that targets the existing OpenBurnBar Hermes relay.
///
/// Hermes already speaks the Chart Studio JSON envelope grammar — this
/// adapter reuses the same `POST /v1/chat/completions` plumbing as
/// `ChartStudioHermesBridge` but asks for an analysis-shaped response
/// instead of a single rendering envelope.
///
/// Two response shapes are supported:
///
/// 1. **Canvas** — `investigate(...)` streams the legacy canvas event
///    sequence, identical to `ChartStudioHermesBridge`. Used by the
///    "default brief" first-launch path.
/// 2. **Structured analysis** — `analyze(...)` builds the same JSON
///    envelope that `OpenAIInsightAdapter` / `AnthropicInsightAdapter`
///    expect, ships it through the transport's chat-completion method,
///    and decodes the response via `InsightAnalysisModelDecoder`. This
///    is what powers every freeform follow-up tap: the user sees a real
///    LLM-authored reply, attributed to Hermes, with token + USD cost
///    folded into the audit log + Spend KPI on the same rollup.
///
/// Streaming follow-up replies hop on `stream(...)`; the orchestrator
/// prefers streaming for `.answerFollowUp` turns and falls back to
/// buffered `analyze` if the transport doesn't implement it.
///
/// The actual transport (LAN socket vs. hosted relay vs. macOS daemon
/// session) is delegated to a `HermesInsightTransport` so each platform
/// shell can plug in its existing connection object.
public struct HermesInsightAdapter: InsightStreamingModelGateway {

    public let providerKey = "hermes"
    public let displayName = "Hermes"
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: false,
        supportsJSONObject: true,
        supportsThinking: false,
        supportsToolUse: false,
        supportsStreaming: true
    )

    public let transport: HermesInsightTransport
    public let availableModelList: [InsightCatalogModel]

    public init(transport: HermesInsightTransport,
                availableModels: [InsightCatalogModel] = HermesInsightAdapter.defaultModels) {
        self.transport = transport
        self.availableModelList = availableModels
    }

    public func availableModels() async throws -> [InsightCatalogModel] {
        if !availableModelList.isEmpty { return availableModelList }
        return try await transport.discoverModels()
    }

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let canvas = try await transport.sendCanvasRequest(request: request)
                    continuation.yield(.finalCanvas(canvas))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func analyze(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) async throws -> InsightAnalysisResult {
        let startedAt = Date()
        let chatRequest = try buildChatRequest(for: request, platform: platform)
        let response = try await transport.runAnalysisCompletion(request: chatRequest)
        let usage = makeTokenUsage(
            from: response.usage,
            request: request,
            startedAt: startedAt,
            completedAt: Date()
        )
        return try InsightAnalysisModelDecoder.decode(
            from: response.responseJSON,
            request: request,
            platform: platform,
            tokenUsage: usage
        )
    }

    public func stream(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightAnalysisStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                do {
                    let chatRequest = try buildChatRequest(for: request, platform: platform)
                    var assembled = ""
                    var terminalUsage: HermesInsightTokenUsage?
                    let chunks = transport.streamAnalysisCompletion(request: chatRequest)
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        switch chunk {
                        case .delta(let text):
                            assembled += text
                            continuation.yield(.partialAnswer(text: assembled))
                        case .usage(let usage):
                            terminalUsage = usage
                        case .completed(let fullAnswer):
                            if !fullAnswer.isEmpty, fullAnswer.count > assembled.count {
                                assembled = fullAnswer
                            }
                        }
                    }
                    try Task.checkCancellation()
                    let resolved = makeTokenUsage(
                        from: terminalUsage,
                        request: request,
                        startedAt: startedAt,
                        completedAt: Date()
                    )
                    let result = try Self.materializeStreamedResult(
                        rawAnswer: assembled,
                        request: request,
                        platform: platform,
                        tokenUsage: resolved
                    )
                    continuation.yield(.final(result: result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: InsightGatewayError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    private func buildChatRequest(
        for request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform
    ) throws -> HermesInsightChatRequest {
        let prompt = InsightAnalysisModelPrompt()
        let systemPrompt = prompt.systemPrompt(
            for: request,
            platform: platform,
            strictSchema: capabilities.supportsStrictJSONSchema
        )
        let userPayload = try prompt.userPayload(for: request)
        let tier = capabilities.bestTier(requested: .jsonObject)
        return HermesInsightChatRequest(
            modelID: request.selectedModel.modelID,
            systemPrompt: systemPrompt,
            userPayload: userPayload,
            capabilityTier: tier,
            prefersAnswerLatency: request.instruction == .answerFollowUp
        )
    }

    private func makeTokenUsage(
        from hermes: HermesInsightTokenUsage?,
        request: InsightAnalysisRequest,
        startedAt: Date,
        completedAt: Date
    ) -> InsightTokenUsage? {
        let resolvedInput: Int
        let resolvedOutput: Int
        let resolvedReasoning: Int
        let resolvedCacheCreation: Int
        let resolvedCacheRead: Int
        let resolvedCost: Double

        if let hermes {
            resolvedInput = hermes.inputTokens
            resolvedOutput = hermes.outputTokens
            resolvedReasoning = hermes.reasoningTokens
            resolvedCacheCreation = hermes.cacheCreationTokens
            resolvedCacheRead = hermes.cacheReadTokens
            // Prefer the relay's USD figure (it knows the underlying
            // provider price). If the relay didn't surface one, derive
            // from the catalog model entry so we never emit a zero by
            // default — that would silently hide cost in the audit log.
            if hermes.estimatedCostUSD > 0 {
                resolvedCost = hermes.estimatedCostUSD
            } else {
                resolvedCost = derivedCost(
                    modelID: request.selectedModel.modelID,
                    input: hermes.inputTokens,
                    output: hermes.outputTokens
                )
            }
        } else {
            // No usage block in the response. Don't fabricate token
            // counts — but make it loud that something is off by
            // attributing an empty record so the audit log still gets
            // the start/complete timestamps.
            resolvedInput = 0
            resolvedOutput = 0
            resolvedReasoning = 0
            resolvedCacheCreation = 0
            resolvedCacheRead = 0
            resolvedCost = 0
        }

        return InsightTokenUsage(
            providerKey: providerKey,
            modelID: request.selectedModel.modelID,
            inputTokens: resolvedInput,
            outputTokens: resolvedOutput,
            reasoningTokens: resolvedReasoning,
            cacheCreationTokens: resolvedCacheCreation,
            cacheReadTokens: resolvedCacheRead,
            estimatedCostUSD: resolvedCost,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func derivedCost(modelID: String, input: Int, output: Int) -> Double {
        guard let pricing = availableModelList.first(where: { $0.id == modelID }) else { return 0 }
        let inputCost = (Double(input) / 1_000_000.0) * (pricing.inputCostPerMtoken ?? 0)
        let outputCost = (Double(output) / 1_000_000.0) * (pricing.outputCostPerMtoken ?? 0)
        return inputCost + outputCost
    }

    /// Hermes ships a streamed reply as plain text, not the structured
    /// JSON envelope the buffered `analyze` path produces. The
    /// orchestrator still has to surface an `InsightAnalysisResult` with
    /// the rule-engine's findings/anomalies/recommendations attached so
    /// the rest of the brief renders. We materialize that hybrid here:
    /// the rule engine builds the deterministic surface, and we replace
    /// the `briefingAnswer.answer` with the LLM-authored stream output.
    private static func materializeStreamedResult(
        rawAnswer: String,
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tokenUsage: InsightTokenUsage?
    ) throws -> InsightAnalysisResult {
        // Try the structured-JSON decode first — if the relay delivered
        // the full envelope mid-stream we get back the same fidelity as
        // the buffered path.
        if let envelopeData = rawAnswer.data(using: .utf8),
           let envelope = try? InsightAnalysisModelDecoder.decode(
               from: envelopeData,
               request: request,
               platform: platform,
               tokenUsage: tokenUsage
           ) {
            return envelope
        }
        // Fall back: keep the rule engine's baseline (so findings,
        // anomalies, follow-ups all render) and overlay the LLM answer
        // into the briefing-answer card.
        var baseline = RuleBasedInsightAnalysisEngine.buildResult(request: request, platform: platform)
        baseline.tokenUsage = tokenUsage
        baseline.estimatedCostUSD = tokenUsage?.estimatedCostUSD
        baseline.briefingAnswer = InsightBriefingAnswer(
            question: request.prompt,
            answer: rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines),
            bullets: baseline.briefingAnswer?.bullets ?? [],
            citations: baseline.briefingAnswer?.citations ?? Array(baseline.citations.prefix(3)),
            source: .modelGateway,
            modelDisplayName: request.selectedModel.displayName,
            isFallback: false
        )
        baseline.modelTag = request.selectedModel
        return baseline
    }
}

extension HermesInsightAdapter {
    /// Default catalog entry surfaced for the user's Hermes relay.
    ///
    /// Hermes is a **relay** — the actual model + price depends on
    /// whatever the user's relay routes to under the hood. We surface
    /// one synthetic catalog entry (`hermes-default`) with no fixed
    /// price; the transport reports the truthful `estimatedCostUSD`
    /// each turn. Shell layers can override `availableModels` to expose
    /// a richer picker when the relay advertises specific routes.
    public static let defaultModels: [InsightCatalogModel] = [
        .init(
            id: "hermes-default",
            displayName: "Hermes",
            providerKey: "hermes",
            egressTier: .userRelay,
            capabilities: .init(
                supportsStrictJSONSchema: false,
                supportsJSONObject: true,
                supportsThinking: false,
                supportsToolUse: false,
                supportsStreaming: true
            ),
            inputCostPerMtoken: 0,
            outputCostPerMtoken: 0,
            symbolName: "antenna.radiowaves.left.and.right"
        )
    ]
}

// MARK: - Transport

/// Pluggable transport so we don't have to import the entire Hermes
/// stack into core. Shell layers provide their own implementation:
/// mobile wires HermesService, macOS wires the daemon's Hermes session,
/// Android wires HermesAndroidService.
///
/// All adapters can implement the legacy canvas path (`sendCanvasRequest`)
/// + at least one of the analysis paths. The buffered + streaming
/// completion methods have default "not implemented" bodies so each
/// transport can opt in incrementally without breaking existing shells.
public protocol HermesInsightTransport: Sendable {
    /// Discover what specific models the relay can route to (e.g. when
    /// the user has multiple Hermes sub-providers attached). Optional —
    /// the adapter falls back to `HermesInsightAdapter.defaultModels`
    /// when the transport hasn't advertised anything.
    func discoverModels() async throws -> [InsightCatalogModel]
    /// Legacy canvas pipeline: ask Hermes to render the entire canvas
    /// in one envelope. Used by the default-brief first-launch path.
    func sendCanvasRequest(request: InsightInvestigateRequest) async throws -> InsightCanvas
    /// Buffered chat-completion path. The adapter assembles the
    /// structured-prompt request; the transport ships it through
    /// whatever connection Hermes is using (LAN HTTP, hosted relay,
    /// daemon IPC) and returns the full response body for decoding.
    func runAnalysisCompletion(request: HermesInsightChatRequest) async throws -> HermesInsightChatResponse
    /// Streaming chat-completion path. Yields `.delta` chunks as the
    /// relay sends them, then a terminal `.usage` chunk + `.completed`
    /// when the upstream finishes. Cancellation MUST propagate down
    /// the transport so a dropped subscriber stops the upstream call.
    func streamAnalysisCompletion(request: HermesInsightChatRequest) -> AsyncThrowingStream<HermesInsightChunk, Error>
}

public extension HermesInsightTransport {
    func runAnalysisCompletion(
        request: HermesInsightChatRequest
    ) async throws -> HermesInsightChatResponse {
        // Default: fold the streaming path into a buffered result by
        // accumulating chunks. Transports that have a faster buffered
        // endpoint should override this.
        var assembled = ""
        var terminalUsage: HermesInsightTokenUsage?
        for try await chunk in streamAnalysisCompletion(request: request) {
            switch chunk {
            case .delta(let text): assembled += text
            case .usage(let usage): terminalUsage = usage
            case .completed(let fullAnswer):
                if fullAnswer.count > assembled.count { assembled = fullAnswer }
            }
        }
        return HermesInsightChatResponse(
            responseJSON: Data(assembled.utf8),
            usage: terminalUsage
        )
    }

    func streamAnalysisCompletion(
        request: HermesInsightChatRequest
    ) -> AsyncThrowingStream<HermesInsightChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: InsightGatewayError.modelUnavailable(
                modelID: request.modelID,
                reason: "Hermes transport does not implement streaming."
            ))
        }
    }
}

// MARK: - Streaming protocol

/// Optional capability: gateways that implement this protocol expose a
/// `stream(...)` method on top of buffered `analyze(...)`. The
/// orchestrator prefers streaming for `.answerFollowUp` turns so the
/// follow-up tap renders token-by-token instead of waiting for the full
/// response. Existing gateways without this conformance keep working
/// through the buffered path unchanged.
public protocol InsightStreamingModelGateway: InsightModelGateway {
    func stream(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightAnalysisStreamEvent, Error>
}

/// One event in a streaming analysis. The orchestrator forwards these
/// to the UI so the brief's answer text can grow incrementally.
public enum InsightAnalysisStreamEvent: Sendable {
    /// Latest accumulated answer text. Each event carries the full
    /// running answer (not just the delta) so the UI doesn't need to
    /// reconstruct state when chunks are dropped or coalesced.
    case partialAnswer(text: String)
    /// Stream completed cleanly. The final `InsightAnalysisResult`
    /// carries the canonical token usage + cost the audit log records.
    case final(result: InsightAnalysisResult)
}
