import Foundation
import XCTest
@testable import OpenBurnBar

final class GitHubCopilotUsageAPITests: XCTestCase {
    override func tearDown() {
        GitHubCopilotUsageStubURLProtocol.reset()
        super.tearDown()
    }

    func testFetchUsage_modelBreakdown_returnsPricedModelRecord() async throws {
        GitHubCopilotUsageStubURLProtocol.configure(json: """
        [
          {
            "date": "2026-07-13",
            "copilot_ide_chat": {
              "models": [
                {
                  "name": "claude-sonnet-4-20250514",
                  "total_tokens": 10000,
                  "total_engaged_users": 7
                }
              ]
            }
          }
        ]
        """)
        let api = GitHubCopilotUsageAPI(pat: "test-pat", session: makeSession())

        let records = try await api.fetchUsage(since: Date(timeIntervalSince1970: 1_752_364_800))

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(record.inputTokens, 8_500)
        XCTAssertEqual(record.outputTokens, 1_500)
        XCTAssertEqual(record.requestCount, 7)
        XCTAssertEqual(record.costUSD, 0.048, accuracy: 0.000_000_001)
        XCTAssertGreaterThan(record.costUSD, 0)
        XCTAssertEqual(GitHubCopilotUsageStubURLProtocol.requestCount, 1)
    }

    func testFetchUsage_flatTotalTokens_returnsPricedCopilotRecord() async throws {
        GitHubCopilotUsageStubURLProtocol.configure(json: """
        [
          {
            "date": "2026-07-13",
            "total_tokens_used": 20000,
            "total_active_users": 4
          }
        ]
        """)
        let api = GitHubCopilotUsageAPI(pat: "test-pat", session: makeSession())

        let records = try await api.fetchUsage(since: Date(timeIntervalSince1970: 1_752_364_800))

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.model, "copilot")
        XCTAssertEqual(record.inputTokens, 17_000)
        XCTAssertEqual(record.outputTokens, 3_000)
        XCTAssertEqual(record.requestCount, 4)
        XCTAssertEqual(record.costUSD, 0.0725, accuracy: 0.000_000_001)
        XCTAssertGreaterThan(record.costUSD, 0)
        XCTAssertEqual(GitHubCopilotUsageStubURLProtocol.requestCount, 1)
    }

    func testFetchUsage_mixedMultiDayMetrics_preservesEveryDay() async throws {
        GitHubCopilotUsageStubURLProtocol.configure(json: """
        [
          {
            "date": "2026-07-11",
            "copilot_ide_chat": {
              "models": [
                {
                  "name": "claude-sonnet-4-20250514",
                  "total_tokens": 10000,
                  "total_engaged_users": 7
                }
              ]
            }
          },
          {
            "date": "2026-07-12",
            "total_tokens_used": 20000,
            "total_active_users": 4
          },
          {
            "date": "2026-07-13",
            "total_tokens": 10000,
            "total_active_users": 2
          }
        ]
        """)
        let api = GitHubCopilotUsageAPI(pat: "test-pat", session: makeSession())

        let records = try await api.fetchUsage(since: Date(timeIntervalSince1970: 1_752_364_800))

        XCTAssertEqual(records.map(\.model), ["claude-sonnet-4-20250514", "copilot", "copilot"])
        XCTAssertEqual(records.map(\.inputTokens), [8_500, 17_000, 8_500])
        XCTAssertEqual(records.map(\.outputTokens), [1_500, 3_000, 1_500])
        XCTAssertEqual(records.map(\.requestCount), [7, 4, 2])
        XCTAssertEqual(GitHubCopilotUsageStubURLProtocol.requestCount, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubCopilotUsageStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private class GitHubCopilotUsageStubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var responseData = Data()
        var requestCount = 0
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.requestCount
    }

    static func configure(json: String) {
        lock.lock()
        state = State(responseData: Data(json.utf8), requestCount: 0)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.state.requestCount += 1
        let data = Self.state.responseData
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
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
