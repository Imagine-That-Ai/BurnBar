import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarCLITests: XCTestCase {
    func testStartupPreflightReturnsUsageBeforeRunnerConstruction() {
        for arguments in [[], ["help"], ["--help"], ["-h"], ["--", "help"]] {
            let result = BurnBarCLIRunner.startupPreflightResult(
                arguments: arguments,
                invokedExecutablePath: "/tmp/OpenBurnBarCLI"
            )

            XCTAssertEqual(result?.exitCode, EXIT_SUCCESS)
            XCTAssertEqual(result?.writesToStandardError, false)
            XCTAssertTrue(result?.output.contains("openburnbar-cli <command>") == true)
        }
    }

    func testStartupPreflightRejectsInvalidCanonicalCommandBeforeRunnerConstruction() {
        let result = BurnBarCLIRunner.startupPreflightResult(
            arguments: ["definitely-not-a-command"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )

        XCTAssertEqual(result?.exitCode, EXIT_FAILURE)
        XCTAssertEqual(result?.writesToStandardError, true)
        XCTAssertTrue(result?.output.contains("Unsupported OpenBurnBar CLI command 'definitely-not-a-command'.") == true)
        XCTAssertTrue(result?.output.contains("openburnbar-cli <command>") == true)
    }

    func testStartupPreflightAllowsKnownCommandsAndShellShimInvocations() {
        XCTAssertNil(BurnBarCLIRunner.startupPreflightResult(
            arguments: ["health"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        ))
        XCTAssertNil(BurnBarCLIRunner.startupPreflightResult(
            arguments: ["remote-unlock-certification", "status"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        ))
        XCTAssertNil(BurnBarCLIRunner.startupPreflightResult(
            arguments: ["--model", "gpt-5"],
            invokedExecutablePath: "/tmp/codex"
        ))
        XCTAssertNil(BurnBarCLIRunner.startupPreflightResult(
            arguments: ["--help"],
            invokedExecutablePath: "/tmp/codex"
        ))
        XCTAssertNil(BurnBarCLIRunner.startupPreflightResult(
            arguments: [],
            invokedExecutablePath: "/tmp/codex"
        ))
    }

    func testHealthCommandFormatsDaemonStatus() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["health"])

        XCTAssertTrue(output.contains("Daemon 0.1.0"))
        XCTAssertTrue(output.contains("ok=true"))
    }

    func testRemoteUnlockCertificationStatusUsesProofStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cli-remote-unlock-\(UUID().uuidString)", isDirectory: true)
        let store = RemoteUnlockCertificationReportStore(
            fileURL: directory.appendingPathComponent("proof.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = BurnBarCLIRunner(
            client: FakeCLIClient(),
            remoteUnlockCertificationStore: store
        )

        let missing = try runner.run(arguments: ["remote-unlock-certification", "status"])
        XCTAssertTrue(missing.contains("missing"))

        let report = RemoteUnlockCertificationReport.certifiedHardware(
            currentOSBuild: "24F74",
            credentialRecipientKeyId: "hpke-0123456789abcdef01234567",
            credentialRecipientPublicKeyBase64: Data(repeating: 0x42, count: 32).base64EncodedString(),
            fileVaultSSHSupported: false,
            generatedAt: Date(timeIntervalSince1970: 1_774_000_000)
        )
        try store.save(report)

        let present = try runner.run(arguments: ["remote-unlock-certification", "status"])
        XCTAssertTrue(present.contains("Remote Unlock certification: present"))
        XCTAssertTrue(present.contains(report.reportId))
        XCTAssertTrue(present.contains("hpke-0123456789abcdef01234567"))
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

    func testResumeCommandParsingAndNativeOutput() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["resume", "codex-session", "--as", "Codex", "--model", "gpt-5.1"])

        XCTAssertTrue(output.contains("# Run from: /tmp/fixture"))
        XCTAssertTrue(output.contains("codex resume codex-session"))
    }

    func testResumeAsRequiresValue() {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())

        XCTAssertThrowsError(try runner.run(arguments: ["resume", "session", "--as"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("--as requires a value"))
        }
        XCTAssertThrowsError(try runner.run(arguments: ["resume", "session", "--as", "--copy"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("--as requires a value"))
        }
    }

    func testResumeFormatterHandlesPortedAndErrors() {
        let ported = BurnBarCLIRunner.formatRunResumeResponse(
            BurnBarRunResumeResponse(
                kind: "ported",
                briefingMD: "# Briefing",
                note: "native_handle_invalid_fell_back_to_port"
            ),
            mode: .print
        )
        let error = BurnBarCLIRunner.formatRunResumeResponse(
            BurnBarRunResumeResponse(kind: "error", errorCode: "target_required", errorRecovery: "Pass --as."),
            mode: .print
        )

        XCTAssertTrue(ported.contains("# note: native_handle_invalid_fell_back_to_port"))
        XCTAssertTrue(ported.contains("# Briefing"))
        XCTAssertTrue(error.contains("error: target_required"))
    }

    func testResumeErrorResponseExitsFailure() async throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let result = try await runner.invoke(
            arguments: ["resume", "missing"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )

        XCTAssertEqual(result.exitCode, EXIT_FAILURE)
        XCTAssertTrue(result.output?.contains("error: session_not_found") == true)
    }

    func testResumeSpawnModeFormatsSpawnedResponse() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["resume", "codex-session", "--as", "Codex", "--spawn"])

        XCTAssertTrue(output.contains("spawned Codex"))
        XCTAssertTrue(output.contains("pid=4242"))
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

    func runResume(
        sessionID: String,
        targetHarness: String?,
        targetModel: String?,
        mode: BurnBarResumeMode
    ) throws -> BurnBarRunResumeResponse {
        if mode == .spawn {
            return BurnBarRunResumeResponse(
                kind: "spawned",
                targetHarness: targetHarness,
                targetArgv: ["codex", "resume", sessionID],
                workingDirectory: "/tmp/fixture",
                pid: 4242,
                cleanupAfterSeconds: 600
            )
        }
        if sessionID == "missing" {
            return BurnBarRunResumeResponse(
                kind: "error",
                errorCode: "session_not_found",
                errorRecovery: "Run burnbar_list_resumable_conversations to find a valid sessionId."
            )
        }
        return BurnBarRunResumeResponse(
            kind: "native",
            argv: ["codex", "resume", sessionID],
            targetHarness: targetHarness,
            workingDirectory: "/tmp/fixture"
        )
    }
}
