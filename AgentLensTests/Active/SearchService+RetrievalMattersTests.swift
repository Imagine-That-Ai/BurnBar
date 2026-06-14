import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavioral coverage for the `try?` error-swallow in `SearchService+Retrieval.swift`
/// (`readableSharedSourceIDs = try? dataStore.fetchReadableSharedArtifactSourceIDs(...)`)
/// that was judged to MATTER.
///
/// `readableSharedSourceIDs` is the ALLOW-list `matchesFilters` consults for
/// `.sharedArtifact` documents (`SearchService+Ranking.swift`): a shared artifact is
/// surfaced only when this set is present AND contains its `sourceID`. The lookup is an
/// access-control decision. When it fails it MUST fail closed (deny every shared
/// artifact) and the failure MUST be observable (index marked stale, lexical health
/// recorded `.degraded` with `INDEX_STALE_PARTIAL_RESULTS`) — never silently swallowed.
///
/// To exercise only the access-control lookup we drop the `source_artifacts` table,
/// which `fetchReadableSharedArtifactSourceIDs` reads (`FROM source_artifacts AS s`) but
/// neither the lexical FTS query nor chunk/document hydration touch. That makes the
/// access lookup — and only the access lookup — throw, so the shared artifact reaches the
/// candidate set yet must be withheld by the fail-closed path.
@MainActor
final class SearchServiceRetrievalMattersTests: XCTestCase {

    // MARK: - Fixtures

    private let base = Date(timeIntervalSince1970: 1_743_300_000)

    private func makeArtifact(
        id: String,
        title: String,
        body: String,
        contentHash: String
    ) -> SourceArtifactRecord {
        SourceArtifactRecord(
            id: id,
            sourceKind: .sharedArtifact,
            canonicalPath: "/tmp/shared-matters/\(id).md",
            rootPath: "/tmp/shared-matters",
            relativePath: "\(id).md",
            provenance: "test:\(id)",
            title: title,
            body: body,
            contentHash: contentHash,
            fileSizeBytes: body.utf8.count,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
    }

    /// Projects a readable shared artifact and grants the access context viewer permission.
    /// Returns the service wired to that access context.
    private func makeServiceWithReadableSharedArtifact(
        store: DataStore,
        accessContext: SharedArtifactAccessContext
    ) async throws -> (service: SearchService, artifactID: String) {
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-matters")

        let artifact = makeArtifact(
            id: "artifact-matters-shared",
            title: "Shared Permissions Document",
            body: "Shared artifact body about permissions and access control.",
            contentHash: "hash-matters-shared"
        )
        _ = try store.upsertSourceArtifact(artifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: .sharedArtifact,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 40)

        _ = try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: artifact.id,
                workspaceID: accessContext.workspaceID,
                teamID: accessContext.teamID,
                principalType: .user,
                principalID: accessContext.userID,
                role: .viewer,
                visibility: .team,
                canRead: true,
                canWrite: false,
                canShare: false,
                createdAt: base,
                updatedAt: base
            )
        )

        let now = base
        let service = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { accessContext },
            nowProvider: { now }
        )
        return (service, artifact.id)
    }

    private func sharedQuery() -> RetrievalQuery {
        RetrievalQuery(
            text: "permissions",
            filters: RetrievalFilters(ownership: .shared),
            semanticCandidateLimit: 0
        )
    }

    // MARK: - Control: healthy lookup surfaces the readable shared artifact

    /// Baseline proving the fixture is sound: with the access table intact the readable
    /// shared artifact IS returned and lexical health stays `.healthy`. This isolates the
    /// fail-closed test below to the access-lookup failure (not a broken projection).
    func test_sharedArtifactAccessLookup_succeeds_surfacesReadableArtifact_healthy() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let accessContext = SharedArtifactAccessContext(
            userID: "user-matters",
            workspaceID: "workspace-matters",
            teamID: "team-matters"
        )
        let (service, artifactID) = try await makeServiceWithReadableSharedArtifact(
            store: store,
            accessContext: accessContext
        )

        let results = await service.retrieve(sharedQuery())

        XCTAssertEqual(results.count, 1, "Readable shared artifact should be surfaced when access lookup succeeds")
        XCTAssertEqual(results.first?.sourceID, artifactID)

        let lexicalHealth = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .lexical })
        XCTAssertEqual(lexicalHealth?.status, .healthy)
        XCTAssertNil(lexicalHealth?.errorCode)
    }

    // MARK: - Fail-closed: lookup failure denies shared artifacts and is observable

    /// The core regression: when `fetchReadableSharedArtifactSourceIDs` throws, the shared
    /// artifact the user could otherwise read MUST be withheld (fail closed), and the
    /// failure MUST surface as a `.degraded` lexical health record carrying
    /// `INDEX_STALE_PARTIAL_RESULTS`. A `try?` swallow would silently fail closed with no
    /// health signal; the old code therefore left operators blind to a broken access path.
    func test_sharedArtifactAccessLookup_failure_failsClosed_andRecordsDegradedHealth() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let accessContext = SharedArtifactAccessContext(
            userID: "user-matters",
            workspaceID: "workspace-matters",
            teamID: "team-matters"
        )
        let (service, _) = try await makeServiceWithReadableSharedArtifact(
            store: store,
            accessContext: accessContext
        )

        // Break ONLY the access-control lookup: `fetchReadableSharedArtifactSourceIDs`
        // reads `source_artifacts`, while the lexical FTS query and chunk/document
        // hydration do not. Dropping it makes the authoritative re-check throw while the
        // shared artifact still reaches the candidate set via the FTS index.
        try await store.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE source_artifacts")
        }

        let results = await service.retrieve(sharedQuery())

        // Fail closed: no shared artifact may leak when the access decision cannot be made.
        XCTAssertTrue(
            results.allSatisfy { $0.sourceKind != .sharedArtifact },
            "A failed access lookup must deny every shared artifact (fail closed)"
        )

        // Observability: the failure is recorded as degraded lexical health, not swallowed.
        let lexicalHealth = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .lexical })
        XCTAssertEqual(lexicalHealth?.status, .degraded, "Access-lookup failure must mark retrieval degraded")
        XCTAssertEqual(lexicalHealth?.errorCode, "INDEX_STALE_PARTIAL_RESULTS")
    }

    /// Without an access context the lookup is skipped and shared artifacts are denied via
    /// the empty closed set. Confirms the fail-closed default is preserved (no regression
    /// from the edit) and that the no-context path is not spuriously marked degraded.
    func test_sharedArtifactAccess_noContext_deniesSharedArtifacts_withoutDegradedHealth() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let setupContext = SharedArtifactAccessContext(
            userID: "user-matters",
            workspaceID: "workspace-matters",
            teamID: "team-matters"
        )
        // Reuse the projection helper to put a shared artifact in the index, then build a
        // service WITHOUT an access context.
        _ = try await makeServiceWithReadableSharedArtifact(store: store, accessContext: setupContext)

        let now = base
        let noContextService = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { now }
        )

        let results = await noContextService.retrieve(sharedQuery())

        XCTAssertTrue(
            results.allSatisfy { $0.sourceKind != .sharedArtifact },
            "No access context must deny shared artifacts"
        )

        // The no-context path does not consult the data store, so it must not be reported
        // as a degraded/stale index. (Lexical health here reflects the empty result set.)
        let lexicalHealth = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .lexical })
        XCTAssertNotEqual(
            lexicalHealth?.errorCode,
            "INDEX_STALE_PARTIAL_RESULTS",
            "A skipped (no-context) lookup must not be reported as a stale index"
        )
    }
}
