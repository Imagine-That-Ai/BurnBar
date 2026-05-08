import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class TrendInsightEngineTests: XCTestCase {

    func testEmptyDigestReturnsFallbackInsight() {
        let digest = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: [],
            displayMode: .currency
        )
        let insights = TrendInsightEngine.insights(from: digest)
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights.first?.id, "fallback.empty")
    }

    func testProviderDominanceTriggersWhenOverEightyPercent() {
        let providers = [
            RollupProviderSummary(provider: "claudecode", providerID: ProviderID(rawValue: "claudecode"), totalRequests: 100, totalTokens: 900_000, totalCost: 90),
            RollupProviderSummary(provider: "codex",      providerID: ProviderID(rawValue: "codex"),      totalRequests: 100, totalTokens: 100_000, totalCost: 10)
        ]
        let digest = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: providers,
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: [],
            displayMode: .currency
        )
        let insights = TrendInsightEngine.insights(from: digest)
        let dominance = insights.first { $0.id == "providerDominance" }
        XCTAssertNotNil(dominance)
        XCTAssertEqual(dominance?.tone, .warning)
    }

    func testCacheLowFiresWarning() {
        let usages = [
            TokenUsage(
                provider: .codex, sessionId: "s", projectName: "p", model: "m",
                inputTokens: 10_000, outputTokens: 1_000,
                cacheCreationTokens: 0, cacheReadTokens: 100,
                costUSD: 1.0, startTime: Date(), endTime: Date().addingTimeInterval(60)
            )
        ]
        let digest = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: usages,
            displayMode: .currency
        )
        let insights = TrendInsightEngine.insights(from: digest)
        XCTAssertNotNil(insights.first { $0.id == "cacheLow" })
    }

    func testReasoningSpikeFiresOnHeavyReasoning() {
        let now = Date()
        let usages = (0..<5).map { i in
            TokenUsage(
                provider: .codex, sessionId: "s\(i)", projectName: "p", model: "m",
                inputTokens: 1_000, outputTokens: 200,
                cacheCreationTokens: 0, cacheReadTokens: 0,
                reasoningTokens: 1_000,
                costUSD: 1.0, startTime: now, endTime: now.addingTimeInterval(60)
            )
        }
        let digest = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: usages,
            displayMode: .currency
        )
        let insights = TrendInsightEngine.insights(from: digest)
        XCTAssertNotNil(insights.first { $0.id == "reasoningSpike" })
    }

    func testInsightsAreSortedByPriorityDescending() {
        let providers = [
            RollupProviderSummary(provider: "claudecode", providerID: ProviderID(rawValue: "claudecode"), totalRequests: 100, totalTokens: 900_000, totalCost: 90),
            RollupProviderSummary(provider: "codex",      providerID: ProviderID(rawValue: "codex"),      totalRequests: 100, totalTokens: 100_000, totalCost: 10)
        ]
        let usages = [
            TokenUsage(
                provider: .codex, sessionId: "s", projectName: "p", model: "m",
                inputTokens: 10_000, outputTokens: 1_000,
                cacheCreationTokens: 0, cacheReadTokens: 100,
                costUSD: 1.0, startTime: Date(), endTime: Date().addingTimeInterval(60)
            )
        ]
        let digest = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: providers,
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: usages,
            displayMode: .currency
        )
        let insights = TrendInsightEngine.insights(from: digest)
        for (lhs, rhs) in zip(insights, insights.dropFirst()) {
            XCTAssertGreaterThanOrEqual(lhs.priority, rhs.priority)
        }
    }
}
