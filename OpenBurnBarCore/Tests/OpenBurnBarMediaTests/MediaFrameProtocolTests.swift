import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarMedia

/// These tests cover the JSON envelope extension on
/// `HermesRealtimeRelayFrame` — the dispatch substrate that lets new media
/// frame types ride the existing chat control stream without breaking
/// older peers.
final class MediaFrameProtocolTests: XCTestCase {
    func testChatFrameWithoutMediaPayloadDoesNotEmitMediaKey() throws {
        let chat = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: "u1",
            connectionId: "c1",
            requestId: "r1"
        )
        let encoded = try JSONEncoder().encode(chat)
        let decodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decodedString.contains("\"media\""),
                       "chat-only frames must not carry an empty media key on the wire")
    }

    func testMediaAdvertiseFrameRoundTrips() throws {
        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "m_abcd",
            blobHash: "blake3:0123456789abcdef",
            filename: "hermes-dashboard.png",
            mime: "image/png",
            size: 4_200_000,
            peerDeviceId: "ed25519:xyz",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: "u1",
            connectionId: "c1",
            requestId: "att_1",
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: manifest,
                blobTicket: "blob1abcdef..."
            )
        )

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: encoded)
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.type, .mediaBlobAdvertise)
        XCTAssertEqual(decoded.media?.attachment?.filename, "hermes-dashboard.png")
        XCTAssertEqual(decoded.media?.streamClass, MediaStreamClass.blobAdvertise.rawValue)
    }

    func testForwardCompatChatDecoderIgnoresUnknownMediaSubfields() throws {
        // Simulate a future field the older client doesn't know about.
        // Decoder should still successfully decode the known portions
        // (Codable defaults to ignoring unknown keys).
        let raw = #"""
        {
          "type": "media.blob.advertise",
          "uid": "u1",
          "connectionId": "c1",
          "requestId": "att_1",
          "protocolVersion": 1,
          "media": {
            "streamClass": "media.blob.advertise",
            "attachment": {
              "manifestId": "m1",
              "blobHash": "h",
              "filename": "x.png",
              "mime": "image/png",
              "size": 10,
              "peerDeviceId": "n1",
              "createdAt": 1700000000,
              "futureField": "ignore-me"
            },
            "blobTicket": "blob1xyz",
            "futureField": "ignore-me-too"
          }
        }
        """#
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(decoded.type, .mediaBlobAdvertise)
        XCTAssertEqual(decoded.media?.attachment?.manifestId, "m1")
    }

    func testAckFrameSurvivesRoundTrip() throws {
        let ack = HermesRealtimeRelayMediaAck(
            manifestId: "m_xyz",
            status: .received
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: "u1",
            connectionId: "c1",
            requestId: "att_1",
            media: HermesRealtimeRelayMediaPayload(ack: ack)
        )
        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: encoded)
        XCTAssertEqual(decoded.media?.ack?.status, .received)
        XCTAssertEqual(decoded.media?.ack?.manifestId, "m_xyz")
    }

    // MARK: - Mercury Phase 8 — mirror request / ack / presence

    func testMirrorRequestRoundTripsThroughCodable() throws {
        let req = HermesRealtimeRelayMirrorRequest(
            requestId: "req_abc",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            requesterDisplayName: "Alberto's iPhone",
            streamClass: MediaStreamClass.screenVideo.rawValue
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "u1",
            connectionId: "c1",
            requestId: req.requestId,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: req)
        )

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: encoded)
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.type, .mediaMirrorRequest)
        XCTAssertEqual(decoded.media?.mirrorRequest?.requesterDisplayName, "Alberto's iPhone")
        XCTAssertEqual(decoded.media?.mirrorRequest?.streamClass,
                       MediaStreamClass.screenVideo.rawValue)
    }

    func testMirrorAckOmitsNilCooldownFromJSON() throws {
        let acceptedAck = HermesRealtimeRelayMirrorAck(
            requestId: "req_abc",
            decision: .accepted
        )
        let acceptedFrame = HermesRealtimeRelayFrame(
            type: .mediaMirrorAck,
            uid: "u1",
            connectionId: "c1",
            requestId: acceptedAck.requestId,
            media: HermesRealtimeRelayMediaPayload(mirrorAck: acceptedAck)
        )

        let acceptedJSON = String(
            data: try JSONEncoder().encode(acceptedFrame),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(
            acceptedJSON.contains("cooldownSecondsRemaining"),
            "nil cooldown must be omitted from the wire form to keep older decoders byte-identical"
        )
        XCTAssertTrue(acceptedJSON.contains("\"decision\":\"accepted\""))

        let coolingAck = HermesRealtimeRelayMirrorAck(
            requestId: "req_xyz",
            decision: .coolingDown,
            detail: "Wait a sec",
            cooldownSecondsRemaining: 17
        )
        let coolingFrame = HermesRealtimeRelayFrame(
            type: .mediaMirrorAck,
            uid: "u1",
            connectionId: "c1",
            requestId: coolingAck.requestId,
            media: HermesRealtimeRelayMediaPayload(mirrorAck: coolingAck)
        )
        let coolingDecoded = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: try JSONEncoder().encode(coolingFrame)
        )
        XCTAssertEqual(coolingDecoded.media?.mirrorAck?.decision, .coolingDown)
        XCTAssertEqual(coolingDecoded.media?.mirrorAck?.cooldownSecondsRemaining, 17)
        XCTAssertEqual(coolingDecoded.media?.mirrorAck?.detail, "Wait a sec")
    }

    func testPresenceHeartbeatRoundTrips() throws {
        let heartbeat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(timeIntervalSince1970: 1_700_000_100),
            deviceDisplayName: "Alberto's iPhone",
            capabilities: ["mirror.viewer", "file.send", "call.receive"]
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: "u1",
            connectionId: "c1",
            media: HermesRealtimeRelayMediaPayload(presence: heartbeat)
        )

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: encoded)
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.media?.presence?.capabilities,
                       ["mirror.viewer", "file.send", "call.receive"])
    }

    func testCallInviteAndAckRoundTrip() throws {
        let invite = HermesRealtimeRelayCallInvite(
            requestId: "call_abc",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_200),
            requesterDisplayName: "Alberto's Android",
            callKind: "video"
        )
        let inviteFrame = HermesRealtimeRelayFrame(
            type: .mediaCallInvite,
            uid: "u1",
            connectionId: "c1",
            requestId: invite.requestId,
            media: HermesRealtimeRelayMediaPayload(callInvite: invite)
        )

        let inviteDecoded = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: try JSONEncoder().encode(inviteFrame)
        )
        XCTAssertEqual(inviteDecoded, inviteFrame)
        XCTAssertEqual(inviteDecoded.media?.callInvite?.requesterDisplayName, "Alberto's Android")
        XCTAssertEqual(inviteDecoded.media?.callInvite?.callKind, "video")

        let ack = HermesRealtimeRelayCallAck(
            requestId: invite.requestId,
            decision: .accepted,
            detail: "Mac accepted"
        )
        let ackFrame = HermesRealtimeRelayFrame(
            type: .mediaCallAck,
            uid: "u1",
            connectionId: "c1",
            requestId: ack.requestId,
            media: HermesRealtimeRelayMediaPayload(callAck: ack)
        )
        let ackDecoded = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: try JSONEncoder().encode(ackFrame)
        )
        XCTAssertEqual(ackDecoded.type, .mediaCallAck)
        XCTAssertEqual(ackDecoded.media?.callAck?.decision, .accepted)
        XCTAssertEqual(ackDecoded.media?.callAck?.detail, "Mac accepted")
    }

    func testStreamFrameEnvelopeRoundTripsEncodedMediaPacket() throws {
        let codec = MediaPacketCodec()
        let mediaFrame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 42,
            frameIndex: 7,
            presentationTimestampMillis: 1_234,
            payload: Data([0, 1, 2, 3])
        )
        let packet = try codec.encode(mediaFrame)
        let relayFrame = HermesRealtimeRelayFrame(
            type: .mediaStreamFrame,
            uid: "u1",
            connectionId: "c1",
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.screenVideo.rawValue,
                encodedFrameBase64: packet.base64EncodedString()
            )
        )

        let encoded = try JSONEncoder().encode(relayFrame)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: encoded)
        XCTAssertEqual(decoded.type, .mediaStreamFrame)
        XCTAssertEqual(decoded.media?.streamClass, MediaStreamClass.screenVideo.rawValue)
        XCTAssertEqual(decoded.media?.encodedFrameBase64, packet.base64EncodedString())

        let decodedPacket = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(decoded.media?.encodedFrameBase64)))
        let decodedMediaFrame = try codec.decode(decodedPacket).frame
        XCTAssertEqual(decodedMediaFrame, mediaFrame)
    }

    func testOlderDecoderIgnoresUnknownMirrorFields() throws {
        // Forward-compat probe: synthesize a payload with an extra future
        // field. The current decoder should still pull out the known
        // mirrorRequest body without throwing.
        let raw = #"""
        {
          "type": "media.mirror.request",
          "uid": "u1",
          "connectionId": "c1",
          "requestId": "req_abc",
          "protocolVersion": 1,
          "media": {
            "streamClass": "media.screen.video",
            "mirrorRequest": {
              "requestId": "req_abc",
              "requestedAt": 1700000000,
              "requesterDisplayName": "iPhone",
              "streamClass": "media.screen.video",
              "futureKnob": "ignore-me"
            }
          }
        }
        """#
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(decoded.type, .mediaMirrorRequest)
        XCTAssertEqual(decoded.media?.mirrorRequest?.requestId, "req_abc")
    }
}
