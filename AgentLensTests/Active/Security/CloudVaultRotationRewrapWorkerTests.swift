import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

final class CloudVaultRotationRewrapWorkerTests: XCTestCase {
    func testCloudSearchChunks_preservesBodyWithinByteLimit() throws {
        let body = "first section second section"

        let chunks = try CloudVaultRotationRewrapWorker.cloudSearchChunks(
            body,
            title: "Rotation title",
            provider: "claude",
            maxBytes: 14
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), body)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 14 })
    }

    // MARK: - memory_facts under vault-key rotation (spec §6 / §8)

    /// The collection set the document-rewrap pass walks must contain
    /// `memory_facts`. This is the wiring half of spec §6: the worker is
    /// data-driven over `DataDomains`, so "does a rotation reach the member's
    /// memories" is decided by the registry entry, not by anything visible in
    /// the worker's own text. Pin it, or a registry edit strands every synced
    /// memory on the old vault generation with nothing failing.
    func testTheDocumentRewrapPassCoversMemoryFacts() {
        XCTAssertTrue(
            CloudVaultRotationRewrapWorker.documentRewrapCollectionIDs.contains("memory_facts"),
            "a vault rotation must re-seal users/{uid}/memory_facts; it is reached through the pensieve domain"
        )
        XCTAssertEqual(
            CloudVaultRotationRewrapWorker.documentRewrapDomains.first(where: {
                $0.firestorePaths.contains("memory_facts")
            })?.id,
            "pensieve"
        )
    }

    /// **A rotation leaves no memory document on the old generation.** The §8
    /// row this closes.
    ///
    /// Builds real `memory_facts` documents with the production encoder, runs
    /// each through exactly the call `rewrapCollection` makes for every document
    /// in a covered collection, and then asserts the two things that matter: the
    /// old key can no longer open any of them, and the new key can — under the
    /// AAD naming this collection, this document and this field, which is the
    /// same AAD `MemoryCloudPullService.verify` demands. So a member who rotates
    /// their vault key keeps syncing rather than silently losing every memory.
    func testRotatingTheVaultKeyResealsEveryMemoryFactAndStrandsNone() throws {
        let uid = "rotation-member"
        let oldKey = Data(repeating: 0x11, count: 32)
        let newKey = Data(repeating: 0x22, count: 32)
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKey)
        let jobID = "rotation-job-1"
        let generation = 7
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let documents = try (0..<3).map { index -> (docID: String, data: [String: Any]) in
            let engineID = String(format: "mem_%032x", index + 1)
            let memory = Memory(
                id: "local-\(engineID)",
                sourceKind: .agent,
                kind: .fact,
                scope: MemoryScope(userID: uid, appID: "rotation-app"),
                confidence: 0.9,
                bodyRedacted: "ref",
                reviewStatus: .approved,
                citations: [],
                validFrom: now,
                createdAt: now,
                updatedAt: now
            )
            return try MemoryCloudSyncService.encodeMemoryFact(
                memory: memory,
                body: "Rotation-covered memory number \(index).",
                uid: uid,
                vaultKey: oldKey,
                now: now,
                documentIdentity: engineID,
                projectID: "proj_rotation",
                engineScope: "project"
            )
        }

        for document in documents {
            let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
                document.data,
                uid: uid,
                collection: "memory_facts",
                docID: document.docID,
                oldKeyData: oldKey,
                newKeyData: newKey,
                newVaultKeyID: newVaultKeyID,
                vaultGeneration: generation,
                rotationJobId: jobID
            )

            XCTAssertTrue(result.changed, "every sealed memory document is re-sealed")
            XCTAssertEqual(result.changedFields, ["sealedMemory"], "the sealed blob is the field that moves")
            XCTAssertEqual(result.data["vaultGeneration"] as? Int, generation)
            XCTAssertEqual(result.data["rewrapJobId"] as? String, jobID)

            let aad = try CloudVaultAADContext(
                uid: uid,
                collection: "memory_facts",
                docID: document.docID,
                field: "sealedMemory"
            )
            let envelope = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: result.data["sealedMemory"]))
            // Nothing is stranded on the old generation...
            XCTAssertThrowsError(try CloudVaultCrypto.openBlob(envelope, keyData: oldKey, aadContext: aad))
            // ...and the new generation opens it under the AAD the pull requires.
            let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: newKey, aadContext: aad)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(MemoryCloudFactPayload.self, from: plaintext)
            XCTAssertEqual(
                document.docID,
                try CloudVaultCrypto.pensieveSlugHmac("memory-fact:\(payload.memoryID)", keyData: oldKey),
                "the document id is derived from the member's slug key and is untouched by rotation"
            )
            XCTAssertEqual(payload.projectID, "proj_rotation", "the convergence identity survives the rewrap")
        }
    }

    func testCloudSearchChunks_includesTitleAndProviderInMetadataBudget() {
        let nearlyFullTitle = Array(repeating: "metadata", count: 4_094).joined(separator: " ")

        XCTAssertThrowsError(
            try CloudVaultRotationRewrapWorker.cloudSearchChunks(
                "body token",
                title: nearlyFullTitle,
                provider: "provider token",
                maxBytes: 16_000
            )
        ) { error in
            guard case CloudVaultCryptoError.invalidSearchInput = error else {
                return XCTFail("Expected invalidSearchInput, got \(error)")
            }
        }
    }
}
