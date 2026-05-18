import XCTest
@testable import OpenBurnBarCore

final class VerdictComposerTests: XCTestCase {

    private func makeDigest() -> InsightDigest {
        let now = Date()
        return InsightDigest(
            contentHash: "h",
            generatedAt: now,
            window: DateInterval(start: now.addingTimeInterval(-86_400), end: now),
            rowCount: 1,
            totals: .init(costUSD: 2.0, totalTokens: 4000, inputTokens: 1000,
                          outputTokens: 1000, reasoningTokens: 0,
                          cacheReadTokens: 2000, cacheCreationTokens: 0,
                          sessionCount: 2),
            providers: [
                .init(id: "anthropic", displayName: "Claude Code",
                      costUSD: 2.0, totalTokens: 4000, sessionCount: 2,
                      topModels: [], topInferredTaskTitles: [], topKeyTools: [])
            ],
            models: [],
            projects: [],
            devices: [],
            daily: (0..<30).map { i in
                .init(day: Date().addingTimeInterval(-Double(i) * 86_400),
                      costUSD: 2.0, totalTokens: 4000, sessionCount: 2,
                      perProvider: [:])
            },
            hourly: Array(repeating: 0, count: 24),
            useCaseHistogram: [.init(id: "refactor", count: 3, costUSD: 1.0)],
            agentFocusSignals: [],
            modelFocusSignals: [],
            quotaSnapshots: [],
            operatingActions: [],
            summaryRunsLog: [],
            anomalies: []
        )
    }

    func testRefreshEmitsRuleBasedUpgradeEvenWithoutLLM() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let composer = VerdictComposer(
            deviceID: "dev",
            cache: cache,
            digestProducer: { _ in self.makeDigest() },
            llmAuthor: nil
        )
        let stream = await composer.refresh(window: .today)
        var sawRuleBased = false
        for await event in stream {
            if case .ruleBasedUpgrade(let v) = event {
                sawRuleBased = true
                XCTAssertTrue(v.isRuleBased)
                XCTAssertEqual(v.rings.count, 3)
            }
        }
        XCTAssertTrue(sawRuleBased)
    }

    func testRefreshFailsCleanlyWhenDigestProducerThrows() async {
        struct Boom: Error {}
        let cache = VerdictCache(storage: .memoryOnly)
        let composer = VerdictComposer(
            deviceID: "dev",
            cache: cache,
            digestProducer: { _ in throw Boom() },
            llmAuthor: nil
        )
        let stream = await composer.refresh(window: .today)
        var sawFailure = false
        for await event in stream {
            if case .failed = event {
                sawFailure = true
            }
        }
        XCTAssertTrue(sawFailure)
    }

    func testRefreshAcceptsCleanLLMUpgrade() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let composer = VerdictComposer(
            deviceID: "dev",
            cache: cache,
            digestProducer: { _ in self.makeDigest() },
            llmAuthor: { draft, _ in
                var upgraded = draft
                upgraded.headline = "Upgraded: you spent $2.00 with 3 cache hits."
                upgraded.isRuleBased = false
                upgraded.provenance = InsightModelTag(
                    providerKey: "anthropic",
                    modelID: "claude-sonnet-4-6",
                    displayName: "Claude Sonnet 4.6",
                    egressTier: .userKey
                )
                return upgraded
            },
            citationValidatorFactory: { _ in InsightVoicePostProcessor.acceptAllCitations }
        )
        let stream = await composer.refresh(window: .today)
        var sawUpgrade = false
        for await event in stream {
            if case .llmUpgrade(let v, _) = event {
                sawUpgrade = true
                XCTAssertTrue(v.headline.contains("Upgraded"))
            }
        }
        XCTAssertTrue(sawUpgrade)
    }

    func testSeedDemoFillsEmptyCache() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let composer = VerdictComposer(
            deviceID: "dev",
            cache: cache,
            digestProducer: { _ in self.makeDigest() }
        )
        await composer.seedDemoIfEmpty(window: .today)
        let read = await composer.instant(window: .today)
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.verdict.provenance.providerKey, "burnbar-demo")
    }

    func testSeedDemoIsNoOpWhenCachePopulated() async {
        let cache = VerdictCache(storage: .memoryOnly)
        let now = Date()
        await cache.write(
            InsightVerdict(
                generatedAt: now,
                window: .today,
                headline: "Already authored",
                rings: [
                    VerdictRing(identity: .spend, label: "S", current: 1, target: 2,
                                unit: .usd, valueLabel: "1/2"),
                    VerdictRing(identity: .cache, label: "C", current: 1, target: 2,
                                unit: .percent, valueLabel: "1/2"),
                    VerdictRing(identity: .sessions, label: "Se", current: 1, target: 2,
                                unit: .sessions, valueLabel: "1/2")
                ],
                provenance: InsightModelTag(providerKey: "p", modelID: "m", displayName: "M",
                                            egressTier: .localOnly)
            ),
            deviceID: "dev",
            now: now
        )
        let composer = VerdictComposer(
            deviceID: "dev",
            cache: cache,
            digestProducer: { _ in self.makeDigest() }
        )
        await composer.seedDemoIfEmpty(window: .today)
        let read = await composer.instant(window: .today)
        XCTAssertEqual(read?.verdict.headline, "Already authored")
    }
}
