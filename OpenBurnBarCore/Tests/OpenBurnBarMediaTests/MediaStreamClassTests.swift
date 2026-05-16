import XCTest
@testable import OpenBurnBarMedia

final class MediaStreamClassTests: XCTestCase {
    func testKnownClassesMapToFeatures() {
        XCTAssertEqual(MediaStreamClass.blob.feature, .fileTransfer)
        XCTAssertEqual(MediaStreamClass.blobAdvertise.feature, .fileTransfer)
        XCTAssertEqual(MediaStreamClass.blobFetch.feature, .fileTransfer)
        XCTAssertEqual(MediaStreamClass.screenVideo.feature, .screenShare)
        XCTAssertEqual(MediaStreamClass.videoOut.feature, .videoCall)
        XCTAssertEqual(MediaStreamClass.videoIn.feature, .videoCall)
        XCTAssertEqual(MediaStreamClass.audioOut.feature, .videoCall)
        XCTAssertEqual(MediaStreamClass.audioIn.feature, .videoCall)
    }

    func testControlAndClassifyHaveNoFeatureBucket() {
        XCTAssertNil(MediaStreamClass.control.feature)
        XCTAssertNil(MediaStreamClass.classify.feature)
    }

    func testUnknownClassReturnsNilFeature() {
        let future = MediaStreamClass("media.future.something")
        XCTAssertNil(future.feature)
    }

    func testPhaseAvailabilityMatrix() {
        // Phase 1 — file transfer only
        XCTAssertTrue(MediaStreamClass.blob.isAvailable(asOfPhase: 1))
        XCTAssertFalse(MediaStreamClass.screenVideo.isAvailable(asOfPhase: 1))
        XCTAssertFalse(MediaStreamClass.audioOut.isAvailable(asOfPhase: 1))
        XCTAssertFalse(MediaStreamClass.videoOut.isAvailable(asOfPhase: 1))

        // Phase 3 — screen share + control
        XCTAssertTrue(MediaStreamClass.screenVideo.isAvailable(asOfPhase: 3))
        XCTAssertTrue(MediaStreamClass.control.isAvailable(asOfPhase: 3))
        XCTAssertFalse(MediaStreamClass.audioOut.isAvailable(asOfPhase: 3))
        XCTAssertFalse(MediaStreamClass.videoOut.isAvailable(asOfPhase: 3))

        // Phase 4 — audio
        XCTAssertTrue(MediaStreamClass.audioOut.isAvailable(asOfPhase: 4))
        XCTAssertTrue(MediaStreamClass.audioIn.isAvailable(asOfPhase: 4))
        XCTAssertFalse(MediaStreamClass.videoOut.isAvailable(asOfPhase: 4))

        // Phase 5 — video
        XCTAssertTrue(MediaStreamClass.videoOut.isAvailable(asOfPhase: 5))
        XCTAssertTrue(MediaStreamClass.videoIn.isAvailable(asOfPhase: 5))

        // Unknown class is never available
        XCTAssertFalse(MediaStreamClass("media.future").isAvailable(asOfPhase: 99))
    }

    func testRawValueRoundTripsThroughCodable() throws {
        let original = MediaStreamClass.blobAdvertise
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaStreamClass.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
