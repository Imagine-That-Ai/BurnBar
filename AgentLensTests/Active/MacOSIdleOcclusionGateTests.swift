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
/// This Swift test does NOT skip in CI — it exercises the policy's input tuple
/// directly, without source-string matching or a real window server connection.
@MainActor
final class MacOSIdleOcclusionGateTests: XCTestCase {

    func testPerformanceGateLoadURLPinsFullMotionWithoutChangingNormalLoads() throws {
        let indexURL = try XCTUnwrap(URL(string: "file:///tmp/KernelBackdrop/index.html"))
        let production = KernelBackdropView.Coordinator.loadURL(
            indexURL: indexURL,
            initialKernel: "boids",
            performanceGate: false
        )
        let certification = KernelBackdropView.Coordinator.loadURL(
            indexURL: indexURL,
            initialKernel: "boids",
            performanceGate: true
        )

        XCTAssertEqual(production.fragment, "boids")
        XCTAssertEqual(
            URLComponents(url: production, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "maxFps", value: "30")],
            "Tahoe rAF is uncapped; the kernel must boot already paced"
        )
        XCTAssertEqual(certification.fragment, "boids")
        XCTAssertEqual(
            URLComponents(url: certification, resolvingAgainstBaseURL: false)?.queryItems,
            [
                URLQueryItem(name: "maxFps", value: "60"),
                URLQueryItem(name: "motion", value: "full")
            ]
        )
    }

    // MARK: - OcclusionVisibilityPolicy: nil window (detached)

    func testPolicy_nilWindow_returnsInactive() {
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(window: nil),
            "A nil window (detached from any window) must yield inactive — the backdrop pauses."
        )
    }

    func testPolicy_performanceGateTrueOverride_activatesOtherwiseOccludedState() {
        XCTAssertTrue(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: [],
                performanceGateOverride: true
            ),
            "An explicit performance-gate enable must take precedence over ordinary occluded-state behavior."
        )
    }

    // MARK: - OcclusionVisibilityPolicy: live window state

    func testPolicy_performanceGateFalseOverride_deactivatesOtherwiseVisibleState() {
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                performanceGateOverride: false
            ),
            "An explicit performance-gate disable must take precedence over ordinary visible-state behavior."
        )
    }

    func testPolicy_nilPerformanceGateOverride_preservesOrdinaryStateBehavior() {
        XCTAssertTrue(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                performanceGateOverride: nil
            )
        )
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: [],
                performanceGateOverride: nil
            )
        )
    }

    func testPolicy_visibleWindow_returnsActive() {
        XCTAssertTrue(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible
            )
        )
    }

    func testPolicy_occludedWindow_returnsInactive() {
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: []
            )
        )
    }

    func testPolicy_orderedOffWindowWithStaleVisibleBit_returnsInactive() {
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: false,
                isMiniaturized: false,
                occlusionState: .visible
            ),
            "An ordered-off window must pause even while AppKit retains a stale .visible bit."
        )
    }

    func testPolicy_miniaturizedWindowWithStaleVisibleBit_returnsInactive() {
        XCTAssertFalse(
            OcclusionVisibilityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: true,
                occlusionState: .visible
            ),
            "A minimized window must pause even while AppKit retains a stale .visible bit."
        )
    }

    // MARK: - Guard removal tripwire: policy must exist and be callable

    func testActivityPolicy_contentOcclusionPausesVisibleWindow() {
        XCTAssertFalse(
            KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                opaqueCoverage: 0.97,
                windowHasSheet: false
            )
        )
        XCTAssertTrue(
            KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                opaqueCoverage: 0,
                windowHasSheet: false
            )
        )
    }

    func testPolicy_existsAndIsCallable() {
        // If OcclusionVisibilityPolicy is removed or renamed, this test fails to compile.
        // That is the tripwire: the policy seam cannot be silently deleted.
        let active = OcclusionVisibilityPolicy.shouldBackdropBeActive(
            isVisible: true,
            isMiniaturized: false,
            occlusionState: .visible
        )
        let inactive = OcclusionVisibilityPolicy.shouldBackdropBeActive(window: nil)
        XCTAssertTrue(active)
        XCTAssertFalse(inactive)
    }
}
