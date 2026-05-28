import XCTest
import OpenBurnBarMedia
@testable import OpenBurnBar

@MainActor
final class MediaSessionCoordinatorTests: XCTestCase {
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
            }
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
