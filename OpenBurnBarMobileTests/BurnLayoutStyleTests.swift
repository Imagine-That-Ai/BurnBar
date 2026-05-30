import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class BurnLayoutStyleTests: XCTestCase {

    func testHasFiveCasesWithStableRawValues() {
        XCTAssertEqual(BurnLayoutStyle.allCases.count, 5)
        XCTAssertEqual(
            BurnLayoutStyle.allCases.map(\.rawValue),
            ["cards", "constellation", "grid", "leaderboard", "timeline"]
        )
    }

    func testEveryCaseHasLabelIconAndAccessibility() {
        for style in BurnLayoutStyle.allCases {
            XCTAssertFalse(style.label.isEmpty, "missing label for \(style)")
            XCTAssertFalse(style.systemImage.isEmpty, "missing icon for \(style)")
            XCTAssertFalse(style.accessibilityLabel.isEmpty, "missing a11y for \(style)")
        }
    }

    func testResolveFallsBackToCards() {
        XCTAssertEqual(BurnLayoutStyle.resolve("grid"), .grid)
        XCTAssertEqual(BurnLayoutStyle.resolve("timeline"), .timeline)
        XCTAssertEqual(BurnLayoutStyle.resolve("nonsense"), .cards)
        XCTAssertEqual(BurnLayoutStyle.resolve(""), .cards)
    }

    func testLeaderboardRankingByCostAndTokens() {
        let a = RollupProviderSummary(provider: "anthropic", totalRequests: 1, totalTokens: 100, totalCost: 5.0)
        let b = RollupProviderSummary(provider: "openai", totalRequests: 1, totalTokens: 300, totalCost: 2.0)
        let zero = RollupProviderSummary(provider: "google", totalRequests: 0, totalTokens: 0, totalCost: 0.0)

        // By cost: a (5) > b (2); zero filtered out.
        XCTAssertEqual(
            BurnLeaderboardMath.ranked([a, b, zero], displayMode: .currency).map(\.provider),
            ["anthropic", "openai"]
        )
        // By tokens: b (300) > a (100); zero filtered out.
        XCTAssertEqual(
            BurnLeaderboardMath.ranked([a, b, zero], displayMode: .tokens).map(\.provider),
            ["openai", "anthropic"]
        )
    }

    func testLeaderboardValueAndFraction() {
        let p = RollupProviderSummary(provider: "x", totalRequests: 0, totalTokens: 42, totalCost: 3.5)
        XCTAssertEqual(BurnLeaderboardMath.value(p, displayMode: .currency), 3.5, accuracy: 0.0001)
        XCTAssertEqual(BurnLeaderboardMath.value(p, displayMode: .tokens), 42, accuracy: 0.0001)

        XCTAssertEqual(BurnLeaderboardMath.fraction(value: 5, max: 10), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BurnLeaderboardMath.fraction(value: 20, max: 10), 1.0, accuracy: 0.0001) // clamped
        XCTAssertEqual(BurnLeaderboardMath.fraction(value: 5, max: 0), 0.0, accuracy: 0.0001)   // zero-guard
    }
}
