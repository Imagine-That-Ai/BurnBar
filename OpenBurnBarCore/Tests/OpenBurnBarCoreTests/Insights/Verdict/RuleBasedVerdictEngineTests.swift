import XCTest
@testable import OpenBurnBarCore

final class RuleBasedVerdictEngineTests: XCTestCase {

    private func makeDigest(
        costUSD: Double = 4.12,
        sessionCount: Int = 3,
        cacheReadTokens: Int = 9100,
        inputTokens: Int = 900,
        dailyCount: Int = 30,
        anomalyZ: Double? = nil,
        providers: [InsightDigest.ProviderSnapshot] = [
            .init(id: "anthropic", displayName: "Claude Code",
                  costUSD: 3.5, totalTokens: 8000, sessionCount: 2,
                  topModels: ["claude-sonnet-4-6"], topInferredTaskTitles: [], topKeyTools: [])
        ],
        models: [InsightDigest.ModelSnapshot] = [
            .init(id: "claude-sonnet-4-6", providerID: "anthropic",
                  costUSD: 3.5, totalTokens: 8000, sessionCount: 2,
                  avgCostPerSession: 1.75, cacheHitRate: 0.91,
                  topInferredTaskTitles: [], topProjects: [])
        ],
        useCaseHistogram: [InsightDigest.UseCaseBin] = [
            .init(id: "refactor", count: 5, costUSD: 1.5)
        ]
    ) -> InsightDigest {
        let now = Date()
        let daily = (0..<dailyCount).map { i in
            InsightDigest.DailyPoint(
                day: Calendar.current.date(byAdding: .day, value: -i, to: now) ?? now,
                costUSD: 4.0,
                totalTokens: 8000,
                sessionCount: 2,
                perProvider: ["anthropic": 3.5]
            )
        }
        let anomalies: [InsightDigest.PrecomputedAnomaly] = {
            guard let z = anomalyZ else { return [] }
            return [
                .init(id: "anom-1", occurredAt: now,
                      label: "Cache drop on agentlens-mobile",
                      score: z, detail: "Cache hit dropped 27 points")
            ]
        }()
        return InsightDigest(
            contentHash: "h",
            generatedAt: now,
            window: DateInterval(start: now.addingTimeInterval(-86_400), end: now),
            rowCount: sessionCount,
            totals: .init(costUSD: costUSD,
                          totalTokens: cacheReadTokens + inputTokens,
                          inputTokens: inputTokens,
                          outputTokens: 0, reasoningTokens: 0,
                          cacheReadTokens: cacheReadTokens,
                          cacheCreationTokens: 0,
                          sessionCount: sessionCount),
            providers: providers,
            models: models,
            projects: [],
            devices: [],
            daily: daily,
            hourly: Array(repeating: 0, count: 24),
            useCaseHistogram: useCaseHistogram,
            agentFocusSignals: [],
            modelFocusSignals: [],
            quotaSnapshots: [],
            operatingActions: [],
            summaryRunsLog: [],
            anomalies: anomalies
        )
    }

    func testProducesExactlyThreeRingsInCanonicalOrder() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(digest: makeDigest(), window: .today)
        XCTAssertEqual(v.rings.count, 3)
        XCTAssertEqual(v.rings.map(\.identity), [.spend, .cache, .sessions])
    }

    func testCacheRingComputesFromTokens() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(
            digest: makeDigest(cacheReadTokens: 9000, inputTokens: 1000),
            window: .today
        )
        guard let cache = v.rings.first(where: { $0.identity == .cache }) else {
            return XCTFail("missing cache ring")
        }
        XCTAssertEqual(cache.current, 90, accuracy: 0.01)
    }

    func testAnomalyBelowZThresholdIsNotSurfaced() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(
            digest: makeDigest(anomalyZ: 1.5),
            window: .today
        )
        XCTAssertNil(v.anomaly)
    }

    func testAnomalyAtOrAboveZThresholdIsSurfaced() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(
            digest: makeDigest(anomalyZ: 2.5),
            window: .today
        )
        XCTAssertNotNil(v.anomaly)
        XCTAssertEqual(v.anomaly?.zScore, 2.5)
        XCTAssertEqual(v.anomaly?.acceptAction?.intent, .investigate)
    }

    func testRecommendationGatesAtMinDailyHistory() {
        let engine = RuleBasedVerdictEngine()
        // <60d: no recommendation
        let shortHistory = engine.produce(
            digest: makeDigest(
                dailyCount: 14,
                models: [
                    .init(id: "claude-sonnet-4-6", providerID: "anthropic",
                          costUSD: 100, totalTokens: 80000, sessionCount: 30,
                          avgCostPerSession: 3.0, cacheHitRate: 0.5,
                          topInferredTaskTitles: [], topProjects: []),
                    .init(id: "claude-haiku-4-5", providerID: "anthropic",
                          costUSD: 5, totalTokens: 4000, sessionCount: 10,
                          avgCostPerSession: 0.5, cacheHitRate: 0.5,
                          topInferredTaskTitles: [], topProjects: [])
                ]
            ),
            window: .today
        )
        XCTAssertNil(shortHistory.recommendation)

        // ≥60d: recommendation present
        let longHistory = engine.produce(
            digest: makeDigest(
                dailyCount: 90,
                models: [
                    .init(id: "claude-sonnet-4-6", providerID: "anthropic",
                          costUSD: 100, totalTokens: 80000, sessionCount: 30,
                          avgCostPerSession: 3.0, cacheHitRate: 0.5,
                          topInferredTaskTitles: [], topProjects: []),
                    .init(id: "claude-haiku-4-5", providerID: "anthropic",
                          costUSD: 5, totalTokens: 4000, sessionCount: 10,
                          avgCostPerSession: 0.5, cacheHitRate: 0.5,
                          topInferredTaskTitles: [], topProjects: [])
                ]
            ),
            window: .today
        )
        XCTAssertNotNil(longHistory.recommendation)
        XCTAssertEqual(longHistory.recommendation?.acceptAction.intent, .switchRouterRule)
    }

    func testBulletsAlwaysHaveAtLeastOneCitation() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(digest: makeDigest(), window: .today)
        for bullet in v.bullets {
            XCTAssertFalse(bullet.citations.isEmpty,
                           "rule engine emitted uncited bullet: \(bullet.claim)")
        }
    }

    func testEveryBulletContainsNumericToken() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(digest: makeDigest(), window: .today)
        let processor = InsightVoicePostProcessor()
        for bullet in v.bullets {
            XCTAssertTrue(
                processor.containsNumericToken(bullet.claim),
                "non-numeric bullet: \(bullet.claim)"
            )
        }
    }

    func testProvenanceIsLocalRules() {
        let v = RuleBasedVerdictEngine().produce(digest: makeDigest(), window: .today)
        XCTAssertEqual(v.provenance.providerKey, "local-rules")
        XCTAssertEqual(v.provenance.egressTier, .localOnly)
        XCTAssertTrue(v.isRuleBased)
    }

    func testHeadlineIncludesNumericTokenAndSpend() {
        let v = RuleBasedVerdictEngine().produce(
            digest: makeDigest(costUSD: 12.34),
            window: .today
        )
        XCTAssertTrue(v.headline.contains("12.34"))
    }

    func testEmptyDigestStillProducesRenderableVerdict() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(
            digest: makeDigest(
                costUSD: 0,
                sessionCount: 0,
                cacheReadTokens: 0,
                inputTokens: 0,
                providers: [],
                models: [],
                useCaseHistogram: []
            ),
            window: .today
        )
        XCTAssertEqual(v.rings.count, 3)
        XCTAssertFalse(v.headline.isEmpty)
        // 30 daily points satisfies `trendsMinDailyHistory` (14) but not
        // `recommendationMinDailyHistory` (60), so confidence sits at medium.
        XCTAssertEqual(v.confidence, .medium)
    }

    func testHighConfidenceAtSixtyDaysHistory() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(digest: makeDigest(dailyCount: 60), window: .today)
        XCTAssertEqual(v.confidence, .high)
    }

    func testLowConfidenceUnderTwoWeeksHistory() {
        let engine = RuleBasedVerdictEngine()
        let v = engine.produce(digest: makeDigest(dailyCount: 7), window: .today)
        XCTAssertEqual(v.confidence, .low)
    }

    func testContentHashIsStableForSameInputs() {
        let engine = RuleBasedVerdictEngine()
        let fixedNow = Date(timeIntervalSince1970: 1_715_000_000)
        let digest = makeDigest()
        let a = engine.produce(digest: digest, window: .today, now: fixedNow)
        let b = engine.produce(digest: digest, window: .today, now: fixedNow)
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertFalse(a.contentHash.isEmpty)
    }
}
