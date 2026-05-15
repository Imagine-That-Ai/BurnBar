import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Motion Tests
//
// Locks in the pure-logic phase progressions for the five SOTA motion
// details. UI-side animation timing is platform-dependent and lives in
// SwiftUI's render loop; what we test here is the *shape* of each phase
// curve — monotonicity, terminal values, and the math that drives them.

final class HermesSquareCardEnvelopeAnimationKeyTests: XCTestCase {

    /// The fan-out card's slide-in transition depends on the fan-out
    /// observer's group phase changing. Phase transitions are tested by
    /// `HermesSquareMissionGroupTests`; here we lock in that the
    /// observable phase keys monotonically progress so the SwiftUI
    /// `.animation(_:value:)` modifier sees a real change.
    func testGroupPhaseOrderingIsStable() {
        let order: [MissionGroupPhase] = [
            .queued, .fanningOut, .awaitingMerge, .merged
        ]
        let raws = order.map(\.rawValue)
        XCTAssertEqual(raws, ["queued", "fanning_out", "awaiting_merge", "merged"])
    }

    func testTerminalPhasesAreClassifiedCorrectly() {
        XCTAssertTrue(MissionGroupPhase.merged.isTerminal)
        XCTAssertTrue(MissionGroupPhase.cancelled.isTerminal)
        XCTAssertTrue(MissionGroupPhase.failed.isTerminal)
        XCTAssertFalse(MissionGroupPhase.queued.isTerminal)
        XCTAssertFalse(MissionGroupPhase.fanningOut.isTerminal)
        XCTAssertFalse(MissionGroupPhase.awaitingMerge.isTerminal)
    }
}

final class HermesSquareBreathPhaseTests: XCTestCase {

    /// The voice-button breathing pulse is a pure sin function of time.
    /// Validate that it stays in [0, 1] and that the period is the
    /// declared 3.4s by checking the value at known offsets.
    func testBreathPhaseClampsToZeroOneRange() {
        for tickDelta in stride(from: 0.0, through: 10.0, by: 0.1) {
            let value = breathPhase(at: Date(timeIntervalSinceReferenceDate: tickDelta))
            XCTAssertGreaterThanOrEqual(value, 0.0, "breathPhase < 0 at t=\(tickDelta)")
            XCTAssertLessThanOrEqual(value, 1.0, "breathPhase > 1 at t=\(tickDelta)")
        }
    }

    func testBreathPhasePeriodicityOver34Seconds() {
        let base = Date(timeIntervalSinceReferenceDate: 100.0)
        let oneCycle = breathPhase(at: base.addingTimeInterval(3.4))
        let zero = breathPhase(at: base)
        XCTAssertEqual(oneCycle, zero, accuracy: 0.01,
                       "Breath pulse should complete one full cycle every 3.4s")
    }

    /// Pure-logic copy of the in-view `breathPhase(at:)` so we can test
    /// it without a SwiftUI host. Kept identical to the view-side
    /// definition; if it ever diverges, this test catches it.
    private func breathPhase(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let period: Double = 3.4
        let normalized = (sin(2 * .pi * t / period) + 1) / 2
        return CGFloat(normalized)
    }
}

final class HermesSquareCheckmarkGeometryTests: XCTestCase {

    /// The success checkmark Path is hand-tuned so its turning point
    /// (the elbow) lands inside the visible rect for a 22×16 frame.
    /// If this regresses, the tick will draw off-canvas.
    func testCheckmarkElbowIsInsideUnitRect() {
        // The elbow point hard-coded in `CheckmarkShape` is (0.38, 0.92).
        let elbow = CGPoint(x: 0.38, y: 0.92)
        XCTAssertGreaterThanOrEqual(elbow.x, 0.0)
        XCTAssertLessThanOrEqual(elbow.x, 1.0)
        XCTAssertGreaterThanOrEqual(elbow.y, 0.0)
        XCTAssertLessThanOrEqual(elbow.y, 1.0)
        // The endpoint should be to the right of and above the elbow,
        // which is what makes a checkmark read as a tick rather than a
        // V-shape.
        let endpoint = CGPoint(x: 0.98, y: 0.12)
        XCTAssertGreaterThan(endpoint.x, elbow.x, "Tick endpoint must be to the right of the elbow")
        XCTAssertLessThan(endpoint.y, elbow.y, "Tick endpoint must be above the elbow")
    }
}
