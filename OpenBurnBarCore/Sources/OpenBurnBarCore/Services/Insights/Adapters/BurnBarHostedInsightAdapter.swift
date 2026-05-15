import Foundation
import os.log

/// Server-proxied hosted fallback adapter for the Intelligence Brief
/// answer path.
///
/// Used **only** when no user-owned route (Hermes, Pi, OpenClaw,
/// Claude, Codex, OpenCode, Ollama, OpenAI-compatible, etc.) is
/// reachable. Calls a Firebase callable that proxies to OpenRouter →
/// MiniMax so the OpenRouter API key never lands on a client device.
///
/// Wire format mirrors Firebase v2 HTTPS callables:
///   request:  `POST <endpointURL>` `application/json` `{ "data": <payload> }`
///   response: `{ "result": { envelope, providerKey, modelSlug,
///                            modelDisplayName, egressTier, tokenUsage,
///                            ranAt } }`
///
/// The response `envelope` is the raw LLM-emitted JSON object (the
/// same shape `InsightAnalysisModelDecoder` knows how to hydrate),
/// not a fully-formed `InsightAnalysisResult`. Keeping the wire
/// envelope thin avoids re-encoding the platform-specific
/// `InsightCitation.Kind` enum-with-associated-values on the server
/// and reuses the existing, tested model-decoder hydration path on
/// every client.
///
/// Authorization and App Check tokens are attached when the shell
/// supplies them. The adapter is intentionally token-provider driven
/// (rather than depending on the Firebase SDK) so `OpenBurnBarCore`
/// stays free of platform-specific dependencies.
public struct BurnBarHostedInsightAdapter: InsightModelGateway {
    public static let providerKeyRaw = "burnbar-hosted"
    public static let defaultModelID = "minimax-m2.7"
    public static let defaultModelDisplayName = "MiniMax 2.7 · BurnBar Hosted"

    public let providerKey = BurnBarHostedInsightAdapter.providerKeyRaw
    public let displayName = "BurnBar Hosted"
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: false,
        supportsJSONObject: true,
        supportsThinking: false,
        supportsToolUse: false,
        supportsStreaming: false
    )

    public let endpointURL: URL
    public let modelID: String
    public let modelDisplayName: String
    public let urlSession: URLSession
    public let authTokenProvider: @Sendable () async -> String?
    public let appCheckTokenProvider: @Sendable () async -> String?
    public let timeout: TimeInterval

    public init(
        endpointURL: URL,
        modelID: String = BurnBarHostedInsightAdapter.defaultModelID,
        modelDisplayName: String = BurnBarHostedInsightAdapter.defaultModelDisplayName,
        urlSession: URLSession = .shared,
        authTokenProvider: @escaping @Sendable () async -> String? = { nil },
        appCheckTokenProvider: @escaping @Sendable () async -> String? = { nil },
        timeout: TimeInterval = 30
    ) {
        self.endpointURL = endpointURL
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.urlSession = urlSession
        self.authTokenProvider = authTokenProvider
        self.appCheckTokenProvider = appCheckTokenProvider
        self.timeout = timeout
    }

    private static let log = Logger(subsystem: "com.openburnbar.core", category: "BurnBarHostedInsightAdapter")

    // MARK: - InsightModelGateway

    public func availableModels() async throws -> [InsightCatalogModel] {
        [
            InsightCatalogModel(
                id: modelID,
                displayName: modelDisplayName,
                providerKey: providerKey,
                egressTier: .hosted,
                capabilities: capabilities,
                inputCostPerMtoken: nil,
                outputCostPerMtoken: nil,
                symbolName: "cloud.fill"
            )
        ]
    }

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let analyzeRequest = InsightAnalysisRequest(
                        prompt: request.prompt,
                        context: .init(
                            digest: request.digest,
                            evidenceIndex: [],
                            budgetReport: .init(
                                encodedBytes: 0,
                                estimatedPromptTokens: 0,
                                includedDataSources: []
                            )
                        ),
                        currentCanvas: request.canvas,
                        selectedModel: request.modelTag,
                        instruction: .updateCanvas,
                        maxGeneratedWidgets: request.maxNewWidgets
                    )
                    let result = try await analyze(
                        request: analyzeRequest,
                        platform: .macOS,
                        tools: tools
                    )
                    continuation.yield(
                        .finalCanvas(
                            RuleBasedInsightAnalysisEngine.materializeCanvas(from: result, prompt: request.prompt)
                        )
                    )
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
        let response = try await callHostedRoute(
            request: request,
            platform: platform
        )

        guard let envelopeData = response.envelope.data(using: .utf8) else {
            throw InsightGatewayError.malformedResponse(
                modelID: response.modelSlug,
                detail: "envelope is not UTF-8"
            )
        }

        // Stamp the model tag from the *server's* response so the
        // audit log records the slug that actually ran, not the
        // client-side hint. The orchestrator uses these fields to
        // decide the briefingAnswer source.
        let hostedTag = InsightModelTag(
            providerKey: response.providerKey,
            modelID: response.modelSlug,
            displayName: response.modelDisplayName,
            egressTier: .hosted
        )
        var hostedRequest = request
        hostedRequest.selectedModel = hostedTag

        // Reuse the existing LLM-envelope decoder so we don't
        // duplicate the citation hydration logic (CitationResolver
        // maps `{id, label}` refs to the rich `InsightCitation.Kind`
        // graph the UI expects).
        var decoded = try InsightAnalysisModelDecoder.decode(
            from: envelopeData,
            request: hostedRequest,
            platform: platform,
            tokenUsage: response.tokenUsage
        )

        decoded.estimatedCostUSD = response.tokenUsage?.estimatedCostUSD
        if request.instruction == .answerFollowUp {
            let body = composedAnswerBody(from: decoded)
            let bullets = composedGroundedPoints(from: decoded)
            decoded.briefingAnswer = InsightBriefingAnswer(
                question: request.prompt,
                answer: body,
                bullets: bullets,
                citations: Array(decoded.citations.prefix(3)),
                source: .hostedFallback,
                modelDisplayName: response.modelDisplayName,
                isFallback: false
            )
        }
        return decoded
    }

    // MARK: - Internal helpers

    /// Compose the long-form answer body for the briefing card from
    /// the hydrated result. Mirrors the orchestrator's
    /// `composeAnswerBody(from:)` but stays local so the adapter has
    /// no dependency on the orchestrator's internals.
    private func composedAnswerBody(from result: InsightAnalysisResult) -> String {
        var parts: [String] = []
        if !result.executiveSummary.isEmpty {
            parts.append(result.executiveSummary)
        }
        if let lead = result.findings.first {
            if !result.executiveSummary.lowercased().contains(lead.title.lowercased()) {
                parts.append(lead.whyItMatters)
            }
            parts.append(lead.recommendedAction)
        }
        return parts.joined(separator: " ")
    }

    private func composedGroundedPoints(from result: InsightAnalysisResult) -> [String] {
        var points: [String] = []
        for finding in result.findings.prefix(3) {
            points.append(finding.title)
        }
        for anomaly in result.anomalies.prefix(2) {
            points.append("⚡ \(anomaly.title)")
        }
        for rec in result.recommendations.prefix(2) {
            points.append("→ \(rec.title)")
        }
        return Array(points.prefix(4))
    }

    // MARK: - Wire layer

    /// Decoded shape of `{ "result": { ... } }` from the Firebase
    /// callable response. Kept narrow so a forward-compatible server
    /// can append fields without breaking the decoder.
    struct HostedAnswerResponse {
        let envelope: String
        let providerKey: String
        let modelSlug: String
        let modelDisplayName: String
        let egressTier: InsightEgressTier
        let tokenUsage: InsightTokenUsage?
        let ranAt: Date?
    }

    private func callHostedRoute(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform
    ) async throws -> HostedAnswerResponse {
        let payload = try Self.encodeCallablePayload(
            request: request,
            platform: platform,
            modelID: modelID
        )

        var urlRequest = URLRequest(url: endpointURL, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer = await authTokenProvider(), !bearer.isEmpty {
            urlRequest.addValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let appCheck = await appCheckTokenProvider(), !appCheck.isEmpty {
            urlRequest.addValue(appCheck, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        urlRequest.httpBody = payload

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch {
            Self.log.error("hosted POST transport error: \(error.localizedDescription, privacy: .public)")
            throw InsightGatewayError.requestRejected(
                modelID: modelID,
                reason: "transport: \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw InsightGatewayError.requestRejected(modelID: modelID, reason: "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the server's error code/message when present so
            // the UI banner can show "App Check rejected" /
            // "unauthenticated" instead of a generic HTTP code.
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = parsed["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "HTTP \(http.statusCode)"
                Self.log.error("hosted POST HTTP \(http.statusCode, privacy: .public): \(message, privacy: .public)")

                // Route the BurnBar Pro paywall response to a dedicated
                // error case so the orchestrator can degrade to local
                // rules with the upgrade CTA — not a generic
                // "rejected" banner. We honor four signals:
                //   1. `details.code == "subscription-required"` — our
                //      canonical, hand-attached marker. Strongest.
                //   2. v2 callable `status` (canonical-name uppercase)
                //      equal to `PERMISSION_DENIED` or
                //      `UNAUTHENTICATED`. Firebase Functions v2 emits
                //      `status` (NOT `code`) per
                //      `HttpsError.toJSON()` — verified in
                //      `firebase-functions/lib/common/providers/https.js`.
                //      Both denied + unauthenticated land on the same
                //      upgrade CTA because StoreKit / Play Billing
                //      handle sign-in as the first step of the
                //      purchase flow anyway.
                //   3. Legacy v1 `code` field (hyphenated lowercase).
                //   4. HTTP status code (401 / 403) as last-resort
                //      back-compat for any proxy that drops the body.
                let details = error["details"] as? [String: Any]
                let detailCode = details?["code"] as? String
                let productID = details?["productID"] as? String
                let rawStatus = (error["status"] as? String)
                    ?? (error["code"] as? String)
                    ?? ""
                let normalizedStatus = rawStatus
                    .replacingOccurrences(of: "_", with: "-")
                    .lowercased()
                let isPaywallStatus = normalizedStatus == "permission-denied"
                    || normalizedStatus == "unauthenticated"
                let isPaywallHTTP = http.statusCode == 401 || http.statusCode == 403
                let mentionsBurnBarPro = message.localizedCaseInsensitiveContains("BurnBar Pro")
                if detailCode == "subscription-required"
                    || (isPaywallStatus && (mentionsBurnBarPro || normalizedStatus == "unauthenticated"))
                    || (isPaywallHTTP && rawStatus.isEmpty) {
                    throw InsightGatewayError.subscriptionRequired(
                        modelID: modelID,
                        productID: productID
                    )
                }
                throw InsightGatewayError.requestRejected(modelID: modelID, reason: message)
            }
            // No parseable error body. Still treat 401/403 as a
            // paywall signal so the UI shows "Upgrade to BurnBar
            // Pro" instead of a bare HTTP code that gives the user
            // no recovery action.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw InsightGatewayError.subscriptionRequired(
                    modelID: modelID,
                    productID: nil
                )
            }
            throw InsightGatewayError.requestRejected(modelID: modelID, reason: "HTTP \(http.statusCode)")
        }

        // Parse `{ "result": <HostedAnswerResponse> }`.
        let envelope: Any
        do {
            let wrapper = try JSONSerialization.jsonObject(with: data)
            guard let dict = wrapper as? [String: Any] else {
                throw InsightGatewayError.malformedResponse(modelID: modelID, detail: "callable envelope wasn't a dict")
            }
            guard let inner = dict["result"] else {
                throw InsightGatewayError.malformedResponse(modelID: modelID, detail: "callable envelope missing 'result'")
            }
            envelope = inner
        } catch let error as InsightGatewayError {
            throw error
        } catch {
            throw InsightGatewayError.malformedResponse(modelID: modelID, detail: "JSON parse: \(error.localizedDescription)")
        }

        guard let resultDict = envelope as? [String: Any] else {
            throw InsightGatewayError.malformedResponse(modelID: modelID, detail: "result body wasn't a dict")
        }

        guard let envelopeString = resultDict["envelope"] as? String, !envelopeString.isEmpty else {
            throw InsightGatewayError.malformedResponse(
                modelID: modelID,
                detail: "result.envelope missing or empty"
            )
        }

        let resolvedModelSlug = (resultDict["modelSlug"] as? String) ?? modelID
        let resolvedDisplayName = (resultDict["modelDisplayName"] as? String) ?? modelDisplayName
        let resolvedProviderKey = (resultDict["providerKey"] as? String) ?? providerKey
        let egress = InsightEgressTier(rawValue: (resultDict["egressTier"] as? String) ?? "hosted") ?? .hosted
        let tokenUsage = Self.decodeTokenUsage(resultDict["tokenUsage"], modelSlug: resolvedModelSlug)
        let ranAt = (resultDict["ranAt"] as? String).flatMap(Self.iso8601.date(from:))

        return HostedAnswerResponse(
            envelope: envelopeString,
            providerKey: resolvedProviderKey,
            modelSlug: resolvedModelSlug,
            modelDisplayName: resolvedDisplayName,
            egressTier: egress,
            tokenUsage: tokenUsage,
            ranAt: ranAt
        )
    }

    private static func decodeTokenUsage(_ value: Any?, modelSlug: String) -> InsightTokenUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        let providerKey = (dict["providerKey"] as? String) ?? "burnbar-hosted"
        let modelID = (dict["modelID"] as? String) ?? modelSlug
        let inputTokens = (dict["inputTokens"] as? Int)
            ?? Int((dict["inputTokens"] as? NSNumber)?.intValue ?? 0)
        let outputTokens = (dict["outputTokens"] as? Int)
            ?? Int((dict["outputTokens"] as? NSNumber)?.intValue ?? 0)
        let estimatedCostUSD = (dict["estimatedCostUSD"] as? Double) ?? 0
        let started = (dict["startedAt"] as? String).flatMap(iso8601.date(from:)) ?? Date()
        let completed = (dict["completedAt"] as? String).flatMap(iso8601.date(from:)) ?? Date()
        return InsightTokenUsage(
            providerKey: providerKey,
            modelID: modelID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCostUSD: estimatedCostUSD,
            startedAt: started,
            completedAt: completed
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Encodes the analysis request as the Firebase v2 callable
    /// payload (`{ "data": ... }`). Keeps the digest and the canvas
    /// payload compact so we don't blow the callable's 10 MB body
    /// budget when the digest is large.
    static func encodeCallablePayload(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        modelID: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = []
        let requestJSON = try encoder.encode(request)
        let requestObject = try JSONSerialization.jsonObject(with: requestJSON)

        // Surface a few well-known top-level fields so the server can
        // route without re-parsing the entire request blob.
        let envelope: [String: Any] = [
            "data": [
                "schemaVersion": InsightAnalysisResult.currentSchemaVersion,
                "platform": platform.rawValue,
                "modelID": modelID,
                "instruction": request.instruction.rawValue,
                "promptPreview": String(request.prompt.prefix(280)),
                "request": requestObject
            ]
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [])
    }
}
