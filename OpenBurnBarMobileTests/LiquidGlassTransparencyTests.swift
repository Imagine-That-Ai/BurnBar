import SwiftUI
import XCTest
@testable import OpenBurnBarMobile

/// Covers the `LiquidGlassTransparency` preference mapping that every glass
/// surface routes through (`Theme/LiquidGlass.swift`). The macOS app carries
/// a lockstep mirror of both the implementation and this suite
/// (`AgentLensTests/Active/LiquidGlassTransparencyTests.swift`).
final class LiquidGlassTransparencyTests: XCTestCase {

    // MARK: - effective(_:reduceTransparency:)

    func testEffectiveClampsToRange() {
        XCTAssertEqual(LiquidGlassTransparency.effective(5, reduceTransparency: false), 1)
        XCTAssertEqual(LiquidGlassTransparency.effective(-5, reduceTransparency: false), -1)
        XCTAssertEqual(LiquidGlassTransparency.effective(0.4, reduceTransparency: false), 0.4)
    }

    func testEffectiveNeutralizesNonFiniteValues() {
        XCTAssertEqual(LiquidGlassTransparency.effective(.nan, reduceTransparency: false), 0)
        XCTAssertEqual(LiquidGlassTransparency.effective(.infinity, reduceTransparency: false), 0)
        XCTAssertEqual(LiquidGlassTransparency.effective(-.infinity, reduceTransparency: true), 0)
    }

    func testReduceTransparencyBlocksClearerButAllowsFrostier() {
        // Clearer would fight the accessibility setting — it resolves to system.
        XCTAssertEqual(LiquidGlassTransparency.effective(0.8, reduceTransparency: true), 0)
        // Frostier only adds opacity, which is what the setting asks for.
        XCTAssertEqual(LiquidGlassTransparency.effective(-0.8, reduceTransparency: true), -0.8)
        XCTAssertEqual(LiquidGlassTransparency.effective(0, reduceTransparency: true), 0)
    }

    // MARK: - System-default render invariant

    func testZeroAdjustmentLeavesSystemRenderUntouched() {
        // At t == 0 every layer the adjustment can add must be inert, so the
        // default render is exactly what the OS draws.
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(0))
        XCTAssertEqual(LiquidGlassTransparency.frostScrimOpacity(0), 0)
        XCTAssertEqual(LiquidGlassTransparency.clearBridgeScrimOpacity(0), 0)
        XCTAssertEqual(LiquidGlassTransparency.fallbackPlateOpacity(0), 1)
    }

    // MARK: - Variant selection

    func testClearVariantOnlyForPositiveAdjustment() {
        // `.clear` now requires WWDC25 s219's preconditions, not merely a positive
        // slider: media-rich content behind it AND a decisive preference. Kept in
        // lockstep with the macOS suite, which is this file's stated contract.
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(-1, overMediaRichContent: true))
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(-0.01, overMediaRichContent: true))
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(0.01, overMediaRichContent: true))
        XCTAssertTrue(LiquidGlassTransparency.usesClearGlass(1, overMediaRichContent: true))
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(1, overMediaRichContent: false))
    }

    // MARK: - Frost scrim

    func testFrostScrimGrowsMonotonicallyTowardFrosted() {
        XCTAssertEqual(LiquidGlassTransparency.frostScrimOpacity(0.5), 0)
        let mild = LiquidGlassTransparency.frostScrimOpacity(-0.25)
        let strong = LiquidGlassTransparency.frostScrimOpacity(-0.75)
        let max = LiquidGlassTransparency.frostScrimOpacity(-1)
        XCTAssertGreaterThan(mild, 0)
        XCTAssertGreaterThan(strong, mild)
        XCTAssertEqual(max, 0.9, accuracy: 0.0001)
    }

    // MARK: - Clear bridge scrim

    func testClearBridgeScrimFadesOutTowardFullClear() {
        XCTAssertEqual(
            LiquidGlassTransparency.clearBridgeScrimOpacity(-0.5, overMediaRichContent: true), 0
        )
        // Below the threshold the plate is `.regular`, which is adaptive and needs no
        // dimming layer at all.
        XCTAssertEqual(
            LiquidGlassTransparency.clearBridgeScrimOpacity(0.05, overMediaRichContent: true), 0
        )
        let nearCenter = LiquidGlassTransparency.clearBridgeScrimOpacity(0.6, overMediaRichContent: true)
        let nearClear = LiquidGlassTransparency.clearBridgeScrimOpacity(0.95, overMediaRichContent: true)
        XCTAssertGreaterThan(nearCenter, nearClear)
        // A small floor remains at full clear so the plate doesn't vanish.
        XCTAssertEqual(
            LiquidGlassTransparency.clearBridgeScrimOpacity(1, overMediaRichContent: true),
            0.12,
            accuracy: 0.0001
        )
    }

    // MARK: - Fallback plate (pre-26 systems)

    func testFallbackPlateFadesOnlyTowardClear() {
        XCTAssertEqual(LiquidGlassTransparency.fallbackPlateOpacity(-1), 1)
        XCTAssertEqual(LiquidGlassTransparency.fallbackPlateOpacity(-0.3), 1)
        let half = LiquidGlassTransparency.fallbackPlateOpacity(0.5)
        let full = LiquidGlassTransparency.fallbackPlateOpacity(1)
        XCTAssertLessThan(half, 1)
        XCTAssertLessThan(full, half)
        // Even at full clear a faint plate remains so content stays legible.
        XCTAssertGreaterThan(full, 0.2)
    }

    // MARK: - LiquidGlassStyle → Glass resolution (iOS 26+)

    func testStyleResolvesVariantAndCompositionFromTransparency() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Glass requires iOS 26")
        }
        XCTAssertEqual(LiquidGlassStyle.regular.resolvedGlass(at: 0, overMediaRichContent: true), Glass.regular)
        XCTAssertEqual(LiquidGlassStyle.regular.resolvedGlass(at: 0.5, overMediaRichContent: true), Glass.regular)
        XCTAssertEqual(LiquidGlassStyle.regular.resolvedGlass(at: -0.5), Glass.regular)
        XCTAssertEqual(
            LiquidGlassStyle.regular.interactive().resolvedGlass(at: 0),
            Glass.regular.interactive()
        )
        XCTAssertEqual(
            LiquidGlassStyle.regular.tint(.red).interactive().resolvedGlass(at: 0),
            Glass.regular.tint(.red).interactive()
        )
        XCTAssertEqual(
            LiquidGlassStyle.regular.tint(.red).interactive().resolvedGlass(at: 1),
            Glass.clear.tint(.red).interactive()
        )
    }
}
