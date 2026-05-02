import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class OpenBurnBarMobileTests: XCTestCase {

    // MARK: - Shared Model Compatibility

    func testAgentProviderRoundTrip() {
        let provider = AgentProvider.minimax
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertEqual(provider.persistedToken, "minimax")
        XCTAssertEqual(AgentProvider.fromPersistedToken("minimax"), .minimax)
        XCTAssertNil(AgentProvider.fromPersistedToken("unknown"))
    }

    func testTokenUsageCodable() throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "sess-1",
            projectName: "Test",
            model: "claude-3",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded.provider, usage.provider)
        XCTAssertEqual(decoded.totalTokens, 150)
        XCTAssertEqual(decoded.cost, 0.01)
    }

    func testProviderQuotaBucketProgress() {
        let bucket = ProviderQuotaBucket(
            key: "tokens",
            label: "Tokens",
            windowKind: .monthly,
            usedValue: 75,
            limitValue: 100,
            remainingValue: 25,
            usedPercent: 75,
            resetsAt: nil,
            unit: .tokens,
            isEstimated: false
        )
        XCTAssertEqual(bucket.progressFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(bucket.remainingPercent, 25, accuracy: 0.001)
    }

    func testUsageRollupDocCodable() throws {
        let doc = UsageRollupDoc(
            windowKey: .today,
            totals: RollupTotals(requests: 10, tokens: 1000, costUsd: 0.50),
            providerSummaries: [RollupProviderSummary(provider: "minimax", totalRequests: 5, totalTokens: 500)],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [RollupDailyPoint(date: "2026-05-01", tokens: 1000)],
            computedAt: Date()
        )
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(UsageRollupDoc.self, from: data)
        XCTAssertEqual(decoded.windowKey, .today)
        XCTAssertEqual(decoded.totals.tokens, 1000)
    }

    // MARK: - Formatting

    func testCostFormatting() {
        XCTAssertEqual(1.5.formatAsCost(), "$1.50")
        XCTAssertEqual(0.005.formatAsCost(), "$0.0050")
        XCTAssertEqual(0.0.formatAsCost(), "$0.00")
    }

    func testTokenFormatting() {
        XCTAssertEqual(1500.formatAsTokens(), "1.5K")
        XCTAssertEqual(1_500_000.formatAsTokens(), "1.5M")
        XCTAssertEqual(500.formatAsTokens(), "500")
    }

    // MARK: - Provider Connection Types

    func testProviderConnectionStatusRawValue() {
        XCTAssertEqual(ProviderConnectionStatus.connected.rawValue, "connected")
        XCTAssertEqual(ProviderConnectionStatus.error.rawValue, "error")
    }
}
