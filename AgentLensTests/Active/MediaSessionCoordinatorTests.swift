import CoreMedia
import XCTest
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import OpenBurnBarMedia
@testable import OpenBurnBar

@MainActor
final class MediaSessionCoordinatorTests: XCTestCase {
    #if canImport(ScreenCaptureKit)
    func testIndependentWindowCaptureScalesToFillConfiguredCanvas() {
        let configuration = ScreenCapturePipeline.Configuration(windowID: 42)
        let streamConfiguration = ScreenCapturePipeline.makeStreamConfiguration(
            for: configuration,
            isIndependentWindowCapture: true
        )

        XCTAssertTrue(streamConfiguration.scalesToFit)
        XCTAssertEqual(streamConfiguration.width, 1920)
        XCTAssertEqual(streamConfiguration.height, 1080)
    }

    func testDisplayCaptureDoesNotUpscaleToFillConfiguredCanvas() {
        let configuration = ScreenCapturePipeline.Configuration(displayId: "main")
        let streamConfiguration = ScreenCapturePipeline.makeStreamConfiguration(
            for: configuration,
            isIndependentWindowCapture: false
        )

        XCTAssertFalse(streamConfiguration.scalesToFit)
        XCTAssertEqual(streamConfiguration.width, 1920)
        XCTAssertEqual(streamConfiguration.height, 1080)
    }

    func testDisplayWindowFallbackCropsSourceToTerminalWindow() {
        let sourceRect = CGRect(x: 120, y: 80, width: 900, height: 620)
        let configuration = ScreenCapturePipeline.Configuration(windowID: 42)
        let streamConfiguration = ScreenCapturePipeline.makeStreamConfiguration(
            for: configuration,
            isIndependentWindowCapture: false,
            sourceRect: sourceRect
        )

        XCTAssertFalse(streamConfiguration.scalesToFit)
        XCTAssertEqual(streamConfiguration.sourceRect, sourceRect)
    }

    func testStaleWindowFallbackDoesNotEnableWindowScaleToFit() {
        let configuration = ScreenCapturePipeline.Configuration(windowID: 42)
        let streamConfiguration = ScreenCapturePipeline.makeStreamConfiguration(
            for: configuration,
            isIndependentWindowCapture: false
        )

        XCTAssertFalse(streamConfiguration.scalesToFit)
    }

    func testSourceRectClampsWindowFrameToDisplayCoordinates() {
        let rect = ScreenCapturePipeline.sourceRect(
            forWindowFrame: CGRect(x: -80, y: 120, width: 620, height: 460),
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 120, width: 540, height: 460))
    }

    func testSourceRectReturnsNilForOffDisplayWindow() {
        let rect = ScreenCapturePipeline.sourceRect(
            forWindowFrame: CGRect(x: 1600, y: 120, width: 620, height: 460),
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertNil(rect)
    }
    #endif

    func testStartScreenShareRollsBackAfterCaptureStartFailureAndCanRetry() async throws {
        var starts = 0
        let coordinator = MediaSessionCoordinator(
            capabilityGate: AlwaysAllowMediaCapabilityGate(),
            screenCaptureFactory: { _, _ in
                starts += 1
                if starts == 1 {
                    return FailingScreenCaptureSession()
                }
                return RecordingScreenCaptureSession()
            },
            // Stub encoder: virtualized CI Macs have no hardware HEVC encoder
            // (VTCompressionSessionCreate → -12908), and this test's subject
            // is the rollback/retry state machine, not VideoToolbox.
            videoEncoderFactory: { _, _ in StubVideoEncoder() }
        )

        do {
            try await coordinator.startScreenShare(
                peerDeviceID: "iphone",
                sink: RecordingMediaSink()
            )
            XCTFail("Expected the first capture start to fail")
        } catch ScreenCapturePipeline.Failure.noShareableContent {
            // Expected: locked macOS can briefly report no shareable displays.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(coordinator.phase, .ended(reason: .error))

        try await coordinator.startScreenShare(
            peerDeviceID: "iphone",
            sink: RecordingMediaSink()
        )
        XCTAssertEqual(coordinator.phase, .active(feature: .screenShare))

        await coordinator.stop()
    }
}

@MainActor
private final class StubVideoEncoder: VideoEncoding {
    func start() throws {}
    func encode(sampleBuffer: CMSampleBuffer) async throws {}
    func setTargetBitsPerSecond(_ bps: Int) throws {}
    func acknowledgeLongTermReferenceToken(_ tokenValue: UInt64) {}
    func stop() {}
}

@MainActor
private final class FailingScreenCaptureSession: ScreenCaptureSession {
    func start() async throws {
        throw ScreenCapturePipeline.Failure.noShareableContent
    }

    func stop() async {}
}

@MainActor
private final class RecordingScreenCaptureSession: ScreenCaptureSession {
    private(set) var didStart = false
    private(set) var didStop = false

    func start() async throws {
        didStart = true
    }

    func stop() async {
        didStop = true
    }
}

private final class RecordingMediaSink: MediaStreamSink, @unchecked Sendable {
    func write(frame: MediaFrame) async {}
    func write(frameV2: MediaFrameV2) async {}
    func close() async {}
}
