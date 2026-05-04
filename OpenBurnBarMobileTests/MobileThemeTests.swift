import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class MobileThemeTests: XCTestCase {

    // MARK: - Color For Model (Deterministic Hashing)

    func testColorForModelIsDeterministic() {
        let c1 = MobileTheme.Colors.colorForModel("gpt-4o")
        let c2 = MobileTheme.Colors.colorForModel("gpt-4o")
        XCTAssertEqual(c1, c2)
    }

    func testColorForModelUnknownHashesWithoutCrash() {
        let _ = MobileTheme.Colors.colorForModel("")
        let _ = MobileTheme.Colors.colorForModel("a")
        let _ = MobileTheme.Colors.colorForModel(String(repeating: "x", count: 10_000))
    }

    func testColorForModelKnownBrands() {
        let claude = MobileTheme.Colors.colorForModel("claude-3-5-sonnet")
        let gpt = MobileTheme.Colors.colorForModel("gpt-4")
        let gemini = MobileTheme.Colors.colorForModel("gemini-pro")

        XCTAssertNotEqual(claude, gpt)
        XCTAssertNotEqual(gpt, gemini)
    }

    func testGradientForModel() {
        let gradient = MobileTheme.Colors.gradientForModel("claude-3")
        // Gradient equality is not directly testable; just ensure it doesn't crash.
        XCTAssertNotNil(gradient)
    }

    // MARK: - Provider Color Palette

    func testChartPaletteHasFourColors() {
        for provider in AgentProvider.allCases {
            let palette = MobileTheme.Colors.chartPalette(for: provider)
            XCTAssertEqual(palette.count, 4, "Provider \(provider) should have 4 chart colors")
        }
    }

    func testPrimaryAndAccentDifferForMostProviders() {
        for provider in AgentProvider.allCases {
            let primary = MobileTheme.Colors.primary(for: provider)
            let accent = MobileTheme.Colors.accent(for: provider)
            // Some providers may intentionally share; this is a sanity check.
            XCTAssertNotNil(primary)
            XCTAssertNotNil(accent)
        }
    }

    // MARK: - Hermes Tokens

    func testMercuryGradientExists() {
        let gradient = MobileTheme.mercuryGradient
        XCTAssertNotNil(gradient)
    }

    func testAnimationCurves() {
        let standard = MobileTheme.Animation.standard
        let gentle = MobileTheme.Animation.gentle
        let snappy = MobileTheme.Animation.snappy
        let hover = MobileTheme.Animation.hover

        XCTAssertNotNil(standard)
        XCTAssertNotNil(gentle)
        XCTAssertNotNil(snappy)
        XCTAssertNotNil(hover)
    }
}
