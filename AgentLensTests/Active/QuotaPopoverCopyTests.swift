import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias ProviderQuotaBucket = OpenBurnBar.ProviderQuotaBucket
private typealias ProviderQuotaWindowKind = OpenBurnBar.ProviderQuotaWindowKind
private typealias ProviderQuotaUnit = OpenBurnBar.ProviderQuotaUnit
private typealias UsageDisplayMode = OpenBurnBar.UsageDisplayMode

/// Coverage for the popover's collapsed quota row copy (`QuotaPopoverCopy`),
/// the shared bar fill thresholds (`QuotaBarFill`), the per-appearance
/// provider-color legibility nudge, and the header burn headline
/// (`PopoverHeaderCopy`).
@MainActor
final class QuotaPopoverCopyTests: XCTestCase {

    // MARK: - remainingLeftText

    func test_remainingLeftText_nilBucket_showsPlaceholder() {
        XCTAssertEqual(QuotaPopoverCopy.remainingLeftText(for: nil), "—")
    }

    func test_remainingLeftText_percentBucket_appendsLeft() {
        let bucket = Self.makeBucket(usedPercent: 25) // → 75% remaining
        XCTAssertEqual(QuotaPopoverCopy.remainingLeftText(for: bucket), "75% left")
    }

    func test_remainingLeftText_zeroRemaining_readsZeroLeft() {
        let bucket = Self.makeBucket(usedPercent: 150) // clamps to 0% remaining
        XCTAssertEqual(QuotaPopoverCopy.remainingLeftText(for: bucket), "0% left")
    }

    func test_remainingLeftText_absoluteTokenValue_usesAbbreviation() {
        let bucket = Self.makeBucket(remainingValue: 350_800_000, unit: .tokens)
        XCTAssertEqual(QuotaPopoverCopy.remainingLeftText(for: bucket), "350.8M left")
    }

    func test_remainingLeftText_currencyValue_usesDollars() {
        let bucket = Self.makeBucket(remainingValue: 0, unit: .currency)
        XCTAssertEqual(QuotaPopoverCopy.remainingLeftText(for: bucket), "$0.00 left")
    }

    func test_remainingLeftText_signalFreeBucket_staysUnavailable() {
        let bucket = Self.makeBucket()
        XCTAssertEqual(QuotaPopoverCopy.remainingLeftText(for: bucket), "Unavailable")
    }

    // MARK: - windowLabel

    func test_windowLabel_mapsEveryWindowKind() {
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .rollingHours)), "5h")
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .daily)), "24h")
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .weekly)), "7d")
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .rollingDays)), "7d")
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .monthly)), "30d")
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .lifetime)), "All")
        XCTAssertEqual(QuotaPopoverCopy.windowLabel(for: Self.makeBucket(windowKind: .custom)), "")
    }

    // MARK: - resetsText

    func test_resetsText_nilBucket_isNil() {
        XCTAssertNil(QuotaPopoverCopy.resetsText(for: nil))
    }

    func test_resetsText_noResetMoment_isNil() {
        XCTAssertNil(QuotaPopoverCopy.resetsText(for: Self.makeBucket()))
    }

    func test_resetsText_windowedBucket_leadsWithWindowTag() {
        let bucket = Self.makeBucket(
            windowKind: .weekly,
            resetsAt: Date().addingTimeInterval(4 * 86_400 + 22 * 3_600)
        )
        let text = QuotaPopoverCopy.resetsText(for: bucket)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("7d · resets in") ?? false,
                      "Expected window tag prefix, got \(text ?? "nil")")
    }

    func test_resetsText_customWindow_omitsTag() {
        let bucket = Self.makeBucket(
            windowKind: .custom,
            resetsAt: Date().addingTimeInterval(3_600)
        )
        let text = QuotaPopoverCopy.resetsText(for: bucket)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("resets in") ?? false,
                      "Expected bare resets line, got \(text ?? "nil")")
    }

    // MARK: - QuotaBarFill

    func test_barFillFraction_prefersRemainingPercent() {
        XCTAssertEqual(QuotaBarFill.fraction(for: Self.makeBucket(usedPercent: 25)), 0.75, accuracy: 0.001)
    }

    func test_barFillFraction_fallsBackToProgressComplement() {
        // No percent signal: used 25 / limit 100 → 0.75 remaining.
        let bucket = ProviderQuotaBucket(
            key: "test",
            label: "Test window",
            windowKind: .rollingHours,
            usedValue: 25,
            limitValue: 100,
            remainingValue: nil,
            usedPercent: nil,
            resetsAt: nil,
            unit: .tokens,
            isEstimated: false
        )
        XCTAssertEqual(QuotaBarFill.fraction(for: bucket), 0.75, accuracy: 0.001)
    }

    func test_barFillColor_thresholdSteps() {
        let theme = ProviderTheme.theme(for: .codex)
        XCTAssertEqual(QuotaBarFill.color(for: 1.0, theme: theme), theme.primaryColor)
        XCTAssertEqual(QuotaBarFill.color(for: 0.75, theme: theme), theme.primaryColor)
        XCTAssertEqual(QuotaBarFill.color(for: 0.6, theme: theme), theme.primaryColor.opacity(0.72))
        XCTAssertEqual(QuotaBarFill.color(for: 0.4, theme: theme), DesignSystem.Colors.amber)
        XCTAssertEqual(QuotaBarFill.color(for: 0.1, theme: theme), DesignSystem.Colors.warning)
    }

    func test_barFillTrack_adaptsToAppearance() {
        XCTAssertNotEqual(QuotaBarFill.trackColor(for: .dark), QuotaBarFill.trackColor(for: .light))
    }

    // MARK: - quotaLegibleProviderColor

    func test_legibleColor_lightMode_darkensNearWhite() {
        let warp = Color(hex: "DDE4EA")
        let adjusted = quotaLegibleProviderColor(warp, in: .light)
        XCTAssertLessThan(Self.luminance(of: adjusted), Self.luminance(of: warp),
                          "Near-white provider color must darken to survive light mode")
    }

    func test_legibleColor_darkMode_lightensNearBlack() {
        let xai = Color(hex: "1A1A1A")
        let adjusted = quotaLegibleProviderColor(xai, in: .dark)
        XCTAssertGreaterThan(Self.luminance(of: adjusted), Self.luminance(of: xai),
                             "Near-black provider color must lighten to survive dark mode")
    }

    func test_legibleColor_midLuminance_unchangedInBothModes() {
        let claude = Color(hex: "CC785C") // luminance ≈ 0.53 — legible as-is
        XCTAssertEqual(Self.luminance(of: quotaLegibleProviderColor(claude, in: .light)),
                       Self.luminance(of: claude), accuracy: 0.001)
        XCTAssertEqual(Self.luminance(of: quotaLegibleProviderColor(claude, in: .dark)),
                       Self.luminance(of: claude), accuracy: 0.001)
    }

    func test_legibleColor_crossMode_notDoubleAdjusted() {
        // Near-white is only a light-mode problem; dark mode must leave it alone.
        let warp = Color(hex: "DDE4EA")
        XCTAssertEqual(Self.luminance(of: quotaLegibleProviderColor(warp, in: .dark)),
                       Self.luminance(of: warp), accuracy: 0.001)
    }

    // MARK: - PopoverHeaderCopy

    func test_burnTitle_withUsage_readsBurningMetric() {
        XCTAssertEqual(PopoverHeaderCopy.burnTitle(metric: "52.4M", hasUsage: true), "Burning 52.4M")
        XCTAssertEqual(PopoverHeaderCopy.burnTitle(metric: "$284.12", hasUsage: true), "Burning $284.12")
    }

    func test_burnTitle_withoutUsage_fallsBackToAppName() {
        XCTAssertEqual(PopoverHeaderCopy.burnTitle(metric: "0", hasUsage: false), "OpenBurnBar")
    }

    func test_burnSubtitle_namesUnitsInTokenMode() {
        XCTAssertEqual(PopoverHeaderCopy.burnSubtitle(hasUsage: true, mode: .tokens), "tokens per week")
    }

    func test_burnSubtitle_currencyMode_omitsRedundantUnit() {
        XCTAssertEqual(PopoverHeaderCopy.burnSubtitle(hasUsage: true, mode: .currency), "per week")
    }

    func test_burnSubtitle_withoutUsage_isNil() {
        XCTAssertNil(PopoverHeaderCopy.burnSubtitle(hasUsage: false, mode: .tokens))
        XCTAssertNil(PopoverHeaderCopy.burnSubtitle(hasUsage: false, mode: .currency))
    }

    // MARK: - Helpers

    private static func makeBucket(
        windowKind: ProviderQuotaWindowKind = .rollingHours,
        usedPercent: Double? = nil,
        remainingValue: Double? = nil,
        resetsAt: Date? = nil,
        unit: ProviderQuotaUnit = .percent
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: "test",
            label: "Test window",
            windowKind: windowKind,
            usedValue: nil,
            limitValue: nil,
            remainingValue: remainingValue,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: unit,
            isEstimated: false
        )
    }

    private static func luminance(of color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return -1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
