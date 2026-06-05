import CryptoKit
import Foundation
import LibSignalClient
import OpenBurnBarCore
@testable import OpenBurnBarSignalCore
import XCTest

final class SignalAtRestSealerTests: XCTestCase {
    private static let physicalMatrixPhonePrivateKeyB64 = "yGZ5zfds7ljkjsopcLya1ayDbjV+TCL6/b4BQBpqfV0="
    private static let physicalMatrixPhonePublicKeyB64 = "BVw7AC8duGgSdz/wLmMLMe+ymSUCcMkOcoJ+E6Eb+RhO"

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
                ),
            ],
            binding: binding
        )

        XCTAssertEqual(envelope.signalEnvelopeFormatVersion, 1)
        XCTAssertEqual(envelope.mode, CloudVaultCrypto.signalAtRestMode)
        XCTAssertEqual(envelope.relayEncryption, CloudVaultCrypto.signalAtRestEncryption)
        XCTAssertEqual(envelope.keyDelivery.wraps.count, 2)
        XCTAssertEqual(envelope.keyDelivery.contentKeyLength, 32)
        XCTAssertTrue(envelope.ciphertextLayer.payloadAADLabel.hasPrefix("bindingToAAD-sha256:"))
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: device.privateKey.serialize(),
                expectedBinding: binding
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
                )
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .bindingMismatch)
        }
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "escrow-key-1",
                recipientIdentityPrivateKey: escrow.privateKey.serialize(),
                expectedBinding: binding
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: escrow.privateKey.serialize(),
                expectedBinding: binding
            )
        )
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
                ),
            ],
            binding: binding
        )
        let mutated = CloudVaultSignalEnvelope(
            ciphertextLayer: CloudVaultSignalCiphertextLayer(
                payloadCiphertextB64: String(envelope.ciphertextLayer.payloadCiphertextB64.dropLast()) + "A",
                payloadAADLabel: envelope.ciphertextLayer.payloadAADLabel,
                schemaVersion: envelope.ciphertextLayer.schemaVersion
            ),
            keyDelivery: envelope.keyDelivery,
            binding: envelope.binding
        )

        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                mutated,
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityPrivateKey: identity.privateKey.serialize(),
                expectedBinding: binding
            )
        )
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

    func testPhysicalMatrixMacEmitsEnvelopeForMobile() throws {
        let binding = CloudVaultSignalBinding(
            uid: "physical-matrix-user",
            collection: "mobile_assistant_chats",
            docId: "mac-to-mobile-thread",
            field: "signalEnvelope"
        )
        let plaintext = "physical-matrix mac-to-mobile at-rest payload"
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            Data(plaintext.utf8),
            recipients: [
                OpenBurnBarSignalAtRestRecipient(
                    recipientKind: "device",
                    recipientIdentityKeyId: "physical-mobile-device_1",
                    publicKeyData: try decodeBase64(Self.physicalMatrixPhonePublicKeyB64)
                ),
            ],
            binding: binding
        )

        let vector = PhysicalMatrixVector(
            producer: "mac",
            consumer: "mobile",
            recipientIdentityKeyId: "physical-mobile-device_1",
            recipientPrivateKeyB64: Self.physicalMatrixPhonePrivateKeyB64,
            plaintext: plaintext,
            binding: binding,
            envelope: envelope
        )
        print("SIGNAL_MATRIX_MAC_TO_MOBILE_V1 \(try vector.encodedForLog())")
    }

    func testPhysicalMatrixMacOpensMobileProducedEnvelopeFromEnvironment() throws {
        let vector = try Self.matrixVector(fromEnvironment: "OPENBURNBAR_SIGNAL_MATRIX_MOBILE_TO_MAC_B64")
        XCTAssertEqual(vector.producer, "mobile")
        XCTAssertEqual(vector.consumer, "mac")
        let opened = try OpenBurnBarSignalAtRest.openPayload(
            vector.envelope,
            recipientIdentityKeyId: vector.recipientIdentityKeyId,
            recipientIdentityPrivateKey: try decodeBase64(vector.recipientPrivateKeyB64),
            expectedBinding: vector.binding
        )
        XCTAssertEqual(String(data: opened, encoding: .utf8), vector.plaintext)
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                vector.envelope,
                recipientIdentityKeyId: vector.recipientIdentityKeyId,
                recipientIdentityPrivateKey: try decodeBase64(vector.recipientPrivateKeyB64),
                expectedBinding: CloudVaultSignalBinding(
                    uid: vector.binding.uid,
                    collection: vector.binding.collection,
                    docId: "relocated-\(vector.binding.docId)",
                    field: vector.binding.field
                )
            )
        )
    }

    func testPhysicalMatrixMacOpensAndroidProducedEnvelopeFromEnvironment() throws {
        let vector = try Self.matrixVector(fromEnvironment: "OPENBURNBAR_SIGNAL_MATRIX_ANDROID_TO_MAC_B64")
        XCTAssertEqual(vector.producer, "android")
        XCTAssertEqual(vector.consumer, "mac")
        let opened = try OpenBurnBarSignalAtRest.openPayload(
            vector.envelope,
            recipientIdentityKeyId: vector.recipientIdentityKeyId,
            recipientIdentityPrivateKey: try decodeBase64(vector.recipientPrivateKeyB64),
            expectedBinding: vector.binding
        )
        XCTAssertEqual(String(data: opened, encoding: .utf8), vector.plaintext)
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                vector.envelope,
                recipientIdentityKeyId: vector.recipientIdentityKeyId,
                recipientIdentityPrivateKey: try decodeBase64(vector.recipientPrivateKeyB64),
                expectedBinding: CloudVaultSignalBinding(
                    uid: vector.binding.uid,
                    collection: vector.binding.collection,
                    docId: "relocated-\(vector.binding.docId)",
                    field: vector.binding.field
                )
            )
        )
    }

    private func loadKATVector() throws -> KATVector {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "SignalEnvelopeV1Vector", withExtension: "json"))
        return try JSONDecoder().decode(KATVector.self, from: Data(contentsOf: url))
    }

    private static func matrixVector(fromEnvironment name: String) throws -> PhysicalMatrixVector {
        guard let encoded = ProcessInfo.processInfo.environment[name], !encoded.isEmpty else {
            throw XCTSkip("Set \(name) to a base64 PhysicalMatrixVector produced by the peer-device test.")
        }
        let data = try decodeBase64(encoded)
        return try JSONDecoder().decode(PhysicalMatrixVector.self, from: data)
    }
}

private struct PhysicalMatrixVector: Codable {
    var producer: String
    var consumer: String
    var recipientIdentityKeyId: String
    var recipientPrivateKeyB64: String
    var plaintext: String
    var binding: CloudVaultSignalBinding
    var envelope: CloudVaultSignalEnvelope

    func encodedForLog() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self).base64EncodedString()
    }
}

private func decodeBase64(_ value: String) throws -> Data {
    try XCTUnwrap(Data(base64Encoded: value, options: [.ignoreUnknownCharacters]))
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
