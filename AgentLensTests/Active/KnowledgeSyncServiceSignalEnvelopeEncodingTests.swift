import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class KnowledgeSyncServiceSignalEnvelopeEncodingTests: XCTestCase {
    func testEncodeKeepsFlagOffPayloadLegacyOnly() throws {
        let batch = try makeBatch(vectorId: "pensieve-vector-1", plaintext: "legacy-only chunk")

        let payload = KnowledgeSyncService.encode(batch)
        let vectors = try XCTUnwrap(payload["vectors"] as? [[String: Any]])
        let vector = try XCTUnwrap(vectors.first)

        XCTAssertNil(vector["signalEnvelope"])
        XCTAssertNotNil(vector["sealedCiphertext"])
        XCTAssertEqual(vector["vectorId"] as? String, "pensieve-vector-1")
        XCTAssertEqual(vector["sourceKind"] as? String, "repo_docs")
    }

    func testEncodeAddsOptionalSignalEnvelopeWithoutDroppingLegacyCiphertext() throws {
        let batch = try makeBatch(vectorId: "pensieve-vector-2", plaintext: "signal sidecar chunk")
        let signalEnvelope: [String: Any] = [
            "signalEnvelopeFormatVersion": 1,
            "mode": "at-rest",
            "relayEncryption": CloudVaultCrypto.signalAtRestEncryption,
            "binding": [
                "uid": "uid-1",
                "scope": "cloudvault",
                "collection": "cloud_search_knowledge",
                "docId": "pensieve-vector-2",
                "field": "sealedCiphertext",
                "mode": "at-rest",
                "formatVersion": 1
            ]
        ]

        let payload = try KnowledgeSyncService.encode(batch) { vector in
            XCTAssertEqual(vector.vectorId, "pensieve-vector-2")
            return signalEnvelope
        }
        let vectors = try XCTUnwrap(payload["vectors"] as? [[String: Any]])
        let vector = try XCTUnwrap(vectors.first)

        XCTAssertNotNil(vector["sealedCiphertext"])
        XCTAssertNotNil(vector["sealedMetadata"])
        XCTAssertEqual(vector["signalEnvelope"] as? NSDictionary, signalEnvelope as NSDictionary)
    }

    private func makeBatch(vectorId: String, plaintext: String) throws -> PensieveKnowledgeBatch {
        let vaultKey = Data(repeating: 0x42, count: 32)
        let sealedCiphertext = try CloudVaultCrypto.sealText(plaintext, keyData: vaultKey)
        let sealedMetadata = try CloudVaultCrypto.sealText("{}", keyData: vaultKey)
        let vector = PensieveKnowledgeVector(
            vectorId: vectorId,
            cloakedVector: [0.1, 0.2, 0.3],
            sealedCiphertext: sealedCiphertext,
            sealedMetadata: sealedMetadata,
            dedupHash: String(repeating: "a", count: 64),
            sourceKind: .repoDocs,
            chunkIndex: 0,
            byteCount: plaintext.utf8.count
        )
        return PensieveKnowledgeBatch(
            sourceSlug: "repo-doc",
            slugHmac: String(repeating: "b", count: 64),
            embeddingModelVersion: "test",
            vectors: [vector]
        )
    }
}
