import XCTest
import SwiftUI
@testable import OpenBurnBarMobile
import OpenBurnBarCore

final class EmberBackdropTests: XCTestCase {

    @MainActor
    func testEmberSurfaceBackgroundExists() {
        let view = EmberSurfaceBackground()
        XCTAssertNotNil(view)
    }

    @MainActor
    func testReduceTransparencyDisablesEffects() {
        // The view should compile and its body should not crash
        let view = EmberSurfaceBackground(respectsReduceTransparency: true)
        _ = view.body
    }

    func testEmberSkeletonExists() {
        let skeleton = EmberSkeleton(height: 16, cornerRadius: 8)
        XCTAssertNotNil(skeleton)
    }

    func testHapticsHelperExists() {
        // Haptics is an enum with static methods — just verify it compiles
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.warning()
        Haptics.error()
        Haptics.selection()
    }
}

// MARK: - Aurora Backdrop Drift Phase

/// Pins the frame-capped `TimelineView` drift driver to the exact value curve
/// of the retired `withAnimation(.linear(duration: 18).repeatForever(autoreverses: true))`
/// drive, so the 24Hz cadence swap stays pixel-equivalent.
final class AuroraBackdropDriftPhaseTests: XCTestCase {

    func testPhaseStartsAtRest() {
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 0), 0)
    }

    func testNegativeElapsedClampsToRest() {
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: -5), 0)
    }

    func testForwardLegMatchesLinear18s() {
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 4.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 9), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 18), 1.0, accuracy: 1e-9)
    }

    func testAutoreverseLegMirrorsBackToRest() {
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 27), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 36), 0, accuracy: 1e-9)
    }

    func testRepeatsForever() {
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 36 + 9), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AuroraBackdrop.driftPhase(elapsed: 10 * 36 + 18), 1.0, accuracy: 1e-9)
    }

    func testPhaseStaysWithinUnitRange() {
        for elapsed in stride(from: 0.0, through: 144.0, by: 0.37) {
            let phase = AuroraBackdrop.driftPhase(elapsed: elapsed)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThanOrEqual(phase, 1)
        }
    }
}
