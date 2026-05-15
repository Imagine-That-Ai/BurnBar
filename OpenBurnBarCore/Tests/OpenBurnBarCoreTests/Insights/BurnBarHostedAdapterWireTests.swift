import XCTest
@testable import OpenBurnBarCore

/// Wire-format regression suite for `BurnBarHostedInsightAdapter`.
///
/// The orchestrator-level `HostedFallbackTests` use stub gateways
/// that bypass URLSession entirely. These tests pin the HTTP
/// contract the adapter speaks with the `insightsHostedAnswer`
/// Firebase callable so a server-side schema change is caught
/// before it ships.
final class BurnBarHostedAdapterWireTests: XCTestCase {

    // MARK: - Payload encoding

    func testEncodedPayloadCarriesAllRoutingFields() throws {
        let request = try makeRequest(prompt: "Why is cost up?")
        let data = try BurnBarHostedInsightAdapter.encodeCallablePayload(
            request: request,
            platform: .iOS,
            modelID: "minimax-m2.7"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(payload["platform"] as? String, "iOS")
        XCTAssertEqual(payload["modelID"] as? String, "minimax-m2.7")
        XCTAssertEqual(payload["instruction"] as? String, "answerFollowUp")
        XCTAssertEqual(payload["promptPreview"] as? String, "Why is cost up?")
        XCTAssertEqual(payload["schemaVersion"] as? Int, InsightAnalysisResult.currentSchemaVersion)

        let nestedRequest = try XCTUnwrap(payload["request"] as? [String: Any])
        XCTAssertEqual(nestedRequest["prompt"] as? String, "Why is cost up?")
        XCTAssertNotNil(nestedRequest["context"])
    }

    func testEncodedPayloadClipsPromptPreviewTo280Chars() throws {
        let huge = String(repeating: "a", count: 1024)
        let request = try makeRequest(prompt: huge)
        let data = try BurnBarHostedInsightAdapter.encodeCallablePayload(
            request: request,
            platform: .macOS,
            modelID: "minimax-m2.7"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["data"] as? [String: Any])
        let preview = try XCTUnwrap(payload["promptPreview"] as? String)
        XCTAssertEqual(preview.count, 280,
                       "promptPreview is the cheap routing field — keep it bounded so the callable body never balloons.")
    }

    // MARK: - End-to-end response decode

    /// Drives the adapter through a real `URLSession` configured with
    /// `URLProtocol` stubs so the encode → HTTP → decode → hydrate →
    /// briefing-stamp pipeline runs exactly as it would against the
    /// deployed function.
    func testAdapterHydratesEnvelopeIntoHostedFallbackBriefing() async throws {
        let envelope: [String: Any] = [
            "executiveSummary": "Hosted route answered with grounded analysis.",
            "findings": [
                [
                    "title": "Spend concentrated in Claude",
                    "whyItMatters": "Claude accounted for 62% of cost this week.",
                    "evidence": [
                        ["id": "claude", "label": "Claude usage"]
                    ],
                    "confidence": "high",
                    "severity": "medium",
                    "recommendedAction": "Compare against Haiku-4.5 before the next deep run."
                ]
            ],
            "anomalies": [],
            "recommendations": [],
            "missionCandidates": [],
            "generatedWidgets": [],
            "followUpQuestions": [],
            "citations": []
        ]
        let envelopeString = try String(
            data: JSONSerialization.data(withJSONObject: envelope),
            encoding: .utf8
        ) ?? ""

        let serverResponse: [String: Any] = [
            "result": [
                "envelope": envelopeString,
                "providerKey": "burnbar-hosted",
                "modelSlug": "minimax/minimax-m2",
                "modelDisplayName": "MiniMax 2.7 · BurnBar Hosted",
                "egressTier": "hosted",
                "tokenUsage": [
                    "providerKey": "burnbar-hosted",
                    "modelID": "minimax/minimax-m2",
                    "inputTokens": 1024,
                    "outputTokens": 512,
                    "estimatedCostUSD": 0.000773,
                    "startedAt": "2026-05-14T19:24:00.000Z",
                    "completedAt": "2026-05-14T19:24:01.500Z"
                ],
                "ranAt": "2026-05-14T19:24:01.500Z"
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: serverResponse)
        let url = URL(string: "https://us-central1-burnbar.test/insightsHostedAnswer")!

        let session = StubURLProtocol.makeSession()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-id-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "test-app-check")
            // The HTTPBody isn't exposed on URLRequest after URLSession
            // sets it via httpBodyStream, so we don't re-validate the
            // body here — the payload-encoder tests above pin that.
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, responseData)
        }

        let adapter = BurnBarHostedInsightAdapter(
            endpointURL: url,
            urlSession: session,
            authTokenProvider: { "test-id-token" },
            appCheckTokenProvider: { "test-app-check" }
        )

        let request = try makeRequest(prompt: "Where did this week's spend go?")
        let result = try await adapter.analyze(
            request: request,
            platform: .iOS,
            tools: nil
        )

        // The hydrated result carries the server's model identity, the
        // hostedFallback source attribution, and the LLM's findings.
        XCTAssertEqual(result.modelTag.providerKey, "burnbar-hosted")
        XCTAssertEqual(result.modelTag.modelID, "minimax/minimax-m2",
                       "modelTag.modelID must reflect the slug the server actually used, not the client-side hint.")
        XCTAssertEqual(result.modelTag.displayName, "MiniMax 2.7 · BurnBar Hosted")
        XCTAssertEqual(result.modelTag.egressTier, .hosted)
        XCTAssertEqual(result.executiveSummary, "Hosted route answered with grounded analysis.")
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings.first?.title, "Spend concentrated in Claude")

        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .hostedFallback)
        XCTAssertFalse(answer.isFallback,
                       "Hosted route succeeded; isFallback is reserved for the local-rules error state.")
        XCTAssertEqual(answer.modelDisplayName, "MiniMax 2.7 · BurnBar Hosted")
        XCTAssertEqual(result.tokenUsage?.inputTokens, 1024)
        XCTAssertEqual(result.tokenUsage?.outputTokens, 512)
        XCTAssertEqual(result.estimatedCostUSD ?? 0, 0.000773, accuracy: 0.000001)
    }

    // MARK: - Pro paywall wire detection

    /// Firebase Functions v2 ships error envelopes as
    /// `{ error: { status: "PERMISSION_DENIED", message, details } }`
    /// — note the canonical-name string in `status`, not a
    /// hyphenated `code` field. The adapter must detect that, plus
    /// the canonical `details.code == "subscription-required"`
    /// marker, and surface
    /// `InsightGatewayError.subscriptionRequired` so the
    /// orchestrator can swap to the upgrade CTA.
    func testAdapterDetectsV2PaywallStatusField() async throws {
        let url = URL(string: "https://us-central1-burnbar.test/insightsHostedAnswer")!
        let session = StubURLProtocol.makeSession()
        StubURLProtocol.handler = { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": [
                    "status": "PERMISSION_DENIED",
                    "message": "Active BurnBar Pro subscription required for hosted Intelligence Brief answers.",
                    "details": [
                        "code": "subscription-required",
                        "productID": "com.openburnbar.hostedQuotaSync.cloud.monthly"
                    ]
                ]
            ])
            let http = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (http, body)
        }
        let adapter = BurnBarHostedInsightAdapter(endpointURL: url, urlSession: session)
        let request = try makeRequest(prompt: "Free-tier user asking")
        do {
            _ = try await adapter.analyze(request: request, platform: .iOS, tools: nil)
            XCTFail("Adapter must throw subscriptionRequired on 403 + subscription-required detail.")
        } catch InsightGatewayError.subscriptionRequired(_, let productID) {
            XCTAssertEqual(productID, "com.openburnbar.hostedQuotaSync.cloud.monthly",
                           "productID must round-trip through the wire so the shell paywall opens the right SKU.")
        } catch {
            XCTFail("Expected subscriptionRequired, got \(type(of: error)): \(error)")
        }
    }

    /// Anonymous (not-signed-in) callers hit `UNAUTHENTICATED` from
    /// the server's `assertAuth`. The brief routes that to the
    /// upgrade CTA too, because StoreKit / Play Billing handles
    /// sign-in as the first step of the purchase flow.
    func testAdapterRoutesUnauthenticatedToUpgradeCTA() async throws {
        let url = URL(string: "https://us-central1-burnbar.test/insightsHostedAnswer")!
        let session = StubURLProtocol.makeSession()
        StubURLProtocol.handler = { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": [
                    "status": "UNAUTHENTICATED",
                    "message": "Request must be authenticated with Firebase Auth."
                ]
            ])
            let http = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (http, body)
        }
        let adapter = BurnBarHostedInsightAdapter(endpointURL: url, urlSession: session)
        let request = try makeRequest(prompt: "Anonymous user asking")
        do {
            _ = try await adapter.analyze(request: request, platform: .iOS, tools: nil)
            XCTFail("Adapter must throw subscriptionRequired on 401 UNAUTHENTICATED.")
        } catch InsightGatewayError.subscriptionRequired {
            // Expected.
        } catch {
            XCTFail("Expected subscriptionRequired, got \(type(of: error)): \(error)")
        }
    }

    /// Bare HTTP 401/403 with no parseable error body (e.g. proxy
    /// stripped the response). Treat that as a paywall signal too
    /// so the user still gets a useful recovery action.
    func testAdapterTreatsBare401AsUpgradeCTA() async throws {
        let url = URL(string: "https://us-central1-burnbar.test/insightsHostedAnswer")!
        let session = StubURLProtocol.makeSession()
        StubURLProtocol.handler = { _ in
            let http = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (http, Data())
        }
        let adapter = BurnBarHostedInsightAdapter(endpointURL: url, urlSession: session)
        let request = try makeRequest(prompt: "Body-stripped 401")
        do {
            _ = try await adapter.analyze(request: request, platform: .iOS, tools: nil)
            XCTFail("Adapter must throw subscriptionRequired on bare 401.")
        } catch InsightGatewayError.subscriptionRequired {
            // Expected.
        } catch {
            XCTFail("Expected subscriptionRequired, got \(type(of: error)): \(error)")
        }
    }

    /// Non-paywall callable errors (e.g. a 500 INTERNAL with a
    /// useful message) must surface as a descriptive
    /// `InsightGatewayError.requestRejected` rather than collapse
    /// into the paywall flow, so the banner discloses the actual
    /// failure and the user knows it's not their subscription.
    func testAdapterSurfacesNonPaywallCallableErrorEnvelope() async throws {
        let url = URL(string: "https://us-central1-burnbar.test/insightsHostedAnswer")!
        let session = StubURLProtocol.makeSession()
        StubURLProtocol.handler = { _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": [
                    "status": "INTERNAL",
                    "message": "OpenRouter returned non-JSON: <html>503 upstream</html>"
                ]
            ])
            let http = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (http, body)
        }
        let adapter = BurnBarHostedInsightAdapter(
            endpointURL: url,
            urlSession: session
        )
        let request = try makeRequest(prompt: "trigger 500")
        do {
            _ = try await adapter.analyze(request: request, platform: .iOS, tools: nil)
            XCTFail("Adapter should have thrown on a 500 callable error.")
        } catch InsightGatewayError.subscriptionRequired {
            XCTFail("A 500 INTERNAL must NOT route to the paywall — that's a server issue, not a Pro gate.")
        } catch let error as InsightGatewayError {
            let description = String(describing: error)
            XCTAssertTrue(description.contains("OpenRouter"),
                          "Error path must surface the server's message so the banner can disclose recovery action. Got: \(description)")
        } catch {
            XCTFail("Expected InsightGatewayError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Helpers

    private func makeRequest(prompt: String) throws -> InsightAnalysisRequest {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "provider_summaries"]
        )
        return InsightAnalysisRequest(
            prompt: prompt,
            context: context,
            selectedModel: .init(
                providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
                modelID: BurnBarHostedInsightAdapter.defaultModelID,
                displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
                egressTier: .hosted
            ),
            instruction: .answerFollowUp,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 4
        )
    }
}

/// `URLProtocol` stub used to intercept the adapter's POST without
/// hitting the network. Pattern lifted from the Foundation
/// documentation's example; each test sets `StubURLProtocol.handler`
/// before invoking the adapter.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
