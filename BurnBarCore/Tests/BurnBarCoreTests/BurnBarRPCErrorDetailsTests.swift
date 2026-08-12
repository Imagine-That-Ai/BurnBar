@testable import BurnBarCore
import XCTest

/// VAL-RPC-016 contract-layer regression tests (M1 repair,
/// rpc-error-details-repair): `BurnBarRPCError.details` is non-optional,
/// always encodes, and round-trips through the response envelope.
final class BurnBarRPCErrorDetailsTests: XCTestCase {
    func test_detailsAlwaysEncodesEvenWithInitDefault() throws {
        // The `details` field is non-optional: it must ALWAYS appear in the
        // encoded error object, even when the init default is used.
        let error = BurnBarRPCError(code: -32601, message: "Unsupported method.")
        let data = try JSONEncoder().encode(error)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"details\""), "details key must always encode: \(json)")
        let decoded = try JSONDecoder().decode(BurnBarRPCError.self, from: data)
        XCTAssertEqual(decoded.code, -32601)
        XCTAssertEqual(decoded.message, "Unsupported method.")
        XCTAssertEqual(decoded.details, "", "init default must be an empty string")
    }

    func test_detailsExplicitValueRoundTrips() throws {
        let detailed = BurnBarRPCError(
            code: -32002,
            message: "Frame too large.",
            details: "max_bytes=65536; received_bytes=65537"
        )
        let data = try JSONEncoder().encode(detailed)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            json.contains("\"details\":\"max_bytes=65536; received_bytes=65537\""),
            "details value must encode: \(json)"
        )
        let decoded = try JSONDecoder().decode(BurnBarRPCError.self, from: data)
        XCTAssertEqual(decoded.details, "max_bytes=65536; received_bytes=65537")
    }

    func test_detailsSurvivesResponseEnvelopeRoundTrip() throws {
        let detailed = BurnBarRPCError(
            code: -32002,
            message: "Frame too large.",
            details: "max_bytes=65536; received_bytes=65537"
        )
        let envelope = BurnBarRPCResponseEnvelope<BurnBarHealthResponse>(
            id: "no-id",
            protocolVersion: BurnBarProtocolVersion.current,
            result: nil,
            error: detailed
        )
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"details\""), "envelope error must carry details: \(json)")
        let decoded = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarHealthResponse>.self,
            from: data
        )
        XCTAssertEqual(decoded.error?.details, "max_bytes=65536; received_bytes=65537")
        XCTAssertNil(decoded.result)
    }
}
