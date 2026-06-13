import XCTest
import SwiftUI
@testable import OpenBurnBarMobile

// MARK: - Screen Privacy Guard (RR-14)
//
// Locks the masking contract of the Mac-mirror privacy overlay (the iOS
// FLAG_SECURE equivalent) so a future change can't silently expose the mirrored
// Mac surface to an app-switcher snapshot or a screen recording. The state
// machine is a pure value type, so these exercise the decision logic directly
// without standing up a SwiftUI scene.

final class ScreenPrivacyGuardTests: XCTestCase {

    func testActiveAndNotCapturedDoesNotMask() {
        let state = MobileScreenPrivacyState(scenePhase: .active, isCaptured: false)
        XCTAssertFalse(state.shouldMask, "A foreground, un-recorded screen must show the mirror")
        XCTAssertNil(state.maskReason)
    }

    func testInactivePhaseMasksForAppSwitcherSnapshot() {
        // `.inactive` fires before `.background` and is exactly the window in
        // which iOS captures the multitasking snapshot.
        let state = MobileScreenPrivacyState(scenePhase: .inactive, isCaptured: false)
        XCTAssertTrue(state.shouldMask, "Leaving .active must mask before the app-switcher snapshot is taken")
        XCTAssertEqual(state.maskReason, .backgrounded)
    }

    func testBackgroundPhaseMasks() {
        let state = MobileScreenPrivacyState(scenePhase: .background, isCaptured: false)
        XCTAssertTrue(state.shouldMask)
        XCTAssertEqual(state.maskReason, .backgrounded)
    }

    func testScreenCaptureMasksWhileActive() {
        // Screen recording / mirroring leaks even though the app stays active.
        let state = MobileScreenPrivacyState(scenePhase: .active, isCaptured: true)
        XCTAssertTrue(state.shouldMask, "An active but recorded screen must still be masked")
        XCTAssertEqual(state.maskReason, .screenCaptured)
    }

    func testCaptureReasonTakesPrecedenceOverBackground() {
        // Both vectors active at once: the recording-specific copy is the more
        // actionable message, so capture wins the reason.
        let state = MobileScreenPrivacyState(scenePhase: .inactive, isCaptured: true)
        XCTAssertTrue(state.shouldMask)
        XCTAssertEqual(state.maskReason, .screenCaptured)
    }

    func testDefaultStateIsUnmasked() {
        // A guard installed while already foregrounded and not captured starts
        // visible — no flash of the privacy cover on appear.
        let state = MobileScreenPrivacyState()
        XCTAssertFalse(state.shouldMask)
        XCTAssertNil(state.maskReason)
    }

    func testUnmaskRestoresWhenReturningToActiveAndCaptureStops() {
        var state = MobileScreenPrivacyState(scenePhase: .background, isCaptured: true)
        XCTAssertTrue(state.shouldMask)

        // Capture stops first while still backgrounded — still masked.
        state.isCaptured = false
        XCTAssertTrue(state.shouldMask)
        XCTAssertEqual(state.maskReason, .backgrounded)

        // Return to the foreground — now fully unmasked, mirror resumes instantly.
        state.scenePhase = .active
        XCTAssertFalse(state.shouldMask)
        XCTAssertNil(state.maskReason)
    }
}
