import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore

final class PensieveKnowledgeChunkerTests: XCTestCase {
    private let key = Data(repeating: 0x42, count: 32)

    func test_prepareBatch_sealsTextAndProducesCommitShape() throws {
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: "BurnBar seals chunk text on device before it ever reaches the cloud.",
            sourceKind: .notes,
            sourcePath: "notes/security.md",
            sourceSlug: "notes-security-md",
            vaultKey: key,
            title: "Security note",
            category: "architecture"
        )
        XCTAssertEqual(batch.sourceSlug, "notes-security-md")
        XCTAssertEqual(batch.embeddingModelVersion, PensieveVectorCloak.deterministicModelVersion)
        XCTAssertFalse(batch.vectors.isEmpty)

        let vector = try XCTUnwrap(batch.vectors.first)
        // Cloaked vector is exactly 384-dim — matches commitKnowledgeBatch's guard.
        XCTAssertEqual(vector.cloakedVector.count, PensieveVectorCloak.embeddingDim)
        // vectorId == contentHash, lowercase hex (64) — passes requireHexDigest.
        XCTAssertEqual(vector.vectorId, vector.contentHash)
        XCTAssertEqual(vector.contentHash.count, 64)
        XCTAssertTrue(vector.contentHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // sealedCiphertext decrypts back to the chunk plaintext with the vault key.
        let decrypted = try CloudVaultCrypto.openText(vector.sealedCiphertext, keyData: key)
        XCTAssertTrue(decrypted.contains("BurnBar seals chunk text"))
        // sealedMetadata decrypts to JSON carrying source_path + category.
        let metadataJSON = try CloudVaultCrypto.openText(vector.sealedMetadata, keyData: key)
        let metadata = try JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any]
        XCTAssertEqual(metadata?["source_path"] as? String, "notes/security.md")
        XCTAssertEqual(metadata?["category"] as? String, "architecture")
        XCTAssertEqual(metadata?["sourceKind"] as? String, "notes")
        XCTAssertEqual(vector.sourceKind, .notes)
    }

    func test_redactSecrets_stripsKnownShapes() {
        let raw = "use sk-ABCDEFGHIJKLMNOPQRSTUVWX and token=supersecretvalue here"
        let cleaned = PensieveKnowledgeChunker.redactSecrets(raw)
        XCTAssertFalse(cleaned.contains("sk-ABCDEFGHIJKLMNOPQRSTUVWX"))
        XCTAssertTrue(cleaned.contains("[REDACTED_API_KEY]"))
        XCTAssertFalse(cleaned.contains("supersecretvalue"))
    }

    func test_chunk_respectsByteCeiling() {
        let big = String(repeating: "knowledge ", count: 2000) // ~20 KB
        let chunks = PensieveKnowledgeChunker.chunk(big, maxBytes: 1024)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf8.count, 1024)
        }
    }

    func test_prepareBatch_dedupesIdenticalChunks() throws {
        // A repeated paragraph (same contentHash) collapses to one vector.
        let para = "Repeated fact about the vault key never leaving the device."
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: para,
            sourceKind: .repoDocs,
            sourcePath: "docs/a.md",
            sourceSlug: "docs-a-md",
            vaultKey: key
        )
        let ids = Set(batch.vectors.map(\.vectorId))
        XCTAssertEqual(ids.count, batch.vectors.count) // no duplicate vectorIds
    }
}
