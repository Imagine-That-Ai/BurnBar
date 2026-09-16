import Foundation
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarQuota

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TogetherQuotaAdapterTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_784_275_200) // 2026-07-15T00:00:00Z

    override func tearDown() {
        TogetherMockURLProtocol.responder = nil
        super.tearDown()
    }

    func test_missingKey_returnsUnavailableWithoutCallingTogether() async throws {
        var requested = 0
        TogetherMockURLProtocol.responder = { _ in
            requested += 1
            return Self.respond(status: 500, json: "{}", for: URLRequest(url: URL(string: "https://example.invalid")!))
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: nil))

        XCTAssertEqual(requested, 0)
        XCTAssertEqual(snapshot.provider, AgentProvider.together.rawValue)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("Add a Together / Llama API key"), true)
    }

    func test_billingUsage200_reportsMonthToDateSpendWithoutInventingRemainingCredits() async throws {
        let monthJSON = """
        {
          "object": "list",
          "organization_id": "org_test",
          "billing_period": "2026-07",
          "currency": "USD",
          "data": [
            {
              "date": "2026-07-01",
              "line_items": [
                { "product_name": "Serverless Inference - Input Tokens", "quantity": "1000", "unit_price": "0.0002", "cost": "1.25" },
                { "product_name": "Serverless Inference - Output Tokens", "quantity": "200", "unit_price": "0.0008", "cost": "0.75" }
              ]
            },
            {
              "date": "2026-07-02",
              "line_items": [
                { "product_name": "Serverless Inference - Input Tokens", "quantity": "10", "unit_price": "0.0002", "cost": "0.50" }
              ]
            }
          ],
          "next_cursor": null
        }
        """
        var requestedURLs: [String] = []
        TogetherMockURLProtocol.responder = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tog-test-key")
            return Self.respond(json: monthJSON, for: request)
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "tog-test-key"))

        XCTAssertEqual(snapshot.provider, AgentProvider.together.rawValue)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.sourceKind, .officialAPI)
        XCTAssertEqual(snapshot.managementURL, TogetherQuotaAdapter.managementURL)
        XCTAssertEqual(requestedURLs.count, 1)
        XCTAssertTrue(requestedURLs[0].contains("/v1/billing/usage"))
        XCTAssertTrue(requestedURLs[0].contains("month=2026-07"))
        XCTAssertFalse(requestedURLs[0].contains("facebook"), "Meter path must stay on Together billing, not Facebook")

        guard let bucket = snapshot.buckets.first(where: { $0.key == "together-billing-usage-2026-07" }) else {
            XCTFail("Missing month spend bucket")
            return
        }
        XCTAssertEqual(bucket.unit, .currency)
        XCTAssertEqual(bucket.windowKind, .monthly)
        XCTAssertEqual(bucket.usedValue ?? -1, 2.50, accuracy: 0.001)
        XCTAssertNil(bucket.limitValue)
        XCTAssertNil(bucket.remainingValue)
        XCTAssertNil(bucket.usedPercent)
        XCTAssertEqual(snapshot.statusMessage?.contains("Remaining prepaid credits are console-only"), true)
        XCTAssertEqual(snapshot.statusMessage?.contains("not Facebook"), true)
    }

    func test_billingUsage200_emptyMonth_reportsZeroSpend() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(
                json: """
                { "object": "list", "billing_period": "2026-07", "currency": "USD", "data": [], "next_cursor": null }
                """,
                for: request
            )
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "tog-empty"))
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.first?.usedValue ?? -1, 0, accuracy: 0.001)
    }

    func test_billingUsagePaginatesUntilCursorClears() async throws {
        var pages = 0
        TogetherMockURLProtocol.responder = { request in
            pages += 1
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after" })?.value
            if after == nil {
                return Self.respond(
                    json: """
                    { "billing_period": "2026-07", "data": [ { "line_items": [ { "cost": "1.00" } ] } ], "next_cursor": "page-2" }
                    """,
                    for: request
                )
            }
            XCTAssertEqual(after, "page-2")
            return Self.respond(
                json: """
                { "billing_period": "2026-07", "data": [ { "line_items": [ { "cost": "0.25" } ] } ], "next_cursor": null }
                """,
                for: request
            )
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "tog-pages"))
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(snapshot.buckets.first?.usedValue ?? -1, 1.25, accuracy: 0.001)
    }

    func test_billingUsage404_isExplicitUnsupportedRemainingCredit() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(status: 404, json: #"{"error":{"message":"not enabled","type":"not_found_error"}}"#, for: request)
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "tog-gated"))
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("has not enabled billing usage"), true)
        XCTAssertEqual(snapshot.statusMessage?.contains("not a remaining-credit window"), true)
        XCTAssertEqual(snapshot.statusMessage?.localizedCaseInsensitiveContains("facebook"), true)
    }

    func test_revokedKey401_asksToReconnect() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(status: 401, json: #"{"error":{"message":"invalid api key"}}"#, for: request)
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "revoked"))
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("rejected this API key"), true)
    }

    func test_forbidden403_asksToReconnect() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(status: 403, json: "{}", for: request)
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "wrong-org"))
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("Reconnect a Together"), true)
    }

    func test_rateLimit429_doesNotInventAMeter() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(status: 429, json: "{}", for: request)
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "slow"))
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("rate-limited"), true)
    }

    func test_malformed200JSON_isUnavailable() async throws {
        TogetherMockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not-json".utf8))
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "bad-json"))
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("not valid JSON"), true)
    }

    func test_inlineErrorObject_isUnavailable() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(json: #"{"error":{"message":"usage exploded","type":"api_error"}}"#, for: request)
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "inline"))
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("usage exploded"), true)
    }

    func test_unexpected500_throwsHTTPStatus() async throws {
        TogetherMockURLProtocol.responder = { request in
            Self.respond(status: 500, json: "{}", for: request)
        }

        do {
            _ = try await adapter().fetch(context: try makeContext(apiKey: "boom"))
            XCTFail("Expected HTTP 500 to throw")
        } catch let error as QuotaServiceError {
            guard case let .httpStatus(provider, code) = error else {
                XCTFail("Expected httpStatus, got \(error)")
                return
            }
            XCTAssertEqual(provider, .together)
            XCTAssertEqual(code, 500)
        }
    }

    func test_resolvesMetaTogetherKeyIdentifier() async throws {
        TogetherMockURLProtocol.responder = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer from-meta-slot")
            return Self.respond(
                json: #"{ "billing_period": "2026-07", "data": [ { "line_items": [ { "cost": "3.00" } ] } ], "next_cursor": null }"#,
                for: request
            )
        }

        let context = try makeContext(apiKey: nil, extraKeys: ["meta-together-key": "from-meta-slot"])
        let snapshot = try await adapter().fetch(context: context)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.first?.usedValue ?? -1, 3.0, accuracy: 0.001)
    }

    func test_billingMonthIsUTC() {
        XCTAssertEqual(TogetherQuotaAdapter.billingMonth(now: fixedNow), "2026-07")
    }

    func test_environmentTogetherAPIKey_isAcceptedWhenSlotIsEmpty() async throws {
        TogetherMockURLProtocol.responder = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer env-together-key")
            return Self.respond(
                json: #"{ "billing_period": "2026-07", "data": [ { "line_items": [ { "cost": "4.00" } ] } ], "next_cursor": null }"#,
                for: request
            )
        }

        let context = try makeContext(
            apiKey: nil,
            environment: ["TOGETHER_API_KEY": "env-together-key"]
        )
        let snapshot = try await adapter().fetch(context: context)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.first?.usedValue ?? -1, 4.0, accuracy: 0.001)
    }

    func test_whitespaceOnlyKey_isTreatedAsMissing() async throws {
        var requested = 0
        TogetherMockURLProtocol.responder = { _ in
            requested += 1
            return Self.respond(status: 200, json: "{}", for: URLRequest(url: URL(string: "https://example.invalid")!))
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "   "))
        XCTAssertEqual(requested, 0)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("Add a Together / Llama API key"), true)
    }

    func test_paginationStopsAtMaxPagesWithoutInventingRemainder() async throws {
        var pages = 0
        TogetherMockURLProtocol.responder = { request in
            pages += 1
            return Self.respond(
                json: """
                { "billing_period": "2026-07", "data": [ { "line_items": [ { "cost": "1.00" } ] } ], "next_cursor": "more" }
                """,
                for: request
            )
        }

        let snapshot = try await adapter().fetch(context: try makeContext(apiKey: "tog-cap"))
        XCTAssertEqual(pages, TogetherQuotaAdapter.maxUsagePages)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.first?.usedValue ?? -1, Double(TogetherQuotaAdapter.maxUsagePages), accuracy: 0.001)
        XCTAssertNil(snapshot.buckets.first?.remainingValue)
    }

    func test_resolveAPIKeyChecksTogetherBeforeMetaSlot() {
        let context = try! makeContext(
            apiKey: nil,
            extraKeys: [
                "together": "loose-together",
                "meta-together-key": "slot-key"
            ]
        )
        XCTAssertEqual(TogetherQuotaAdapter.resolveAPIKey(context: context), "loose-together")
    }

    private func adapter() -> TogetherQuotaAdapter {
        TogetherQuotaAdapter(now: { self.fixedNow })
    }

    private func makeContext(
        apiKey: String?,
        extraKeys: [String: String] = [:],
        environment: [String: String] = [:]
    ) throws -> ProviderQuotaAdapterContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-together-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TogetherMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var keys: [String: String?] = extraKeys.mapValues { $0 }
        if let apiKey {
            keys["together"] = apiKey
        }

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: .default,
            session: session,
            environment: environment,
            homeDirectoryURL: root,
            snapshotStore: TogetherStubQuotaSnapshotStore(),
            bridgeManager: TogetherStubClaudeBridge(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: keys
        )
    }

    private static func respond(status: Int = 200, json: String, for request: URLRequest) -> (URLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.together.ai/v1/billing/usage")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private struct TogetherStubQuotaSnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct TogetherStubClaudeBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}

private final class TogetherMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (URLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
