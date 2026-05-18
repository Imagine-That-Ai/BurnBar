import XCTest
@testable import OpenBurnBarMedia

final class BitrateControllerTests: XCTestCase {
    func testStartsAtCeiling() {
        let controller = BitrateController(steps: .screenShare)
        XCTAssertEqual(controller.currentBitsPerSecond, 8_000_000)
    }

    func testRttSpikeStepsDownOnce() {
        var controller = BitrateController(steps: .screenShare)
        let next = controller.apply(sample: BitrateController.Sample(
            roundTripMillis: 500,
            packetLossRate: 0.0,
            observedBitsPerSecond: 8_000_000
        ))
        XCTAssertEqual(next, 4_000_000)
        XCTAssertEqual(controller.currentBitsPerSecond, 4_000_000)
    }

    func testLossRateDownAdaptsIndependently() {
        var controller = BitrateController(steps: .screenShare)
        let next = controller.apply(sample: BitrateController.Sample(
            roundTripMillis: 50,
            packetLossRate: 0.10,
            observedBitsPerSecond: 8_000_000
        ))
        XCTAssertEqual(next, 4_000_000)
    }

    func testRecoveryRequiresHysteresisGoodSamples() {
        var controller = BitrateController(steps: .videoCall)
        // Force down-adapt twice to land at 300_000.
        _ = controller.apply(sample: BitrateController.Sample(
            roundTripMillis: 500, packetLossRate: 0.0, observedBitsPerSecond: 0
        ))
        _ = controller.apply(sample: BitrateController.Sample(
            roundTripMillis: 500, packetLossRate: 0.0, observedBitsPerSecond: 0
        ))
        XCTAssertEqual(controller.currentBitsPerSecond, 300_000)

        // Two good samples should not yet trigger recovery (default
        // hysteresis = 3).
        for _ in 0..<2 {
            _ = controller.apply(sample: BitrateController.Sample(
                roundTripMillis: 30, packetLossRate: 0.001, observedBitsPerSecond: 1_200_000
            ))
        }
        XCTAssertEqual(controller.currentBitsPerSecond, 300_000)

        // Third good sample crosses the hysteresis threshold.
        _ = controller.apply(sample: BitrateController.Sample(
            roundTripMillis: 30, packetLossRate: 0.001, observedBitsPerSecond: 1_200_000
        ))
        XCTAssertEqual(controller.currentBitsPerSecond, 600_000)
    }

    func testCeilingIsClampedAtMaxStep() {
        var controller = BitrateController(steps: .videoCall)
        // From the top, repeatedly applying good samples should never exceed
        // the ceiling (1_200_000 in the videoCall step ladder).
        for _ in 0..<20 {
            _ = controller.apply(sample: BitrateController.Sample(
                roundTripMillis: 10, packetLossRate: 0.0, observedBitsPerSecond: 5_000_000
            ))
        }
        XCTAssertEqual(controller.currentBitsPerSecond, 1_200_000)
    }

    func testFloorIsClampedAtMinStep() {
        var controller = BitrateController(steps: .videoCall)
        for _ in 0..<20 {
            _ = controller.apply(sample: BitrateController.Sample(
                roundTripMillis: 800, packetLossRate: 0.5, observedBitsPerSecond: 100
            ))
        }
        XCTAssertEqual(controller.currentBitsPerSecond, 300_000)
    }
}
