import XCTest
import SwiftUI
@testable import OpenBurnBarMobile

// MARK: - MotionStoreTests
//
// Regression coverage for the tilt deadband: a stationary device's sensor
// noise plus the asymptotic exponential smoothing must not keep mutating the
// `@Observable` `tilt` property (which would invalidate every parallax and
// specular consumer 30×/s while the phone lies flat).

@MainActor
final class MotionStoreTests: XCTestCase {

    /// Thread-safe flag for `withObservationTracking`'s `@Sendable` onChange.
    private final class MutationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var fired: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private func settle(_ store: MotionStore, x: CGFloat, y: CGFloat) {
        for _ in 0..<200 {
            store.applyTilt(normalizedX: x, normalizedY: y)
        }
    }

    func testApplyTiltSmoothsTowardTargetWhileConverging() {
        let store = MotionStore()
        store.applyTilt(normalizedX: 1.0, normalizedY: -1.0)
        // One smoothing step of 0.18 toward the target from zero.
        XCTAssertEqual(store.tilt.width, 0.18, accuracy: 1e-9)
        XCTAssertEqual(store.tilt.height, -0.18, accuracy: 1e-9)
    }

    func testApplyTiltSnapsExactlyToTargetOnConvergence() {
        let store = MotionStore()
        settle(store, x: 0.3, y: -0.2)
        // Without the snap, the exponential approach never reaches the
        // target and every callback keeps assigning a new value.
        XCTAssertEqual(store.tilt.width, 0.3)
        XCTAssertEqual(store.tilt.height, -0.2)
    }

    func testStationaryJitterWithinDeadbandSkipsMutation() {
        let store = MotionStore()
        settle(store, x: 0.3, y: -0.2)
        let settled = store.tilt

        // `@Observable` fires `withMutation` even for equal-value writes, so
        // the deadband must skip the assignment itself — verify no
        // observation fires for sub-deadband (< 0.01 normalized) noise.
        let flag = MutationFlag()
        withObservationTracking {
            _ = store.tilt
        } onChange: {
            flag.set()
        }
        store.applyTilt(normalizedX: 0.305, normalizedY: -0.204)
        store.applyTilt(normalizedX: 0.294, normalizedY: -0.193)

        XCTAssertEqual(store.tilt, settled)
        XCTAssertFalse(flag.fired)
    }

    func testMovementBeyondDeadbandResumesSmoothing() {
        let store = MotionStore()
        settle(store, x: 0.3, y: -0.2)
        let settled = store.tilt

        store.applyTilt(normalizedX: 0.9, normalizedY: -0.2)
        XCTAssertEqual(
            store.tilt.width,
            settled.width + (0.9 - settled.width) * 0.18,
            accuracy: 1e-9
        )
    }
}
