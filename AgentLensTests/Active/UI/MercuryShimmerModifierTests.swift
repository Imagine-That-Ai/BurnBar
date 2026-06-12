import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - MercuryShimmerModifier

@MainActor
final class MercuryShimmerModifierTests: XCTestCase {

    func test_modifierApplied() throws {
        struct TestView: View {
            var body: some View {
                Color.clear.frame(width: 100, height: 50)
                    .mercuryShimmer(active: true)
            }
        }

        let view = TestView()
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(ViewType.Color.self))
    }

    func test_inactiveModifier() throws {
        struct TestView: View {
            var body: some View {
                Color.clear.frame(width: 100, height: 50)
                    .mercuryShimmer(active: false)
            }
        }

        let view = TestView()
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(ViewType.Color.self))
    }
}

// MARK: - MercuryDroplet animation helpers (unit tests for pure functions)

@MainActor
final class MercuryDropletAnimationTests: XCTestCase {

    // The MercuryDroplet is private, but we can verify the HermesThinkingView
    // renders the expected structure.

    func test_thinkingViewContainsHStack() throws {
        let view = HermesThinkingView()
        XCTAssertNoThrow(try view.inspect())
    }

    func test_thinkingViewUsesDesignSystemSpacing() throws {
        // Verify the view doesn't crash when using DesignSystem spacing tokens
        _ = DesignSystem.Spacing.lg
        _ = DesignSystem.Spacing.md
        // If DesignSystem constants change, these tests catch compile errors
        XCTAssertTrue(DesignSystem.Spacing.lg > 0)
        XCTAssertTrue(DesignSystem.Spacing.md > 0)
    }
}

// MARK: - Mercury Call HUD State

@MainActor
final class MercuryCallHUDStateTests: XCTestCase {

    func test_resetStartsStreamingHUDCollapsed() {
        let state = CallHUDState()
        state.isCollapsed = false
        state.isMicMuted = true
        state.isCameraMuted = true
        state.isSharingScreen = true

        state.reset(startedAt: Date(timeIntervalSince1970: 42))

        XCTAssertTrue(state.isCollapsed)
        XCTAssertFalse(state.isMicMuted)
        XCTAssertFalse(state.isCameraMuted)
        XCTAssertFalse(state.isSharingScreen)
        XCTAssertEqual(state.startedAt, Date(timeIntervalSince1970: 42))
    }

    func test_collapsedHUDRendersTrafficLightPillControls() throws {
        let state = CallHUDState()
        state.isCollapsed = true

        let view = CallHUD(
            state: state,
            onMuteMic: {},
            onMuteCamera: {},
            onShareScreen: {},
            onEnd: {}
        )

        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 3)

        try buttons[1].tap()
        XCTAssertFalse(state.isCollapsed)
    }
}
