import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarCLITests: XCTestCase {
    func testSocketAuthTokenUsesExplicitEnvironmentPrecedence() throws {
        let token = try BurnBarCLISocketClient.resolvedSocketAuthToken(environment: [
            "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "  direct-token  ",
            "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE": "/does/not/exist"
        ])
        XCTAssertEqual(token, "direct-token")
    }

    func testSocketAuthTokenReadsExplicitTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token")
        try "file-token\n".write(to: file, atomically: true, encoding: .utf8)

        let token = try BurnBarCLISocketClient.resolvedSocketAuthToken(environment: [
            "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE": file.path
        ])
        XCTAssertEqual(token, "file-token")
    }

    #if os(Linux)
    func testSocketAuthTokenReadsCanonicalLinuxSupportFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-linux-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("daemon-socket-auth-token")
        try "canonical-token\n".write(to: file, atomically: true, encoding: .utf8)

        let token = try BurnBarCLISocketClient.resolvedSocketAuthToken(environment: [
            "OPENBURNBAR_DAEMON_SUPPORT_DIR": directory.path
        ])
        XCTAssertEqual(token, "canonical-token")
    }
    #endif

    func testStartupPreflightReturnsUsageBeforeRunnerConstruction() {
        for arguments in [[], ["help"], ["--help"], ["-h"], ["--", "help"]] {
            let result = BurnBarCLIRunner.startupPreflightResult(
                arguments: arguments,
                invokedExecutablePath: "/tmp/OpenBurnBarCLI"
            )

            XCTAssertEqual(result?.exitCode, EXIT_SUCCESS)
            XCTAssertEqual(result?.writesToStandardError, false)
            XCTAssertEqual(result?.output.contains("openburnbar-cli <command>"), true)
        }
    }

    func testStartupPreflightRejectsInvalidCanonicalCommandBeforeRunnerConstruction() {
        let result = BurnBarCLIRunner.startupPreflightResult(
            arguments: ["definitely-not-a-command"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )

        XCTAssertEqual(result?.exitCode, EXIT_FAILURE)
        XCTAssertEqual(result?.writesToStandardError, true)
        XCTAssertEqual(result?.output.contains("Unsupported OpenBurnBar CLI command 'definitely-not-a-command'."), true)
        XCTAssertEqual(result?.output.contains("openburnbar-cli <command>"), true)
    }

    /// `startupPreflightResult` rejects any command missing from
    /// `directCommandNames` under a canonical executable name, before the
    /// socket is touched. The three courier commands the Python MCP invokes
    /// must pass under every canonical name.
    func testStartupPreflightAllowsTheSignedCourierCommands() {
        for executable in ["/tmp/OpenBurnBarCLI", "/tmp/openburnbar-cli", "/tmp/burnbar", "/tmp/openburnbar"] {
            for command in ["search-sql", "memory-remember", "memory-forget", "memory-model-policy"] {
                XCTAssertNil(
                    BurnBarCLIRunner.startupPreflightResult(arguments: [command], invokedExecutablePath: executable),
                    "\(command) must pass preflight under \(executable)"
                )
            }
        }
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
            arguments: ["memory-remember"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        ))
        XCTAssertNil(BurnBarCLIRunner.startupPreflightResult(
            arguments: ["memory-forget"],
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

    func testHealthFastPathIsLimitedToCanonicalOpenBurnBarExecutable() {
        XCTAssertTrue(BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: ["health"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        ))
        XCTAssertTrue(BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: ["--", "health"],
            invokedExecutablePath: "/tmp/openburnbar-cli"
        ))
        XCTAssertFalse(BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: ["health"],
            invokedExecutablePath: "/tmp/codex"
        ))
        XCTAssertFalse(BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: ["health"],
            invokedExecutablePath: nil
        ))
        XCTAssertFalse(BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: ["exec", "codex", "health"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        ))
    }

    func testHealthCommandFormatsDaemonStatus() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["health"])

        XCTAssertTrue(output.contains("Daemon 0.1.0"))
        XCTAssertTrue(output.contains("ok=true"))
    }

    func testSharedHealthFormatterMatchesCLIOutput() throws {
        let response = try FakeCLIClient().health()

        XCTAssertEqual(
            BurnBarCLIHealthFormatter.format(response),
            "Daemon 0.1.0 | protocol 1 | socket /tmp/openburnbar.sock | ok=true"
        )
    }

    func testSocketClientResolvesExplicitSocketPathFromEnvironment() {
        let url = BurnBarCLISocketClient.resolvedSocketURL(environment: [
            "OPENBURNBAR_DAEMON_SOCKET_PATH": " /tmp/openburnbar-release-smoke.sock ",
            "OPENBURNBAR_DAEMON_SUPPORT_DIR": "/tmp/ignored-support-dir"
        ])

        XCTAssertEqual(url.path, "/tmp/openburnbar-release-smoke.sock")
    }

    func testSocketClientResolvesLegacyExplicitSocketPathFromEnvironment() {
        let url = BurnBarCLISocketClient.resolvedSocketURL(environment: [
            "BURNBAR_DAEMON_SOCKET_PATH": "/tmp/openburnbar-legacy-smoke.sock"
        ])

        XCTAssertEqual(url.path, "/tmp/openburnbar-legacy-smoke.sock")
    }

    func testSocketClientPrefersPrimaryExplicitSocketPathEnvironmentName() {
        let url = BurnBarCLISocketClient.resolvedSocketURL(environment: [
            "OPENBURNBAR_DAEMON_SOCKET_PATH": "/tmp/openburnbar-primary.sock",
            "BURNBAR_DAEMON_SOCKET_PATH": "/tmp/openburnbar-legacy.sock"
        ])

        XCTAssertEqual(url.path, "/tmp/openburnbar-primary.sock")
    }

    func testSocketClientFallsBackWhenExplicitSocketPathIsBlank() {
        let url = BurnBarCLISocketClient.resolvedSocketURL(environment: [
            "OPENBURNBAR_DAEMON_SOCKET_PATH": "  "
        ])

        XCTAssertEqual(url, BurnBarDaemonPaths.defaultSocketURL)
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

    func testProjectCodeMemoryIndexWatchAndHealthcheckFormatBudgetState() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())

        let watch = try runner.run(arguments: ["index", "--watch", "--storage-budget-bytes", "4096", "--poll-seconds", "0.5"])
        XCTAssertTrue(watch.contains("Watching project proj_fixture"))
        XCTAssertTrue(watch.contains("poll_seconds=0.5"))

        let health = try runner.run(arguments: ["healthcheck"])
        XCTAssertTrue(health.contains("storage=1024/4096 within_budget=true"))
        XCTAssertTrue(health.contains("last_vacuumed_at=2026-06-16T00:00:01Z"))
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
        XCTAssertEqual(result.output?.contains("error: session_not_found"), true)
    }

    func testResumeSpawnModeFormatsSpawnedResponse() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.run(arguments: ["resume", "codex-session", "--as", "Codex", "--spawn"])

        XCTAssertTrue(output.contains("spawned Codex"))
        XCTAssertTrue(output.contains("pid=4242"))
    }

    func testComputerUsePanicHaltFormatsDaemonResponse() async throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let result = try await runner.invoke(
            arguments: ["computer-use", "panic-halt", "--session-id", "session-123", "--source", "hotkey"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )

        XCTAssertEqual(result.exitCode, EXIT_SUCCESS)
        XCTAssertEqual(result.output?.contains("computer_use_panic_halt=accepted"), true)
        XCTAssertEqual(result.output?.contains("session_id=session-123"), true)
        XCTAssertEqual(result.output?.contains("source=hotkey"), true)
    }

    func testPrivacyRPCReadsJSONAndReturnsOnlyTypedResult() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.runPrivacyRPC(input: Data(#"{"method":"daemon.privacy.inventory","params":{}}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((object["stores"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(object["token"])
    }

    func testPrivacyRPCRejectsNonPrivacyMethods() {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        XCTAssertThrowsError(try runner.runPrivacyRPC(input: Data(#"{"method":"daemon.health","params":{}}"#.utf8)))
    }

    func testMemoryModelPolicyReturnsTypedJSON() throws {
        let output = try BurnBarCLIRunner(client: FakeCLIClient()).runMemoryModelPolicy()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["proActive"] as? Bool, true)
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["gatewayURL"] as? String, "http://127.0.0.1:8317")
        XCTAssertEqual((object["cli"] as? [String: Bool])?["claude_cli"], true)
        XCTAssertEqual(((object["providers"] as? [[String: Any]])?.first?["id"]) as? String, "openrouter")
    }

    func testMemoryRememberReadsJSONAndReturnsTypedResult() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.runMemoryRemember(input: Data(#"{"text":"Remember the signed bridge.","projectPath":"/tmp/fixture","kind":"architecture","scope":"project","tags":["bridge"],"confidence":0.9}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])

        XCTAssertEqual(object["memoryID"] as? String, "mem_architecture")
        XCTAssertEqual(object["projectID"] as? String, "proj_/tmp/fixture")
        XCTAssertEqual(object["auditHash"] as? String, "audit-remember")
    }

    func testMemoryForgetReadsJSONAndReturnsTypedResult() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.runMemoryForget(input: Data(#"{"memoryID":"mem_signed_bridge","projectPath":"/tmp/fixture","requireCloudDelete":true}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])

        XCTAssertEqual(object["memoryID"] as? String, "mem_signed_bridge")
        XCTAssertEqual(object["localDeleted"] as? Bool, true)
        XCTAssertEqual(object["cloudDeletePending"] as? Bool, true)
        XCTAssertEqual(object["auditHash"] as? String, "audit-forget")
    }

    func testChatQueryCommandsEmitStableJSON() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let threads = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try runner.run(arguments: ["chat", "threads", "--query", "release", "--limit", "7"]).utf8)) as? [String: Any])
        XCTAssertEqual((threads["threads"] as? [[String: Any]])?.first?["id"] as? String, "thread-fixture")

        let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try runner.run(arguments: ["chat", "thread", "thread-fixture", "--max-messages", "1"]).utf8)) as? [String: Any])
        XCTAssertEqual((page["messages"] as? [[String: Any]])?.first?["threadID"] as? String, "thread-fixture")
        XCTAssertEqual(page["hasMoreBefore"] as? Bool, true)

        XCTAssertThrowsError(try runner.run(arguments: ["chat", "threads", "--limit", "zero"]))
        XCTAssertThrowsError(try runner.run(arguments: ["chat", "thread", "thread-fixture", "--before-message-id", "message-fixture"]))
    }

    func testActivityQueryCommandsEmitStableJSONAndRejectInvalidBounds() throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())

        let history = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try runner.run(arguments: ["activity", "history", "--limit", "7"]).utf8)
        ) as? [String: Any])
        XCTAssertEqual(history["historyComplete"] as? Bool, true)
        XCTAssertEqual((history["sessions"] as? [[String: Any]])?.first?["sourceID"] as? String, "Codex:activity-fixture")

        let search = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try runner.run(arguments: ["activity", "search", "needle", "--limit", "3"]).utf8)
        ) as? [String: Any])
        XCTAssertEqual((search["hits"] as? [[String: Any]])?.first?["sourceID"] as? String, "Codex:activity-fixture")

        let replay = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try runner.run(arguments: ["activity", "replay", "Codex:activity-fixture"]).utf8)
        ) as? [String: Any])
        XCTAssertEqual(replay["kind"] as? String, "native")

        XCTAssertThrowsError(try runner.run(arguments: ["activity", "history", "--limit", "0"]))
        XCTAssertThrowsError(try runner.run(arguments: ["activity", "search", "--limit", "1"]))
        XCTAssertThrowsError(try runner.run(arguments: ["activity", "replay", "source", "extra"]))
    }

    func testActivityReplayInvocationUsesExitStatusForLookupFailure() async throws {
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let success = try await runner.invoke(
            arguments: ["activity", "replay", "Codex:activity-fixture"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )
        let missing = try await runner.invoke(
            arguments: ["activity", "replay", "missing"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )

        XCTAssertEqual(success.exitCode, EXIT_SUCCESS)
        XCTAssertEqual(missing.exitCode, EXIT_FAILURE)
        XCTAssertEqual(missing.output?.contains("session_not_found"), true)
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

    func searchSQL(_ request: BurnBarSearchSQLRequest) throws -> BurnBarSearchSQLResult {
        BurnBarSearchSQLResult(
            columns: ["id", "title"],
            rows: [[.text("conv-1"), .text(request.sql)]],
            truncated: false
        )
    }

    func memoryModelPolicy() throws -> BurnBarMemoryModelPolicyResponse {
        BurnBarMemoryModelPolicyResponse(
            proActive: true,
            enabled: true,
            gatewayURL: "http://127.0.0.1:8317",
            gatewayToken: String(repeating: "a", count: 64),
            tokenExpiresAt: "2099-01-01T00:00:00Z",
            providers: [BurnBarMemoryModelPolicyProvider(id: "openrouter", consented: true, retention: "deny", purposes: ["memory-extract": ["anthropic/claude-opus-5"]])],
            cli: ["claude_cli": true, "codex_cli": false],
            membershipUpdatedAt: "2026-09-01T00:00:00Z",
            code: nil
        )
    }

    func memoryRemember(_ request: BurnBarProjectMemoryRememberRequest) throws -> BurnBarProjectMemoryRememberResponse {
        BurnBarProjectMemoryRememberResponse(
            traceID: "trace-remember",
            projectID: "proj_\(request.projectPath ?? "default")",
            memoryID: "mem_\(request.kind)",
            auditHash: "audit-remember"
        )
    }

    func memoryForget(_ request: BurnBarProjectMemoryForgetRequest) throws -> BurnBarProjectMemoryForgetResponse {
        BurnBarProjectMemoryForgetResponse(
            traceID: "trace-forget",
            projectID: "proj_\(request.projectPath ?? "default")",
            memoryID: request.memoryID,
            localDeleted: true,
            cloudDeletePending: request.requireCloudDelete,
            auditHash: "audit-forget"
        )
    }

    func memoryRecall(query: String, projectPath: String?, limit: Int) throws -> BurnBarProjectMemoryRecallResponse {
        BurnBarProjectMemoryRecallResponse(
            traceID: "trace-test",
            projectID: "proj_fixture",
            hits: [
                BurnBarProjectMemoryHit(
                    memoryID: "mem_fixture",
                    projectID: "proj_fixture",
                    kind: "note",
                    scope: "personal",
                    confidence: 1.0,
                    bodyRedacted: "Use the fixture pipeline.",
                    tags: ["fixture"],
                    sourcePath: nil,
                    snippet: "Use the fixture pipeline.",
                    rank: nil
                )
            ]
        )
    }

    func codeIndex(projectPath: String?, maxFiles: Int, maxFileBytes: Int, storageBudgetBytes: Int?) throws -> BurnBarProjectCodeIndexProjectResponse {
        BurnBarProjectCodeIndexProjectResponse(
            traceID: "trace-test",
            projectID: "proj_fixture",
            projectRoot: projectPath ?? "/tmp/fixture",
            indexedFiles: 1,
            chunkCount: 1,
            symbolCount: 1,
            rejectedFiles: [],
            commitSHA: nil,
            auditHash: "audit"
        )
    }

    func codeWatch(
        projectPath: String?,
        maxFiles: Int,
        maxFileBytes: Int,
        storageBudgetBytes: Int?,
        pollIntervalSeconds: Double
    ) throws -> BurnBarProjectCodeWatchProjectResponse {
        BurnBarProjectCodeWatchProjectResponse(
            traceID: "trace-test",
            projectID: "proj_fixture",
            projectRoot: projectPath ?? "/tmp/fixture",
            watching: true,
            pollIntervalSeconds: pollIntervalSeconds,
            signature: "sig_fixture",
            indexedFiles: 1
        )
    }

    func codeSearch(query: String, projectPath: String?, limit: Int) throws -> BurnBarProjectCodeSearchResponse {
        BurnBarProjectCodeSearchResponse(
            traceID: "trace-test",
            projectID: "proj_fixture",
            hits: [
                BurnBarProjectCodeSearchHit(
                    chunkID: "chunk_fixture",
                    filePath: "Sources/App.swift",
                    snippet: "func fixture() {}",
                    rank: nil
                )
            ]
        )
    }

    func codeIndexStatus(projectPath: String?) throws -> BurnBarProjectCodeIndexStatusResponse {
        BurnBarProjectCodeIndexStatusResponse(
            traceID: "trace-test",
            projectID: "proj_fixture",
            projectRoot: projectPath ?? "/tmp/fixture",
            indexedAt: "2026-06-16T00:00:00Z",
            artifactCount: 1,
            chunkCount: 1,
            symbolCount: 1,
            referenceCount: 0,
            callEdgeCount: 0,
            rejectedCount: 0,
            lastCommitSHA: nil,
            pendingForgetCount: 0,
            storageByteCount: 1024,
            storageBudgetBytes: 4096,
            storageWithinBudget: true,
            lastVacuumedAt: "2026-06-16T00:00:01Z"
        )
    }

    func attachRunClient(clientID: BurnBarClientID, sessionID: BurnBarSessionID) throws {}

    func createRun(_ request: BurnBarRunCreateRequest) throws -> BurnBarRunCreateResponse {
        BurnBarRunCreateResponse(runID: BurnBarRunID(rawValue: "run-fixture"), phase: .completed)
    }

    func listRuns(_ request: BurnBarRunListRequest) throws -> BurnBarRunListResponse {
        BurnBarRunListResponse(runs: [
            BurnBarRunStateSnapshot(
                runID: BurnBarRunID(rawValue: "run-fixture"),
                clientID: request.clientID,
                sessionID: BurnBarSessionID(rawValue: "session-fixture"),
                phase: .completed,
                modelID: "gpt-5.5",
                updatedAt: Date()
            )
        ])
    }

    func getRun(_ request: BurnBarRunGetRequest) throws -> BurnBarRunDetailResponse {
        BurnBarRunDetailResponse(
            run: BurnBarRunStateSnapshot(
                runID: request.runID,
                clientID: request.clientID,
                sessionID: BurnBarSessionID(rawValue: "session-fixture"),
                phase: .completed,
                modelID: "gpt-5.5",
                updatedAt: Date()
            )
        )
    }

    func pollRuns(_ request: BurnBarRunPollRequest) throws -> BurnBarRunEventBatch {
        BurnBarRunEventBatch(
            runs: [
                BurnBarRunStateSnapshot(
                    runID: request.runID ?? BurnBarRunID(rawValue: "run-fixture"),
                    clientID: request.clientID,
                    sessionID: request.sessionID,
                    phase: .completed,
                    modelID: "gpt-5.5",
                    updatedAt: Date()
                )
            ],
            approvals: [],
            pendingToolCalls: [],
            arbitration: nil,
            emittedAt: Date()
        )
    }

    func cancelRun(_ request: BurnBarRunCancelRequest) throws -> BurnBarRunDetailResponse {
        BurnBarRunDetailResponse(
            run: BurnBarRunStateSnapshot(
                runID: request.runID,
                clientID: request.clientID,
                sessionID: BurnBarSessionID(rawValue: "session-fixture"),
                phase: .cancelled,
                modelID: "gpt-5.5",
                updatedAt: Date()
            )
        )
    }

    func retryRun(_ request: BurnBarRunRetryRequest) throws -> BurnBarRunDetailResponse {
        BurnBarRunDetailResponse(
            run: BurnBarRunStateSnapshot(
                runID: request.runID,
                clientID: request.clientID,
                sessionID: BurnBarSessionID(rawValue: "session-fixture"),
                phase: .completed,
                modelID: "gpt-5.5",
                updatedAt: Date()
            )
        )
    }

    func respondToApproval(_ request: BurnBarApprovalRespondRequest) throws -> BurnBarRunDetailResponse {
        BurnBarRunDetailResponse(
            run: BurnBarRunStateSnapshot(
                runID: BurnBarRunID(rawValue: "run-fixture"),
                clientID: request.response.clientID,
                sessionID: BurnBarSessionID(rawValue: "session-fixture"),
                phase: request.response.decision == .approve ? .completed : .cancelled,
                modelID: "gpt-5.5",
                updatedAt: Date()
            )
        )
    }

    func panicHalt(_ request: ComputerUsePanicHaltRequest) throws -> ComputerUsePanicHaltResponse {
        ComputerUsePanicHaltResponse(
            sessionId: request.sessionId,
            endedAt: Date(timeIntervalSince1970: 1_780_000_000),
            auditHeadHashHex: "panic-head-fixture"
        )
    }

    func startSubscription(_ request: BurnBarSubscriptionStartRequest) throws -> BurnBarSubscriptionResponse {
        BurnBarSubscriptionResponse(
            subscriptionID: request.requestedSubscriptionID ?? "sub-fixture",
            topic: request.topic,
            seq: 1,
            cursor: "1",
            firstSnapshot: true,
            events: [
                BurnBarSubscriptionEvent(
                    seq: 1,
                    kind: "\(request.topic).snapshot",
                    snapshot: ["topic": request.topic]
                )
            ],
            degradedFallback: true,
            degradationReason: "test-fixture",
            backpressure: "coalesce_latest_per_topic",
            disconnectDetected: false,
            recoveredAfterRestart: false,
            terminalStateDelivered: true
        )
    }

    func resumeSubscription(_ request: BurnBarSubscriptionResumeRequest) throws -> BurnBarSubscriptionResponse {
        let seq = request.afterSeq + 1
        return BurnBarSubscriptionResponse(
            subscriptionID: request.subscriptionID,
            topic: request.topic,
            seq: seq,
            cursor: String(seq),
            firstSnapshot: false,
            events: [
                BurnBarSubscriptionEvent(
                    seq: seq,
                    kind: "\(request.topic).resume_snapshot",
                    snapshot: ["topic": request.topic]
                )
            ],
            degradedFallback: true,
            degradationReason: "test-fixture",
            backpressure: "coalesce_latest_per_topic",
            disconnectDetected: true,
            recoveredAfterRestart: true,
            terminalStateDelivered: true
        )
    }

    func chatThreadList(_ request: BurnBarChatThreadListRequest) throws -> BurnBarChatThreadListResponse {
        BurnBarChatThreadListResponse(threads: [
            BurnBarChatThreadSummary(
                id: "thread-fixture", title: request.query ?? "Fixture", preview: "Durable chat", messageCount: 2,
                createdAt: "2026-07-20T00:00:00Z", updatedAt: "2026-07-20T00:01:00Z", backendID: "openai"
            )
        ])
    }

    func chatThreadGet(_ request: BurnBarChatThreadGetRequest) throws -> BurnBarChatThreadGetResponse {
        BurnBarChatThreadGetResponse(
            thread: BurnBarChatThreadSummary(
                id: request.threadID, title: "Fixture", preview: "Durable chat", messageCount: 2,
                createdAt: "2026-07-20T00:00:00Z", updatedAt: "2026-07-20T00:01:00Z", backendID: "openai"
            ),
            messages: [BurnBarChatMessage(
                id: "message-fixture", threadID: request.threadID, role: .user, content: "Hello",
                timestamp: "2026-07-20T00:00:00Z", backendID: "openai"
            )],
            hasMoreBefore: true
        )
    }

    func activityHistory(limit: Int) throws -> BurnBarActivityHistoryResponse {
        BurnBarActivityHistoryResponse(
            sessions: [BurnBarActivityHistorySession(
                id: "Codex:activity-fixture",
                provider: "Codex",
                model: "gpt-5.5",
                startedAt: "2026-07-20T00:00:00Z",
                tokens: 42,
                costUsd: 0.01,
                title: "Activity fixture",
                sourceID: "Codex:activity-fixture",
                providerSessionID: "activity-fixture",
                projectName: "OpenBurnBar",
                bodyMD: "# Activity fixture"
            )],
            nextCursor: nil,
            historyComplete: true,
            historyLimit: limit,
            totalCount: 1
        )
    }

    func activitySearch(query: String, limit: Int) throws -> BurnBarSearchQueryResult {
        BurnBarSearchQueryResult(
            plan: BurnBarSearchPlan(
                mode: .retrieve,
                lexicalFTSQuery: query,
                semanticText: query,
                aggregatePatterns: [],
                note: nil
            ),
            aggregateOccurrenceCount: nil,
            hits: [BurnBarIndexedSearchHit(
                chunkID: "activity-chunk-fixture",
                sourceKind: "conversation",
                sourceID: "Codex:activity-fixture",
                title: "Activity fixture",
                snippet: "needle",
                provider: "Codex",
                projectName: "OpenBurnBar"
            )],
            degradedMessage: nil,
            semanticSearchPerformed: false,
            semanticHitCount: nil
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

    func linuxPrivacyInventory() throws -> BurnBarLinuxPrivacyInventoryResponse {
        BurnBarLinuxPrivacyInventoryResponse(
            stores: BurnBarLinuxPrivacyStoreID.allCases.map {
                BurnBarLinuxPrivacyStoreInventory(store: $0, state: .ready, bytes: 1, reason: "ready")
            },
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    func linuxPrivacyDeletionPreview(_ request: BurnBarLinuxPrivacyDeletionPreviewRequest) throws -> BurnBarLinuxPrivacyDeletionPreviewResponse {
        BurnBarLinuxPrivacyDeletionPreviewResponse(
            token: "preview-token",
            stores: request.stores,
            entries: request.stores.map {
                BurnBarLinuxPrivacyStoreInventory(store: $0, state: .ready, bytes: 1, reason: "ready")
            },
            expiresAt: Date(timeIntervalSince1970: 1_780_000_300),
            confirmationPhrase: "DELETE LOCAL DATA"
        )
    }

    func linuxPrivacyDeletionExecute(_ request: BurnBarLinuxPrivacyDeletionExecuteRequest) throws -> BurnBarLinuxPrivacyDeletionExecuteResponse {
        BurnBarLinuxPrivacyDeletionExecuteResponse(
            stores: request.stores,
            deleted: request.stores,
            alreadyAbsent: [],
            bytesRemoved: 1,
            idempotent: false
        )
    }

    func linuxPrivacyExport(_ request: BurnBarLinuxPrivacyExportRequest) throws -> BurnBarLinuxPrivacyExportResponse {
        BurnBarLinuxPrivacyExportResponse(
            stores: request.stores,
            destinationPath: request.destinationPath,
            byteCount: 8,
            formatVersion: 1
        )
    }

    func linuxPrivacyRetentionStatus() throws -> BurnBarLinuxPrivacyRetentionStatusResponse {
        BurnBarLinuxPrivacyRetentionStatusResponse(
            policyState: .defaults,
            rules: [],
            stores: [],
            evaluatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    func linuxPrivacyRetentionApply(_ request: BurnBarLinuxPrivacyRetentionApplyRequest) throws -> BurnBarLinuxPrivacyRetentionApplyResponse {
        BurnBarLinuxPrivacyRetentionApplyResponse(
            status: try linuxPrivacyRetentionStatus(),
            removedBytes: 0,
            removedEntries: 0
        )
    }
}
