import Foundation
import OpenBurnBarKernelModels
import XCTest

/// Characterization tests for the Hermes realtime-relay wire types.
///
/// Captured **before** the Phase-3 file-size decomposition of
/// `HermesRealtimeRelayTypes.swift` (unit P3-G9) and re-run after, to prove the
/// behavior-preserving split — relocating the value types into sibling files
/// within the same module, plus widening the shared `HermesRealtimeRelayDateCodec`
/// helper from `private` to module-`internal` — changes no Codable behavior.
///
/// These assertions go through the **public API only** (no `@testable` import),
/// so the exact same test text passes against the pre-split monolith and the
/// post-split sibling files. They lock: the ISO-8601 date wire format shared by
/// every relay type, the legacy Android `displayName` alias, and nil-field
/// omission. The cross-platform golden vectors in
/// `HermesRelayCrossPlatformVectorTests` remain the contract net for the frame
/// envelope itself.
final class HermesRealtimeRelayTypesCharacterizationTests: XCTestCase {

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Shared ISO-8601 date codec (exercised transitively, public API only)

    func test_relayDates_encodeAsISO8601StringWithFractionalSeconds() throws {
        // Unix 1_700_000_000 == 2023-11-14T22:13:20Z. A relay date must serialize
        // as an ISO-8601 *string* (not a JSONEncoder numeric Date) with explicit
        // millisecond precision and a UTC `Z` suffix.
        let ack = HermesRealtimeRelayLongTermReferenceAck(
            tokenValue: 42,
            decodedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let obj = try jsonObject(try JSONEncoder().encode(ack))
        let decodedAt = try XCTUnwrap(
            obj["decodedAt"] as? String,
            "relay dates must serialize as an ISO-8601 string, not a JSON number"
        )
        XCTAssertEqual(decodedAt, "2023-11-14T22:13:20.000Z")
    }

    func test_relayDateDecode_isStableUnderReEncoding() throws {
        // Sub-second instant: assert decode/encode is idempotent (the millisecond
        // truncation is applied once, then fixed) rather than asserting exact
        // float equality against the constructed value.
        let original = HermesRealtimeRelayLongTermReferenceAck(
            requestId: "req-1",
            tokenValue: 7,
            decodedAt: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        let once = try JSONDecoder().decode(
            HermesRealtimeRelayLongTermReferenceAck.self,
            from: try JSONEncoder().encode(original)
        )
        let twice = try JSONDecoder().decode(
            HermesRealtimeRelayLongTermReferenceAck.self,
            from: try JSONEncoder().encode(once)
        )
        XCTAssertEqual(once, twice, "relay date round-trip must be idempotent")
    }

    // MARK: - Representative value types per relocated cluster

    func test_longTermReferenceAck_roundTrips() throws {
        let value = HermesRealtimeRelayLongTermReferenceAck(
            requestId: "req-9",
            tokenValue: .max,
            decodedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let back = try JSONDecoder().decode(
            HermesRealtimeRelayLongTermReferenceAck.self,
            from: try JSONEncoder().encode(value)
        )
        XCTAssertEqual(value, back)
    }

    func test_presenceHeartbeat_roundTrips_andEmitsAndroidDisplayNameAlias() throws {
        let value = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceDisplayName: "Alberto's iPhone",
            capabilities: ["mirror", "unlock"],
            peerDeviceId: "peer-7"
        )
        let data = try JSONEncoder().encode(value)
        let obj = try jsonObject(data)
        // Load-bearing wire-compat: the canonical `deviceDisplayName` and the
        // legacy Android `displayName` alias must BOTH be emitted, same value.
        XCTAssertEqual(obj["deviceDisplayName"] as? String, "Alberto's iPhone")
        XCTAssertEqual(obj["displayName"] as? String, "Alberto's iPhone")
        let back = try JSONDecoder().decode(HermesRealtimeRelayPresenceHeartbeat.self, from: data)
        XCTAssertEqual(value, back)
    }

    func test_presenceHeartbeat_decodesLegacyAndroidDisplayNameAlias() throws {
        // Older Android peers send only `displayName`; it must populate the
        // canonical `deviceDisplayName`.
        let legacy = Data("""
        {"sentAt":"2023-11-14T22:13:20.000Z","displayName":"Pixel","capabilities":[]}
        """.utf8)
        let back = try JSONDecoder().decode(HermesRealtimeRelayPresenceHeartbeat.self, from: legacy)
        XCTAssertEqual(back.deviceDisplayName, "Pixel")
    }

    func test_mirrorSelection_decodesISOdate_butReEmitsNumber() throws {
        // The `numericEncodeIsoDecode` regime: MirrorDisplaySelection.selectedAt
        // TOLERATES an ISO-8601 string on the wire (older/cross-platform senders)
        // but RE-EMITS a JSON number (Swift-synthesized Date). A naive global
        // "iso everywhere" would regress this to a string. Lock both directions.
        let withISO = Data("""
        {"requestId":"r1","displayId":"d1","selectedAt":"2023-11-14T22:13:20.000Z"}
        """.utf8)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayMirrorDisplaySelection.self, from: withISO)
        XCTAssertEqual(decoded.selectedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        let reencoded = try jsonObject(try JSONEncoder().encode(decoded))
        XCTAssertTrue(reencoded["selectedAt"] is NSNumber,
                      "selectedAt must re-emit as a JSON number, not a string")
        XCTAssertFalse(reencoded["selectedAt"] is String)
    }

    func test_payload_roundTrips_andOmitsNilFields() throws {
        let value = HermesRealtimeRelayPayload(
            method: "session.create",
            sequence: 3,
            errorCode: "E_NONE"
        )
        let data = try JSONEncoder().encode(value)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["method"] as? String, "session.create")
        XCTAssertEqual(obj["sequence"] as? Int, 3)
        XCTAssertNil(obj["ciphertext"], "nil fields must be omitted from the wire")
        let back = try JSONDecoder().decode(HermesRealtimeRelayPayload.self, from: data)
        XCTAssertEqual(value, back)
    }
}
