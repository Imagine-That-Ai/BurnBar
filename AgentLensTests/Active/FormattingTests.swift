import XCTest
@testable import OpenBurnBar

/// Unit tests for formatting utilities — pure functions with no
/// external dependencies. These are the display formatters used
/// throughout dashboard, menu bar, and session detail views.
final class FormattingTests: XCTestCase {

    // MARK: - Double.formatAsCost()

    func test_formatAsCost_zero() {
        XCTAssertEqual(0.0.formatAsCost(), "$0.00")
    }

    func test_formatAsCost_nearZero() {
        XCTAssertEqual(1e-10.formatAsCost(), "$0.00")
    }

    func test_formatAsCost_negativeNearZero() {
        XCTAssertEqual((-1e-10).formatAsCost(), "$0.00")
    }

    func test_formatAsCost_smallFraction() {
        // < 0.01 → 4 decimal places
        XCTAssertEqual(0.001.formatAsCost(), "$0.0010")
        XCTAssertEqual(0.0099.formatAsCost(), "$0.0099")
    }

    func test_formatAsCost_standard() {
        XCTAssertEqual(0.01.formatAsCost(), "$0.01")
        XCTAssertEqual(1.0.formatAsCost(), "$1.00")
        XCTAssertEqual(1234.56.formatAsCost(), "$1234.56")
    }

    func test_formatAsCost_large() {
        XCTAssertEqual(1_000_000.0.formatAsCost(), "$1000000.00")
    }

    func test_formatAsCost_negative() {
        XCTAssertEqual((-5.0).formatAsCost(), "-$5.00")
    }

    // MARK: - Double.formatAsPercent()

    func test_formatAsPercent_zero() {
        XCTAssertEqual(0.0.formatAsPercent(), "0.0%")
    }

    func test_formatAsPercent_wholeNumber() {
        XCTAssertEqual(0.5.formatAsPercent(), "50%")
        XCTAssertEqual(1.0.formatAsPercent(), "100%")
    }

    func test_formatAsPercent_aboveTen() {
        XCTAssertEqual(0.1.formatAsPercent(), "10%")
        XCTAssertEqual(0.123.formatAsPercent(), "12%")
        XCTAssertEqual(0.99.formatAsPercent(), "99%")
    }

    func test_formatAsPercent_belowTen() {
        XCTAssertEqual(0.05.formatAsPercent(), "5.0%")
        XCTAssertEqual(0.001.formatAsPercent(), "0.1%")
    }

    func test_formatAsPercent_verySmall() {
        XCTAssertEqual(0.0009.formatAsPercent(), "0.09%")
    }

    func test_formatAsPercent_verySmallNonZero() {
        // Below 0.1% but non-zero → 2 decimal places
        XCTAssertEqual(0.0005.formatAsPercent(), "0.05%")
    }

    func test_formatAsPercent_negative() {
        XCTAssertEqual((-0.25).formatAsPercent(), "-25%")
    }

    func test_formatAsPercent_nonFinite() {
        XCTAssertEqual(Double.infinity.formatAsPercent(), "—")
        XCTAssertEqual(Double.nan.formatAsPercent(), "—")
        XCTAssertEqual((-Double.infinity).formatAsPercent(), "—")
    }

    // MARK: - Int.formatAsTokens()

    func test_formatAsTokens_smallValues() {
        XCTAssertEqual(0.formatAsTokens(), "0")
        XCTAssertEqual(42.formatAsTokens(), "42")
        XCTAssertEqual(999.formatAsTokens(), "999")
    }

    func test_formatAsTokens_kilo() {
        XCTAssertEqual(1_000.formatAsTokens(), "1.0K")
        XCTAssertEqual(1_500.formatAsTokens(), "1.5K")
        XCTAssertEqual(999_999.formatAsTokens(), "1000.0K")
    }

    func test_formatAsTokens_mega() {
        XCTAssertEqual(1_000_000.formatAsTokens(), "1.0M")
        XCTAssertEqual(2_500_000.formatAsTokens(), "2.5M")
        XCTAssertEqual(999_000_000.formatAsTokens(), "999.0M")
    }

    // MARK: - Int.formatAsTokenVolume()

    func test_formatAsTokenVolume_smallValues() {
        XCTAssertEqual(0.formatAsTokenVolume(), "0")
        XCTAssertEqual(42.formatAsTokenVolume(), "42")
        XCTAssertEqual(999.formatAsTokenVolume(), "999")
    }

    func test_formatAsTokenVolume_kilo() {
        XCTAssertEqual(1_000.formatAsTokenVolume(), "1.0K")
        XCTAssertEqual(10_500.formatAsTokenVolume(), "10.5K")
    }

    func test_formatAsTokenVolume_mega() {
        XCTAssertEqual(1_000_000.formatAsTokenVolume(), "1.00M")
        XCTAssertEqual(25_500_000.formatAsTokenVolume(), "25.50M")
    }

    func test_formatAsTokenVolume_billion() {
        XCTAssertEqual(1_000_000_000.formatAsTokenVolume(), "1.00B")
        XCTAssertEqual(2_500_000_000.formatAsTokenVolume(), "2.50B")
    }

    // MARK: - UsageDisplayMode

    func test_usageDisplayMode_label_currency() {
        XCTAssertEqual(UsageDisplayMode.currency.label, "USD")
    }

    func test_usageDisplayMode_label_tokens() {
        XCTAssertEqual(UsageDisplayMode.tokens.label, "Tokens")
    }

    func test_usageDisplayMode_id_matchesRawValue() {
        for mode in UsageDisplayMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func test_usageDisplayMode_allCases() {
        let cases = UsageDisplayMode.allCases
        XCTAssertEqual(cases.count, 2)
        XCTAssertTrue(cases.contains(.currency))
        XCTAssertTrue(cases.contains(.tokens))
    }
}
