import CryptoKit
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
