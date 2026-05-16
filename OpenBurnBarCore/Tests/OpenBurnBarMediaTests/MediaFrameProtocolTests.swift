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
}
