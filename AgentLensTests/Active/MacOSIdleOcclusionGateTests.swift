import XCTest
@testable import OpenBurnBar

/// Behavioral tripwire for P-PERF-3: verifies the macOS WebGL backdrop
/// render-loop occlusion pause guard via a pure Swift policy seam.
///
/// `OcclusionVisibilityPolicy` is the pure decision function extracted from
/// `KernelBackdropView.Coordinator`: it returns `false` (inactive) when the
/// host window is nil or occluded, and `true` (active) when visible. The
/// Coordinator calls this policy in `syncOcclusionState()` and pushes the
/// result to the JS bundle via `window.__setBackdropActive`.
///
/// The JS-side behavioral proof (rAF cancellation on `__setBackdropActive(false)`)
/// is in `scripts/ci/macos-idle-occlusion-gate.test.mjs`, which loads the real
/// `kernel-backdrop.js` bundle in a mock DOM+rAF harness.
///
/// This Swift test does NOT skip in CI — it tests a pure function with mock
/// NSWindow occlusion states, no source-string matching, no real window required.
@MainActor
final class MacOSIdleOcclusionGateTests: XCTestCase {

    // MARK: - OcclusionVisibilityPolicy: nil window (detached)

    func testPolicy_nilWindow_returnsInactive() {
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(window: nil),
            "A nil window (detached from any window) must yield inactive — the backdrop pauses."
        )
    }

    // MARK: - OcclusionVisibilityPolicy: visible window

    func testPolicy_visibleWindow_returnsActive() {
        let window = TestWindow(occlusionState: .visible)
        XCTAssertTrue(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window),
            "A visible window must yield active — the backdrop renders."
        )
    }

    // MARK: - OcclusionVisibilityPolicy: occluded window

    func testPolicy_occludedWindow_returnsInactive() {
        // .visible is NOT in the occlusion state when the window is fully covered
        let window = TestWindow(occlusionState: [])
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window),
            "An occluded window (no .visible in occlusionState) must yield inactive."
        )
    }

    // MARK: - OcclusionVisibilityPolicy: transition visible → occluded

    func testPolicy_transitionVisibleToOccluded_changesToInactive() {
        let window = TestWindow(occlusionState: .visible)
        XCTAssertTrue(OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window))

        window.occlusionState = []
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window),
            "After the window transitions from visible to occluded, the policy must return inactive."
        )
    }

    // MARK: - OcclusionVisibilityPolicy: transition occluded → visible

    func testPolicy_transitionOccludedToVisible_changesToActive() {
        let window = TestWindow(occlusionState: [])
        XCTAssertFalse(OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window))

        window.occlusionState = .visible
        XCTAssertTrue(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window),
            "After the window transitions from occluded to visible, the policy must return active."
        )
    }

    // MARK: - Guard removal tripwire: policy must exist and be callable

    func testPolicy_existsAndIsCallable() {
        // If OcclusionVisibilityPolicy is removed or renamed, this test fails to compile.
        // That is the tripwire: the policy seam cannot be silently deleted.
        let active = OcclusionVisibilityPolicy.shouldBackdropBeActive(window: TestWindow(occlusionState: .visible))
        let inactive = OcclusionVisibilityPolicy.shouldBackdropBeActive(window: nil)
        XCTAssertTrue(active)
        XCTAssertFalse(inactive)
    }
}

// MARK: - TestWindow: a minimal NSWindow subclass with controllable occlusionState

/// A minimal NSWindow subclass that allows tests to set `occlusionState`
/// without a real window server connection. `occlusionState` is normally
/// read-only; we override it with a stored property.
@MainActor
private final class TestWindow: NSWindow {
    private var _occlusionState: NSWindow.OcclusionState

    init(occlusionState: NSWindow.OcclusionState) {
        _occlusionState = occlusionState
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }

    override var occlusionState: NSWindow.OcclusionState {
        get { _occlusionState }
        set { _occlusionState = newValue }
    }
}
