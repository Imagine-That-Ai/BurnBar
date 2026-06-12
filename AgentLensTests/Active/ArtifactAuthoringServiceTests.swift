import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class ArtifactAuthoringServiceTests: XCTestCase {
    func test_draftSkill_buildsBoundedPromptWithRetrievedContext() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_780_000)

        let contextDocument = SearchDocumentRecord(
            id: "doc-authoring-context",
            sourceKind: .agentDoc,
            sourceID: "artifact-context",
            sourceVersionID: "context-v1",
            provider: nil,
            projectName: "OpenBurnBar",
            title: "Release Hardening Agent Guide",
            subtitle: "AGENTS.md",
            bodyPreview: "Checklist for release hardening.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-authoring-context",
            createdAt: now,
            updatedAt: now
        )
        try store.upsertSearchDocument(contextDocument)
        try store.replaceSearchChunks(
            documentID: contextDocument.id,
            title: contextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-authoring-context",
                    documentID: contextDocument.id,
                    sourceKind: .agentDoc,
                    sourceID: contextDocument.sourceID,
                    sourceVersionID: contextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 96,
                    sectionPath: "Hardening",
                    text: "Release hardening requires smoke tests, rollback drills, and deployment health checks.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let generator = StubArtifactAuthoringTextGenerator(
            response: """
            # Release hardening skill
            Keep rollback paths rehearsed.

            ## Grounding
            - [R1] Context applied.
            """
        )
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: ["/tmp"]
        )
        let service = ArtifactAuthoringService(
            dataStore: store,
            retrievalService: SearchService(dataStore: store),
            settingsProvider: settings,
            textGenerator: generator,
            nowProvider: { now }
        )

        let draft = try await service.draftSkill(
            request: "Create a release hardening skill with deployment safeguards.",
            projectName: "OpenBurnBar",
            retrievalQuery: "release hardening smoke tests rollback",
            contextLimit: 4
        )

        XCTAssertEqual(draft.sourceKind, .skillDoc)
        XCTAssertEqual(draft.operation, .draft)
        XCTAssertEqual(draft.references.count, 1)
        XCTAssertEqual(draft.references.first?.sourceID, "artifact-context")
        XCTAssertTrue(draft.userPrompt.contains("[R1]"))
        XCTAssertTrue(draft.userPrompt.localizedCaseInsensitiveContains("release hardening"))
        XCTAssertTrue(draft.provenanceSummary.contains("artifact-context"))
        XCTAssertEqual(generator.userPrompts.last, draft.userPrompt)
    }

    func test_saveDraft_roundTripsIntoProjectionAndSearch() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let root = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let store = try makeDiscoveryInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_790_000)
        let generator = StubArtifactAuthoringTextGenerator(
            response: """
            # Bootstrap Skill
            Use the orion-e2e-authoring-needle checklist before every release.

            ## Grounding
            - No historical references available.
            """
        )
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [root.path]
        )
        let service = ArtifactAuthoringService(
            dataStore: store,
            retrievalService: SearchService(dataStore: store),
            settingsProvider: settings,
            textGenerator: generator,
            fileManager: fileManager,
            nowProvider: { now }
        )

        let draft = try await service.draftSkill(
            request: "Draft a bootstrap release skill.",
            projectName: "OpenBurnBar",
            retrievalQuery: "bootstrap release checklist",
            contextLimit: 3
        )
        let destinationPath = root.appendingPathComponent("SKILL.md").path
        let saveResult = try service.saveDraft(draft, to: destinationPath)

        XCTAssertEqual(saveResult.disposition, .inserted)
        XCTAssertTrue(saveResult.projectionJobEnqueued)
        XCTAssertNotNil(saveResult.projectionJobID)
        XCTAssertTrue(saveResult.artifact.provenance.hasPrefix("authoring:draft|"))

        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "authoring-roundtrip")
        _ = try await projector.runSweep(maxJobs: 10)

        let retrieval = SearchService(dataStore: store)
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "orion-e2e-authoring-needle",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )
        XCTAssertEqual(Set(results.map(\.sourceID)), Set([saveResult.artifact.id]))
    }
}

@MainActor
private final class StubArtifactAuthoringTextGenerator: ArtifactAuthoringTextGenerating {
    var response: String
    private(set) var systemPrompts: [String] = []
    private(set) var userPrompts: [String] = []

    init(response: String) {
        self.response = response
    }

    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        systemPrompts.append(systemPrompt)
        userPrompts.append(userPrompt)
        return response
    }
}
