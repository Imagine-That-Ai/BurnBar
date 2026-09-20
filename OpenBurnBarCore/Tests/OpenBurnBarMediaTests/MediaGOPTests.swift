import XCTest
@testable import OpenBurnBarMedia

final class MediaGOPTests: XCTestCase {
    func testDropsUnanchoredDeltaUntilKeyframe() {
        var window = MediaGOPReceiveWindow()
        XCTAssertEqual(
            window.admit(gopID: 3, isKeyframe: false, isEndOfGroup: false),
            .dropUnanchored
        )
    }

    func testKeyframeAnchorsAndLaterDeltaDecodes() {
        var window = MediaGOPReceiveWindow()
        XCTAssertEqual(window.admit(gopID: 4, isKeyframe: true, isEndOfGroup: false), .decode)
        XCTAssertEqual(window.admit(gopID: 4, isKeyframe: false, isEndOfGroup: false), .decode)
        XCTAssertEqual(window.activeGopID, 4)
    }

    func testNewerKeyframeAbortsOlderGOPFrames() {
        var window = MediaGOPReceiveWindow()
        XCTAssertEqual(window.admit(gopID: 5, isKeyframe: true, isEndOfGroup: false), .decode)
        XCTAssertEqual(window.admit(gopID: 5, isKeyframe: false, isEndOfGroup: false), .decode)
        XCTAssertEqual(window.admit(gopID: 6, isKeyframe: true, isEndOfGroup: false), .decode)
        XCTAssertEqual(window.highestCompletedGopID, 5)
        XCTAssertEqual(window.admit(gopID: 5, isKeyframe: false, isEndOfGroup: true), .dropStale)
        XCTAssertEqual(window.admit(gopID: 6, isKeyframe: false, isEndOfGroup: true), .decode)
        XCTAssertEqual(window.highestCompletedGopID, 6)
    }

    func testCompletedNewerGOPDropsLateOlderKeyframe() {
        var window = MediaGOPReceiveWindow()
        _ = window.admit(gopID: 8, isKeyframe: true, isEndOfGroup: false)
        _ = window.admit(gopID: 8, isKeyframe: false, isEndOfGroup: true)
        XCTAssertEqual(window.admit(gopID: 7, isKeyframe: true, isEndOfGroup: false), .dropStale)
    }

    func testMissingKeyframeOnNewerGOPIsUnanchored() {
        var window = MediaGOPReceiveWindow()
        _ = window.admit(gopID: 2, isKeyframe: true, isEndOfGroup: false)
        XCTAssertEqual(
            window.admit(gopID: 3, isKeyframe: false, isEndOfGroup: false),
            .dropUnanchored
        )
    }

    func testStamperMarksPreviousGOPOnNextKeyframe() throws {
        var stamper = MediaGOPEndStamper()
        XCTAssertNil(stamper.push(MediaFrame(kind: .videoNAL, flags: [.keyframe], gopID: 1)))

        let mid = MediaFrame(kind: .videoNAL, gopID: 1, frameIndex: 1)
        let first = try XCTUnwrap(stamper.push(mid))
        XCTAssertTrue(first.flags.contains(.keyframe))
        XCTAssertFalse(first.flags.contains(.endOfGroup))

        let nextKey = MediaFrame(kind: .videoNAL, flags: [.keyframe], gopID: 2)
        let lastOfFirst = try XCTUnwrap(stamper.push(nextKey))
        XCTAssertEqual(lastOfFirst.gopID, 1)
        XCTAssertTrue(lastOfFirst.flags.contains(.endOfGroup))
    }

    func testStamperFlushMarksHeldFrameEndOfGroup() throws {
        var stamper = MediaGOPEndStamper()
        _ = stamper.push(MediaFrame(kind: .videoNAL, flags: [.keyframe], gopID: 9))
        let flushed = try XCTUnwrap(stamper.flush())
        XCTAssertTrue(flushed.flags.contains(.endOfGroup))
        XCTAssertTrue(flushed.flags.contains(.keyframe))
        XCTAssertNil(stamper.flush())
    }

    func testBweFeedbackPayloadRoundTripsIntoControllerSample() throws {
        let payload = MediaBweFeedbackPayload(
            roundTripMillis: 240,
            packetLossRate: 0.05,
            observedBitsPerSecond: 400_000,
            pathConstrained: true
        )
        let decoded = try MediaBweFeedbackPayload.decode(payload.encoded())
        XCTAssertEqual(decoded, payload)
        XCTAssertTrue(decoded.sample.pathConstrained)
        XCTAssertEqual(decoded.sample.roundTripMillis, 240)
        XCTAssertTrue(MediaBweFeedbackPayload.isConstrainedPath(
            usesCellular: true,
            isExpensive: false,
            isConstrained: false
        ))
        XCTAssertFalse(MediaBweFeedbackPayload.isConstrainedPath(
            usesCellular: false,
            isExpensive: false,
            isConstrained: false
        ))
    }

    func testBweFeedbackPacketCodecRoundTrips() throws {
        let codec = MediaPacketCodec()
        let payload = MediaBweFeedbackPayload(
            roundTripMillis: 210,
            packetLossRate: 0.04,
            observedBitsPerSecond: 0,
            pathConstrained: true
        )
        let encoded = try codec.encode(MediaFrame(kind: .bweFeedback, payload: try payload.encoded()))
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.frame.kind, .bweFeedback)
        XCTAssertEqual(try MediaBweFeedbackPayload.decode(decoded.frame.payload), payload)
    }
}
