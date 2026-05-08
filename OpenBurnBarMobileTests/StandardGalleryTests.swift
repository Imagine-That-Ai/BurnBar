import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class StandardGalleryTests: XCTestCase {

    private func realisticDigest() -> TrendDataDigest {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()

        let providers: [RollupProviderSummary] = [
            .init(provider: "claudecode", providerID: ProviderID(rawValue: "claudecode"), totalRequests: 500, totalTokens: 4_200_000, totalCost: 92.10),
            .init(provider: "codex",      providerID: ProviderID(rawValue: "codex"),      totalRequests: 220, totalTokens: 1_800_000, totalCost: 24.80),
            .init(provider: "factory",    providerID: ProviderID(rawValue: "factory"),    totalRequests: 110, totalTokens: 900_000,   totalCost: 11.30),
            .init(provider: "kimi",       providerID: ProviderID(rawValue: "kimi"),       totalRequests: 60,  totalTokens: 320_000,   totalCost: 3.20)
        ]
        let models: [RollupModelSummary] = [
            .init(model: "claude-sonnet-4.5", provider: "claudecode", requests: 300, tokens: 2_500_000, cost: 60.0),
            .init(model: "gpt-5.4-codex",     provider: "codex",      requests: 200, tokens: 1_700_000, cost: 22.0),
            .init(model: "kimi-k3",           provider: "kimi",       requests: 50,  tokens: 290_000,   cost: 3.0)
        ]

        let dailyPoints: [RollupDailyPoint] = (0..<14).map { i -> RollupDailyPoint in
            let day = cal.date(byAdding: .day, value: -i, to: now)!
            return RollupDailyPoint(date: day, value: 8.0 + Double(i) * 1.2)
        }.reversed()

        let usages: [TokenUsage] = (0..<24).map { i -> TokenUsage in
            let start = cal.date(byAdding: .hour, value: -i, to: now)!
            let end = start.addingTimeInterval(60 * 30)
            return TokenUsage(
                provider: AgentProvider.allCases[i % AgentProvider.allCases.count],
                sessionId: "sess-\(i)",
                projectName: "project-\(i % 3)",
                model: "model-\(i % 4)",
                inputTokens: 5_000,
                outputTokens: 2_000,
                cacheCreationTokens: 800,
                cacheReadTokens: 4_000,
                reasoningTokens: i % 4 == 0 ? 600 : 0,
                costUSD: 0.5,
                startTime: start,
                endTime: end
            )
        }

        return TrendDataDigest.build(
            windowTotals: [
                .today:      RollupTotals(requests: 60,  tokens: 350_000,   costUsd: 18.74),
                .sevenDays:  RollupTotals(requests: 420, tokens: 2_700_000, costUsd: 131.40),
                .thirtyDays: RollupTotals(requests: 1_900, tokens: 12_400_000, costUsd: 612.00)
            ],
            providerSummaries: providers,
            modelSummaries: models,
            deviceSummaries: [],
            dailyPoints: Array(dailyPoints),
            recentUsages: usages,
            displayMode: .currency,
            now: now
        )
    }

    func testQuickFactsAlwaysHaveAtLeastTwoTiles() {
        let digest = realisticDigest()
        let facts = StandardGallery.quickFacts(from: digest)
        XCTAssertGreaterThanOrEqual(facts.count, 2)
        XCTAssertNotNil(facts.first { $0.label == "TODAY" })
        XCTAssertNotNil(facts.first { $0.label == "TOP PROVIDER" })
    }

    func testGalleryProducesAllSixItemsForRealisticData() {
        let digest = realisticDigest()
        let items = StandardGallery.items(from: digest)
        XCTAssertEqual(items.count, 6, "Expected all 6 standard items to render with realistic data.")

        let ids = Set(items.map(\.id))
        XCTAssertTrue(ids.contains("gallery.burnTrajectory"))
        XCTAssertTrue(ids.contains("gallery.stackedDaily"))
        XCTAssertTrue(ids.contains("gallery.providerDonut"))
        XCTAssertTrue(ids.contains("gallery.modelScatter"))
        XCTAssertTrue(ids.contains("gallery.hourHeat"))
        XCTAssertTrue(ids.contains("gallery.cacheHealth"))
    }

    func testEmptyDigestProducesNoGalleryItems() {
        let empty = TrendDataDigest.build(
            windowTotals: [:],
            providerSummaries: [],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: [],
            displayMode: .currency
        )
        let items = StandardGallery.items(from: empty)
        XCTAssertEqual(items.count, 0, "Gallery should not invent charts when there's no data.")
    }

    func testHourHeatRendersAsAsciiVariant() {
        let digest = realisticDigest()
        let items = StandardGallery.items(from: digest)
        let heat = items.first { $0.id == "gallery.hourHeat" }
        XCTAssertNotNil(heat)
        if case .ascii(let spec) = heat?.rendering {
            XCTAssertEqual(spec.variant, .heatmap)
            XCTAssertGreaterThanOrEqual(spec.blocks.count, 1)
        } else {
            XCTFail("Expected hour heat to be ascii heatmap")
        }
    }

    func testCacheHealthInsightTracksHitRate() {
        let digest = realisticDigest()
        let items = StandardGallery.items(from: digest)
        let cache = items.first { $0.id == "gallery.cacheHealth" }
        XCTAssertNotNil(cache)
        if case .insight(let spec) = cache?.rendering {
            XCTAssertTrue(spec.title.contains("%"))
            XCTAssertNotNil(spec.tone)
        } else {
            XCTFail("Expected cache health insight")
        }
    }
}
