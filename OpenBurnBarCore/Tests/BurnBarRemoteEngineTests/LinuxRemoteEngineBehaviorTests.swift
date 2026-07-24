import XCTest
@testable import BurnBarRemoteEngine

/// Linux exercises the dependency-free remote-engine seam.  These tests keep
/// the wire-facing readiness, dimension, and permission contracts executable
/// even when the optional native FFI artifact is not installed.
final class BurnBarRemoteEngineLinuxBehaviorTests: XCTestCase {
    func testReadinessAdvertisesStableTransportContract() {
        let readiness = BurnBarRemoteEngineSupport.readiness()

        XCTAssertEqual(readiness.protocolVersion, "burnbar-remote/v1")
        XCTAssertTrue(readiness.supportsIrohTransport)
        XCTAssertTrue(readiness.supportsAdaptiveQuality)
        XCTAssertTrue(readiness.supportsPermissionGate)
        XCTAssertEqual(
            readiness.nativeBridgeAvailable,
            BurnBarRemoteEngineSupport.isNativeBridgeAvailable
        )
    }

    func testReadinessIsDeterministicAcrossRepeatedTransportRequests() {
        // Provider selection must not change this transport handshake. The
        // Linux seam has no provider credentials, so repeated reads model the
        // stable contract consumed by every provider adapter.
        XCTAssertEqual(
            BurnBarRemoteEngineSupport.readiness(),
            BurnBarRemoteEngineSupport.readiness()
        )
    }

    func testDimensionsRejectInvalidTransportFrames() {
        let invalidFrames: [(width: UInt32, height: UInt32)] = [
            (0, 1080),
            (1920, 0),
            (0, 0)
        ]

        for frame in invalidFrames {
            XCTAssertThrowsError(
                try BurnBarRemoteEngineDimensions(width: frame.width, height: frame.height)
            ) { error in
                XCTAssertEqual(
                    error as? BurnBarRemoteEngineError,
                    .invalidDimensions(width: frame.width, height: frame.height)
                )
            }
        }
    }

    func testScalingUsesDeterministicIntegerWireDimensions() throws {
        let source = try BurnBarRemoteEngineDimensions(width: 801, height: 601)

        let scaled = try BurnBarRemoteEngineSupport.scaledDimensions(
            source,
            numerator: 2,
            denominator: 3
        )

        // The Rust/native contract uses integer floor division for each axis.
        XCTAssertEqual(scaled, try BurnBarRemoteEngineDimensions(width: 534, height: 400))
    }

    func testScalingTreatsZeroDenominatorAsUnitDenominator() throws {
        let source = try BurnBarRemoteEngineDimensions(width: 640, height: 360)

        let zeroDenominator = try BurnBarRemoteEngineSupport.scaledDimensions(
            source,
            numerator: 2,
            denominator: 0
        )
        let unitDenominator = try BurnBarRemoteEngineSupport.scaledDimensions(
            source,
            numerator: 2,
            denominator: 1
        )

        XCTAssertEqual(zeroDenominator, unitDenominator)
    }

    func testScalingNeverProducesZeroSizedTransportFrame() throws {
        let source = try BurnBarRemoteEngineDimensions(width: 1, height: 1)

        let scaled = try BurnBarRemoteEngineSupport.scaledDimensions(
            source,
            numerator: 0,
            denominator: 10
        )

        XCTAssertEqual(scaled, source)
    }

    func testScalingClampsOversizedNativeFrameToUInt32WireLimit() throws {
        let source = try BurnBarRemoteEngineDimensions(width: .max, height: .max)

        let scaled = try BurnBarRemoteEngineSupport.scaledDimensions(
            source,
            numerator: .max,
            denominator: 1
        )

        XCTAssertEqual(scaled.width, .max)
        XCTAssertEqual(scaled.height, .max)
    }

    func testControlTransportRequiresInputPermission() {
        XCTAssertTrue(BurnBarRemoteEngineSupport.modeRequiresInputPermission())
    }
}
