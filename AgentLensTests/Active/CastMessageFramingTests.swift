import XCTest
@testable import OpenBurnBar

final class CastMessageFramingTests: XCTestCase {

    // MARK: - Round-trip

    func testEncodeDecode_roundTrip_preservesAllFields() {
        let original = CastMessage(
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.receiver",
            payloadUTF8: #"{"type":"GET_STATUS","requestId":1}"#
        )
        let bytes = CastFraming.encode(original)
        var buffer = bytes
        let decoded = CastFraming.decode(from: &buffer)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(buffer.isEmpty, "Buffer should be drained after a single full frame")
    }

    func testEncodeDecode_emptyPayload_isStillValid() {
        let original = CastMessage(
            sourceId: "src",
            destinationId: "dst",
            namespace: "urn:x-cast:com.google.cast.tp.heartbeat",
            payloadUTF8: ""
        )
        var bytes = CastFraming.encode(original)
        let decoded = CastFraming.decode(from: &bytes)
        XCTAssertEqual(decoded, original)
    }

    func testEncodeDecode_unicodePayload() {
        let original = CastMessage(
            sourceId: "sender-0",
            destinationId: "transport-12345",
            namespace: "urn:x-cast:es.offd.dashcast",
            payloadUTF8: #"{"url":"http://öpenburnbar.local:8787/render.html"}"#
        )
        var bytes = CastFraming.encode(original)
        let decoded = CastFraming.decode(from: &bytes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Streaming

    func testDecode_handlesPartialFrame_returnsNilThenSucceeds() {
        let msg = CastMessage(
            sourceId: "s",
            destinationId: "d",
            namespace: "ns",
            payloadUTF8: "hello"
        )
        let bytes = CastFraming.encode(msg)
        var buffer = bytes.prefix(bytes.count - 3)
        XCTAssertNil(CastFraming.decode(from: &buffer), "Partial frame should not decode")
        buffer.append(bytes.suffix(3))
        let decoded = CastFraming.decode(from: &buffer)
        XCTAssertEqual(decoded, msg)
    }

    func testDecode_concatenatedFrames_drainsBoth() {
        let m1 = CastMessage(sourceId: "a", destinationId: "b", namespace: "ns1", payloadUTF8: "p1")
        let m2 = CastMessage(sourceId: "c", destinationId: "d", namespace: "ns2", payloadUTF8: "p2")
        var buffer = CastFraming.encode(m1) + CastFraming.encode(m2)
        XCTAssertEqual(CastFraming.decode(from: &buffer), m1)
        XCTAssertEqual(CastFraming.decode(from: &buffer), m2)
        XCTAssertNil(CastFraming.decode(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - Forward compatibility

    func testDecode_unknownField_isSkippedGracefully() {
        // Build a body manually with field 99 that the schema doesn't know.
        var body = Data()
        // Field 1: protocol_version = 0
        body.append(0x08); body.append(0x00)
        // Field 2: source_id = "x"
        body.append(0x12); body.append(0x01); body.append(0x78)
        // Field 3: destination_id = "y"
        body.append(0x1A); body.append(0x01); body.append(0x79)
        // Field 4: namespace = "ns"
        body.append(0x22); body.append(0x02); body.append(0x6E); body.append(0x73)
        // Field 5: payload_type = 0
        body.append(0x28); body.append(0x00)
        // Field 6: payload_utf8 = "p"
        body.append(0x32); body.append(0x01); body.append(0x70)
        // Unknown field 99, wire type 0 (varint), value 42.
        // Tag = (99 << 3) | 0 = 0x318 → encoded as varint multi-byte tag.
        // Use a smaller field number with type 0 to keep the test focused — field 8 wire 0 = 0x40.
        body.append(0x40); body.append(0x2A)

        let decoded = CastFraming.decodeBody(body)
        XCTAssertEqual(decoded?.sourceId, "x")
        XCTAssertEqual(decoded?.destinationId, "y")
        XCTAssertEqual(decoded?.namespace, "ns")
        XCTAssertEqual(decoded?.payloadUTF8, "p")
    }

    // MARK: - Length prefix

    func testDecode_returnsNilForBufferShorterThanLengthPrefix() {
        var buffer = Data([0x01, 0x02])
        XCTAssertNil(CastFraming.decode(from: &buffer))
    }
}
