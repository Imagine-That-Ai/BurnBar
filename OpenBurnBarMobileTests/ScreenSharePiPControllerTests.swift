#if canImport(UIKit) && canImport(AVKit)
import AVFoundation
import XCTest
@testable import OpenBurnBarMobile

@MainActor
final class ScreenSharePiPControllerTests: XCTestCase {
    func test_attach_configuresAutomaticInlinePiP() {
        let controller = ScreenSharePiPController(isPictureInPictureSupported: { true })
        let layer = AVSampleBufferDisplayLayer()

        controller.attach(displayLayer: layer)

        XCTAssertTrue(controller.didRequestAutomaticInlinePiP)
    }

    func test_delegateLifecycle_surfacesStartAndStopCallbacks() {
        let controller = ScreenSharePiPController(isPictureInPictureSupported: { true })
        var events: [String] = []
        controller.onDidStart = { events.append("start") }
        controller.onDidStop = { events.append("stop") }

        controller.handleDidStartPictureInPicture()
        XCTAssertTrue(controller.isPictureInPictureActive)

        controller.handleDidStopPictureInPicture()
        XCTAssertFalse(controller.isPictureInPictureActive)
        XCTAssertEqual(events, ["start", "stop"])
    }
}
#endif
