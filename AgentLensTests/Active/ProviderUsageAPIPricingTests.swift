import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class ProviderUsageAPIPricingTests: XCTestCase {
    override func tearDown() {
        ProviderUsagePricingStubURLProtocol.reset()
        super.tearDown()
    }

    func testOpenRouterFetchUsageComputesMissingReportedCostFromModelPricing() async throws {
        ProviderUsagePricingStubURLProtocol.configure(json: """
        {
          "data": [
            {
              "date": "2026-07-13T00:00:00Z",
              "model": "gpt-4o",
              "input_tokens": 1000000,
              "output_tokens": 1000000,
              "num_requests": 3
            }
          ]
        }
        """)
        let api = OpenRouterUsageAPI(apiKey: "router-key", session: makeSession())

        let records = try await api.fetchUsage(since: Date(timeIntervalSince1970: 1_752_364_800))

        let record = try XCTUnwrap(records.single)
        XCTAssertEqual(record.providerName, "OpenRouter")
        XCTAssertEqual(record.model, "gpt-4o")
        XCTAssertEqual(record.inputTokens, 1_000_000)
        XCTAssertEqual(record.outputTokens, 1_000_000)
        XCTAssertEqual(record.costUSD, 12.5, accuracy: 0.000_000_001)
        XCTAssertEqual(record.requestCount, 3)
        XCTAssertEqual(ProviderUsagePricingStubURLProtocol.lastRequest?.path, "/api/v1/activity")
        XCTAssertEqual(
            ProviderUsagePricingStubURLProtocol.lastRequest?.authorization,
            "Bearer router-key"
        )
    }

    func testAnthropicFetchUsageComputesCacheAwareModelPricing() async throws {
        ProviderUsagePricingStubURLProtocol.configure(json: """
        {
          "data": [
            {
              "start_time": "2026-07-13T00:00:00Z",
              "model": "claude-sonnet-4-20250514",
              "input_tokens": 1000000,
              "output_tokens": 1000000,
              "cached_input_tokens": 1000000,
              "cache_creation_input_tokens": 1000000,
              "num_requests": 4
            }
          ],
          "has_more": false
        }
        """)
        let api = AnthropicUsageAPI(apiKey: "anthropic-key", session: makeSession())

        let records = try await api.fetchUsage(since: Date(timeIntervalSince1970: 1_752_364_800))

        let record = try XCTUnwrap(records.single)
        XCTAssertEqual(record.providerName, "Anthropic")
        XCTAssertEqual(record.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(record.inputTokens, 1_000_000)
        XCTAssertEqual(record.outputTokens, 1_000_000)
        XCTAssertEqual(record.cacheReadTokens, 1_000_000)
        XCTAssertEqual(record.cacheCreationTokens, 1_000_000)
        XCTAssertEqual(record.costUSD, 22.05, accuracy: 0.000_000_001)
        XCTAssertEqual(record.requestCount, 4)
        XCTAssertEqual(
            ProviderUsagePricingStubURLProtocol.lastRequest?.path,
            "/v1/organizations/usage_report/messages"
        )
        XCTAssertEqual(ProviderUsagePricingStubURLProtocol.lastRequest?.apiKey, "anthropic-key")
    }

    func testOpenAIFetchUsageComputesUncachedAndCachedModelPricing() async throws {
        ProviderUsagePricingStubURLProtocol.configure(json: """
        {
          "data": [
            {
              "start_time": 1752364800,
              "results": [
                {
                  "model": "gpt-4o",
                  "input_tokens": 2000000,
                  "output_tokens": 1000000,
                  "input_cached_tokens": 1000000,
                  "num_model_requests": 5
                }
              ]
            }
          ],
          "has_more": false
        }
        """)
        let api = OpenAIUsageAPI(apiKey: "openai-key", session: makeSession())

        let records = try await api.fetchUsage(since: Date(timeIntervalSince1970: 1_752_364_800))

        let record = try XCTUnwrap(records.single)
        XCTAssertEqual(record.providerName, "OpenAI")
        XCTAssertEqual(record.model, "gpt-4o")
        XCTAssertEqual(record.inputTokens, 1_000_000)
        XCTAssertEqual(record.outputTokens, 1_000_000)
        XCTAssertEqual(record.cacheReadTokens, 1_000_000)
        XCTAssertEqual(record.cacheCreationTokens, 0)
        XCTAssertEqual(record.costUSD, 13.75, accuracy: 0.000_000_001)
        XCTAssertEqual(record.requestCount, 5)
        XCTAssertEqual(
            ProviderUsagePricingStubURLProtocol.lastRequest?.path,
            "/v1/organization/usage/completions"
        )
        XCTAssertEqual(
            ProviderUsagePricingStubURLProtocol.lastRequest?.authorization,
            "Bearer openai-key"
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUsagePricingStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ProviderUsagePricingStubURLProtocol: URLProtocol {
    struct RequestSnapshot: Sendable {
        let path: String
        let authorization: String?
        let apiKey: String?
    }

    private struct State: Sendable {
        var responseData = Data()
        var lastRequest: RequestSnapshot?
    }

    private static let state = Locked(State())

    static var lastRequest: RequestSnapshot? {
        state.read().lastRequest
    }

    static func configure(json: String) {
        state.write(State(responseData: Data(json.utf8), lastRequest: nil))
    }

    static func reset() {
        state.write(State())
    }

    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let data = Self.state.withLock { state in
            state.lastRequest = RequestSnapshot(
                path: url.path,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                apiKey: request.value(forHTTPHeaderField: "x-api-key")
            )
            return state.responseData
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
