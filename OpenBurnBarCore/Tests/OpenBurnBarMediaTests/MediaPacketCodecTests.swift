import XCTest
@testable import OpenBurnBarMedia

final class MediaPacketCodecTests: XCTestCase {
    func testRoundTripPreservesAllHeaderFields() throws {
        let codec = MediaPacketCodec()
        let payload = Data((0..<256).map { UInt8($0 & 0xFF) })
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe, .endOfGroup],
            gopID: 0xABCD_EF01,
            frameIndex: 17,
            presentationTimestampMillis: 1_700_000_000_000,
            payload: payload
        )

        let encoded = try codec.encode(frame)
        let (decoded, consumed) = try codec.decode(encoded)

        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(decoded, frame)
    }

    func testOversizePayloadIsRejected() {
        let codec = MediaPacketCodec(maxPayloadBytes: 64)
        let frame = MediaFrame(
            kind: .audioOpus,
            payload: Data(repeating: 0xFF, count: 128)
        )
        XCTAssertThrowsError(try codec.encode(frame)) { err in
            guard case let MediaPacketCodec.CodecError.payloadTooLarge(actual, max) = err else {
                XCTFail("expected payloadTooLarge, got \(err)")
                return
            }
            XCTAssertEqual(max, 64)
            XCTAssertGreaterThan(actual, 64)
        }
    }

    func testTruncatedEnvelopeRejectedAtFirstGuard() {
        let codec = MediaPacketCodec()
        // Length prefix is well-formed but the envelope is shorter than even
        // a header would require. First guard catches this.
        var tooShort = Data()
        var lengthBE = UInt32(100).bigEndian
        withUnsafeBytes(of: &lengthBE) { tooShort.append(contentsOf: $0) }
        tooShort.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try codec.decode(tooShort)) { err in
            guard case MediaPacketCodec.CodecError.envelopeTooShort = err else {
                XCTFail("expected envelopeTooShort, got \(err)")
                return
            }
        }
    }

    func testTruncatedEnvelopeRejectedAtPayloadGuard() {
        let codec = MediaPacketCodec()
        // Length prefix says 100 bytes follow; provide 18 (just the header
        // length). Passes the first guard, fails the inner length check.
        var partial = Data()
        var lengthBE = UInt32(100).bigEndian
        withUnsafeBytes(of: &lengthBE) { partial.append(contentsOf: $0) }
        partial.append(contentsOf: Array(repeating: UInt8(0), count: MediaFrame.headerByteCount))
        // Make the first byte a valid kind so we don't trip unknownKind
        // before headerTruncated.
        partial[4] = MediaFrame.Kind.videoNAL.rawValue

        XCTAssertThrowsError(try codec.decode(partial)) { err in
            guard case MediaPacketCodec.CodecError.headerTruncated = err else {
                XCTFail("expected headerTruncated, got \(err)")
                return
            }
        }
    }

    func testUnknownKindIsRejected() {
        let codec = MediaPacketCodec()
        // Build a minimum-length envelope (header only) with bogus kind 0x99.
        var bogus = Data()
        var lengthBE = UInt32(MediaFrame.headerByteCount).bigEndian
        withUnsafeBytes(of: &lengthBE) { bogus.append(contentsOf: $0) }
        bogus.append(0x99) // bogus kind
        bogus.append(0x00) // flags
        bogus.append(contentsOf: [0, 0, 0, 0]) // gopID
        bogus.append(contentsOf: [0, 0, 0, 0]) // frameIndex
        bogus.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // pts

        XCTAssertThrowsError(try codec.decode(bogus)) { err in
            guard case MediaPacketCodec.CodecError.unknownKind(let kind) = err else {
                XCTFail("expected unknownKind, got \(err)")
                return
            }
            XCTAssertEqual(kind, 0x99)
        }
    }

    func testGopBoundaryMetadataSurvivesRoundTrip() throws {
        let codec = MediaPacketCodec()
        let firstFrame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 100,
            frameIndex: 0,
            presentationTimestampMillis: 0,
            payload: Data([0xDE, 0xAD])
        )
        let lastFrame = MediaFrame(
            kind: .videoNAL,
            flags: [.endOfGroup],
            gopID: 100,
            frameIndex: 59,
            presentationTimestampMillis: 1_966,
            payload: Data([0xBE, 0xEF])
        )

        let firstEnvelope = try codec.encode(firstFrame)
        let lastEnvelope = try codec.encode(lastFrame)

        let (firstDecoded, _) = try codec.decode(firstEnvelope)
        let (lastDecoded, _) = try codec.decode(lastEnvelope)

        XCTAssertTrue(firstDecoded.flags.contains(.keyframe))
        XCTAssertFalse(firstDecoded.flags.contains(.endOfGroup))
        XCTAssertTrue(lastDecoded.flags.contains(.endOfGroup))
        XCTAssertFalse(lastDecoded.flags.contains(.keyframe))
        XCTAssertEqual(firstDecoded.gopID, lastDecoded.gopID)
    }
}
