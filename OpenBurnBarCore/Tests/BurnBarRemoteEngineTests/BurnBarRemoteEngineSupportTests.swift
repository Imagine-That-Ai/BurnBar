import XCTest
@testable import BurnBarRemoteEngine

final class BurnBarRemoteEngineSupportTests: XCTestCase {
    func testReadinessUsesStableProtocolSurface() {
        let readiness = BurnBarRemoteEngineSupport.readiness()

        XCTAssertEqual(readiness.protocolVersion, "burnbar-remote/v1")
        XCTAssertTrue(readiness.supportsIrohTransport)
        XCTAssertTrue(readiness.supportsAdaptiveQuality)
        XCTAssertTrue(readiness.supportsPermissionGate)
        XCTAssertEqual(readiness.nativeBridgeAvailable, BurnBarRemoteEngineSupport.isNativeBridgeAvailable)
    }

    func testDimensionScalingMatchesRustContractFallback() throws {
        let dimensions = try BurnBarRemoteEngineDimensions(width: 3840, height: 2160)

        let scaled = try BurnBarRemoteEngineSupport.scaledDimensions(
            dimensions,
            numerator: 1,
            denominator: 2
        )

        XCTAssertEqual(scaled, try BurnBarRemoteEngineDimensions(width: 1920, height: 1080))
    }

    func testDimensionScalingNeverReturnsZero() throws {
        let dimensions = try BurnBarRemoteEngineDimensions(width: 1, height: 1)

        let scaled = try BurnBarRemoteEngineSupport.scaledDimensions(
            dimensions,
            numerator: 0,
            denominator: 10
        )

        XCTAssertEqual(scaled, try BurnBarRemoteEngineDimensions(width: 1, height: 1))
    }

    func testControlModeRequiresInputPermission() {
        XCTAssertTrue(BurnBarRemoteEngineSupport.modeRequiresInputPermission())
    }
}
