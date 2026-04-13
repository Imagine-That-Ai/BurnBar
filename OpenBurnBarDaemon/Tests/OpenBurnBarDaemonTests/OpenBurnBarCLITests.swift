import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarCLITests: XCTestCase {
    func testHealthCommandFormatsDaemonStatus() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["health"])

        XCTAssertTrue(output.contains("Daemon 0.1.0"))
        XCTAssertTrue(output.contains("ok=true"))
    }

    func testMissionApproveCommandRequiresIdentifier() {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())

        XCTAssertThrowsError(try runner.run(arguments: ["mission-approve"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Usage: openburnbar-cli mission-approve"))
        }
    }

    func testQuestionsAndFollowupsCommandsRenderIdentifiers() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())

        let questions = try runner.run(arguments: ["questions"])
        let followups = try runner.run(arguments: ["followups"])

        XCTAssertTrue(questions.contains("question-apollo"))
        XCTAssertTrue(followups.contains("followup-apollo"))
    }

    func testSimulatorReplayCommandFormatsReplaySummary() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["simulator-replay", "sim-apollo"])

        XCTAssertTrue(output.contains("Replayed Daily Review"))
        XCTAssertTrue(output.contains("1 event"))
    }
}

struct FakeCLIClient: BurnBarCLIClient {
    func health() throws -> BurnBarHealthResponse {
        BurnBarHealthResponse(ok: true, daemonVersion: "0.1.0", protocolVersion: 1, socketPath: "/tmp/openburnbar.sock")
    }

    func controllerSummary(projectSlug: String?) throws -> BurnBarControllerSummary {
        BurnBarControllerSummary(
            updatedAt: Date(timeIntervalSince1970: 1_710_400_000),
            counts: BurnBarControllerCounts(
                projectCount: 1,
                pendingQuestionCount: 1,
                openFollowupCount: 1,
                activeMissionCount: 1,
                staleProjectCount: 0
            ),
            freshness: .fresh
        )
    }

    func questions(projectSlug: String?) throws -> [BurnBarPendingQuestionSnapshot] {
        [
            BurnBarPendingQuestionSnapshot(
                id: BurnBarQuestionID(rawValue: "question-apollo"),
                projectSlug: "apollo",
                title: "Ship the approval sheet?",
                prompt: "Need a decision.",
                stageLabel: "Operator Decision",
                status: .pending,
                priority: .high,
                askedAt: Date()
            )
        ]
    }

    func followups(projectSlug: String?) throws -> [BurnBarFollowupSnapshot] {
        [
            BurnBarFollowupSnapshot(
                id: BurnBarFollowupID(rawValue: "followup-apollo"),
                projectSlug: "apollo",
                title: "Review approval sheet",
                summary: "Operator followup.",
                status: .open,
                kind: .pendingQuestion,
                createdAt: Date()
            )
        ]
    }

    func missions(projectSlug: String?) throws -> [BurnBarMissionSnapshot] {
        [
            BurnBarMissionSnapshot(
                id: BurnBarMissionID(rawValue: "mission-apollo"),
                projectSlug: "apollo",
                title: "Ship Apollo",
                summary: "Mission summary.",
                status: .inProgress,
                recommendation: .proceed,
                createdAt: Date(),
                updatedAt: Date(),
                approval: BurnBarMissionApprovalSnapshot(approved: true)
            )
        ]
    }

    func approveMission(id: BurnBarMissionID, note: String?) throws -> BurnBarMissionSnapshot {
        BurnBarMissionSnapshot(
            id: id,
            projectSlug: "apollo",
            title: "Ship Apollo",
            summary: note ?? "Approved.",
            status: .approved,
            recommendation: .proceed,
            createdAt: Date(),
            updatedAt: Date(),
            approval: BurnBarMissionApprovalSnapshot(approved: true, approvedAt: Date(), approvedBy: "openburnbar-cli", note: note)
        )
    }

    func simulatorRuns(projectSlug: String?) throws -> [BurnBarSimulatorRunSnapshot] {
        [
            BurnBarSimulatorRunSnapshot(
                id: BurnBarSimulatorRunID(rawValue: "sim-apollo"),
                projectSlug: "apollo",
                scenarioName: "Daily Review",
                status: .queued,
                seed: 7,
                startedAt: Date(),
                summary: "Queued."
            )
        ]
    }

    func simulatorReplay(runID: BurnBarSimulatorRunID) throws -> BurnBarSimulatorRunSnapshot {
        BurnBarSimulatorRunSnapshot(
            id: runID,
            projectSlug: "apollo",
            scenarioName: "Daily Review",
            status: .completed,
            seed: 7,
            startedAt: Date(),
            completedAt: Date(),
            emittedEvents: [
                BurnBarControllerEvent(
                    id: BurnBarControllerEventID(rawValue: "event-1"),
                    family: .controller,
                    eventType: "project_upserted",
                    projectSlug: "apollo",
                    recordedAt: Date(),
                    sequence: 1,
                    summary: "Apollo",
                    detail: nil
                )
            ],
            summary: "Replay complete."
        )
    }
}
