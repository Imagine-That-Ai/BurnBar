import XCTest
@testable import OpenBurnBarCore

/// Wire-format pins for the F2/F7/F10 additive relay-type fields:
/// `PhoneControlSigningKeyKind` (+ `keyKind` on the authority envelope),
/// `HermesRealtimeRelayControlSealKeyEnvelope` (control + media seal wraps),
/// `sealedFrameBase64`/`controlSealKey` on the control payload,
/// `sealedFramePosition` on the media payload, `mediaSealKey` on the mirror
/// request, and `streamingCapabilities` on the mirror ack. Every field is
/// additive — pre-F2/F7/F10 JSON MUST keep decoding, and new fields MUST
/// survive a round trip — so these tests pin both directions.
final class HermesRealtimeRelayTypesTests: XCTestCase {

    // MARK: - PhoneControlSigningKeyKind (F2)

    func testSigningKeyKindRawValuesArePinnedToTheWireStrings() {
        XCTAssertEqual(PhoneControlSigningKeyKind.ed25519.rawValue, "ed25519")
        XCTAssertEqual(PhoneControlSigningKeyKind.secureEnclaveP256.rawValue, "se-p256")
        XCTAssertEqual(PhoneControlSigningKeyKind.allCases.count, 2)
        XCTAssertEqual(PhoneControlSigningKeyKind.legacyDefault, .ed25519)
    }

    func testSigningKeyKindRejectsUnknownWireValues() {
        XCTAssertNil(PhoneControlSigningKeyKind(rawValue: "se-p384"))
        XCTAssertNil(PhoneControlSigningKeyKind(rawValue: "ED25519"))
        XCTAssertNil(PhoneControlSigningKeyKind(rawValue: ""))
    }

    // MARK: - Authority envelope keyKind (F2)

    private func makeAuthorityEnvelope(keyKind: PhoneControlSigningKeyKind? = nil) -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "phone-peer",
            counter: 7,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            intentHashBlake3: String(repeating: "a", count: 64),
            signatureEd25519: "c2lnbmF0dXJl",
            attestationHashBlake3: nil,
            keyKind: keyKind
        )
    }

    func testAuthorityEnvelopeResolvedKeyKindDefaultsAbsentToLegacyEd25519() {
        XCTAssertEqual(makeAuthorityEnvelope(keyKind: nil).resolvedKeyKind, .ed25519)
        XCTAssertEqual(makeAuthorityEnvelope(keyKind: .secureEnclaveP256).resolvedKeyKind, .secureEnclaveP256)
        XCTAssertEqual(makeAuthorityEnvelope(keyKind: .ed25519).resolvedKeyKind, .ed25519)
    }

    func testAuthorityEnvelopeOmitsKeyKindOnTheWireWhenNil() throws {
        let data = try JSONEncoder().encode(makeAuthorityEnvelope(keyKind: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Pre-F2 receivers must see byte-compatible envelopes: no keyKind key at all.
        XCTAssertNil(object["keyKind"])
    }

    func testAuthorityEnvelopeEncodesSecureEnclaveKeyKindAsSeP256() throws {
        let data = try JSONEncoder().encode(makeAuthorityEnvelope(keyKind: .secureEnclaveP256))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["keyKind"] as? String, "se-p256")

        let decoded = try JSONDecoder().decode(HermesRealtimeRelayAuthorityEnvelope.self, from: data)
        XCTAssertEqual(decoded.keyKind, .secureEnclaveP256)
        XCTAssertEqual(decoded.resolvedKeyKind, .secureEnclaveP256)
    }

    func testAuthorityEnvelopeDecodesPreF2JSONWithoutKeyKind() throws {
        let legacyJSON = """
        {
          "peerNodeId": "phone-peer",
          "counter": 3,
          "timestamp": 1750000000,
          "intentHashBlake3": "\(String(repeating: "b", count: 64))",
          "signatureEd25519": "c2ln"
        }
        """
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayAuthorityEnvelope.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(decoded.keyKind)
        XCTAssertEqual(decoded.resolvedKeyKind, .ed25519)
        XCTAssertEqual(decoded.counter, 3)
    }

    // MARK: - Control seal key envelope (F10 / reused for F7)

    private func makeSealKeyEnvelope(counter: Int64 = 11) -> HermesRealtimeRelayControlSealKeyEnvelope {
        HermesRealtimeRelayControlSealKeyEnvelope(
            encBase64: Data("enc-bytes".utf8).base64EncodedString(),
            wrappedKeyBase64: Data("wrapped-key".utf8).base64EncodedString(),
            senderDeviceId: "iphone-device",
            senderPeerNodeId: "relay-sender-peer",
            senderKeyId: "key-1",
            senderCounter: counter,
            relayKeyVersion: 3
        )
    }

    func testControlSealKeyEnvelopeCodableRoundTrip() throws {
        let envelope = makeSealKeyEnvelope()
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayControlSealKeyEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.senderDeviceId, "iphone-device")
        XCTAssertEqual(decoded.senderPeerNodeId, "relay-sender-peer")
        XCTAssertEqual(decoded.senderKeyId, "key-1")
        XCTAssertEqual(decoded.senderCounter, 11)
        XCTAssertEqual(decoded.relayKeyVersion, 3)
    }

    // MARK: - Control payload seal fields (F10)

    func testControlPayloadRoundTripsSealFieldsAndKeepsStreamClassVisible() throws {
        let payload = HermesRealtimeRelayControlPayload(
            streamClass: "control.input",
            sessionId: "session-1",
            controlSealKey: makeSealKeyEnvelope(),
            sealedFrameBase64: Data("sealed-shell".utf8).base64EncodedString()
        )
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayControlPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.streamClass, "control.input")
        XCTAssertEqual(decoded.controlSealKey, makeSealKeyEnvelope())
        XCTAssertEqual(decoded.sealedFrameBase64, Data("sealed-shell".utf8).base64EncodedString())
    }

    func testControlPayloadDecodesPreF10JSONWithoutSealFields() throws {
        let legacyJSON = """
        {"streamClass": "control.input", "sessionId": "session-legacy"}
        """
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayControlPayload.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(decoded.controlSealKey)
        XCTAssertNil(decoded.sealedFrameBase64)
        XCTAssertEqual(decoded.sessionId, "session-legacy")
    }

    // MARK: - Sealed media frame position (F7)

    func testSealedMediaFramePositionRoundTripsThroughMediaPayload() throws {
        let position = HermesRealtimeRelaySealedMediaFramePosition(kind: 1, gopId: 42, frameIndex: 7)
        let payload = HermesRealtimeRelayMediaPayload(
            streamClass: "media.screen",
            encodedFrameBase64: Data("sealed-frame".utf8).base64EncodedString(),
            sealedFramePosition: position
        )
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayMediaPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded.sealedFramePosition, position)
        XCTAssertEqual(decoded.sealedFramePosition?.kind, 1)
        XCTAssertEqual(decoded.sealedFramePosition?.gopId, 42)
        XCTAssertEqual(decoded.sealedFramePosition?.frameIndex, 7)
        // The seal positions ride alongside the sealed frame, never instead of it.
        XCTAssertEqual(decoded.encodedFrameBase64, payload.encodedFrameBase64)
    }

    func testMediaPayloadDecodesPreF7JSONWithoutSealedFramePosition() throws {
        let legacyJSON = """
        {"streamClass": "media.screen", "encodedFrameBase64": "cGxhaW4="}
        """
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayMediaPayload.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(decoded.sealedFramePosition)
        XCTAssertEqual(decoded.encodedFrameBase64, "cGxhaW4=")
    }

    // MARK: - Mirror request mediaSealKey (F7, hand-written Codable)

    private func makeMirrorRequest(
        mediaSealKey: HermesRealtimeRelayControlSealKeyEnvelope? = nil
    ) -> HermesRealtimeRelayMirrorRequest {
        HermesRealtimeRelayMirrorRequest(
            requestId: "mirror-1",
            requestedAt: Date(timeIntervalSince1970: 1_750_000_000),
            requesterDisplayName: "Alberto's iPhone",
            streamClass: "media.screen.video",
            mediaSealKey: mediaSealKey
        )
    }

    func testMirrorRequestRoundTripsMediaSealKey() throws {
        let request = makeMirrorRequest(mediaSealKey: makeSealKeyEnvelope(counter: 99))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["mediaSealKey"], "hand-written encode(to:) must emit the wrap")

        let decoded = try JSONDecoder().decode(HermesRealtimeRelayMirrorRequest.self, from: data)
        XCTAssertEqual(decoded.mediaSealKey, makeSealKeyEnvelope(counter: 99))
        XCTAssertEqual(decoded.requestId, "mirror-1")
    }

    func testMirrorRequestDecodesPreF7WireFormWithoutMediaSealKey() throws {
        // Pre-F7 senders encode no `mediaSealKey` key at all; encoding a
        // request without the wrap reproduces that exact wire form.
        let data = try JSONEncoder().encode(makeMirrorRequest(mediaSealKey: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["mediaSealKey"], "absent wrap must stay byte-compatible with pre-F7 senders")

        let decoded = try JSONDecoder().decode(HermesRealtimeRelayMirrorRequest.self, from: data)
        XCTAssertNil(decoded.mediaSealKey, "pre-F7 mirror requests carry no wrap and must stay decodable")
        XCTAssertEqual(decoded.requestId, "mirror-1")
    }

    // MARK: - Mirror ack streamingCapabilities (F7)

    func testMirrorAckRoundTripsStreamingCapabilities() throws {
        let capabilities = HermesRealtimeRelayStreamingCapabilities(
            codecCapabilities: [],
            source: "videotoolbox-probe"
        )
        let ack = HermesRealtimeRelayMirrorAck(
            requestId: "mirror-1",
            decision: .accepted,
            streamingCapabilities: capabilities
        )
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayMirrorAck.self,
            from: JSONEncoder().encode(ack)
        )
        XCTAssertEqual(decoded.streamingCapabilities, capabilities)
        XCTAssertEqual(decoded.streamingCapabilities?.source, "videotoolbox-probe")
    }

    func testMirrorAckDecodesPreF7JSONWithoutStreamingCapabilities() throws {
        let legacyJSON = """
        {"requestId": "mirror-legacy", "decision": "accepted"}
        """
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayMirrorAck.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(decoded.streamingCapabilities)
        XCTAssertEqual(decoded.decision, .accepted)
    }

    // MARK: - Frame-level round trip with seal fields

    func testControlClassifyFrameRoundTripsSealEstablishment() throws {
        let frame = HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: "uid-1",
            connectionId: "conn-1",
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                authorityPeerNodeId: "phone-peer",
                controlSealKey: makeSealKeyEnvelope()
            )
        )
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: JSONEncoder().encode(frame)
        )
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.control?.controlSealKey, makeSealKeyEnvelope())
        XCTAssertEqual(decoded.control?.authorityPeerNodeId, "phone-peer")
    }
}
