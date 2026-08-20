import AppKit
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// Covers the `LiquidGlassTransparency` preference mapping that every glass
/// surface routes through (`Theme/LiquidGlass.swift`). The iOS app carries
/// a lockstep mirror of both the implementation and this suite
/// (`OpenBurnBarMobileTests/LiquidGlassTransparencyTests.swift`).
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

    /// `.clear` now requires WWDC25 s219's preconditions, not merely a positive slider.
    ///
    /// The old contract selected `.clear` at `t > 0.001` over any background. `.clear`
    /// has no adaptive behaviour — no light/dark flip, no shadow adaptation — so that
    /// produced washed chrome the moment the slider left centre. It is gated on the
    /// media-rich condition and a decisive preference.
    func testClearVariantRequiresMediaRichContentAndADecisivePreference() {
        // Never on the negative (frost) side, whatever is behind it.
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(-1, overMediaRichContent: true))
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(-0.01, overMediaRichContent: true))

        // A nudge is not a decision — this is the case that used to pick `.clear`.
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(0.01, overMediaRichContent: true))

        // Decisive, and over the live kernel: the one sanctioned case.
        XCTAssertTrue(LiquidGlassTransparency.usesClearGlass(0.9, overMediaRichContent: true))
        XCTAssertTrue(LiquidGlassTransparency.usesClearGlass(1, overMediaRichContent: true))

        // No media behind it: `.clear` is never correct, even at full preference.
        XCTAssertFalse(LiquidGlassTransparency.usesClearGlass(1, overMediaRichContent: false))
    }

    /// The dimming layer is condition (2) of the same rule, so whenever `.clear` is
    /// selected the scrim must be substantial enough to actually carry legibility.
    func testClearAlwaysCarriesADimmingLayer() {
        let defaults = UserDefaults(suiteName: "burnbar.clearglass.test")!
        defaults.set(true, forKey: LiquidGlassTransparency.mediaRichBackdropKey)
        defer { defaults.removeSuite(named: "burnbar.clearglass.test") }

        XCTAssertTrue(LiquidGlassTransparency.isOverMediaRichContent(defaults: defaults))
        XCTAssertFalse(
            LiquidGlassTransparency.isOverMediaRichContent(defaults: UserDefaults(suiteName: "burnbar.empty")!),
            "an unset preference must not imply media-rich content"
        )
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

    func testClearBridgeScrimOnlyExistsWhereClearGlassDoes() {
        // Frost side: never a bridge.
        XCTAssertEqual(
            LiquidGlassTransparency.clearBridgeScrimOpacity(-0.5, overMediaRichContent: true), 0
        )
        // Below the threshold the plate is `.regular`, which is adaptive and needs no
        // dimming layer. Under the old contract this was already `.clear` at 0.05 —
        // washed chrome with a 0.06 scrim trying to rescue it.
        XCTAssertEqual(
            LiquidGlassTransparency.clearBridgeScrimOpacity(0.05, overMediaRichContent: true), 0
        )
        // No media behind it: `.clear` is never selected, so no bridge either.
        XCTAssertEqual(
            LiquidGlassTransparency.clearBridgeScrimOpacity(1, overMediaRichContent: false), 0
        )

        // Where `.clear` *is* legitimate the scrim exists and eases off toward full
        // clear, but never below the floor that carries legibility.
        let justOver = LiquidGlassTransparency.clearBridgeScrimOpacity(0.6, overMediaRichContent: true)
        let full = LiquidGlassTransparency.clearBridgeScrimOpacity(1, overMediaRichContent: true)
        XCTAssertGreaterThan(justOver, full)
        XCTAssertEqual(full, 0.12, accuracy: 0.0001)
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

    // MARK: - LiquidGlassStyle → Glass resolution (macOS 26+)

    func testStyleResolvesVariantAndCompositionFromTransparency() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Glass requires macOS 26")
        }
        XCTAssertEqual(LiquidGlassStyle.regular.resolvedGlass(at: 0, overMediaRichContent: true), Glass.regular)
        // `.clear` is no longer selected by the slider alone. Without the kernel
        // backdrop running there is no media-rich content behind the plate, so the
        // first of WWDC25 s219's three preconditions fails and `.regular` is correct —
        // this is the case that used to produce washed chrome.
        XCTAssertEqual(LiquidGlassStyle.regular.resolvedGlass(at: 0.5, overMediaRichContent: true), Glass.regular)
        XCTAssertEqual(LiquidGlassStyle.regular.resolvedGlass(at: -0.5, overMediaRichContent: true), Glass.regular)
        XCTAssertEqual(
            LiquidGlassStyle.regular.interactive().resolvedGlass(at: 0),
            Glass.regular.interactive()
        )
        XCTAssertEqual(
            LiquidGlassStyle.regular.tint(.red).interactive().resolvedGlass(at: 0, overMediaRichContent: true),
            Glass.regular.tint(.red).interactive()
        )
        // Both branches pinned explicitly. This previously asserted `.clear` while
        // routing through the `UserDefaults`-reading convenience, so it was green only
        // on a machine with the kernel backdrop switched on and would have failed CI.
        XCTAssertEqual(
            LiquidGlassStyle.regular.tint(.red).interactive()
                .resolvedGlass(at: 1, overMediaRichContent: true),
            Glass.clear.tint(.red).interactive()
        )
        XCTAssertEqual(
            LiquidGlassStyle.regular.tint(.red).interactive()
                .resolvedGlass(at: 1, overMediaRichContent: false),
            Glass.regular.tint(.red).interactive(),
            "without media-rich content behind it, .clear is never correct"
        )
    }

    func testWindowBlendUsesBehindWindowMaterial() {
        let view = LiquidGlassWindowBlend.makeVisualEffectView()

        XCTAssertEqual(view.material, .underWindowBackground)
        XCTAssertEqual(view.blendingMode, .behindWindow)
        XCTAssertEqual(view.state, .active)
    }
}
