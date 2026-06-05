import Foundation
import XCTest
@testable import OpenBurnBarCore

/// Type-only coverage for the additive, flag-OFF at-rest ``CloudVaultSignalEnvelope``.
///
/// There is no Swift sealing yet (blocked on the libsignal Swift binding), so
/// these tests freeze the TYPE: its Codable JSON shape (which must match the
/// shared TS `SignalEnvelope` at-rest variant byte-for-byte at the field level),
/// its constant defaults, and that its binding bridges into the single canonical
/// AAD serializer ``signalEnvelopeBindingToAAD(_:)`` rather than re-deriving the
/// string.
final class CloudVaultSignalEnvelopeTests: XCTestCase {
    private func makeEnvelope() -> CloudVaultSignalEnvelope {
        CloudVaultSignalEnvelope(
            ciphertextLayer: CloudVaultSignalCiphertextLayer(
                payloadCiphertextB64: "ZG9jLWNpcGhlcnRleHQ=",
                payloadAADLabel: "cloudvault:cloud_search_knowledge/sealedCiphertext",
                schemaVersion: 1
            ),
            keyDelivery: CloudVaultSignalAtRestKeyDelivery(wraps: [
                CloudVaultSignalAtRestWrap(
                    recipientKind: "device",
                    recipientIdentityKeyId: "device-1",
                    recipientIdentityKeyB64: "cHVibGljLWtleQ==",
                    sealedContentKeyB64: "c2VhbGVkLWtleQ=="
                )
            ]),
            binding: CloudVaultSignalBinding(
                uid: "uid-1",
                collection: "cloud_search_knowledge",
                docId: "doc-1",
                field: "sealedCiphertext"
            )
        )
    }

    func test_defaultsMatchTheSharedContract() {
        let envelope = makeEnvelope()
        XCTAssertEqual(envelope.signalEnvelopeFormatVersion, 1)
        XCTAssertEqual(envelope.mode, "at-rest")
        XCTAssertEqual(envelope.relayEncryption, "signal-hpke-identity-seal-v1")
        XCTAssertEqual(envelope.keyDelivery.scheme, "signal-hpke-identity-seal-v1")
        XCTAssertEqual(envelope.keyDelivery.contentKeyLength, 32)
        XCTAssertEqual(envelope.binding.scope, "cloudvault")
        XCTAssertEqual(envelope.binding.mode, "at-rest")
        XCTAssertEqual(envelope.binding.formatVersion, 1)
    }

    func test_codableRoundTripAndJSONShape() throws {
        let envelope = makeEnvelope()
        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The at-rest envelope MUST NOT carry relayKeyVersion (the contract rejects
        // it on at-rest) — Codable omits the absent field entirely.
        XCTAssertNil(json["relayKeyVersion"])
        XCTAssertEqual(json["mode"] as? String, "at-rest")
        XCTAssertEqual(json["relayEncryption"] as? String, "signal-hpke-identity-seal-v1")

        let binding = try XCTUnwrap(json["binding"] as? [String: Any])
        XCTAssertEqual(binding["scope"] as? String, "cloudvault")
        XCTAssertNil(binding["clientId"]) // gateway-only field absent for cloudvault
        XCTAssertNil(binding["slotId"])

        let decoded = try JSONDecoder().decode(CloudVaultSignalEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func test_bindingBridgesIntoTheCanonicalAADSerializer() throws {
        let binding = CloudVaultSignalBinding(
            uid: "uid-1",
            collection: "cloud_search_knowledge",
            docId: "doc-1",
            field: "sealedCiphertext"
        )
        let aad = try signalEnvelopeBindingToAAD(binding.aadBinding)
        // Byte-identical to the TS contract's at-rest serialization (cloudvault
        // scope, empty clientId/slotId segments held in fixed positions).
        XCTAssertEqual(
            aad,
            "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|uid-1||cloud_search_knowledge|doc-1|sealedCiphertext||1"
        )
    }
}
