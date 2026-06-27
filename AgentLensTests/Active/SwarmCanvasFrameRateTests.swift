import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class SwarmCanvasFrameRateTests: XCTestCase {

    // MARK: - Stateful Canvas isolation

    func testStatefulCanvasRenderers_doNotRenderAsynchronously() throws {
        let statefulCanvasSources = [
            "AgentLens/Views/Dashboard/DashboardBracketSwarmBackground.swift",
            "AgentLens/Views/Dashboard/Components/EasterEggEventCanvas.swift"
        ]

        for relativePath in statefulCanvasSources {
            let source = try Self.loadSource(relativePath)
            XCTAssertFalse(
                source.contains("rendersAsynchronously: true"),
                "\(relativePath) owns SwiftUI or simulation state from its Canvas closure and must stay synchronous."
            )
            XCTAssertTrue(
                source.contains("rendersAsynchronously: false"),
                "\(relativePath) should make the stateful Canvas execution policy explicit."
            )
        }
    }

    // MARK: - sanitizedFrameRate matrix

    func testSanitizedFrameRate_nil_returnsFallback() {
        XCTAssertEqual(
            SwarmCanvasView.sanitizedFrameRate(nil, fallback: 60),
            60
        )
        XCTAssertEqual(
            SwarmCanvasView.sanitizedFrameRate(nil, fallback: 15),
            15
        )
    }

    func testSanitizedFrameRate_negativeOrZero_returnsFallback() {
        XCTAssertEqual(
            SwarmCanvasView.sanitizedFrameRate(0, fallback: 30),
            30
        )
        XCTAssertEqual(
            SwarmCanvasView.sanitizedFrameRate(-1, fallback: 30),
            30
        )
    }

    func testSanitizedFrameRate_infinite_returnsFallback() {
        XCTAssertEqual(
            SwarmCanvasView.sanitizedFrameRate(.infinity, fallback: 30),
            30
        )
        XCTAssertEqual(
            SwarmCanvasView.sanitizedFrameRate(.nan, fallback: 30),
            30
        )
    }

    func testSanitizedFrameRate_validValue_clampedTo1to120() {
        XCTAssertEqual(SwarmCanvasView.sanitizedFrameRate(30, fallback: 60), 30)
        XCTAssertEqual(SwarmCanvasView.sanitizedFrameRate(15, fallback: 60), 15)
        XCTAssertEqual(SwarmCanvasView.sanitizedFrameRate(1000, fallback: 60), 120)
        XCTAssertEqual(SwarmCanvasView.sanitizedFrameRate(0.5, fallback: 60), 1)
    }

    func testDefaultFrameRate_isBoundedForDecorativeDashboardCanvas() {
        #if os(macOS)
        XCTAssertLessThanOrEqual(SwarmCanvasView.defaultFrameRate, 30)
        #else
        XCTAssertLessThanOrEqual(SwarmCanvasView.defaultFrameRate, 60)
        #endif
    }

    func testAnimationFrameScale_preservesWallClockMotionAtLowerFrameRates() {
        XCTAssertEqual(SwarmSimulation.animationFrameScale(elapsed: nil), 1.0)
        XCTAssertEqual(SwarmSimulation.animationFrameScale(elapsed: 1.0 / 60.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(SwarmSimulation.animationFrameScale(elapsed: 1.0 / 30.0), 2.0, accuracy: 0.001)
        XCTAssertEqual(SwarmSimulation.animationFrameScale(elapsed: 1.0 / 15.0), 4.0, accuracy: 0.001)
        XCTAssertEqual(SwarmSimulation.animationFrameScale(elapsed: 10.0), 4.0, accuracy: 0.001)
    }

    func testGlyphParticleSampling_boundsTextResolutionCost() {
        XCTAssertTrue(SwarmSimulation.shouldDrawGlyphParticle(at: 0, isBatteryThrottled: false, particleCount: 900))
        XCTAssertFalse(SwarmSimulation.shouldDrawGlyphParticle(at: 1, isBatteryThrottled: false, particleCount: 900))
        XCTAssertFalse(SwarmSimulation.shouldDrawGlyphParticle(at: 2, isBatteryThrottled: false, particleCount: 900))
        XCTAssertTrue(SwarmSimulation.shouldDrawGlyphParticle(at: 3, isBatteryThrottled: false, particleCount: 900))
        XCTAssertFalse(SwarmSimulation.shouldDrawGlyphParticle(at: 6, isBatteryThrottled: true, particleCount: 900))
        XCTAssertTrue(SwarmSimulation.shouldDrawGlyphParticle(at: 10, isBatteryThrottled: true, particleCount: 900))
        XCTAssertFalse(SwarmSimulation.shouldDrawGlyphParticle(at: 9, isBatteryThrottled: false, particleCount: 1_200))
        XCTAssertTrue(SwarmSimulation.shouldDrawGlyphParticle(at: 12, isBatteryThrottled: false, particleCount: 1_200))
    }

    // MARK: - RGBA.bucketKey

    func testBucketKey_isStableAcrossEqualValues() {
        let a = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        let b = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        XCTAssertEqual(a.bucketKey, b.bucketKey)
    }

    func testBucketKey_quantizesNearbyValuesIntoSameBucket() {
        let a = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        // 0.5 + 0.001 still rounds to 128/255
        let b = RGBA(r: 0.5 + 0.0005, g: 0.5, b: 0.5, a: 1.0)
        XCTAssertEqual(a.bucketKey, b.bucketKey)
    }

    func testBucketKey_separatesDifferentColors() {
        let red = RGBA(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let green = RGBA(r: 0.0, g: 1.0, b: 0.0, a: 1.0)
        let blue = RGBA(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let alpha = RGBA(r: 1.0, g: 0.0, b: 0.0, a: 0.5)

        XCTAssertNotEqual(red.bucketKey, green.bucketKey)
        XCTAssertNotEqual(green.bucketKey, blue.bucketKey)
        XCTAssertNotEqual(red.bucketKey, alpha.bucketKey)
    }

    func testBucketKey_clampsOutOfRangeValues() {
        // Out-of-range values get clamped to [0, 1] before quantization.
        let highHDR = RGBA(r: 1.4, g: -0.2, b: 1.0, a: 1.0)
        let saturated = RGBA(r: 1.0, g: 0.0, b: 1.0, a: 1.0)
        XCTAssertEqual(highHDR.bucketKey, saturated.bucketKey)
    }

    func testBucketKey_topByteIsRedQuantum() {
        let pureRed = RGBA(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        // R=255 in the top byte: 0xFF000000 | 0x00000000 | 0x00000000 | 0xFF
        let expected: UInt32 = (255 << 24) | (0 << 16) | (0 << 8) | 255
        XCTAssertEqual(pureRed.bucketKey, expected)
    }

    private static func loadSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
