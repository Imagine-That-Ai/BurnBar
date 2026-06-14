#if canImport(UIKit)
import XCTest
import CoreGraphics
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class ScreenShareSmartTextDoubleTapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Double-tap detection

    func testSecondTapWithinWindowAndRadiusIsDoubleTap() {
        let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
            previousAt: now,
            previousPoint: CGPoint(x: 100, y: 100),
            currentPoint: CGPoint(x: 108, y: 96),
            now: now.addingTimeInterval(0.18),
            maxDistance: 40
        )
        XCTAssertTrue(isDoubleTap)
    }

    func testFirstEverTapIsNotDoubleTap() {
        let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
            previousAt: nil,
            previousPoint: nil,
            currentPoint: CGPoint(x: 100, y: 100),
            now: now,
            maxDistance: 40
        )
        XCTAssertFalse(isDoubleTap)
    }

    func testTapTooSlowIsNotDoubleTap() {
        let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
            previousAt: now,
            previousPoint: CGPoint(x: 100, y: 100),
            currentPoint: CGPoint(x: 100, y: 100),
            now: now.addingTimeInterval(0.9),
            maxDistance: 40
        )
        XCTAssertFalse(isDoubleTap)
    }

    func testTapTooFarIsNotDoubleTap() {
        let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
            previousAt: now,
            previousPoint: CGPoint(x: 100, y: 100),
            currentPoint: CGPoint(x: 260, y: 240),
            now: now.addingTimeInterval(0.15),
            maxDistance: 40
        )
        XCTAssertFalse(isDoubleTap)
    }

    func testBoundaryIntervalCountsAsDoubleTap() {
        let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
            previousAt: now,
            previousPoint: CGPoint.zero,
            currentPoint: CGPoint.zero,
            now: now.addingTimeInterval(ScreenShareControlInputPolicy.doubleTapMaxInterval),
            maxDistance: 40
        )
        XCTAssertTrue(isDoubleTap)
    }

    func testNegativeElapsedIsNotDoubleTap() {
        // Guards against clock skew where the second sample predates the first.
        let isDoubleTap = ScreenShareControlInputPolicy.isDoubleTap(
            previousAt: now,
            previousPoint: CGPoint(x: 100, y: 100),
            currentPoint: CGPoint(x: 100, y: 100),
            now: now.addingTimeInterval(-0.05),
            maxDistance: 40
        )
        XCTAssertFalse(isDoubleTap)
    }

    func testViewerQuickZoomOnlyRunsInViewMode() {
        XCTAssertTrue(ScreenShareViewportGesturePolicy.allowsQuickZoom(interactionMode: .view))
        XCTAssertFalse(ScreenShareViewportGesturePolicy.allowsQuickZoom(interactionMode: .control))
        XCTAssertFalse(ScreenShareViewportGesturePolicy.allowsQuickZoom(interactionMode: .trackpad))
        XCTAssertFalse(ScreenShareViewportGesturePolicy.allowsQuickZoom(interactionMode: .coPilot))
    }

    func testControllerMirrorDefaultsToControlModeSoTapsBecomeInput() {
        XCTAssertEqual(
            ScreenShareInteractionModePolicy.defaultMode(controlInputEnabled: true),
            .control
        )
    }

    func testWatcherMirrorDefaultsToViewModeForPanAndZoom() {
        XCTAssertEqual(
            ScreenShareInteractionModePolicy.defaultMode(controlInputEnabled: false),
            .view
        )
    }

    // MARK: - Coach-mark visibility

    func testCoachShowsWhenTextFieldFocusedAndKeyboardDown() {
        XCTAssertTrue(
            ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
                learned: false,
                controlInputEnabled: true,
                isTyping: false,
                isCoPilotMode: false,
                hasActiveTextFocus: true
            )
        )
    }

    func testCoachHiddenAfterLearned() {
        XCTAssertFalse(
            ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
                learned: true,
                controlInputEnabled: true,
                isTyping: false,
                isCoPilotMode: false,
                hasActiveTextFocus: true
            )
        )
    }

    func testCoachHiddenWhileTyping() {
        XCTAssertFalse(
            ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
                learned: false,
                controlInputEnabled: true,
                isTyping: true,
                isCoPilotMode: false,
                hasActiveTextFocus: true
            )
        )
    }

    func testCoachHiddenWhenControlDisabled() {
        XCTAssertFalse(
            ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
                learned: false,
                controlInputEnabled: false,
                isTyping: false,
                isCoPilotMode: false,
                hasActiveTextFocus: true
            )
        )
    }

    func testCoachHiddenInCoPilotMode() {
        XCTAssertFalse(
            ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
                learned: false,
                controlInputEnabled: true,
                isTyping: false,
                isCoPilotMode: true,
                hasActiveTextFocus: true
            )
        )
    }

    func testCoachHiddenWithoutActiveTextFocus() {
        XCTAssertFalse(
            ScreenShareSmartTextActivationPolicy.shouldShowDoubleTapCoach(
                learned: false,
                controlInputEnabled: true,
                isTyping: false,
                isCoPilotMode: false,
                hasActiveTextFocus: false
            )
        )
    }

    func testFocusedRectWinsOverTappedPointForRefinement() {
        let tapped = CGPoint(x: 0.18, y: 0.72)
        let focusedRect = HermesRealtimeRelayNormalizedRect(x: 0.45, y: 0.5, width: 0.2, height: 0.04)
        XCTAssertEqual(
            ScreenShareSmartTextTargetPolicy.preferredTarget(
                focusedRect: focusedRect,
                tappedPoint: tapped
            ),
            .focusedRect(focusedRect)
        )
    }

    func testTappedPointUsedUntilFocusRectArrives() {
        let tapped = CGPoint(x: 0.18, y: 0.72)
        XCTAssertEqual(
            ScreenShareSmartTextTargetPolicy.preferredTarget(
                focusedRect: nil,
                tappedPoint: tapped
            ),
            .tappedPoint(tapped)
        )
    }

    func testFocusContextBeforeGestureGraceIsIgnored() {
        let gestureStartedAt = now
        XCTAssertTrue(
            ScreenShareSmartTextTargetPolicy.acceptsFocusContext(
                receivedAt: gestureStartedAt.addingTimeInterval(-0.04),
                gestureStartedAt: gestureStartedAt
            )
        )
        XCTAssertFalse(
            ScreenShareSmartTextTargetPolicy.acceptsFocusContext(
                receivedAt: gestureStartedAt.addingTimeInterval(-0.5),
                gestureStartedAt: gestureStartedAt
            )
        )
    }

    func testGenericSmartZoomDefersDuringDoubleTapWindowInControlMode() {
        XCTAssertTrue(
            ScreenShareSmartTextTargetPolicy.shouldDeferGenericSmartZoom(
                interactionMode: .control,
                lastControlClickAt: now,
                now: now.addingTimeInterval(0.12)
            )
        )
        XCTAssertFalse(
            ScreenShareSmartTextTargetPolicy.shouldDeferGenericSmartZoom(
                interactionMode: .control,
                lastControlClickAt: now,
                now: now.addingTimeInterval(ScreenShareSmartTextTargetPolicy.genericSmartZoomDelay + 0.01)
            )
        )
        XCTAssertFalse(
            ScreenShareSmartTextTargetPolicy.shouldDeferGenericSmartZoom(
                interactionMode: .view,
                lastControlClickAt: now,
                now: now.addingTimeInterval(0.12)
            )
        )
    }

    func testExistingFocusedRectKeepsSecondTapFromRetargetingMovingViewport() {
        let focusedRect = HermesRealtimeRelayNormalizedRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05)
        let secondTapMappedAfterFirstZoom = CGPoint(x: 0.5, y: 0.5)

        XCTAssertEqual(
            ScreenShareSmartTextTargetPolicy.preferredTarget(
                focusedRect: focusedRect,
                tappedPoint: secondTapMappedAfterFirstZoom
            ),
            .focusedRect(focusedRect)
        )
    }

    func testTinyRepeatedFramingDeltasAreIgnored() {
        XCTAssertFalse(
            ScreenShareSmartTextTargetPolicy.shouldApply(
                currentScale: 2.4,
                currentOffset: CGSize(width: 10, height: -20),
                nextScale: 2.4005,
                nextOffset: CGSize(width: 10.2, height: -20.2)
            )
        )
        XCTAssertTrue(
            ScreenShareSmartTextTargetPolicy.shouldApply(
                currentScale: 2.4,
                currentOffset: CGSize(width: 10, height: -20),
                nextScale: 3.2,
                nextOffset: CGSize(width: 18, height: -80)
            )
        )
    }

    // MARK: - Keyboard-aware framing

    func testZoomLiftsTargetAboveKeyboard() {
        let size = CGSize(width: 400, height: 900)
        let contentRect = CGRect(x: 0, y: 0, width: 400, height: 900)
        let point = HermesRealtimeRelayNormalizedPoint(x: 0.5, y: 0.5)
        let noKeyboard = ScreenShareSmartZoomReducer.centerPointDecision(
            normalizedPoint: point, viewportSize: size, contentRect: contentRect, scale: 2.4, bottomInset: 0
        )
        let withKeyboard = ScreenShareSmartZoomReducer.centerPointDecision(
            normalizedPoint: point, viewportSize: size, contentRect: contentRect, scale: 2.4, bottomInset: 360
        )
        // A keyboard shifts the content up (more-negative Y offset) so the centered
        // target lands in the visible area above the keyboard, not behind it.
        XCTAssertLessThan(withKeyboard.offset.height, noKeyboard.offset.height)
        XCTAssertEqual(withKeyboard.scale, noKeyboard.scale, accuracy: 0.0001)
    }

    func testClampPinsOffsetAtRestButAllowsKeyboardLift() {
        let size = CGSize(width: 400, height: 900)
        // At rest (scale 1, no keyboard) vertical offset is pinned to zero.
        let pinned = ScreenShareViewportState.clamp(
            offset: CGSize(width: 0, height: -100), scale: 1, in: size, bottomInset: 0
        )
        XCTAssertEqual(pinned.height, 0, accuracy: 0.0001)
        // With a keyboard, the content may ride up by half the covered height.
        let lifted = ScreenShareViewportState.clamp(
            offset: CGSize(width: 0, height: -100), scale: 1, in: size, bottomInset: 300
        )
        XCTAssertEqual(lifted.height, -100, accuracy: 0.0001)
        let clampedToLiftLimit = ScreenShareViewportState.clamp(
            offset: CGSize(width: 0, height: -400), scale: 1, in: size, bottomInset: 300
        )
        XCTAssertEqual(clampedToLiftLimit.height, -150, accuracy: 0.0001)
    }

    func testKeyboardInsetIsCappedToVisibleViewport() {
        XCTAssertEqual(
            ScreenShareKeyboardFramePolicy.cappedInset(rawOverlap: 700, viewportHeight: 900),
            540,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScreenShareKeyboardFramePolicy.cappedInset(rawOverlap: -12, viewportHeight: 900),
            0,
            accuracy: 0.0001
        )
    }

    func testKeyboardOverlapUsesViewIntersection() {
        let view = CGRect(x: 0, y: 100, width: 400, height: 700)
        let keyboard = CGRect(x: 0, y: 520, width: 400, height: 380)
        XCTAssertEqual(
            ScreenShareKeyboardOverlapPolicy.overlap(keyboardFrame: keyboard, viewFrame: view),
            280,
            accuracy: 0.0001
        )
        let hiddenKeyboard = CGRect(x: 0, y: 900, width: 400, height: 380)
        XCTAssertEqual(
            ScreenShareKeyboardOverlapPolicy.overlap(keyboardFrame: hiddenKeyboard, viewFrame: view),
            0,
            accuracy: 0.0001
        )
    }
}
#endif
