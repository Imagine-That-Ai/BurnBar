import XCTest
@testable import OpenBurnBarFirestoreModels

final class HermesGatewayFirestoreModelsTests: XCTestCase {
    func testClientDocRoundTripsRelaySignalRatchetAndRuntimeMetadata() throws {
        let json = """
        {
          "id": "client-1",
          "uid": "uid-1",
          "displayName": "Desktop Gateway",
          "status": "active",
          "tokenHash": "hash",
          "tokenPreview": "tok_1234",
          "agentClientSigningPublicKeyBase64": "agent-signing",
          "agentClientSigningKeyId": "agent-key-1",
          "popRequired": true,
          "popVersion": 1,
          "scopes": ["chat", "attachments"],
          "homeDestinationId": "dest-1",
          "expiresAt": "2026-06-13T00:00:00Z",
          "rotatedAt": "2026-06-12T00:00:00Z",
          "lastSeenAt": "2026-06-12T00:01:00Z",
          "agentRelayPublicKey": "agent-relay",
          "agentRelayKeyVersion": 7,
          "agentRelayEncryption": "hpke-v3",
          "agentSupportsRelayEnvelopeVersions": [2, 3],
          "agentPreferredRelayEnvelopeVersion": 3,
          "agentSupportsHpkeV3": true,
          "agentSupportsSignalEnvelope": true,
          "agentPlatform": "macos",
          "agentAppBuild": "100",
          "phoneRelayPublicKey": "phone-relay",
          "phoneRelayKeyVersion": 8,
          "phoneRelayEncryption": "hpke-v3",
          "phoneSupportsRelayEnvelopeVersions": [3],
          "phonePreferredRelayEnvelopeVersion": 3,
          "phoneSupportsHpkeV3": true,
          "phoneSupportsSignalEnvelope": true,
          "phonePlatform": "ios",
          "phoneAppBuild": "200",
          "agentRatchetIdentityPublicKey": "agent-id",
          "agentRatchetSigningPublicKey": "agent-sign",
          "agentRatchetSignedPreKeyPublicKey": "agent-pre",
          "agentRatchetSignedPreKeyId": "agent-pre-1",
          "agentRatchetSignedPreKeySignature": "agent-pre-sig",
          "agentSupportsRatchetV1": true,
          "phoneRatchetIdentityPublicKey": "phone-id",
          "phoneRatchetSigningPublicKey": "phone-sign",
          "phoneRatchetSignedPreKeyPublicKey": "phone-pre",
          "phoneRatchetSignedPreKeyId": "phone-pre-1",
          "phoneRatchetSignedPreKeySignature": "phone-pre-sig",
          "phoneSupportsRatchetV1": true,
          "supportsRatchetV1": true,
          "supportsRelayEnvelopeVersions": [3],
          "preferredRelayEnvelopeVersion": 3,
          "supportsHpkeV3": true,
          "supportsSignalEnvelope": true,
          "relayCapable": true,
          "runtimeModelId": "gpt-4.1",
          "runtimeProviderId": "openai",
          "runtimeModelOptions": [
            {
              "providerId": "openai",
              "providerName": "OpenAI",
              "modelId": "gpt-4.1",
              "displayName": "GPT-4.1"
            }
          ],
          "runtimeUpdatedAt": "2026-06-12T00:02:00Z",
          "agentVersion": "1.0.0",
          "pendingModelId": "gpt-4.1-mini",
          "pendingModelRequestedAt": "2026-06-12T00:03:00Z",
          "oversightMode": "step",
          "revokedAt": null,
          "createdAt": "2026-06-12T00:00:00Z",
          "updatedAt": "2026-06-12T00:04:00Z",
          "schemaVersion": 3
        }
        """

        let decoded = try decode(FirestoreHermesGatewayClientDoc.self, from: json)
        let roundTrip = try JSONDecoder().decode(
            FirestoreHermesGatewayClientDoc.self,
            from: JSONEncoder().encode(decoded)
        )

        XCTAssertEqual(roundTrip, decoded)
        XCTAssertTrue(try XCTUnwrap(decoded.agentSupportsSignalEnvelope))
        XCTAssertTrue(try XCTUnwrap(decoded.phoneSupportsSignalEnvelope))
        XCTAssertEqual(decoded.runtimeModelOptions?.first?.modelId, "gpt-4.1")
    }

    func testEventDocRoundTripsRelayRatchetAndSignalEnvelopes() throws {
        let json = """
        {
          "id": "event-1",
          "sequence": 42,
          "kind": "message",
          "destinationId": "dest-1",
          "targetClientId": "client-1",
          "threadId": "thread-1",
          "senderId": "phone",
          "senderDisplayName": "Phone",
          "text": "sealed",
          "modelId": "gpt-4.1",
          "attachmentIds": ["attachment-1"],
          "relayEnvelope": {
            "payloadCiphertext": "ciphertext",
            "wrappedKey": "wrapped",
            "relayEncryption": "hpke-v3",
            "relayKeyVersion": 3,
            "enc": "enc",
            "senderPublicKey": "sender"
          },
          "ratchetEnvelope": {
            "header": {
              "version": 1,
              "algorithm": "x3dh-ratchet-v1",
              "sessionID": "session-1",
              "senderDeviceID": "phone-1",
              "receiverDeviceID": "agent-1",
              "ratchetPublicKeyBase64": "ratchet",
              "previousChainLength": 2,
              "messageNumber": 5,
              "epoch": 9
            },
            "ciphertextBase64": "ratchet-ciphertext"
          },
          "signalEnvelope": {
            "signalEnvelopeFormatVersion": 1,
            "mode": "at_rest",
            "relayKeyVersion": 3,
            "relayEncryption": "signal-v1",
            "ciphertextLayer": {
              "payloadCiphertextB64": "payload",
              "payloadAADLabel": "gateway.event",
              "schemaVersion": 1
            },
            "keyDelivery": {
              "scheme": "sealed_content_key",
              "signalMessageType": 3,
              "signalMessageB64": "message",
              "senderIdentityKeyId": "sender-key",
              "ratchetEpochHint": 9,
              "wraps": [
                {
                  "recipientKind": "phone",
                  "recipientIdentityKeyId": "phone-key",
                  "recipientIdentityKeyB64": "phone-identity",
                  "sealedContentKeyB64": "sealed-key"
                }
              ],
              "contentKeyLength": 32
            },
            "binding": {
              "uid": "uid-1",
              "scope": "user",
              "clientId": "client-1",
              "collection": "events",
              "docId": "event-1",
              "field": "signalEnvelope",
              "slotId": "primary",
              "mode": "at_rest",
              "formatVersion": 1
            }
          },
          "createdAt": "2026-06-12T00:00:00Z",
          "schemaVersion": 3
        }
        """

        let decoded = try decode(FirestoreHermesGatewayEventDoc.self, from: json)
        let roundTrip = try JSONDecoder().decode(
            FirestoreHermesGatewayEventDoc.self,
            from: JSONEncoder().encode(decoded)
        )

        XCTAssertEqual(roundTrip, decoded)
        XCTAssertEqual(decoded.ratchetEnvelope?.header.sessionID, "session-1")
        XCTAssertEqual(decoded.signalEnvelope?.keyDelivery.wraps?.first?.recipientKind, "phone")
    }

    func testAttachmentManifestDocRequiresStorageMetadataAndRoundTripsOptionalSealedPayloads() throws {
        let json = """
        {
          "id": "attachment-1",
          "clientId": "client-1",
          "destinationId": "dest-1",
          "fileName": "transcript.txt",
          "contentType": "text/plain",
          "byteCount": 128,
          "storagePath": "users/uid-1/hermes/attachment-1",
          "status": "uploaded",
          "relayEnvelope": {
            "payloadCiphertext": "ciphertext",
            "wrappedKey": "wrapped",
            "relayEncryption": "hpke-v3",
            "relayKeyVersion": 3
          },
          "createdAt": "2026-06-12T00:00:00Z",
          "updatedAt": "2026-06-12T00:01:00Z",
          "expiresAt": "2026-06-13T00:00:00Z",
          "uploadedAt": "2026-06-12T00:02:00Z",
          "finalizedAt": "2026-06-12T00:03:00Z",
          "sha256": "abc123",
          "storageGeneration": "generation-1",
          "schemaVersion": 3
        }
        """

        let decoded = try decode(FirestoreHermesGatewayAttachmentManifestDoc.self, from: json)
        let roundTrip = try JSONDecoder().decode(
            FirestoreHermesGatewayAttachmentManifestDoc.self,
            from: JSONEncoder().encode(decoded)
        )

        XCTAssertEqual(roundTrip, decoded)
        XCTAssertEqual(decoded.contentType, "text/plain")
        XCTAssertEqual(decoded.byteCount, 128)
        XCTAssertEqual(decoded.storagePath, "users/uid-1/hermes/attachment-1")
        XCTAssertEqual(decoded.status, "uploaded")
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
