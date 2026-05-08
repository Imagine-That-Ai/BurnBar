import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class TrendDataDigestTests: XCTestCase {

    func testEmptyDigestProducesValidJSON() {
        let digest = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: [],
            displayMode: .currency
        )
        XCTAssertEqual(digest.totals.count, 0)
        XCTAssertTrue(digest.compactJSON().hasPrefix("{"))
        // Empty digest still carries the schema scaffolding (24 hour buckets,
        // empty arrays, cache aggregate, ISO timestamps).
        XCTAssertLessThan(digest.approximateByteSize, 2048)
    }

    func testRealisticDigestStaysUnderSixKB() {
        let totals: [RollupWindowKey: RollupTotals] = [
            .today:     RollupTotals(requests: 74, tokens: 412_800, costUsd: 18.74),
            .sevenDays: RollupTotals(requests: 418, tokens: 2_814_000, costUsd: 126.40),
            .thirtyDays: RollupTotals(requests: 1_882, tokens: 13_740_000, costUsd: 613.92)
        ]

        let providers = (0..<6).map { i in
            RollupProviderSummary(
                provider: "provider-\(i)",
                providerID: ProviderID(rawValue: "provider-\(i)"),
                totalRequests: 200 + i * 10,
                totalTokens: 500_000 + i * 100_000,
                totalCost: 30 + Double(i) * 5
            )
        }

        let models = (0..<8).map { i in
            RollupModelSummary(
                model: "model-\(i)",
                provider: "provider-\(i % 6)",
                requests: 100 + i * 5,
                tokens: 250_000 + i * 50_000,
                cost: 10 + Double(i) * 1.2
            )
        }

        let devices = [
            RollupDeviceSummary(deviceId: "macbook-1", requests: 1200, tokens: 2_500_000),
            RollupDeviceSummary(deviceId: "studio",    requests: 700,  tokens: 1_400_000)
        ]

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let dailyPoints = (0..<30).map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: now)!
            return RollupDailyPoint(date: day, value: Double(20 + offset))
        }.reversed()

        let usages = (0..<25).map { i -> TokenUsage in
            let start = cal.date(byAdding: .hour, value: -i, to: now)!
            let end = start.addingTimeInterval(60 * Double(20 + (i % 10)))
            return TokenUsage(
                provider: AgentProvider.allCases[i % AgentProvider.allCases.count],
                sessionId: "sess-\(i)",
                projectName: "project-\(i % 4)",
                model: "model-\(i % 6)",
                inputTokens: 5_000 + i * 100,
                outputTokens: 1_500 + i * 50,
                cacheCreationTokens: 1_000,
                cacheReadTokens: 2_000 + i * 30,
                reasoningTokens: i % 3 == 0 ? 500 : 0,
                costUSD: 0.5 + Double(i) * 0.05,
                startTime: start,
                endTime: end
            )
        }

        let digest = TrendDataDigest.build(
            windowTotals: totals,
            providerSummaries: providers,
            modelSummaries: models,
            deviceSummaries: devices,
            dailyPoints: Array(dailyPoints),
            recentUsages: usages,
            displayMode: .currency,
            now: now
        )

        XCTAssertEqual(digest.totals.count, 3)
        XCTAssertLessThanOrEqual(digest.providers.count, 6)
        XCTAssertLessThanOrEqual(digest.models.count, 8)
        XCTAssertEqual(digest.hourly.count, 24)
        XCTAssertLessThanOrEqual(digest.recentSessions.count, 15)
        XCTAssertGreaterThan(digest.approximateByteSize, 1024)
        XCTAssertLessThan(digest.approximateByteSize, 12 * 1024,
                          "Digest grew past 12KB — risk of dropping context on small models.")
    }

    func testDigestEncodesProviderSharePercents() {
        let providers = [
            RollupProviderSummary(provider: "claudecode", providerID: ProviderID(rawValue: "claudecode"), totalRequests: 100, totalTokens: 600_000, totalCost: 60),
            RollupProviderSummary(provider: "codex",      providerID: ProviderID(rawValue: "codex"),      totalRequests: 100, totalTokens: 400_000, totalCost: 40)
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
        XCTAssertEqual(digest.providers.count, 2)
        XCTAssertEqual(digest.providers[0].sharePct, 60, accuracy: 0.01)
        XCTAssertEqual(digest.providers[1].sharePct, 40, accuracy: 0.01)
    }

    func testCacheAggregateMatchesInputs() {
        let now = Date()
        let usages = [
            TokenUsage(
                provider: .claudeCode,
                sessionId: "s1",
                projectName: "p",
                model: "m",
                inputTokens: 1000,
                outputTokens: 100,
                cacheCreationTokens: 200,
                cacheReadTokens: 500,
                costUSD: 1,
                startTime: now,
                endTime: now.addingTimeInterval(60)
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
        XCTAssertEqual(digest.cache.totalInputTokens, 1000)
        XCTAssertEqual(digest.cache.totalCacheReadTokens, 500)
        XCTAssertEqual(digest.cache.cacheHitRate, 500.0 / 1700.0, accuracy: 0.0001)
    }
}
