import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

/// Linux-targeted durability coverage for the daemon-owned project registry.
/// These cases model a crash after the journal append but before the projection
/// checkpoint is written, which is the failure boundary that a packaged Linux
/// daemon must recover from on restart.
final class BurnBarMissionControlProjectLifecycleLinuxTests: XCTestCase {
    func testRestartReplaysDeletionWhenProjectionCheckpointLagsJournal() async throws {
        let root = try makeRoot(name: "projection-replay-delete")
        let service = makeService(root: root)
        let project = makeProject(slug: "apollo", id: "stable-apollo", aliases: ["legacy-apollo"])

        _ = try await service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project)
        )
        let projectionBeforeDelete = try Data(
            contentsOf: root.appendingPathComponent("controller-projection.json")
        )
        _ = try await service.controllerProjectDelete(
            BurnBarControllerProjectDeleteRequest(projectSlug: "apollo")
        )

        // Simulate a process crash after the JSONL append. The delete event is
        // durable, but the projection file is intentionally rolled back to the
        // pre-delete checkpoint.
        try projectionBeforeDelete.write(
            to: root.appendingPathComponent("controller-projection.json"),
            options: .atomic
        )

        let restarted = makeService(root: root)
        let response = try await restarted.controllerProjects(
            BurnBarControllerProjectsListRequest(includePaused: true)
        )
        XCTAssertTrue(
            response.projects.isEmpty,
            "restart must replay the journal tail instead of resurrecting a deleted project"
        )
        let detail = try await restarted.controllerProject(
            BurnBarControllerProjectGetRequest(projectSlug: "apollo")
        )
        XCTAssertNil(detail.project)
    }

    func testDeletionTombstonesStableIDAndAliasAcrossRestart() async throws {
        let root = try makeRoot(name: "identity-tombstones")
        let service = makeService(root: root)
        let project = makeProject(slug: "apollo", id: "stable-apollo", aliases: ["legacy-apollo"])

        _ = try await service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project)
        )
        _ = try await service.controllerProjectDelete(
            BurnBarControllerProjectDeleteRequest(projectSlug: "apollo")
        )

        let restarted = makeService(root: root)
        do {
            _ = try await restarted.controllerProjectUpsert(
                BurnBarControllerProjectUpsertRequest(
                    project: makeProject(slug: "new-apollo", id: "stable-apollo")
                )
            )
            XCTFail("a deleted stable project ID must not be silently reused")
        } catch let error as BurnBarMissionControlError {
            guard case .projectDeleted("stable-apollo") = error else {
                return XCTFail("unexpected stable-ID tombstone error: \(error)")
            }
        }

        do {
            _ = try await restarted.controllerProjectUpsert(
                BurnBarControllerProjectUpsertRequest(
                    project: makeProject(
                        slug: "another-apollo",
                        id: "stable-another-apollo",
                        aliases: ["legacy-apollo"]
                    )
                )
            )
            XCTFail("a deleted project alias must not be silently reused")
        } catch let error as BurnBarMissionControlError {
            guard case .projectDeleted("legacy-apollo") = error else {
                return XCTFail("unexpected alias tombstone error: \(error)")
            }
        }
    }

    func testDeletedSourceReassignmentResolvesStableIDAfterRestart() async throws {
        let root = try makeRoot(name: "deleted-source-stable-id")
        let service = makeService(root: root)
        _ = try await service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(
                project: makeProject(slug: "apollo", id: "stable-apollo", aliases: ["legacy-apollo"])
            )
        )
        _ = try await service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: makeProject(slug: "orion", id: "stable-orion"))
        )
        _ = try await service.questionCreate(
            BurnBarQuestionCreateRequest(
                question: BurnBarPendingQuestionSnapshot(
                    id: BurnBarQuestionID(rawValue: "question-deleted-source"),
                    projectSlug: "apollo",
                    title: "Deleted source question",
                    prompt: "Move this durable reference.",
                    status: .pending,
                    priority: .medium,
                    askedAt: Date()
                )
            )
        )
        _ = try await service.controllerProjectDelete(
            BurnBarControllerProjectDeleteRequest(projectSlug: "apollo")
        )

        let restarted = makeService(root: root)
        let reassigned = try await restarted.controllerProjectReassign(
            BurnBarControllerProjectReassignRequest(
                sourceProjectSlug: "stable-apollo",
                targetProjectSlug: "orion"
            )
        )
        XCTAssertEqual(reassigned.sourceProjectSlug, "apollo")
        XCTAssertEqual(reassigned.targetProjectSlug, "orion")
        XCTAssertEqual(reassigned.updatedReferenceCount, 2, "question plus generated follow-up must migrate")

        let questions = try await restarted.questionsList(
            BurnBarQuestionsListRequest(projectSlug: "orion", statuses: BurnBarPendingQuestionStatus.allCases)
        )
        XCTAssertEqual(questions.questions.map(\.projectSlug), ["orion"])
    }

    private func makeRoot(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeService(root: URL) -> BurnBarMissionControlService {
        let store = BurnBarMissionControlStore(
            eventsFileURL: root.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: root.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "linux-project-lifecycle-tests"),
            notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
        )
        return BurnBarMissionControlService(
            store: store,
            logger: BurnBarDaemonLogger(category: "linux-project-lifecycle-tests")
        )
    }

    private func makeProject(
        slug: String,
        id: String,
        aliases: [String] = []
    ) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: id,
            projectSlug: slug,
            displayName: slug,
            summary: "Linux lifecycle test project",
            status: .healthy,
            preferredCadence: .weekly,
            aliases: aliases,
            automationMode: .manual,
            freshness: .fresh,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: false,
            metadata: [:]
        )
    }
}
