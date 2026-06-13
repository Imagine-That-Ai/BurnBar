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

        let payload = KnowledgeSyncService.encode(batch) { vector in
            XCTAssertEqual(vector.vectorId, "pensieve-vector-2")
            return signalEnvelope
        }
        let vectors = try XCTUnwrap(payload["vectors"] as? [[String: Any]])
        let vector = try XCTUnwrap(vectors.first)

        XCTAssertNotNil(vector["sealedCiphertext"])
        XCTAssertNotNil(vector["sealedMetadata"])
        XCTAssertEqual(vector["signalEnvelope"] as? NSDictionary, signalEnvelope as NSDictionary)
    }

    func testSyncPreparedBatchPayloadsUpdatesLockedStateOnSuccess() async throws {
        let callable = FakeKnowledgeSyncCallable(commitResult: KnowledgeCommitResult(
            written: 4,
            skipped: 1,
            tier: "ultra",
            chunkCount: 5
        ))
        let service = KnowledgeSyncService(callable: callable, uidProvider: { "uid-1" })

        let result = try await service.syncPreparedBatchPayloads([["vectors": []]])

        XCTAssertEqual(callable.committedPayloadCount, 1)
        XCTAssertEqual(result?.written, 4)
        XCTAssertEqual(result?.skipped, 1)
        XCTAssertEqual(result?.tier, "ultra")
        XCTAssertEqual(result?.chunkCount, 5)
        XCTAssertEqual(service.lastWritten, 4)
        XCTAssertFalse(service.isSyncing)
        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(service.lastSyncDate)
    }

    func testSyncPreparedBatchPayloadsRecordsLockedStateError() async {
        let callable = FakeKnowledgeSyncCallable(error: KnowledgeSyncError.commitFailed("commit denied"))
        let service = KnowledgeSyncService(callable: callable, uidProvider: { "uid-1" })

        await XCTAssertThrowsErrorAsync({
            try await service.syncPreparedBatchPayloads([["vectors": []]])
        }, { error in
            XCTAssertEqual((error as? KnowledgeSyncError)?.errorDescription, "commit denied")
        })

        XCTAssertFalse(service.isSyncing)
        XCTAssertEqual(service.lastSyncError, "commit denied")
        XCTAssertNil(service.lastSyncDate)
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

private final class FakeKnowledgeSyncCallable: KnowledgeSyncCallable, @unchecked Sendable {
    private let commitResult: KnowledgeCommitResult
    private let error: Error?
    private let committedPayloadCounter = Locked(0)

    var committedPayloadCount: Int {
        committedPayloadCounter.read()
    }

    init(
        commitResult: KnowledgeCommitResult = KnowledgeCommitResult(
            written: 1,
            skipped: 0,
            tier: "pro",
            chunkCount: 1
        ),
        error: Error? = nil
    ) {
        self.commitResult = commitResult
        self.error = error
    }

    func configureKnowledgeSource(
        sourceKind: String,
        rootPath: String?,
        sourceSlug: String?
    ) async throws -> String {
        sourceSlug ?? "source"
    }

    func commitKnowledgeBatch(_ payload: [String: Any]) async throws -> KnowledgeCommitResult {
        committedPayloadCounter.withLock { $0 += 1 }
        if let error {
            throw error
        }
        return commitResult
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
