import Foundation
import XCTest
import OpenBurnBarCore
import OpenBurnBarSignalCore
@testable import OpenBurnBarMobile

final class PensieveMemorySearchSignalTests: XCTestCase {
    func testDecodeHitOpensSignalEnvelopeBoundToSealedCiphertext() throws {
        let uid = "pensieve-signal-user-\(UUID().uuidString)"
        let vectorId = "vector-signal"
        let vaultKey = Data(repeating: 0x13, count: 32)
        let identity = try OpenBurnBarSignalIdentityKeyStore(
            service: "com.openburnbar.tests.pensieve-signal-\(UUID().uuidString)"
        ).loadOrCreate(uid: uid, deviceId: "device-1")

        let raw: [String: Any] = [
            "vectorId": vectorId,
            "score": NSNumber(value: 0.91),
            "signalEnvelope": try Self.signalEnvelopeDictionary(
                plaintext: "Signal memory text",
                uid: uid,
                vectorId: vectorId,
                identity: identity
            ),
            "sealedMetadata": try Self.sealedTextDictionary(
                Self.sealedMetadata(
                    [
                        "source_path": "docs/signal.md",
                        "page_title": "Signal Notes",
                        "category": "docs"
                    ],
                    keyData: vaultKey
                )
            )
        ]

        let hit = try XCTUnwrap(
            FunctionsPensieveMemorySearcher.decodeHit(
                raw,
                uid: uid,
                vaultKey: vaultKey,
                signalIdentity: identity
            )
        )

        XCTAssertEqual(hit.id, vectorId)
        XCTAssertEqual(hit.text, "Signal memory text")
        XCTAssertEqual(hit.sourcePath, "docs/signal.md")
        XCTAssertEqual(hit.title, "Signal Notes")
        XCTAssertEqual(hit.category, "docs")
        XCTAssertEqual(hit.score, 0.91, accuracy: 0.0001)
    }

    func testDecodeHitRejectsRelocatedSignalEnvelope() throws {
        let uid = "pensieve-relocation-user-\(UUID().uuidString)"
        let vaultKey = Data(repeating: 0x27, count: 32)
        let identity = try OpenBurnBarSignalIdentityKeyStore(
            service: "com.openburnbar.tests.pensieve-relocation-\(UUID().uuidString)"
        ).loadOrCreate(uid: uid, deviceId: "device-1")

        let raw: [String: Any] = [
            "vectorId": "vector-relocated",
            "signalEnvelope": try Self.signalEnvelopeDictionary(
                plaintext: "must not move",
                uid: uid,
                vectorId: "vector-original",
                identity: identity
            )
        ]

        XCTAssertNil(
            FunctionsPensieveMemorySearcher.decodeHit(
                raw,
                uid: uid,
                vaultKey: vaultKey,
                signalIdentity: identity
            ),
            "Pensieve Signal envelopes must be bound to cloud_search_knowledge/{vectorId}/sealedCiphertext."
        )
    }

    func testDecodeHitFallsBackToLegacyCiphertextWhenOptionalSignalEnvelopeCannotOpen() throws {
        let uid = "pensieve-legacy-user-\(UUID().uuidString)"
        let vectorId = "vector-legacy"
        let vaultKey = Data(repeating: 0x42, count: 32)
        let legacyCiphertext = try CloudVaultCrypto.sealText("legacy memory text", keyData: vaultKey)

        let raw: [String: Any] = [
            "vectorId": vectorId,
            "signalEnvelope": ["not": "a signal envelope"],
            "ciphertext": Self.sealedTextDictionary(legacyCiphertext)
        ]

        let hit = try XCTUnwrap(
            FunctionsPensieveMemorySearcher.decodeHit(
                raw,
                uid: uid,
                vaultKey: vaultKey,
                signalIdentity: nil
            )
        )

        XCTAssertEqual(hit.id, vectorId)
        XCTAssertEqual(hit.text, "legacy memory text")
    }

    private static func signalEnvelopeDictionary(
        plaintext: String,
        uid: String,
        vectorId: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) throws -> [String: Any] {
        let binding = CloudVaultSignalBinding(
            uid: uid,
            collection: "cloud_search_knowledge",
            docId: vectorId,
            field: "sealedCiphertext"
        )
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            Data(plaintext.utf8),
            recipients: [identity.atRestRecipient()],
            binding: binding
        )
        return try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
    }

    private static func sealedMetadata(_ metadata: [String: String], keyData: Data) throws -> CloudVaultSealedText {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return try CloudVaultCrypto.sealText(json, keyData: keyData)
    }

    private static func sealedTextDictionary(_ envelope: CloudVaultSealedText) -> [String: Any] {
        var dictionary: [String: Any] = [
            "algorithm": envelope.algorithm,
            "keyVersion": envelope.keyVersion,
            "nonce": envelope.nonce,
            "ciphertext": envelope.ciphertext,
            "tag": envelope.tag
        ]
        if let schemaVersion = envelope.schemaVersion {
            dictionary["schemaVersion"] = schemaVersion
        }
        if let aad = envelope.aad {
            dictionary["aad"] = aad
        }
        return dictionary
    }
}
