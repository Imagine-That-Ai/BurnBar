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
        let service = ArtifactDiscoveryService(dataStoreActor: store.actor, settingsProvider: settings, fileManager: fileManager)
        let report = try await service.discoverAndIngest()

        XCTAssertEqual(report.discoveredArtifacts, 2)
        XCTAssertEqual(report.insertedArtifacts, 2)
        XCTAssertTrue(report.issues.isEmpty)

        let artifacts = try store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertFalse(artifacts.contains { $0.canonicalPath.hasPrefix(outsideRoot.path) })
        XCTAssertFalse(artifacts.contains { $0.relativePath == "README.md" })

        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queuedJobs.count, 2)
        XCTAssertEqual(Set(queuedJobs.map(\.jobType)), Set([.project]))

        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .discovery })
        XCTAssertEqual(health?.status, .healthy)
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
        let service = ArtifactDiscoveryService(dataStoreActor: store.actor, settingsProvider: settings, fileManager: fileManager)

        _ = try await service.discoverAndIngest()
        try fileManager.removeItem(at: agentsURL)
        let secondRun = try await service.discoverAndIngest()

        XCTAssertEqual(secondRun.deletedArtifacts, 1)

        let allArtifacts = try store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)

        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queuedJobs.contains { $0.jobType == .purge })
    }
}

