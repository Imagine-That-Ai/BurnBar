import XCTest
@testable import OpenBurnBarMedia

final class MediaFrameV2CodecTests: XCTestCase {
    func testRoundTripSeparatesMetadataFromPayloadWithExplicitLengths() throws {
        let codec = MediaFrameV2Codec()
        let metadata = try MediaFrameV2Metadata(
            codec: .hevc,
            longTermReferenceToken: MercuryLTRToken(value: 9_001)
        ).encode()
        let frame = MediaFrameV2(
            kind: .videoDatagram,
            flags: 0x0003,
            gopID: 99,
            frameIndex: 7,
            presentationTimestampMillis: 1_777_777,
            metadata: metadata,
            payload: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        let encoded = try codec.encode(frame, negotiatedVersion: .v2)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded.consumed, encoded.count)
        XCTAssertEqual(decoded.frame, frame)
        XCTAssertEqual(try MediaFrameV2Metadata.decode(decoded.frame.metadata).codec, .hevc)
        XCTAssertEqual(try MediaFrameV2Metadata.decode(decoded.frame.metadata).longTermReferenceToken?.value, 9_001)
    }

    func testEmptyMetadataDecodesToEmptyMetadataModel() throws {
        let metadata = try MediaFrameV2Metadata.decode(Data())

        XCTAssertNil(metadata.codec)
        XCTAssertNil(metadata.longTermReferenceToken)
    }

    func testEncodeRequiresV2Negotiation() {
        let codec = MediaFrameV2Codec()
        let frame = MediaFrameV2(kind: .rtcReceiverReport, metadata: Data([0x01]), payload: Data([0x02]))

        XCTAssertThrowsError(try codec.encode(frame, negotiatedVersion: .v1)) { error in
            XCTAssertEqual(error as? MediaFrameV2Codec.CodecError, .notNegotiated)
        }
    }

    func testEncodedEnvelopeDetectionUsesLengthPrefixedMagic() throws {
        let v2 = try MediaFrameV2Codec().encode(
            MediaFrameV2(kind: .videoDatagram, metadata: Data([0x01]), payload: Data([0x02])),
            negotiatedVersion: .v2
        )
        let v1 = try MediaPacketCodec().encode(
            MediaFrame(kind: .videoNAL, gopID: 1, frameIndex: 2, payload: Data([0x03]))
        )

        XCTAssertTrue(MediaFrameV2Codec.isEncodedEnvelope(v2))
        XCTAssertFalse(MediaFrameV2Codec.isEncodedEnvelope(v1))
        XCTAssertFalse(MediaFrameV2Codec.isEncodedEnvelope(Data(MediaFrameV2Codec.magic.prefix(3))))
    }

    func testV1CodecRejectsV2EnvelopeRatherThanMisparsingItAsKnownFrame() throws {
        let v2 = try MediaFrameV2Codec().encode(
            MediaFrameV2(kind: .videoDatagram, metadata: Data([0x01]), payload: Data([0x02])),
            negotiatedVersion: .v2
        )

        XCTAssertThrowsError(try MediaPacketCodec().decode(v2)) { error in
            guard case MediaPacketCodec.CodecError.unknownKind = error else {
                return XCTFail("expected v1 unknownKind for v2 magic, got \(error)")
            }
        }
    }

    func testMetadataLengthMismatchIsRejected() throws {
        var encoded = try MediaFrameV2Codec().encode(
            MediaFrameV2(kind: .codecNegotiation, metadata: Data([0x01, 0x02]), payload: Data([0x03])),
            negotiatedVersion: .v2
        )
        // Corrupt metadata length to claim more bytes than the envelope carries.
        encoded[30] = 0x00
        encoded[31] = 0x00
        encoded[32] = 0x00
        encoded[33] = 0xFF

        XCTAssertThrowsError(try MediaFrameV2Codec().decode(encoded)) { error in
            XCTAssertEqual(error as? MediaFrameV2Codec.CodecError, .headerTruncated)
        }
    }
}
