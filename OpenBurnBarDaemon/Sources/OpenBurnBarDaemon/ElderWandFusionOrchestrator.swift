import Foundation
import OpenBurnBarCore

// MARK: - The Elder Wand — model-fusion orchestrator
//
// OpenRouter "Fusion"-compatible model-fusion router. Runs entirely inside the
// daemon gateway (`BurnBarHTTPGatewayServer`):
//
//   1. PANEL   — 1...8 analysis models answer the originating prompt IN PARALLEL
//                (`withThrowingTaskGroup`), each on its own resolved route, each
//                with the server-side web tool-loop (`web_search` + `web_fetch`).
//                Graceful degradation: a failed panel member is dropped; the
//                request fails only if ZERO members succeed.
//   2. JUDGE   — embeds the N panel answers verbatim and COMPARES them into a
//                strict 5-field verdict (consensus / contradictions /
//                partial_coverage / unique_insights / blind_spots). Never merges.
//   3. SYNTHESIS — the ORIGINATING model (the request's top-level `model`) writes
//                the final user-facing answer from the verdict, streamed when the
//                client asked to stream (else buffered).
//
// Recursion guard: every inner sub-call body carries a recursion marker so the
// gateway never re-triggers fusion on panel/judge/synthesis calls.
//
// Accounting: each sub-call records ONE usage event + ONE route-log row, with a
// DISTINCT idempotency key (so identical sub-calls are not deduped) and a SHARED
// `parentRequestID` (so the N rows roll up to one fusion request).

/// Resolved dependencies the gateway server hands the orchestrator. Closures,
/// not the server's private helpers, so the orchestrator stays `Sendable` and
/// the recording/streaming logic stays centralized on the actor.
struct ElderWandFusionOrchestrator: Sendable {
    /// Resolve a winning route for a model slug (calls the router internally).
    /// Returns `nil` when no route serves the model.
    let resolveRoute: @Sendable (_ modelSlug: String) async -> ElderWandResolvedRoute?
    /// Perform one buffered completion on a resolved route (OpenAI Chat
    /// Completions body in → buffered response out). The server wires this to
    /// the concrete executors via the route's format family.
    let bufferedCompletion: @Sendable (_ body: Data, _ route: ElderWandResolvedRoute) async throws -> BurnBarProviderProxyResponse
    /// Record one usage event + one route-log row for a sub-call. The server
    /// implements this against its private recorders, stamping the shared
    /// `parentRequestID` and a distinct idempotency key.
    let recordSubCall: @Sendable (_ record: ElderWandSubCallRecord) async -> Void
    /// The web tool-loop tools (web_search + web_fetch).
    let tools: [ElderWandTool]
    let recursionMarkerKey: String
    let recursionMarkerValue: String
    let logger: BurnBarDaemonLogger

    init(
        resolveRoute: @escaping @Sendable (_ modelSlug: String) async -> ElderWandResolvedRoute?,
        bufferedCompletion: @escaping @Sendable (_ body: Data, _ route: ElderWandResolvedRoute) async throws -> BurnBarProviderProxyResponse,
        recordSubCall: @escaping @Sendable (_ record: ElderWandSubCallRecord) async -> Void,
        tools: [ElderWandTool],
        recursionMarkerKey: String,
        recursionMarkerValue: String,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "elder-wand-fusion")
    ) {
        self.resolveRoute = resolveRoute
        self.bufferedCompletion = bufferedCompletion
        self.recordSubCall = recordSubCall
        self.tools = tools
        self.recursionMarkerKey = recursionMarkerKey
        self.recursionMarkerValue = recursionMarkerValue
        self.logger = logger
    }

    /// Run the full fusion pipeline for one request body.
    ///
    /// - Parameters:
    ///   - bodyData: the raw OpenAI Chat Completions request body.
    ///   - plugin: the active fusion plugin config (already validated non-nil).
    ///   - originatingModel: the request's top-level `model` (the synthesis model).
    ///   - wantsStream: whether the client asked to stream the final answer.
    /// - Returns: a result the gateway maps to its own route outcome.
    func run(
        bodyData: Data,
        plugin: FusionPluginConfig,
        originatingModel: String,
        wantsStream: Bool
    ) async -> ElderWandFusionResult {
        let parentRequestID = "elderwand-\(UUID().uuidString)"

        // Stage 1 — decode config.
        let panelModels = (plugin.analysisModels ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !panelModels.isEmpty else {
            return .failed(.init(
                status: 400,
                message: "The Elder Wand requires at least one analysis_models entry."
            ))
        }
        let boundedPanel = Array(panelModels.prefix(ElderWandPreset.analysisPanelRange.upperBound))
        let judgeModel = plugin.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxToolCalls = Self.clampToolCalls(plugin.maxToolCalls)

        // Extract the originating conversation so panel models answer the real
        // prompt. `messagesJSON` (the serialized `messages` array) is `Sendable`
        // and crosses the panel task-group boundary cleanly; the prompt string
        // is used verbatim by the judge.
        guard let extracted = Self.extractMessages(from: bodyData) else {
            return .failed(.init(
                status: 400,
                message: "The Elder Wand requires a non-empty messages array."
            ))
        }
        let originatingMessagesJSON = extracted.messagesJSON
        let originatingPrompt = extracted.lastUserText

        let loop = ElderWandToolLoop(
            tools: tools,
            recursionMarkerKey: recursionMarkerKey,
            recursionMarkerValue: recursionMarkerValue
        )

        // Stage 2 — PANEL fan-out (parallel).
        let panelAnswers = await runPanel(
            models: boundedPanel,
            originatingMessagesJSON: originatingMessagesJSON,
            maxToolCalls: maxToolCalls,
            loop: loop,
            parentRequestID: parentRequestID
        )
        guard !panelAnswers.isEmpty else {
            return .failed(.init(
                status: 502,
                message: "The Elder Wand could not get an answer from any analysis model."
            ))
        }

        // Stage 3 — JUDGE.
        let judged = await runJudge(
            judgeModel: judgeModel,
            originatingPrompt: originatingPrompt,
            panelAnswers: panelAnswers,
            maxToolCalls: maxToolCalls,
            loop: loop,
            parentRequestID: parentRequestID
        )

        // The panel + judge receipt line items, in pipeline order, carried into
        // the streaming result so the gateway can emit the full itemized session
        // to clients with no local ledger (iOS over the relay).
        let priorLineItems = panelAnswers.compactMap(\.spend) + [judged.spend].compactMap { $0 }

        // Stage 4 — SYNTHESIS on the originating model.
        return await runSynthesis(
            originatingModel: originatingModel,
            originatingMessagesJSON: originatingMessagesJSON,
            verdict: judged.verdict,
            wantsStream: wantsStream,
            parentRequestID: parentRequestID,
            priorLineItems: priorLineItems
        )
    }

    // MARK: - Stage 2: Panel

    private struct PanelAnswer: Sendable {
        let model: String
        let text: String
        /// The panel member's receipt line item, carried so the streaming path
        /// can emit the full itemized session to clients with no local ledger.
        let spend: FusionSubCallSpend?
    }

    private func runPanel(
        models: [String],
        originatingMessagesJSON: Data,
        maxToolCalls: Int,
        loop: ElderWandToolLoop,
        parentRequestID: String
    ) async -> [PanelAnswer] {
        await withTaskGroup(of: PanelAnswer?.self) { group in
            for (index, model) in models.enumerated() {
                group.addTask {
                    await self.runPanelMember(
                        model: model,
                        index: index,
                        originatingMessagesJSON: originatingMessagesJSON,
                        maxToolCalls: maxToolCalls,
                        loop: loop,
                        parentRequestID: parentRequestID
                    )
                }
            }
            var answers: [PanelAnswer] = []
            for await answer in group {
                if let answer { answers.append(answer) }
            }
            // Stable ordering by the panel's declared order keeps the judge
            // prompt deterministic regardless of completion order.
            return answers.sorted { lhs, rhs in
                let lhsIndex = models.firstIndex(of: lhs.model) ?? 0
                let rhsIndex = models.firstIndex(of: rhs.model) ?? 0
                return lhsIndex < rhsIndex
            }
        }
    }

    private func runPanelMember(
        model: String,
        index: Int,
        originatingMessagesJSON: Data,
        maxToolCalls: Int,
        loop: ElderWandToolLoop,
        parentRequestID: String
    ) async -> PanelAnswer? {
        guard let route = await resolveRoute(model) else {
            logger.warning("elder_wand_panel_no_route", metadata: ["model": model])
            await recordSubCall(.failure(
                stage: .panel(index: index),
                modelSlug: model,
                parentRequestID: parentRequestID,
                message: "No eligible route for \(model)."
            ))
            return nil
        }
        do {
            let result = try await loop.run(
                model: route.wireModelSlug,
                systemPrompt: Self.panelSystemPrompt,
                userMessagesJSON: originatingMessagesJSON,
                maxToolCalls: maxToolCalls,
                chat: { body in try await self.bufferedCompletion(body, route) }
            )
            let signature = Self.signature(parentRequestID, "panel", model, index)
            await recordSubCall(.success(
                stage: .panel(index: index),
                route: route,
                parentRequestID: parentRequestID,
                usage: result.usage,
                requestSignature: signature
            ))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PanelAnswer(
                model: model,
                text: text,
                spend: Self.lineItem(stage: .panel(index: index), route: route, requestSignature: signature, usage: result.usage)
            )
        } catch {
            logger.warning("elder_wand_panel_failed", metadata: ["model": model, "error": "\(error)"])
            await recordSubCall(.failure(
                stage: .panel(index: index),
                modelSlug: model,
                route: route,
                parentRequestID: parentRequestID,
                message: error.localizedDescription
            ))
            return nil
        }
    }

    // MARK: - Stage 3: Judge

    private func runJudge(
        judgeModel: String?,
        originatingPrompt: String,
        panelAnswers: [PanelAnswer],
        maxToolCalls: Int,
        loop: ElderWandToolLoop,
        parentRequestID: String
    ) async -> (verdict: String, spend: FusionSubCallSpend?) {
        let panelBlock = panelAnswers.enumerated().map { index, answer in
            "### Analysis answer \(index + 1) — model `\(answer.model)`\n\(answer.text)"
        }.joined(separator: "\n\n")
        let judgeContent = """
            Original user request:
            \(originatingPrompt)

            You are given \(panelAnswers.count) independent analysis answers below. \
            COMPARE them. Do NOT merge them and do NOT write a new answer to the \
            original request. Respond ONLY with a JSON object with exactly these \
            five string fields: "consensus", "contradictions", "partial_coverage", \
            "unique_insights", "blind_spots".

            \(panelBlock)
            """
        let judgeMessagesJSON = Self.encodeMessages([["role": "user", "content": judgeContent]])

        // The judge falls back to the first available panel model when no judge
        // model is configured, so a verdict still gets produced.
        let judgeSlug = (judgeModel?.isEmpty == false ? judgeModel : nil) ?? panelAnswers.first?.model
        guard let judgeSlug, let route = await resolveRoute(judgeSlug) else {
            logger.warning("elder_wand_judge_no_route", metadata: ["model": judgeModel ?? "nil"])
            // Degrade: hand synthesis the raw panel answers if the judge cannot run.
            return (Self.fallbackVerdict(panelBlock: panelBlock), nil)
        }
        do {
            let result = try await loop.run(
                model: route.wireModelSlug,
                systemPrompt: Self.judgeSystemPrompt,
                userMessagesJSON: judgeMessagesJSON,
                maxToolCalls: maxToolCalls,
                chat: { body in try await self.bufferedCompletion(body, route) }
            )
            let signature = Self.signature(parentRequestID, "judge", judgeSlug, 0)
            await recordSubCall(.success(
                stage: .judge,
                route: route,
                parentRequestID: parentRequestID,
                usage: result.usage,
                requestSignature: signature
            ))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let spend = Self.lineItem(stage: .judge, route: route, requestSignature: signature, usage: result.usage)
            return (text.isEmpty ? Self.fallbackVerdict(panelBlock: panelBlock) : text, spend)
        } catch {
            logger.warning("elder_wand_judge_failed", metadata: ["model": judgeSlug, "error": "\(error)"])
            await recordSubCall(.failure(
                stage: .judge,
                modelSlug: judgeSlug,
                route: route,
                parentRequestID: parentRequestID,
                message: error.localizedDescription
            ))
            return (Self.fallbackVerdict(panelBlock: panelBlock), nil)
        }
    }

    // MARK: - Stage 4: Synthesis

    private func runSynthesis(
        originatingModel: String,
        originatingMessagesJSON: Data,
        verdict: String,
        wantsStream: Bool,
        parentRequestID: String,
        priorLineItems: [FusionSubCallSpend]
    ) async -> ElderWandFusionResult {
        guard let route = await resolveRoute(originatingModel) else {
            return .failed(.init(
                status: 503,
                message: "No eligible route for the originating model \(originatingModel)."
            ))
        }

        var synthesisMessages: [[String: Any]] = []
        if let decoded = try? JSONSerialization.jsonObject(with: originatingMessagesJSON) as? [[String: Any]] {
            synthesisMessages.append(contentsOf: decoded)
        }
        synthesisMessages.append([
            "role": "system",
            "content": Self.synthesisSystemPrompt
        ])
        synthesisMessages.append([
            "role": "user",
            "content": """
            A panel of expert models was consulted and a judge compared their \
            answers into the verdict below. Using this verdict, write the final, \
            single best answer to my request. Do not mention the panel, the judge, \
            or this verdict — just answer me directly.

            Judge verdict:
            \(verdict)
            """
        ])

        let requestSignature = Self.signature(parentRequestID, "synthesis", originatingModel, 0)

        if wantsStream {
            // Stream the synthesis answer. The gateway runs the relay over its
            // own connection writer; we hand it an openStream closure + route +
            // distinct idempotency key.
            let body = Self.encodeChatBody(
                model: route.wireModelSlug,
                messages: synthesisMessages,
                stream: true
            )
            return .streaming(.init(
                route: route,
                requestSignature: requestSignature,
                parentRequestID: parentRequestID,
                requestBody: body,
                priorLineItems: priorLineItems
            ))
        }

        // Buffered synthesis.
        let body = Self.encodeChatBody(
            model: route.wireModelSlug,
            messages: synthesisMessages,
            stream: false
        )
        do {
            let response = try await bufferedCompletion(body, route)
            await recordSubCall(.success(
                stage: .synthesis,
                route: route,
                parentRequestID: parentRequestID,
                usage: response.usage,
                requestSignature: requestSignature
            ))
            return .buffered(.init(
                status: response.statusCode,
                contentType: response.contentType,
                body: response.body
            ))
        } catch {
            logger.error("elder_wand_synthesis_failed", metadata: ["model": originatingModel, "error": "\(error)"])
            await recordSubCall(.failure(
                stage: .synthesis,
                modelSlug: originatingModel,
                route: route,
                parentRequestID: parentRequestID,
                message: error.localizedDescription
            ))
            return .failed(.init(
                status: 502,
                message: "The Elder Wand synthesis step failed: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Helpers

    static func clampToolCalls(_ raw: Int?) -> Int {
        let value = raw ?? ElderWandPreset.defaultMaxToolCalls
        return min(max(value, ElderWandPreset.maxToolCallsRange.lowerBound), ElderWandPreset.maxToolCallsRange.upperBound)
    }

    /// The originating `messages` array re-serialized (`Sendable`) plus the last
    /// user message text, extracted in one pass.
    struct ExtractedMessages: Sendable {
        let messagesJSON: Data
        let lastUserText: String
    }

    /// Extract `messages` from the raw request body. Returns `nil` when the body
    /// has no non-empty `messages` array.
    static func extractMessages(from bodyData: Data) -> ExtractedMessages? {
        guard let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let rawMessages = object["messages"] as? [[String: Any]],
              !rawMessages.isEmpty else {
            return nil
        }
        let messagesJSON = (try? JSONSerialization.data(withJSONObject: rawMessages, options: []))
            ?? Data("[]".utf8)
        return ExtractedMessages(
            messagesJSON: messagesJSON,
            lastUserText: lastUserText(from: rawMessages)
        )
    }

    /// The most recent user message text (for the judge's "original request").
    static func lastUserText(from messages: [[String: Any]]) -> String {
        for message in messages.reversed() {
            guard (message["role"] as? String) == "user" else { continue }
            if let content = message["content"] as? String {
                return content
            }
            // Multimodal content arrays: collect text parts.
            if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.compactMap { $0["text"] as? String }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
        }
        return "(no user message found)"
    }

    /// Serialize an OpenAI `messages` array to `Sendable` JSON `Data`.
    static func encodeMessages(_ messages: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: messages, options: [])) ?? Data("[]".utf8)
    }

    /// Build a synthesis request body. The body intentionally omits the
    /// `plugins` block (the structural recursion guard: a body without an active
    /// fusion plugin can never re-trigger fusion if it re-enters the gateway).
    static func encodeChatBody(
        model: String,
        messages: [[String: Any]],
        stream: Bool
    ) -> Data {
        let body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
    }

    static func signature(_ parentRequestID: String, _ stage: String, _ model: String, _ index: Int) -> String {
        "\(parentRequestID)|\(stage)|\(model)|\(index)"
    }

    /// Build a receipt line item from a recorded sub-call's resolved route + usage.
    /// Cost is computed with the same pricing the ledger uses, so the emitted
    /// session reconciles to the recorded usage events. Returns `nil` when the
    /// sub-call produced no usage (so it never fabricates a zero-token line).
    static func lineItem(
        stage: FusionStage,
        route: ElderWandResolvedRoute,
        requestSignature: String,
        usage: BurnBarProviderProxyUsage?
    ) -> FusionSubCallSpend? {
        guard let usage else { return nil }
        let cost = try route.route.pricing.cost(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens
        )
        return FusionSubCallSpend(
            id: requestSignature,
            stage: stage,
            modelID: route.wireModelSlug,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            reasoningTokens: usage.reasoningTokens,
            cost: cost,
            confidence: usage.confidence
        )
    }

    static func fallbackVerdict(panelBlock: String) -> String {
        """
        {"consensus":"(judge unavailable — raw analysis answers follow)","contradictions":"","partial_coverage":"","unique_insights":"","blind_spots":""}

        \(panelBlock)
        """
    }

    // MARK: - Prompts

    static let panelSystemPrompt = """
    You are one expert on a panel answering a user's request independently. \
    Answer thoroughly and accurately. You may use the web_search and web_fetch \
    tools to gather current information when helpful. Do not coordinate with \
    other panelists; give your own best answer.
    """

    static let judgeSystemPrompt = """
    You are a strict comparison judge. You are given several independent answers \
    to the same request. Your ONLY job is to COMPARE them — never to write your \
    own answer to the original request and never to merge the answers. Output \
    must be a single JSON object with exactly these five string fields: \
    "consensus" (points all/most answers agree on), "contradictions" (direct \
    disagreements between answers), "partial_coverage" (points only some answers \
    address), "unique_insights" (valuable points raised by only one answer), and \
    "blind_spots" (important aspects none of the answers covered). You may use \
    web_search/web_fetch to verify a claim. Respond with the JSON object only.
    """

    static let synthesisSystemPrompt = """
    You are writing the final answer to the user. A judge has compared a panel \
    of expert answers into a structured verdict. Use the verdict to write the \
    single best, most accurate, well-organized answer. Resolve contradictions in \
    favor of the most justified position, incorporate the unique insights, and \
    address the blind spots where you can. Answer the user directly without \
    referring to the panel, the judge, or the verdict.
    """
}

// MARK: - Result + sub-call record contracts

/// A route the orchestrator resolved for a model, plus everything the gateway
/// needs to dispatch a completion and record accounting against it.
struct ElderWandResolvedRoute: Sendable {
    let route: BurnBarProviderRoute
    let formatFamily: BurnBarProviderFormatFamily
    /// The model slug to put on the wire (the route's resolved upstream model).
    let wireModelSlug: String

    init(route: BurnBarProviderRoute, formatFamily: BurnBarProviderFormatFamily, wireModelSlug: String? = nil) {
        self.route = route
        self.formatFamily = formatFamily
        self.wireModelSlug = wireModelSlug ?? route.resolvedModelID
    }
}

/// What the orchestrator hands back to the gateway server.
enum ElderWandFusionResult: Sendable {
    case buffered(Buffered)
    case streaming(Streaming)
    case failed(Failure)

    struct Buffered: Sendable {
        let status: Int
        let contentType: String
        let body: Data
    }

    struct Streaming: Sendable {
        let route: ElderWandResolvedRoute
        let requestSignature: String
        let parentRequestID: String
        let requestBody: Data
        /// Panel + judge receipt line items (synthesis is added after the stream
        /// completes), so the gateway can emit the full itemized fusion session.
        let priorLineItems: [FusionSubCallSpend]
    }

    struct Failure: Sendable {
        let status: Int
        let message: String
    }
}

/// One panel/judge/synthesis sub-call's accounting record. The gateway server
/// turns this into a `BurnBarUsageEvent` + `BurnBarProxyRouteLogEntry`, stamping
/// the shared `parentRequestID` and a distinct idempotency key.
struct ElderWandSubCallRecord: Sendable {
    enum Stage: Sendable {
        case panel(index: Int)
        case judge
        case synthesis

        var label: String {
            switch self {
            case .panel(let index): return "panel[\(index)]"
            case .judge: return "judge"
            case .synthesis: return "synthesis"
            }
        }
    }

    let stage: Stage
    let parentRequestID: String
    /// The resolved route, when one was found (nil for a no-route failure).
    let route: BurnBarProviderRoute?
    /// The model slug requested (used when there is no route).
    let modelSlug: String
    /// Distinct per-sub-call request signature → distinct idempotency key.
    let requestSignature: String
    let usage: BurnBarProviderProxyUsage?
    let succeeded: Bool
    let failureMessage: String?

    static func success(
        stage: Stage,
        route: ElderWandResolvedRoute,
        parentRequestID: String,
        usage: BurnBarProviderProxyUsage?,
        requestSignature: String
    ) -> ElderWandSubCallRecord {
        ElderWandSubCallRecord(
            stage: stage,
            parentRequestID: parentRequestID,
            route: route.route,
            modelSlug: route.wireModelSlug,
            requestSignature: requestSignature,
            usage: usage,
            succeeded: true,
            failureMessage: nil
        )
    }

    static func failure(
        stage: Stage,
        modelSlug: String,
        route: ElderWandResolvedRoute? = nil,
        parentRequestID: String,
        message: String
    ) -> ElderWandSubCallRecord {
        ElderWandSubCallRecord(
            stage: stage,
            parentRequestID: parentRequestID,
            route: route?.route,
            modelSlug: route?.wireModelSlug ?? modelSlug,
            requestSignature: "\(parentRequestID)|\(stage.label)|\(modelSlug)|fail",
            usage: nil,
            succeeded: false,
            failureMessage: message
        )
    }
}
