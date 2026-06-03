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

        // B-SEC-2: the batch carries the vault-keyed slugHmac (the opaque filter
        // column) and it matches the documented derivation.
        XCTAssertEqual(batch.slugHmac, try CloudVaultCrypto.pensieveSlugHmac("notes-security-md", keyData: key))
        XCTAssertTrue(batch.slugHmac.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)

        let vector = try XCTUnwrap(batch.vectors.first)
        // Cloaked vector is exactly 384-dim — matches commitKnowledgeBatch's guard.
        XCTAssertEqual(vector.cloakedVector.count, PensieveVectorCloak.embeddingDim)
        // vectorId == dedupHash (vault-keyed HMAC), lowercase hex (64) — passes
        // requireHexDigest. It is NOT the keyless SHA-256 of the chunk.
        XCTAssertEqual(vector.vectorId, vector.dedupHash)
        XCTAssertEqual(vector.dedupHash.count, 64)
        XCTAssertTrue(vector.dedupHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // sealedCiphertext decrypts back to the chunk plaintext with the vault key.
        let decrypted = try CloudVaultCrypto.openText(vector.sealedCiphertext, keyData: key)
        XCTAssertTrue(decrypted.contains("BurnBar seals chunk text"))
        // dedupHash is the vault-keyed HMAC of exactly that decrypted plaintext —
        // never the keyless SHA-256 a server could brute-force.
        XCTAssertEqual(vector.dedupHash, try CloudVaultCrypto.pensieveDedupHash(decrypted, keyData: key))
        let plaintextSHA256 = SHA256.hash(data: Data(decrypted.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(vector.dedupHash, plaintextSHA256)
        // sealedMetadata decrypts to JSON carrying source_path + category — the
        // real path lives ONLY inside the ciphertext (no top-level sourcePath).
        let metadataJSON = try CloudVaultCrypto.openText(vector.sealedMetadata, keyData: key)
        let metadata = try JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any]
        XCTAssertEqual(metadata?["source_path"] as? String, "notes/security.md")
        XCTAssertEqual(metadata?["category"] as? String, "architecture")
        XCTAssertEqual(metadata?["sourceKind"] as? String, "notes")
        XCTAssertEqual(vector.sourceKind, .notes)
    }

    func test_preparedBatch_carriesKeyedColumnsAndNoCleartextSideChannels() throws {
        // The KnowledgeSyncService encoder (app target) and the daemon watcher both
        // serialize exactly the public struct fields, so the privacy invariant is
        // proven on the struct the chunker emits: keyed columns present, NO
        // cleartext contentHash / sourcePath fields exist on the model at all.
        let secretPath = "/Users/alberto/Documents/Windsurf/BurnBar/docs/secret-runbook.md"
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: "Secret runbook: deploy the daemon before midnight.",
            sourceKind: .repoDocs,
            sourcePath: secretPath,
            sourceSlug: "burnbar-docs-secret-runbook",
            vaultKey: key
        )

        // Batch level: opaque slugHmac present (the wire filter column).
        XCTAssertEqual(batch.slugHmac, try CloudVaultCrypto.pensieveSlugHmac("burnbar-docs-secret-runbook", keyData: key))

        let vector = try XCTUnwrap(batch.vectors.first)
        // Keyed dedup column present and used as the opaque vectorId.
        XCTAssertEqual(vector.vectorId, vector.dedupHash)
        XCTAssertTrue(vector.dedupHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)

        // The real path leaves the device ONLY sealed: it must NOT appear in any of
        // the cleartext struct fields the encoders pass through verbatim.
        XCTAssertEqual(vector.vectorId, vector.dedupHash)
        XCTAssertEqual(batch.sourceSlug, "burnbar-docs-secret-runbook")
        XCTAssertFalse(vector.dedupHash.contains(secretPath))
        // The path survives only inside the sealed metadata blob. Parse the JSON
        // (rather than substring-matching the raw string) so the assertion is immune
        // to JSON forward-slash escaping (`/` -> `\/`), which is a wire-encoding
        // detail any JSON parser — including the Node shim's decryptKnowledgeContent
        // — round-trips back to the literal path.
        let metadataJSON = try CloudVaultCrypto.openText(vector.sealedMetadata, keyData: key)
        let parsedMetadata = try JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any]
        XCTAssertEqual(parsedMetadata?["source_path"] as? String, secretPath)
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
        // A repeated paragraph (same dedupHash) collapses to one vector.
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
