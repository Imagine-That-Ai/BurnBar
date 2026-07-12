import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class ArtifactDiscoveryServiceTests: XCTestCase {
    func test_discovery_staysWithinRegisteredRootsAndKnownPatterns() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let approvedRoot = sandbox.appendingPathComponent("approved-root", isDirectory: true)
        let outsideRoot = sandbox.appendingPathComponent("outside-root", isDirectory: true)
        try fileManager.createDirectory(at: approvedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        try writeDiscoveryFixture("# Skill\nDo this.", to: approvedRoot.appendingPathComponent("SKILL.md"))
        try writeDiscoveryFixture("# Agent\nRun tests.", to: approvedRoot.appendingPathComponent("docs/AGENTS.md"))
        try writeDiscoveryFixture("# Notes\nIgnore me.", to: approvedRoot.appendingPathComponent("README.md"))
        try writeDiscoveryFixture("# Outside\nShould not index.", to: outsideRoot.appendingPathComponent("AGENTS.md"))

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [approvedRoot.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)
        let report = try await service.discoverAndIngest()

        XCTAssertEqual(report.discoveredArtifacts, 2)
        XCTAssertEqual(report.insertedArtifacts, 2)
        XCTAssertTrue(report.issues.isEmpty)

        let artifacts = try await store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertFalse(artifacts.contains { $0.canonicalPath.hasPrefix(outsideRoot.path) })
        XCTAssertFalse(artifacts.contains { $0.relativePath == "README.md" })

        let queuedJobs = try await store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queuedJobs.count, 2)
        XCTAssertEqual(Set(queuedJobs.map(\.jobType)), Set([.project]))

        let health = try await store.fetchRetrievalHealth().first(where: { $0.subsystem == .discovery })
        XCTAssertEqual(health?.status, .healthy)
    }

    func test_discovery_skipsUnchangedFilesBySignature_withoutLosingDeletionSweep() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeDiscoveryFixture("# Skill\nDo this.", to: root.appendingPathComponent("SKILL.md"))
        let agentsURL = root.appendingPathComponent("AGENTS.md")
        try writeDiscoveryFixture("# Agent\nv1", to: agentsURL)

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [root.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)

        let first = try await service.discoverAndIngest()
        XCTAssertEqual(first.insertedArtifacts, 2)

        // Second sweep with untouched files: the (mtime, size) gate must
        // report both as unchanged without re-reading or re-queuing jobs.
        let second = try await service.discoverAndIngest()
        XCTAssertEqual(second.discoveredArtifacts, 2)
        XCTAssertEqual(second.unchangedArtifacts, 2)
        XCTAssertEqual(second.insertedArtifacts, 0)
        XCTAssertEqual(second.updatedArtifacts, 0)
        XCTAssertEqual(second.deletedArtifacts, 0)
        XCTAssertEqual(second.queuedJobs, 0)

        // A modified file must break the signature gate and re-project.
        // Backdating-safe: rewrite content of a different size.
        try writeDiscoveryFixture("# Agent\nv2 with more content", to: agentsURL)
        let third = try await service.discoverAndIngest()
        XCTAssertEqual(third.updatedArtifacts, 1)
        XCTAssertEqual(third.unchangedArtifacts, 1)

        // The skip path still feeds the deletion sweep: removing a file that
        // was previously skipped must still mark it deleted.
        try fileManager.removeItem(at: agentsURL)
        let fourth = try await service.discoverAndIngest()
        XCTAssertEqual(fourth.deletedArtifacts, 1)
        XCTAssertEqual(fourth.unchangedArtifacts, 1)
    }

    func test_discovery_marksMissingArtifactsDeleted_andQueuesPurge() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let agentsURL = root.appendingPathComponent("AGENTS.md")
        try writeDiscoveryFixture("# Agent\nv1", to: agentsURL)

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [root.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)

        _ = try await service.discoverAndIngest()
        try fileManager.removeItem(at: agentsURL)
        let secondRun = try await service.discoverAndIngest()

        XCTAssertEqual(secondRun.deletedArtifacts, 1)

        let allArtifacts = try await store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)

        let queuedJobs = try await store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queuedJobs.contains { $0.jobType == .purge })
    }
}
