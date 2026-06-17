import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class SourceArtifactStoreTests: XCTestCase {
    func test_sourceArtifactStore_upsertRoundTrip_andDeleteFlow() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_100_000)

        let initial = SourceArtifactRecord(
            id: "artifact-1",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/repo/AGENTS.md",
            rootPath: "/tmp/repo",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: "# Agent Guide\nInitial",
            contentHash: "hash-v1",
            fileSizeBytes: 64,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )

        let insertedResult = try await store.upsertSourceArtifact(initial)
        XCTAssertEqual(insertedResult, .inserted)

        let timestampOnlyUpdate = SourceArtifactRecord(
            id: initial.id,
            sourceKind: initial.sourceKind,
            canonicalPath: initial.canonicalPath,
            rootPath: initial.rootPath,
            relativePath: initial.relativePath,
            provenance: initial.provenance,
            title: initial.title,
            body: initial.body,
            contentHash: initial.contentHash,
            fileSizeBytes: initial.fileSizeBytes,
            fileModifiedAt: initial.fileModifiedAt,
            status: .active,
            discoveredAt: base.addingTimeInterval(5),
            deletedAt: nil,
            createdAt: initial.createdAt,
            updatedAt: base.addingTimeInterval(5)
        )
        let unchangedResult = try await store.upsertSourceArtifact(timestampOnlyUpdate)
        XCTAssertEqual(unchangedResult, .unchanged)

        let updated = SourceArtifactRecord(
            id: initial.id,
            sourceKind: initial.sourceKind,
            canonicalPath: initial.canonicalPath,
            rootPath: initial.rootPath,
            relativePath: initial.relativePath,
            provenance: initial.provenance,
            title: initial.title,
            body: "# Agent Guide\nUpdated",
            contentHash: "hash-v2",
            fileSizeBytes: 72,
            fileModifiedAt: base.addingTimeInterval(10),
            status: .active,
            discoveredAt: base.addingTimeInterval(10),
            deletedAt: nil,
            createdAt: initial.createdAt,
            updatedAt: base.addingTimeInterval(10)
        )
        let updatedResult = try await store.upsertSourceArtifact(updated)
        XCTAssertEqual(updatedResult, .updated)

        let active = try await store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.contentHash, "hash-v2")

        let markedDeleted = try await store.markSourceArtifactDeleted(id: initial.id, deletedAt: base.addingTimeInterval(20))
        XCTAssertTrue(markedDeleted)
        let remainingActiveCount = try await store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        ).count
        XCTAssertEqual(remainingActiveCount, 0)
        let allArtifacts = try await store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)
    }
}
