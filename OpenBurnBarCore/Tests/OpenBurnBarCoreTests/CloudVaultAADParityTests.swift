import XCTest
@testable import OpenBurnBarCore

/// Cross-language known-answer test for the Cloud Vault at-rest AAD context (RR-8).
///
/// These golden strings are duplicated verbatim in the Android KAT
/// `android/app/src/test/java/com/openburnbar/data/cloud/CloudVaultAadParityTest.kt`.
/// Because the AES-256-GCM additional-authenticated-data is exactly
/// `CloudVaultAADContext.stringValue` UTF-8 bytes, ANY divergence between the Swift
/// and Kotlin string here causes a payload sealed on one platform to silently fail
/// to decrypt on the other (the original RR-8 cross-platform data-loss). If you change
/// the format on one side, this test (and its Kotlin twin) must be updated together.
final class CloudVaultAADParityTests: XCTestCase {
    func testAssistantChatAADStringMatchesGolden() throws {
        let ctx = try CloudVaultAADContext(
            uid: "UID123",
            collection: "mobile_assistant_chats",
            docID: "THREAD456",
            field: "sealedPayload"
        )
        XCTAssertEqual(
            ctx.stringValue,
            "OpenBurnBar-CloudVault-aad-v2|UID123|mobile_assistant_chats|THREAD456|sealedPayload|2|sealedPayload"
        )
    }

    func testMissionRequestAADStringMatchesGolden() throws {
        let ctx = try CloudVaultAADContext(
            uid: "UID123",
            collection: "cli_agent_mission_requests",
            docID: "REQ789",
            field: "sealedPayload"
        )
        XCTAssertEqual(
            ctx.stringValue,
            "OpenBurnBar-CloudVault-aad-v2|UID123|cli_agent_mission_requests|REQ789|sealedPayload|2|sealedPayload"
        )
    }

    func testMissionStateAADStringMatchesGolden() throws {
        let ctx = try CloudVaultAADContext(
            uid: "UID123",
            collection: "cli_agent_mission_requests",
            docID: "REQ789",
            field: "sealedStatePayload"
        )
        XCTAssertEqual(
            ctx.stringValue,
            "OpenBurnBar-CloudVault-aad-v2|UID123|cli_agent_mission_requests|REQ789|sealedStatePayload|2|sealedStatePayload"
        )
    }

    func testMissionEventAADStringMatchesGolden() throws {
        let ctx = try CloudVaultAADContext(
            uid: "UID123",
            collection: "cli_agent_mission_requests/events",
            docID: "REQ789/EVT1",
            field: "sealedPayload"
        )
        XCTAssertEqual(
            ctx.stringValue,
            "OpenBurnBar-CloudVault-aad-v2|UID123|cli_agent_mission_requests/events|REQ789/EVT1|sealedPayload|2|sealedPayload"
        )
    }

    /// The GCM AAD bytes ARE the stringValue UTF-8 — assert that contract explicitly so a
    /// future refactor can't silently change what gets authenticated.
    func testAADDataIsStringValueUTF8() throws {
        let ctx = try CloudVaultAADContext(
            uid: "UID123",
            collection: "mobile_assistant_chats",
            docID: "THREAD456",
            field: "sealedPayload"
        )
        XCTAssertEqual(ctx.data, Data(ctx.stringValue.utf8))
    }

    // MARK: - RR-8 Pensieve chunk path-AAD binding

    /// Golden string for a Pensieve knowledge chunk's sealed TEXT. The doc id is the
    /// chunk's `vectorId` (= dedupHash), the collection is `cloud_search_knowledge`,
    /// and the field is `sealedCiphertext` — byte-identical to the server's Signal
    /// binding (`knowledgeMemory.ts`) and the at-rest `CloudVaultSignalBinding`. Any
    /// divergence here transplants chunks across docs/accounts.
    func testPensieveChunkCiphertextAADStringMatchesGolden() throws {
        let ctx = try PensieveKnowledgeChunker.chunkAADContext(
            uid: "UID123",
            vectorId: "VEC789",
            field: PensieveKnowledgeChunker.chunkCiphertextField
        )
        XCTAssertEqual(
            ctx.stringValue,
            "OpenBurnBar-CloudVault-aad-v2|UID123|cloud_search_knowledge|VEC789|sealedCiphertext|2|sealedCiphertext"
        )
    }

    /// Golden string for a Pensieve chunk's sealed METADATA blob (field
    /// `sealedMetadata`), same coordinates as the ciphertext bar the field.
    func testPensieveChunkMetadataAADStringMatchesGolden() throws {
        let ctx = try PensieveKnowledgeChunker.chunkAADContext(
            uid: "UID123",
            vectorId: "VEC789",
            field: PensieveKnowledgeChunker.chunkMetadataField
        )
        XCTAssertEqual(
            ctx.stringValue,
            "OpenBurnBar-CloudVault-aad-v2|UID123|cloud_search_knowledge|VEC789|sealedMetadata|2|sealedMetadata"
        )
    }

    /// Seal-then-open round-trip: a chunk prepared WITH a uid is path-bound and the
    /// matching opener (same uid + vectorId) recovers both the text and the metadata.
    func testPensieveChunkPathBoundSealOpenRoundTrip() throws {
        let key = Data(repeating: 0x42, count: 32)
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: "BurnBar path-binds each Pensieve chunk to its Firestore identity.",
            sourceKind: .notes,
            sourcePath: "notes/rr8.md",
            sourceSlug: "notes-rr8-md",
            vaultKey: key,
            uid: "UID123",
            category: "security"
        )
        let vector = try XCTUnwrap(batch.vectors.first)

        // The sealed text is schemaVersion-2 path-bound (AAD carries the real id).
        XCTAssertEqual(vector.sealedCiphertext.schemaVersion, CloudVaultCrypto.currentSealedTextSchemaVersion)
        XCTAssertEqual(
            vector.sealedCiphertext.aad,
            try PensieveKnowledgeChunker.chunkAADContext(
                uid: "UID123",
                vectorId: vector.vectorId,
                field: PensieveKnowledgeChunker.chunkCiphertextField
            ).stringValue
        )

        let text = try PensieveKnowledgeChunker.openChunkText(
            vector.sealedCiphertext,
            keyData: key,
            uid: "UID123",
            vectorId: vector.vectorId
        )
        XCTAssertTrue(text.contains("path-binds each Pensieve chunk"))

        let metadataJSON = try PensieveKnowledgeChunker.openChunkMetadata(
            vector.sealedMetadata,
            keyData: key,
            uid: "UID123",
            vectorId: vector.vectorId
        )
        let metadata = try JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any]
        XCTAssertEqual(metadata?["source_path"] as? String, "notes/rr8.md")
        XCTAssertEqual(metadata?["category"] as? String, "security")
    }

    /// RR-8 WIRE round-trip: the Firestore dict serialization
    /// (KnowledgeSyncService.encode / PensieveMemorySearchView.decodeSealed) MUST carry
    /// `schemaVersion` + `aad`. If either is dropped, a path-bound (schemaVersion-2) chunk
    /// decodes into the legacy no-AAD branch and the AES-GCM tag — authenticated over the
    /// path-derived AAD — fails, so the chunk is permanently undecryptable. This locks the
    /// regression the writer/reader activation exposed: it must FAIL when the fields are
    /// stripped and SUCCEED when they survive.
    func testPensieveChunkSurvivesWireDictRoundTripOnlyWhenSchemaVersionAndAADPreserved() throws {
        let key = Data(repeating: 0x42, count: 32)
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: "BurnBar path-binds each Pensieve chunk to its Firestore identity.",
            sourceKind: .notes,
            sourcePath: "notes/rr8.md",
            sourceSlug: "notes-rr8-md",
            vaultKey: key,
            uid: "UID123",
            category: "security"
        )
        let vector = try XCTUnwrap(batch.vectors.first)
        let sealed = vector.sealedCiphertext

        // Reconstruct a CloudVaultSealedText from a Firestore-style dict, exactly as the
        // app/mobile decoders do.
        func decode(_ dict: [String: Any]) throws -> CloudVaultSealedText {
            CloudVaultSealedText(
                schemaVersion: (dict["schemaVersion"] as? NSNumber)?.intValue,
                algorithm: try XCTUnwrap(dict["algorithm"] as? String),
                keyVersion: (dict["keyVersion"] as? NSNumber)?.intValue ?? CloudVaultCrypto.currentKeyVersion,
                nonce: try XCTUnwrap(dict["nonce"] as? String),
                ciphertext: try XCTUnwrap(dict["ciphertext"] as? String),
                tag: try XCTUnwrap(dict["tag"] as? String),
                aad: dict["aad"] as? String
            )
        }

        let base: [String: Any] = [
            "algorithm": sealed.algorithm,
            "keyVersion": sealed.keyVersion,
            "nonce": sealed.nonce,
            "ciphertext": sealed.ciphertext,
            "tag": sealed.tag
        ]

        // Pre-fix (lossy) encoder: schemaVersion + aad dropped -> legacy no-AAD branch -> tag fails.
        XCTAssertThrowsError(try PensieveKnowledgeChunker.openChunkText(
            try decode(base), keyData: key, uid: "UID123", vectorId: vector.vectorId
        ))

        // Fixed encoder: carries schemaVersion + aad -> v2 branch, AAD rebuilt from path -> opens.
        var full = base
        if let schemaVersion = sealed.schemaVersion { full["schemaVersion"] = schemaVersion }
        if let aad = sealed.aad { full["aad"] = aad }
        let text = try PensieveKnowledgeChunker.openChunkText(
            try decode(full), keyData: key, uid: "UID123", vectorId: vector.vectorId
        )
        XCTAssertTrue(text.contains("path-binds each Pensieve chunk"))
    }

    /// Open-with-wrong-path FAILS: a path-bound chunk transplanted to a different
    /// vectorId (or a different uid) is rejected by AES-GCM tag verification, which is
    /// exactly the storage-adversary transplant RR-8 closes.
    func testPensieveChunkOpenWithWrongPathFails() throws {
        let key = Data(repeating: 0x42, count: 32)
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: "Transplanting this chunk to another doc id must not decrypt.",
            sourceKind: .repoDocs,
            sourcePath: "docs/transplant.md",
            sourceSlug: "docs-transplant-md",
            vaultKey: key,
            uid: "UID123"
        )
        let vector = try XCTUnwrap(batch.vectors.first)

        // Wrong vectorId (chunk relocated to another doc id within the same account).
        XCTAssertThrowsError(
            try PensieveKnowledgeChunker.openChunkText(
                vector.sealedCiphertext,
                keyData: key,
                uid: "UID123",
                vectorId: "DIFFERENT_VECTOR_ID"
            )
        )
        // Wrong uid (cross-account transplant).
        XCTAssertThrowsError(
            try PensieveKnowledgeChunker.openChunkText(
                vector.sealedCiphertext,
                keyData: key,
                uid: "OTHER_UID",
                vectorId: vector.vectorId
            )
        )
    }

    /// Legacy global-AAD chunks (sealed with no uid — the daemon queue writer, or any
    /// pre-RR-8 row) stay readable by the backward-compatible opener even when the
    /// reader threads the path-bound coordinates. This is the no-data-loss guarantee.
    func testPensieveLegacyGlobalAADChunkStaysReadable() throws {
        let key = Data(repeating: 0x42, count: 32)
        let batch = try PensieveKnowledgeChunker.prepareBatch(
            text: "Legacy chunk sealed before RR-8 must remain readable.",
            sourceKind: .notes,
            sourcePath: "notes/legacy.md",
            sourceSlug: "notes-legacy-md",
            vaultKey: key
            // uid omitted => legacy global AAD (schemaVersion-1, no path binding).
        )
        let vector = try XCTUnwrap(batch.vectors.first)
        // Legacy seal is the schemaVersion-1 shape (no AAD string on the envelope).
        XCTAssertNil(vector.sealedCiphertext.schemaVersion)
        XCTAssertNil(vector.sealedCiphertext.aad)

        // The path-threading opener still recovers it (the v1 branch ignores the AAD).
        let viaPathOpener = try PensieveKnowledgeChunker.openChunkText(
            vector.sealedCiphertext,
            keyData: key,
            uid: "UID123",
            vectorId: vector.vectorId
        )
        XCTAssertTrue(viaPathOpener.contains("Legacy chunk sealed before RR-8"))

        // And the original no-context reader path is unchanged.
        let viaLegacyOpener = try CloudVaultCrypto.openText(vector.sealedCiphertext, keyData: key)
        XCTAssertEqual(viaPathOpener, viaLegacyOpener)
    }
}
