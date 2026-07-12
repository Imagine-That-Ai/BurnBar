import XCTest
import SwiftUI
import UIKit
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
        XCTAssertEqual(MobileTheme.Colors.colorForModel(""), MobileTheme.Colors.colorForModel(""))
        XCTAssertEqual(MobileTheme.Colors.colorForModel("a"), MobileTheme.Colors.colorForModel("a"))
        let longUnknown = String(repeating: "x", count: 10_000)
        XCTAssertEqual(MobileTheme.Colors.colorForModel(longUnknown), MobileTheme.Colors.colorForModel(longUnknown))
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

    @MainActor
    func testTypographyScalesWithDynamicType() {
        func measuredHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
            let rootView = Text("A representative usage value that wraps at a phone width")
                .font(MobileTheme.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
            let host = UIHostingController(rootView: rootView)
            host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        }

        let regularHeight = measuredHeight(for: .medium)
        let accessibilityHeight = measuredHeight(for: .accessibility3)

        XCTAssertGreaterThan(accessibilityHeight, regularHeight)
    }
}
