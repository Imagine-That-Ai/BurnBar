#if canImport(CryptoKit)
import CryptoKit
#else
 import Crypto
#endif
import Foundation
import LibSignalClient
import OpenBurnBarCore
@testable import OpenBurnBarSignalCore
import XCTest

final class SignalAtRestSealerTests: XCTestCase {
    func testSignalIdentityKeyStorePersistsStableRecipientMaterial() throws {
        let service = "com.openburnbar.signal-identity.tests.\(UUID().uuidString)"
        let store = OpenBurnBarSignalIdentityKeyStore(service: service)
        let first = try store.loadOrCreate(uid: "uid-1", deviceId: "device-1")
        let second = try store.loadOrCreate(uid: "uid-1", deviceId: "device-1")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.identityKeyId, "device-1_1")
        XCTAssertEqual(first.keyVersion, 1)
        XCTAssertFalse(first.publicKeyData.isEmpty)
        XCTAssertFalse(first.privateKeyData.isEmpty)
        XCTAssertEqual(first.publicKeyFingerprint, Data(SHA256.hash(data: first.publicKeyData)).base64EncodedString())

        let opened = try OpenBurnBarSignalAtRest.atRestOpen(
            try OpenBurnBarSignalAtRest.atRestSeal(
                Data("identity store payload".utf8),
                recipientIdentityPublicKey: first.publicKeyData,
                binding: SignalEnvelopeAAD.Binding(
                    uid: "uid-1",
                    scope: .cloudvault,
                    collection: "pensieve",
                    docId: "doc-1",
                    field: "body",
                    mode: .atRest,
                    formatVersion: 1
                )
            ),
            recipientIdentityPrivateKey: second.privateKeyData,
            binding: SignalEnvelopeAAD.Binding(
                uid: "uid-1",
                scope: .cloudvault,
                collection: "pensieve",
                docId: "doc-1",
                field: "body",
                mode: .atRest,
                formatVersion: 1
            )
        )
        XCTAssertEqual(String(data: opened, encoding: .utf8), "identity store payload")
    }

    func testDirectAtRestSealOpenBindsCanonicalAAD() throws {
        let identity = IdentityKeyPair.generate()
        let binding = SignalEnvelopeAAD.Binding(
            uid: "uid-1",
            scope: .cloudvault,
            collection: "pensieve",
            docId: "doc-1",
            field: "body",
            mode: .atRest,
            formatVersion: 1
        )
        let plaintext = Data("swift direct signal at-rest payload".utf8)

        let ciphertext = try OpenBurnBarSignalAtRest.atRestSeal(
            plaintext,
            recipientIdentityPublicKey: identity.publicKey.serialize(),
            binding: binding
        )
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.atRestOpen(
                ciphertext,
                recipientIdentityPrivateKey: identity.privateKey.serialize(),
                binding: binding
            ),
            plaintext
        )

        let wrongBinding = SignalEnvelopeAAD.Binding(
            uid: "uid-1",
            scope: .cloudvault,
            collection: "pensieve",
            docId: "doc-2",
            field: "body",
            mode: .atRest,
            formatVersion: 1
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.atRestOpen(
                ciphertext,
                recipientIdentityPrivateKey: identity.privateKey.serialize(),
                binding: wrongBinding
            )
        )
    }

    func testCloudVaultSignalEnvelopeRoundTripsAndRejectsWrongRecipient() throws {
        let device = IdentityKeyPair.generate()
        let escrow = IdentityKeyPair.generate()
        let binding = CloudVaultSignalBinding(
            uid: "uid-1",
            collection: "pensieve",
            docId: "doc-42",
            field: "body"
        )
        let plaintext = Data("cloudvault signal payload".utf8)
        // The writing device ("device-key-1") is the sender and signs the envelope.
        let trusted = ["device-key-1": device.publicKey.serialize()]
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: [
                OpenBurnBarSignalAtRestRecipient(
                    recipientKind: "device",
                    recipientIdentityKeyId: "device-key-1",
                    publicKeyData: device.publicKey.serialize()
                ),
                OpenBurnBarSignalAtRestRecipient(
                    recipientKind: "escrow",
                    recipientIdentityKeyId: "escrow-key-1",
                    publicKeyData: escrow.publicKey.serialize()
                )
            ],
            binding: binding,
            senderIdentityKeyId: "device-key-1",
            senderIdentityPrivateKey: device.privateKey.serialize()
        )

        XCTAssertEqual(envelope.signalEnvelopeFormatVersion, 1)
        XCTAssertEqual(envelope.mode, CloudVaultCrypto.signalAtRestMode)
        XCTAssertEqual(envelope.relayEncryption, CloudVaultCrypto.signalAtRestEncryption)
        XCTAssertEqual(envelope.keyDelivery.wraps.count, 2)
        XCTAssertEqual(envelope.keyDelivery.contentKeyLength, 32)
        XCTAssertEqual(envelope.senderAuth?.senderIdentityKeyId, "device-key-1")
        XCTAssertTrue(envelope.ciphertextLayer.payloadAADLabel.hasPrefix("bindingToAAD-sha256:"))
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: device.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: trusted
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: device.privateKey.serialize(),
                expectedBinding: CloudVaultSignalBinding(
                    uid: "uid-1",
                    collection: "pensieve",
                    docId: "relocated-doc",
                    field: "body"
                ),
                trustedSenderPublicKeys: trusted
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .bindingMismatch)
        }
        // The escrow recipient can open, but still verifies the SAME sender signature.
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "escrow-key-1",
                recipientIdentityPrivateKey: escrow.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: trusted
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: escrow.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: trusted
            )
        )
        // SENDER AUTH: a reader that does not pin the sender as trusted rejects the
        // envelope (this is what stops a server-forged envelope from being accepted).
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: device.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: [:]
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .senderNotTrusted("device-key-1"))
        }
        // SENDER AUTH: a forged signature (sender id pinned to a DIFFERENT key) fails.
        let attacker = IdentityKeyPair.generate()
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: device.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: ["device-key-1": attacker.publicKey.serialize()]
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .senderSignatureInvalid)
        }
    }

    func testCrossDeviceFanOutAndRevokeFailClosedMatrix() throws {
        // Phase 2.5 G3 — one at-rest envelope sealed for a multi-device recipient list
        // must open on EVERY listed device (cross-device fan-out), while a device dropped
        // from the list (revoked/removed) and a foreign-uid device both fail closed.
        let deviceA = IdentityKeyPair.generate()
        let deviceB = IdentityKeyPair.generate()
        let escrow = IdentityKeyPair.generate()
        let recovery = IdentityKeyPair.generate()
        // A device of a DIFFERENT account that is never a recipient.
        let foreign = IdentityKeyPair.generate()

        let binding = CloudVaultSignalBinding(
            uid: "uid-1",
            collection: "pensieve",
            docId: "doc-fanout",
            field: "body"
        )
        let plaintext = Data("cross-device fan-out payload".utf8)

        // deviceA is the writing device: it is the sender and signs the envelope.
        let trusted = ["deviceA_1": deviceA.publicKey.serialize()]

        // The full device list: two user devices, an escrow recipient, a recovery recipient.
        let fanOut: [(kind: String, id: String, keypair: IdentityKeyPair)] = [
            ("device", "deviceA_1", deviceA),
            ("device", "deviceB_1", deviceB),
            ("escrow", "escrow_1", escrow),
            ("recovery", "recovery_1", recovery)
        ]

        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: fanOut.map {
                OpenBurnBarSignalAtRestRecipient(
                    recipientKind: $0.kind,
                    recipientIdentityKeyId: $0.id,
                    publicKeyData: $0.keypair.publicKey.serialize()
                )
            },
            binding: binding,
            senderIdentityKeyId: "deviceA_1",
            senderIdentityPrivateKey: deviceA.privateKey.serialize()
        )

        // FAN-OUT: one wrap per listed recipient, and EVERY listed recipient opens to the
        // exact same plaintext off the SAME sealed envelope.
        XCTAssertEqual(envelope.keyDelivery.wraps.count, fanOut.count)
        for recipient in fanOut {
            XCTAssertEqual(
                try OpenBurnBarSignalAtRest.openPayload(
                    envelope,
                    recipientIdentityKeyId: recipient.id,
                    recipientIdentityPrivateKey: recipient.keypair.privateKey.serialize(),
                    expectedBinding: binding,
                    trustedSenderPublicKeys: trusted
                ),
                plaintext,
                "listed recipient \(recipient.id) must open the fan-out envelope"
            )
        }

        // FOREIGN-UID, case 1 — a device that is not on the list has no wrap, so open fails
        // closed with missingRecipientWrap (sender-auth passes first: deviceA is pinned).
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "foreign_1",
                recipientIdentityPrivateKey: foreign.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: trusted
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .missingRecipientWrap("foreign_1"))
        }

        // FOREIGN-UID, case 2 — claiming a LISTED id ("deviceB_1") with the wrong (foreign)
        // private key fails closed with the key-binding guard, not a silent wrong-plaintext.
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "deviceB_1",
                recipientIdentityPrivateKey: foreign.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: trusted
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .recipientPrivateKeyMismatch)
        }

        // REVOKE / REMOVE — re-seal the SAME payload with deviceB dropped from the list.
        // The revoked device's wrap is absent and it can no longer open the new envelope.
        let afterRevoke = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: fanOut.filter { $0.id != "deviceB_1" }.map {
                OpenBurnBarSignalAtRestRecipient(
                    recipientKind: $0.kind,
                    recipientIdentityKeyId: $0.id,
                    publicKeyData: $0.keypair.publicKey.serialize()
                )
            },
            binding: binding,
            senderIdentityKeyId: "deviceA_1",
            senderIdentityPrivateKey: deviceA.privateKey.serialize()
        )
        XCTAssertEqual(afterRevoke.keyDelivery.wraps.count, fanOut.count - 1)
        XCTAssertNil(
            afterRevoke.keyDelivery.wraps.first { $0.recipientIdentityKeyId == "deviceB_1" },
            "the revoked device's wrap must be absent from the re-sealed envelope"
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                afterRevoke,
                recipientIdentityKeyId: "deviceB_1",
                recipientIdentityPrivateKey: deviceB.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: trusted
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .missingRecipientWrap("deviceB_1"))
        }
        // The surviving devices still open the post-revocation envelope.
        for recipient in fanOut where recipient.id != "deviceB_1" {
            XCTAssertEqual(
                try OpenBurnBarSignalAtRest.openPayload(
                    afterRevoke,
                    recipientIdentityKeyId: recipient.id,
                    recipientIdentityPrivateKey: recipient.keypair.privateKey.serialize(),
                    expectedBinding: binding,
                    trustedSenderPublicKeys: trusted
                ),
                plaintext
            )
        }
    }

    func testServerForgedEnvelopeIsRejectedBySenderAuth() throws {
        // Models the P0-1 attack: a malicious server holds the victim's PUBLIC identity
        // key (recipient) and forges an envelope sealed to it, signed by the server's OWN
        // (untrusted) key. The reader pins only the legitimate device key, so the forgery
        // is rejected and the caller falls back to the non-forgeable legacy payload.
        let victim = IdentityKeyPair.generate()
        let server = IdentityKeyPair.generate()
        let binding = CloudVaultSignalBinding(uid: "uid-1", collection: "conversations", docId: "doc-9", field: "signalEnvelope")
        let forged = try OpenBurnBarSignalAtRest.sealPayload(
            Data("forged approval policy".utf8),
            recipients: [OpenBurnBarSignalAtRestRecipient(
                recipientKind: "device",
                recipientIdentityKeyId: "victim-device_1",
                publicKeyData: victim.publicKey.serialize()
            )],
            binding: binding,
            senderIdentityKeyId: "victim-device_1", // server LIES about who sent it
            senderIdentityPrivateKey: server.privateKey.serialize() // but can only sign with its own key
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                forged,
                recipientIdentityKeyId: "victim-device_1",
                recipientIdentityPrivateKey: victim.privateKey.serialize(),
                expectedBinding: binding,
                // The reader pins the victim device's REAL public key.
                trustedSenderPublicKeys: ["victim-device_1": victim.publicKey.serialize()]
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .senderSignatureInvalid)
        }
    }

    func testCloudVaultSignalEnvelopeRejectsPayloadTamper() throws {
        let identity = IdentityKeyPair.generate()
        let binding = CloudVaultSignalBinding(
            uid: "uid-1",
            collection: "pensieve",
            docId: "doc-42",
            field: "body"
        )
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            Data("tamper me".utf8),
            recipients: [
                OpenBurnBarSignalAtRestRecipient(
                    recipientKind: "device",
                    recipientIdentityKeyId: "device-key-1",
                    publicKeyData: identity.publicKey.serialize()
                )
            ],
            binding: binding,
            senderIdentityKeyId: "device-key-1",
            senderIdentityPrivateKey: identity.privateKey.serialize()
        )
        // Tamper the ciphertext but keep the (now stale) sender signature: the signature
        // covers the ciphertext, so verification fails closed BEFORE any AEAD attempt.
        let mutated = CloudVaultSignalEnvelope(
            ciphertextLayer: CloudVaultSignalCiphertextLayer(
                payloadCiphertextB64: String(envelope.ciphertextLayer.payloadCiphertextB64.dropLast()) + "A",
                payloadAADLabel: envelope.ciphertextLayer.payloadAADLabel,
                schemaVersion: envelope.ciphertextLayer.schemaVersion
            ),
            keyDelivery: envelope.keyDelivery,
            binding: envelope.binding,
            senderAuth: envelope.senderAuth
        )

        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                mutated,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: identity.privateKey.serialize(),
                expectedBinding: binding,
                trustedSenderPublicKeys: ["device-key-1": identity.publicKey.serialize()]
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .senderSignatureInvalid)
        }
    }

    func testOpensCommittedNodeSealedKatAndTamperFailsClosed() throws {
        let vector = try loadKATVector()
        let binding = try vector.signalBinding()
        let opened = try OpenBurnBarSignalAtRest.atRestOpen(
            vector.ciphertext,
            recipientIdentityPrivateKey: vector.recipientPrivateKey,
            binding: binding
        )
        XCTAssertEqual(opened, vector.plaintext)
        XCTAssertEqual(String(data: opened, encoding: .utf8), "cross-language interop secret — node sealed")

        let wrongBinding = SignalEnvelopeAAD.Binding(
            uid: vector.binding.uid,
            scope: .cloudvault,
            collection: vector.binding.collection,
            docId: "tampered-doc",
            field: vector.binding.field,
            mode: .atRest,
            formatVersion: vector.binding.formatVersion
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.atRestOpen(
                vector.ciphertext,
                recipientIdentityPrivateKey: vector.recipientPrivateKey,
                binding: wrongBinding
            )
        )
    }

    private func loadKATVector() throws -> KATVector {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SignalEnvelopeV1Vector", withExtension: "json"))
        return try JSONDecoder().decode(KATVector.self, from: Data(contentsOf: url))
    }
}

private struct KATVector: Decodable {
    struct Binding: Decodable {
        var uid: String
        var scope: String
        var collection: String
        var docId: String
        var field: String
        var mode: String
        var formatVersion: Int
    }

    var binding: Binding
    var recipientPrivateKeyB64: String
    var plaintextB64: String
    var ciphertextB64: String

    var recipientPrivateKey: Data {
        Data(base64Encoded: recipientPrivateKeyB64)!
    }

    var plaintext: Data {
        Data(base64Encoded: plaintextB64)!
    }

    var ciphertext: Data {
        Data(base64Encoded: ciphertextB64)!
    }

    func signalBinding() throws -> SignalEnvelopeAAD.Binding {
        guard binding.scope == "cloudvault", binding.mode == "at-rest" else {
            throw OpenBurnBarSignalCoreError.invalidEnvelope
        }
        return SignalEnvelopeAAD.Binding(
            uid: binding.uid,
            scope: .cloudvault,
            collection: binding.collection,
            docId: binding.docId,
            field: binding.field,
            mode: .atRest,
            formatVersion: binding.formatVersion
        )
    }
}
