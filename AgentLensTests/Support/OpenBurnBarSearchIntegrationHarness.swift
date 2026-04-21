import Foundation
import GRDB
import XCTest
@testable import OpenBurnBar

enum OpenBurnBarSearchIntegrationHarnessError: LocalizedError {
    case invalidRelativePath(String)
    case missingConversation(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let relativePath):
            return "Fixture relative path is empty or invalid: \(relativePath)"
        case .missingConversation(let conversationID):
            return "Conversation \(conversationID) was not found in the harness store."
        }
    }
}

@MainActor
final class OpenBurnBarSearchIntegrationHarness {
    struct FileRoots {
        let registeredProjectRootURL: URL
        let sharedProjectRootURL: URL
        let outsideRootURL: URL
    }

    let rootURL: URL
    let databaseURL: URL
    let fileRoots: FileRoots
    let dataStore: DataStore
    let clock: OpenBurnBarFakeClock
    let embedder: OpenBurnBarFakeEmbedder
    let queryEmbedder: OpenBurnBarFakeQueryEmbedder
    let sharedAccessContext: SharedArtifactAccessContext

    private let databaseQueue: DatabaseQueue
    private let fileManager: FileManager

    init(
        name: String = "search",
        initialTime: Date = Date(timeIntervalSince1970: 1_742_000_000),
        fileManager: FileManager = .default,
        sharedAccessContext: SharedArtifactAccessContext = SharedArtifactAccessContext(
            userID: "harness-user",
            workspaceID: "harness-workspace",
            teamID: "harness-team"
        ),
        embedderSeed: String = "openburnbar-harness-seed-v1",
        embedderVersionTag: String = "harness-v1",
        embedderDimensions: Int = 96
    ) throws {
        self.fileManager = fileManager
        self.sharedAccessContext = sharedAccessContext
        self.clock = OpenBurnBarFakeClock(now: initialTime)
        self.embedder = OpenBurnBarFakeEmbedder(
            dimensions: embedderDimensions,
            versionTag: embedderVersionTag,
            seed: embedderSeed
        )
        self.queryEmbedder = OpenBurnBarFakeQueryEmbedder(embedder: embedder)

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OpenBurnBarSearchHarness-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        rootURL = root

        let dbDirectory = root.appendingPathComponent("db", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        databaseURL = dbDirectory.appendingPathComponent("openburnbar-search-harness.sqlite", isDirectory: false)

        let registeredRoot = root.appendingPathComponent("registered-root", isDirectory: true)
        let sharedRoot = root.appendingPathComponent("shared-root", isDirectory: true)
        let outsideRoot = root.appendingPathComponent("outside-root", isDirectory: true)
        try fileManager.createDirectory(at: registeredRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        fileRoots = FileRoots(
            registeredProjectRootURL: registeredRoot,
            sharedProjectRootURL: sharedRoot,
            outsideRootURL: outsideRoot
        )

        databaseQueue = try DatabaseQueue(path: databaseURL.path)
        dataStore = try DataStore(
            databaseQueue: databaseQueue,
            runMigrations: true,
            refreshOnInit: false
        )
    }

    func cleanup() {
        try? databaseQueue.close()
        try? fileManager.removeItem(at: rootURL)
    }

    // MARK: - Service Builders

    func makeProjectionService(
        leaseOwner: String = "harness-projection-worker"
    ) -> ProjectionPipelineService {
        ProjectionPipelineService(
            dataStore: dataStore,
            leaseOwner: leaseOwner,
            nowProvider: { [clock] in clock.now() },
            chunkEmbedder: embedder
        )
    }

    func makeSearchService(
        semanticEnabled: Bool = true,
        semanticBackend: VectorBackendKind = .ann,
        exactRerankEnabled: Bool = true,
        exactRerankLimit: Int = 320,
        annCandidateMultiplier: Int = 6,
        sharedAccessContext: SharedArtifactAccessContext? = nil
    ) -> SearchService {
        let semanticProvider: SemanticCandidateProviding?
        if semanticEnabled {
            semanticProvider = VectorSemanticCandidateProvider(
                dataStore: dataStore,
                queryEmbedder: queryEmbedder,
                backend: semanticBackend,
                exactRerankEnabled: exactRerankEnabled,
                exactRerankLimit: exactRerankLimit,
                annCandidateMultiplier: annCandidateMultiplier,
                nowProvider: { [clock] in clock.now() }
            )
        } else {
            semanticProvider = nil
        }

        return SearchService(
            dataStore: dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { [sharedAccessContext] in
                sharedAccessContext ?? self.sharedAccessContext
            },
            nowProvider: { [clock] in clock.now() }
        )
    }

    func makeRetrievalHealthService() -> RetrievalHealthService {
        RetrievalHealthService(
            dataStore: dataStore,
            nowProvider: { [clock] in clock.now() }
        )
    }

    func makeDiscoveryService(
        enabled: Bool = true,
        registeredRoots: [URL]? = nil,
        additionalKnownPatterns: [String] = []
    ) -> (service: ArtifactDiscoveryService, settings: OpenBurnBarHarnessArtifactDiscoverySettings) {
        let roots = registeredRoots ?? [fileRoots.registeredProjectRootURL]
        let settings = OpenBurnBarHarnessArtifactDiscoverySettings(
            artifactDiscoveryEnabled: enabled,
            artifactDiscoveryRegisteredRoots: roots.map(\.path),
            artifactDiscoveryAdditionalKnownPatterns: additionalKnownPatterns
        )
        let service = ArtifactDiscoveryService(
            dataStore: dataStore,
            settingsProvider: settings,
            fileManager: fileManager,
            nowProvider: { [clock] in clock.now() }
        )
        return (service, settings)
    }

    // MARK: - Fixture Builders

    func makeConversationFixture(
        id: String,
        provider: AgentProvider = .claudeCode,
        projectName: String = "OpenBurnBar",
        fullText: String,
        sourceType: ConversationSourceType = .providerLog
    ) -> ConversationRecord {
        OpenBurnBarSearchFixtureBuilder.conversation(
            id: id,
            provider: provider,
            projectName: projectName,
            fullText: fullText,
            indexedAt: clock.now(),
            sourceType: sourceType
        )
    }

    func makeSkillArtifactFixture(
        id: String,
        relativePath: String = "SKILL.md",
        title: String = "Skill Fixture",
        body: String
    ) -> SourceArtifactRecord {
        OpenBurnBarSearchFixtureBuilder.skillArtifact(
            id: id,
            rootPath: fileRoots.registeredProjectRootURL.path,
            relativePath: relativePath,
            title: title,
            body: body,
            fileModifiedAt: clock.now()
        )
    }

    func makeSharedArtifactFixture(
        id: String,
        relativePath: String = "SHARED.md",
        title: String = "Shared Fixture",
        body: String
    ) -> SourceArtifactRecord {
        OpenBurnBarSearchFixtureBuilder.sharedArtifact(
            id: id,
            rootPath: fileRoots.sharedProjectRootURL.path,
            relativePath: relativePath,
            title: title,
            body: body,
            fileModifiedAt: clock.now()
        )
    }

    @discardableResult
    func grantSharedReadAccess(
        to sourceArtifactID: String,
        principalType: SharedArtifactPrincipalType = .user,
        principalID: String? = nil,
        role: SharedArtifactRole = .editor,
        visibility: SharedArtifactVisibility = .team,
        canWrite: Bool = true,
        canShare: Bool = false
    ) throws -> SharedArtifactPermissionRecord {
        let permission = OpenBurnBarSearchFixtureBuilder.sharedArtifactPermission(
            sourceArtifactID: sourceArtifactID,
            accessContext: sharedAccessContext,
            principalType: principalType,
            principalID: principalID,
            role: role,
            visibility: visibility,
            canRead: true,
            canWrite: canWrite,
            canShare: canShare,
            at: clock.now()
        )
        _ = try dataStore.upsertSharedArtifactPermission(permission)
        return permission
    }

    // MARK: - Disk Fixture Utilities

    @discardableResult
    func writeSkillFixture(
        relativePath: String = "SKILL.md",
        body: String = "# Skill\nRun tests first.",
        rootURL: URL? = nil
    ) throws -> URL {
        try writeFixtureFile(
            rootURL: rootURL ?? fileRoots.registeredProjectRootURL,
            relativePath: relativePath,
            contents: body
        )
    }

    @discardableResult
    func writeAgentFixture(
        relativePath: String = "AGENTS.md",
        body: String = "# Agent\nShip safely.",
        rootURL: URL? = nil
    ) throws -> URL {
        try writeFixtureFile(
            rootURL: rootURL ?? fileRoots.registeredProjectRootURL,
            relativePath: relativePath,
            contents: body
        )
    }

    @discardableResult
    func writeFixtureFile(
        rootURL: URL,
        relativePath: String,
        contents: String
    ) throws -> URL {
        let normalizedRelativePath = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedRelativePath.isEmpty == false else {
            throw OpenBurnBarSearchIntegrationHarnessError.invalidRelativePath(relativePath)
        }

        let fileURL = rootURL.appendingPathComponent(normalizedRelativePath, isDirectory: false)
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    // MARK: - Queue Helpers

    @discardableResult
    func enqueueConversationProjection(
        conversationID: String,
        jobType: ProjectionJobType = .project,
        priority: Int = 5
    ) throws -> String {
        guard let conversation = try dataStore.fetchConversation(id: conversationID) else {
            throw OpenBurnBarSearchIntegrationHarnessError.missingConversation(conversationID)
        }
        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        try dataStore.enqueueConversationProjectionJob(
            conversationID: conversationID,
            jobType: jobType,
            priority: priority,
            now: clock.now()
        )
        return ProjectionIdentity.jobID(
            jobType: jobType,
            sourceKind: .conversation,
            sourceID: conversationID,
            sourceVersionID: sourceVersionID
        )
    }

    @discardableResult
    func enqueueArtifactProjection(
        _ artifact: SourceArtifactRecord,
        jobType: ProjectionJobType = .project,
        priority: Int = 10,
        leaseOwner: String = "harness-artifact-enqueue"
    ) throws -> String {
        _ = try dataStore.upsertSourceArtifact(artifact)
        let sourceVersionID = artifact.status == .deleted || jobType == .purge
            ? ProjectionIdentity.deletedSourceVersionID
            : ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash)

        try makeProjectionService(leaseOwner: leaseOwner).enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: sourceVersionID,
            jobType: jobType,
            priority: priority
        )
        return ProjectionIdentity.jobID(
            jobType: jobType,
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: sourceVersionID
        )
    }

    func enqueueRebuild(
        reason: String = "harness-rebuild",
        priority: Int = 1,
        leaseOwner: String = "harness-rebuild-enqueue"
    ) throws {
        try makeProjectionService(leaseOwner: leaseOwner).enqueueRebuildJob(
            reason: reason,
            priority: priority
        )
    }

    @discardableResult
    func runProjectionSweep(
        maxJobs: Int = 128,
        leaseOwner: String = "harness-projection-sweep"
    ) async throws -> ProjectionSweepReport {
        try await makeProjectionService(leaseOwner: leaseOwner).runSweep(maxJobs: maxJobs)
    }

    @discardableResult
    func drainProjectionQueue(
        maxSweeps: Int = 10,
        maxJobsPerSweep: Int = 128,
        advanceClockBy: TimeInterval = 0,
        leaseOwnerPrefix: String = "harness-drain-worker"
    ) async throws -> ProjectionSweepReport {
        guard maxSweeps > 0 else { return ProjectionSweepReport() }

        var aggregate = ProjectionSweepReport()
        for sweep in 0..<maxSweeps {
            let report = try await runProjectionSweep(
                maxJobs: maxJobsPerSweep,
                leaseOwner: "\(leaseOwnerPrefix)-\(sweep)"
            )
            aggregate.adding(report)

            let pending = try dataStore.fetchProjectionJobs(
                statuses: [.queued, .failed, .leased, .running],
                limit: 1
            )
            if pending.isEmpty {
                break
            }

            if report.leasedJobs == 0 {
                if advanceClockBy > 0 {
                    _ = clock.advance(seconds: advanceClockBy)
                    continue
                }
                break
            }

            if advanceClockBy > 0 {
                _ = clock.advance(seconds: advanceClockBy)
            }
        }
        return aggregate
    }

    // MARK: - Health + Degraded Assertions

    func retrievalHealthRecord(
        for subsystem: RetrievalSubsystem
    ) throws -> RetrievalHealthRecord? {
        try dataStore.fetchRetrievalHealth().first(where: { $0.subsystem == subsystem })
    }

    func assertHealthStatus(
        subsystem: RetrievalSubsystem,
        status: RetrievalHealthStatus,
        errorCode: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let row = try retrievalHealthRecord(for: subsystem) else {
            XCTFail("Missing retrieval health row for subsystem \(subsystem.rawValue).", file: file, line: line)
            return
        }
        XCTAssertEqual(row.status, status, file: file, line: line)
        if let errorCode {
            XCTAssertEqual(row.errorCode, errorCode, file: file, line: line)
        }
    }

    func assertDegraded(
        subsystem: RetrievalSubsystem,
        errorCode: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertHealthStatus(
            subsystem: subsystem,
            status: .degraded,
            errorCode: errorCode,
            file: file,
            line: line
        )
    }

    func healthSnapshot(
        indexingEnabled: Bool = true,
        sharedFeaturesAvailable: Bool = true
    ) -> RetrievalSystemHealthSnapshot {
        makeRetrievalHealthService().snapshot(
            indexingEnabled: indexingEnabled,
            sharedFeaturesAvailable: sharedFeaturesAvailable
        )
    }

    func assertDegradedModes(
        _ expectedModes: Set<RetrievalDegradedMode>,
        indexingEnabled: Bool = true,
        sharedFeaturesAvailable: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let modes = Set(
            healthSnapshot(
                indexingEnabled: indexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable
            ).degradedModes.map(\.mode)
        )
        let missingModes = expectedModes.subtracting(modes)
        XCTAssertTrue(
            missingModes.isEmpty,
            "Missing degraded modes: \(missingModes.map(\.rawValue).sorted()) from \(modes.map(\.rawValue).sorted())",
            file: file,
            line: line
        )
    }
}

@MainActor
final class OpenBurnBarHarnessArtifactDiscoverySettings: ArtifactDiscoverySettingsProviding {
    var artifactDiscoveryEnabled: Bool
    var artifactDiscoveryRegisteredRoots: [String]
    var artifactDiscoveryAdditionalKnownPatterns: [String]

    init(
        artifactDiscoveryEnabled: Bool,
        artifactDiscoveryRegisteredRoots: [String],
        artifactDiscoveryAdditionalKnownPatterns: [String]
    ) {
        self.artifactDiscoveryEnabled = artifactDiscoveryEnabled
        self.artifactDiscoveryRegisteredRoots = artifactDiscoveryRegisteredRoots
        self.artifactDiscoveryAdditionalKnownPatterns = artifactDiscoveryAdditionalKnownPatterns
    }
}

enum OpenBurnBarSearchFixtureBuilder {
    static func conversation(
        id: String,
        provider: AgentProvider = .claudeCode,
        projectName: String = "OpenBurnBar",
        fullText: String,
        indexedAt: Date,
        sourceType: ConversationSourceType = .providerLog
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: "session-\(id)",
            projectName: projectName,
            startTime: indexedAt.addingTimeInterval(-90),
            endTime: indexedAt,
            messageCount: 5,
            userWordCount: max(1, fullText.split(separator: " ").count / 2),
            assistantWordCount: max(1, fullText.split(separator: " ").count / 2),
            keyFiles: ["SearchService.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read", "Edit"],
            inferredTaskTitle: "Fixture \(id)",
            lastAssistantMessage: "Done",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: sourceType
        )
    }

    static func skillArtifact(
        id: String,
        rootPath: String,
        relativePath: String = "SKILL.md",
        title: String = "Skill Fixture",
        body: String,
        contentHash: String? = nil,
        fileModifiedAt: Date
    ) -> SourceArtifactRecord {
        artifact(
            id: id,
            sourceKind: .skillDoc,
            rootPath: rootPath,
            relativePath: relativePath,
            title: title,
            body: body,
            contentHash: contentHash,
            fileModifiedAt: fileModifiedAt
        )
    }

    static func sharedArtifact(
        id: String,
        rootPath: String,
        relativePath: String = "SHARED.md",
        title: String = "Shared Fixture",
        body: String,
        contentHash: String? = nil,
        fileModifiedAt: Date
    ) -> SourceArtifactRecord {
        artifact(
            id: id,
            sourceKind: .sharedArtifact,
            rootPath: rootPath,
            relativePath: relativePath,
            title: title,
            body: body,
            contentHash: contentHash,
            fileModifiedAt: fileModifiedAt
        )
    }

    static func sharedArtifactPermission(
        sourceArtifactID: String,
        accessContext: SharedArtifactAccessContext,
        principalType: SharedArtifactPrincipalType = .user,
        principalID: String? = nil,
        role: SharedArtifactRole = .editor,
        visibility: SharedArtifactVisibility = .team,
        canRead: Bool = true,
        canWrite: Bool = true,
        canShare: Bool = false,
        at: Date
    ) -> SharedArtifactPermissionRecord {
        let resolvedPrincipalID: String
        switch principalType {
        case .user:
            resolvedPrincipalID = principalID ?? accessContext.userID
        case .workspace:
            resolvedPrincipalID = principalID ?? accessContext.workspaceID
        case .team:
            resolvedPrincipalID = principalID ?? accessContext.teamID
        }

        return SharedArtifactPermissionRecord(
            sourceArtifactID: sourceArtifactID,
            workspaceID: accessContext.workspaceID,
            teamID: accessContext.teamID,
            principalType: principalType,
            principalID: resolvedPrincipalID,
            role: role,
            visibility: visibility,
            canRead: canRead,
            canWrite: canWrite,
            canShare: canShare,
            createdAt: at,
            updatedAt: at
        )
    }

    private static func artifact(
        id: String,
        sourceKind: SearchSourceKind,
        rootPath: String,
        relativePath: String,
        title: String,
        body: String,
        contentHash: String?,
        fileModifiedAt: Date
    ) -> SourceArtifactRecord {
        let canonicalPath = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(relativePath, isDirectory: false)
            .path
        let hash = contentHash ?? ProjectionIdentity.sha256Hex(
            "\(sourceKind.rawValue)|\(canonicalPath)|\(body)"
        )
        return SourceArtifactRecord(
            id: id,
            sourceKind: sourceKind,
            canonicalPath: canonicalPath,
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: "test:\(relativePath)",
            title: title,
            body: body,
            contentHash: hash,
            fileSizeBytes: body.utf8.count,
            fileModifiedAt: fileModifiedAt,
            status: .active,
            discoveredAt: fileModifiedAt,
            deletedAt: nil,
            createdAt: fileModifiedAt,
            updatedAt: fileModifiedAt
        )
    }
}

@MainActor
final class OpenBurnBarFakeClock {
    private(set) var current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        current
    }

    @discardableResult
    func advance(seconds: TimeInterval) -> Date {
        current = current.addingTimeInterval(seconds)
        return current
    }

    @discardableResult
    func set(_ date: Date) -> Date {
        current = date
        return current
    }
}

enum OpenBurnBarFakeEmbedderError: LocalizedError {
    case forced(String)

    var errorDescription: String? {
        switch self {
        case .forced(let message):
            return message
        }
    }
}

/// Test seam is mutated by single-test flows; mark unchecked to avoid noisy Swift 6 sendability warnings.
final class OpenBurnBarFakeEmbedder: ChunkEmbeddingProviding, @unchecked Sendable {
    private let deterministicEmbedder: DeterministicFakeEmbeddingProvider
    var failAll = false
    var failingSubstrings: Set<String> = []
    var forcedErrorMessage = "Forced OpenBurnBar fake embedder failure."

    var descriptor: EmbeddingModelDescriptor { deterministicEmbedder.descriptor }

    init(
        provider: String = "openburnbar",
        modelName: String = "deterministic-fake-embedding",
        dimensions: Int = 96,
        distanceMetric: EmbeddingDistanceMetric = .cosine,
        versionTag: String = "harness-v1",
        chunkerVersion: String = "openburnbar-chunker-v1",
        normalizationVersion: String = "unit-l2-v1",
        promptVersion: String = "plain-text-v1",
        seed: String = "openburnbar-harness-seed-v1"
    ) {
        deterministicEmbedder = DeterministicFakeEmbeddingProvider(
            provider: provider,
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion,
            seed: seed
        )
    }

    func embedding(for text: String) async throws -> [Float] {
        let normalizedText = text.lowercased()
        if failAll {
            throw OpenBurnBarFakeEmbedderError.forced(forcedErrorMessage)
        }
        if failingSubstrings.contains(where: { normalizedText.contains($0.lowercased()) }) {
            throw OpenBurnBarFakeEmbedderError.forced(forcedErrorMessage)
        }
        return try await deterministicEmbedder.embedding(for: text)
    }
}

@MainActor
final class OpenBurnBarFakeQueryEmbedder: QueryEmbeddingProviding {
    private let embedder: OpenBurnBarFakeEmbedder

    init(embedder: OpenBurnBarFakeEmbedder) {
        self.embedder = embedder
    }

    func embedding(for text: String) async throws -> [Float] {
        try await embedder.embedding(for: text)
    }
}

private extension ProjectionSweepReport {
    mutating func adding(_ other: ProjectionSweepReport) {
        leasedJobs += other.leasedJobs
        completedJobs += other.completedJobs
        retriedJobs += other.retriedJobs
        canceledJobs += other.canceledJobs
    }
}
