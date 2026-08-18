import XCTest
@testable import OpenBurnBarKernel

/// The frame layer is where a hostile or buggy peer meets our code first, so
/// these lean hard on the refusal paths: mislabelled frames, absent payloads,
/// and missing fields all have to throw rather than half-parse.
final class WarWireFrameCodecTests: XCTestCase {

    private let uid = "uid-1"
    private let connectionID = "conn-1"

    private func hello() -> WarWireHello {
        WarWireHello(
            bodyID: "mac-a",
            displayName: "Studio",
            capabilities: [WarWireFrameCodec.capability, "hermes_chat"],
            pairID: WarWireGrant.pairID("mac-a", "mac-b")
        )
    }

    private func body(_ id: String, runs: Int = 0) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: id.uppercased(),
            isLocal: true,
            isOnline: true,
            hermesGatewayReachable: true,
            wireReachable: false,
            capabilities: ["hermes_chat", "fleet_probe"],
            activeRunCount: runs,
            performanceCores: 10
        )
    }

    private func parse(_ frame: HermesRealtimeRelayFrame) throws -> WarWireEvent {
        try WarWireFrameCodec.event(from: frame)
    }

    // MARK: - Round trips

    func test_helloRoundTrips() throws {
        let frame = WarWireFrameCodec.hello(hello(), uid: uid, connectionID: connectionID)
        XCTAssertEqual(frame.type, .warHello)
        XCTAssertEqual(try parse(frame), .hello(hello()))
    }

    func test_helloAckRoundTrips() throws {
        let frame = WarWireFrameCodec.helloAck(hello(), uid: uid, connectionID: connectionID)
        XCTAssertEqual(frame.type, .warHelloAck)
        XCTAssertEqual(try parse(frame), .helloAck(hello()))
    }

    func test_dispatchRoundTrips() throws {
        let request = HermesRealtimeRelayWarDispatchRequest(
            dispatchId: "disp-1",
            instruction: "run the suite",
            requiredCapabilities: ["hermes_chat"],
            originatorKind: "flame",
            originatorRef: "d-abc123"
        )
        let frame = WarWireFrameCodec.dispatch(request, uid: uid, connectionID: connectionID)
        XCTAssertEqual(try parse(frame), .dispatch(request))
    }

    func test_dispatchAckRoundTrips() throws {
        let frame = WarWireFrameCodec.dispatchAck(
            dispatchID: "disp-1", runID: "run-9", uid: uid, connectionID: connectionID
        )
        XCTAssertEqual(try parse(frame), .dispatchAck(dispatchID: "disp-1", runID: "run-9"))
    }

    func test_streamChunkRoundTrips() throws {
        let frame = WarWireFrameCodec.streamChunk(
            runID: "run-9", sequence: 3, text: "compiling…", uid: uid, connectionID: connectionID
        )
        XCTAssertEqual(try parse(frame), .streamChunk(runID: "run-9", sequence: 3, text: "compiling…"))
    }

    func test_streamCompleteRoundTrips() throws {
        let frame = WarWireFrameCodec.streamComplete(
            runID: "run-9", status: .succeeded, message: "0 failures", uid: uid, connectionID: connectionID
        )
        XCTAssertEqual(
            try parse(frame),
            .streamComplete(runID: "run-9", status: .succeeded, message: "0 failures")
        )
    }

    func test_deniedRoundTripsEveryReason() throws {
        for reason in WarWireDenialReason.allCases {
            let frame = WarWireFrameCodec.denied(reason, uid: uid, connectionID: connectionID)
            XCTAssertEqual(frame.type, .warDenied)
            XCTAssertEqual(try parse(frame), .denied(reason, message: nil))
        }
    }

    /// The gate's vocabulary and the frame's vocabulary must stay identical, or
    /// a denial would arrive at the peer as a different reason than the one
    /// that was decided.
    func test_denialVocabulariesAreIdentical() {
        XCTAssertEqual(
            Set(WarWireDenialReason.allCases.map(\.rawValue)),
            Set(HermesRealtimeRelayWarDenialReason.allCases.map(\.rawValue))
        )
    }

    // MARK: - Fleet snapshot

    func test_fleetSnapshotRoundTripsThroughRoutableSnapshots() throws {
        let frame = WarWireFrameCodec.fleetSnapshot(
            [body("mac-a", runs: 2)], uid: uid, connectionID: connectionID
        )
        guard case let .fleetSnapshot(received) = try parse(frame) else {
            XCTFail("expected a fleet snapshot")
            return
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].bodyID, "mac-a")
        XCTAssertEqual(received[0].activeRunCount, 2)
        XCTAssertEqual(received[0].capabilities, ["hermes_chat", "fleet_probe"])
        XCTAssertEqual(received[0].performanceCores, 10)
    }

    /// The receiver, not the sender, decides the three facts a machine must not
    /// be trusted to assert about itself.
    func test_receiverSuppliesPresenceLocalityAndReachability() throws {
        let frame = WarWireFrameCodec.fleetSnapshot(
            [body("mac-a")], uid: uid, connectionID: connectionID
        )
        guard case let .fleetSnapshot(received) = try parse(frame) else {
            XCTFail("expected a fleet snapshot")
            return
        }
        XCTAssertTrue(received[0].isOnline, "the frame arrived, so the peer is up")
        XCTAssertTrue(received[0].wireReachable, "the frame arrived over the Wire")
        XCTAssertFalse(received[0].isLocal, "a peer is never the local machine")
    }

    /// A snapshot arriving over the Wire has to be routable without a second
    /// translation step, which is the whole reason the payload mirrors
    /// FleetBodySnapshot.
    func test_receivedSnapshotFeedsTheFlameDirectly() throws {
        let frame = WarWireFrameCodec.fleetSnapshot(
            [body("mac-remote")], uid: uid, connectionID: connectionID
        )
        guard case let .fleetSnapshot(received) = try parse(frame) else {
            XCTFail("expected a fleet snapshot")
            return
        }
        let decision = FlameRouter.route(
            snapshot: FleetSnapshot(bodies: received),
            requiredCapabilities: ["hermes_chat"]
        )
        XCTAssertEqual(decision.chosenBodyID, "mac-remote")
        XCTAssertEqual(decision.transport, .wire)
    }

    func test_emptyFleetSnapshotIsValid() throws {
        let frame = WarWireFrameCodec.fleetSnapshot([], uid: uid, connectionID: connectionID)
        XCTAssertEqual(try parse(frame), .fleetSnapshot([]))
    }

    // MARK: - Refusals

    func test_rejectsANonWarFrame() {
        let frame = HermesRealtimeRelayFrame(type: .hostRegister, uid: uid, connectionId: connectionID)
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .notAWarFrame(.hostRegister))
        }
    }

    func test_rejectsAWarFrameWithNoPayload() {
        let frame = HermesRealtimeRelayFrame(type: .warHello, uid: uid, connectionId: connectionID)
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .missingPayload(.warHello))
        }
    }

    /// A peer that labels the envelope one thing and the payload another does
    /// not get to pick which label wins.
    func test_rejectsMismatchedEnvelopeAndPayloadKinds() {
        var frame = WarWireFrameCodec.hello(hello(), uid: uid, connectionID: connectionID)
        frame.type = .warDispatch
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .kindMismatch(frame: .warDispatch, payload: .hello))
        }
    }

    func test_rejectsHelloMissingItsBodyID() {
        var frame = WarWireFrameCodec.hello(hello(), uid: uid, connectionID: connectionID)
        frame.war?.bodyId = nil
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .missingField("bodyId"))
        }
    }

    func test_rejectsHelloMissingItsPairID() {
        var frame = WarWireFrameCodec.hello(hello(), uid: uid, connectionID: connectionID)
        frame.war?.pairId = nil
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .missingField("pairId"))
        }
    }

    func test_rejectsStreamChunkMissingItsSequence() {
        var frame = WarWireFrameCodec.streamChunk(
            runID: "run-9", sequence: 1, text: "x", uid: uid, connectionID: connectionID
        )
        frame.war?.sequence = nil
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .missingField("sequence"))
        }
    }

    func test_rejectsStreamCompleteMissingItsStatus() {
        var frame = WarWireFrameCodec.streamComplete(
            runID: "run-9", status: .failed, uid: uid, connectionID: connectionID
        )
        frame.war?.status = nil
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .missingField("status"))
        }
    }

    func test_rejectsDeniedMissingItsReason() {
        var frame = WarWireFrameCodec.denied(.noGrant, uid: uid, connectionID: connectionID)
        frame.war?.denialReason = nil
        XCTAssertThrowsError(try parse(frame)) { error in
            XCTAssertEqual(error as? WarWireFrameError, .missingField("denialReason"))
        }
    }

    // MARK: - Wire form

    /// Non-War Room peers must see a byte-identical envelope, so the war
    /// sibling has to stay absent unless it is actually used.
    func test_warSiblingIsAbsentFromNonWarFrames() throws {
        let frame = HermesRealtimeRelayFrame(type: .hostRegister, uid: uid, connectionId: connectionID)
        let json = try JSONEncoder().encode(frame)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        XCTAssertNil(object["war"])
    }

    func test_warFrameSurvivesJSONEncodingAndDecoding() throws {
        let original = WarWireFrameCodec.fleetSnapshot(
            [body("mac-a", runs: 4)], uid: uid, connectionID: connectionID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try parse(decoded), try parse(original))
    }

    func test_everyWarFrameTypeIsRecognised() {
        let warTypes: [HermesRealtimeRelayFrameType] = [
            .warHello, .warHelloAck, .warFleetSnapshot, .warDispatch,
            .warDispatchAck, .warStreamChunk, .warStreamComplete, .warDenied
        ]
        for type in warTypes {
            XCTAssertTrue(type.isWarFrame, "\(type.rawValue) should belong to the war group")
        }
    }

    func test_neighbouringGroupsAreNotWarFrames() {
        let others: [HermesRealtimeRelayFrameType] = [
            .hostRegister, .mediaClassify, .mediaMirrorRequest, .mediaPresenceHeartbeat
        ]
        for type in others {
            XCTAssertFalse(type.isWarFrame, "\(type.rawValue) must not read as a war frame")
        }
    }
}
