import XCTest
@testable import OpenBurnBarDaemon

final class ClaudeInteractiveHandoffServiceTests: XCTestCase {

    // MARK: - Project path encoding

    func test_claudeProjectDirectory_encodesSlashesAsDashes() {
        let url = ClaudeInteractiveHandoffService.claudeProjectDirectory(for: "/Users/me/code/app")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "-Users-me-code-app")
        XCTAssertEqual(url?.path.hasSuffix(".claude/projects/-Users-me-code-app"), true)
    }

    func test_claudeProjectDirectory_nilWorkingDirectory_returnsNil() {
        XCTAssertNil(ClaudeInteractiveHandoffService.claudeProjectDirectory(for: nil))
    }

    // MARK: - Scoped totals

    func test_scopedTotal_filtersByProjectPrefix() {
        let snapshot = ClaudeCodeJSONLUsageProbe.Snapshot(perFileTokens: [
            "/home/.claude/projects/-Users-me-app/s1.jsonl": 100,
            "/home/.claude/projects/-Users-me-app/s2.jsonl": 50,
            "/home/.claude/projects/-Users-me-other/s3.jsonl": 999
        ])
        let projectDir = URL(fileURLWithPath: "/home/.claude/projects/-Users-me-app", isDirectory: true)
        XCTAssertEqual(
            ClaudeInteractiveHandoffService.scopedTotal(snapshot: snapshot, projectDirectory: projectDir),
            150
        )
    }

    func test_scopedTotal_nilProject_returnsGlobalTotal() {
        let snapshot = ClaudeCodeJSONLUsageProbe.Snapshot(perFileTokens: [
            "/a/s1.jsonl": 100,
            "/b/s2.jsonl": 50
        ])
        XCTAssertEqual(
            ClaudeInteractiveHandoffService.scopedTotal(snapshot: snapshot, projectDirectory: nil),
            150
        )
    }

    func test_scopedFileNames_filtersAndReturnsLeafNames() {
        let snapshot = ClaudeCodeJSONLUsageProbe.Snapshot(perFileTokens: [
            "/home/.claude/projects/-app/b.jsonl": 1,
            "/home/.claude/projects/-app/a.jsonl": 1,
            "/home/.claude/projects/-other/z.jsonl": 1
        ])
        let projectDir = URL(fileURLWithPath: "/home/.claude/projects/-app", isDirectory: true)
        XCTAssertEqual(
            ClaudeInteractiveHandoffService.scopedFileNames(snapshot: snapshot, projectDirectory: projectDir),
            ["a.jsonl", "b.jsonl"]
        )
    }

    // MARK: - Shell quoting

    func test_shellSingleQuote_escapesEmbeddedQuotes() {
        XCTAssertEqual(
            ClaudeInteractiveHandoffService.shellSingleQuote("it's a test"),
            "'it'\\''s a test'"
        )
    }

    func test_shellSingleQuote_wrapsPlainValue() {
        XCTAssertEqual(
            ClaudeInteractiveHandoffService.shellSingleQuote("/usr/bin/claude"),
            "'/usr/bin/claude'"
        )
    }

    // MARK: - Dispatch + persistence (with stubbed claude + open)

    func test_dispatch_writesLauncher_recordsSession_andReconciles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-handoff-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("sessions.json")
        let launcherDir = root.appendingPathComponent("launchers", isDirectory: true)
        // `/bin/echo` is a real executable so the `claude` resolution guard passes;
        // `/usr/bin/true` stands in for `open -a` so nothing actually launches.
        let service = ClaudeInteractiveHandoffService(
            storeURL: storeURL,
            launcherDirectory: launcherDir,
            claudeExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            openExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        let workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let result = try service.dispatch(
            ClaudeInteractiveHandoffService.Request(
                briefing: "Investigate the flaky test in PaymentsView.",
                workingDirectory: workingDirectory.path,
                model: "claude-opus-4-20250514",
                terminal: .terminal
            )
        )

        // Launcher script exists and is executable.
        XCTAssertTrue(fileManager.fileExists(atPath: result.launcherPath))
        XCTAssertTrue(fileManager.isExecutableFile(atPath: result.launcherPath))

        // Script reads the prompt from a sidecar and execs interactive claude (no -p).
        let script = try String(contentsOfFile: result.launcherPath, encoding: .utf8)
        XCTAssertTrue(script.contains("exec '/bin/echo'"))
        XCTAssertFalse(script.contains(" -p "))
        XCTAssertFalse(script.contains("--print"))
        XCTAssertTrue(script.contains("--model 'claude-opus-4-20250514'"))

        // Sidecar prompt file carries the briefing verbatim.
        let sessionDir = URL(fileURLWithPath: result.launcherPath).deletingLastPathComponent()
        let prompt = try String(
            contentsOf: sessionDir.appendingPathComponent("prompt.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(prompt, "Investigate the flaky test in PaymentsView.")

        // Session persisted and listable.
        let listed = service.listSessions()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, result.session.id)
        XCTAssertEqual(listed.first?.terminal, "terminal")
        XCTAssertNil(listed.first?.observedTokenDelta)

        // Reconcile records a (>=0) delta and stamps reconciledAt.
        let reconcile = try service.reconcile(sessionID: result.session.id)
        XCTAssertGreaterThanOrEqual(reconcile.tokenDelta, 0)
        let afterReconcile = service.listSessions().first
        XCTAssertNotNil(afterReconcile?.reconciledAt)
        XCTAssertEqual(afterReconcile?.observedTokenDelta, reconcile.tokenDelta)
    }

    func test_dispatch_emptyBriefing_throws() {
        let service = ClaudeInteractiveHandoffService(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("obb-empty-\(UUID().uuidString).json"),
            claudeExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            openExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        XCTAssertThrowsError(
            try service.dispatch(ClaudeInteractiveHandoffService.Request(briefing: "   "))
        ) { error in
            XCTAssertEqual(error as? ClaudeInteractiveHandoffService.HandoffError, .emptyBriefing)
        }
    }

    func test_reconcile_unknownSession_throws() {
        let service = ClaudeInteractiveHandoffService(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("obb-unknown-\(UUID().uuidString).json")
        )
        XCTAssertThrowsError(try service.reconcile(sessionID: "does-not-exist")) { error in
            XCTAssertEqual(
                error as? ClaudeInteractiveHandoffService.HandoffError,
                .sessionNotFound("does-not-exist")
            )
        }
    }

    // MARK: - Claude executable discovery

    func test_claudeDiscovery_includesNvmInstallWhenPathIsLaunchdMinimal() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-claude-discovery-\(UUID().uuidString)", isDirectory: true)
        let nvmBin = home
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v20.20.2", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
        try Data().write(to: nvmBin.appendingPathComponent("claude"))
        defer { try? FileManager.default.removeItem(at: home) }

        let launchdEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let candidates = ClaudeInteractiveHandoffService.claudeExecutableCandidatePaths(
            environment: launchdEnvironment,
            homeDirectory: home
        )

        let expectedClaude = nvmBin
            .appendingPathComponent("claude")
            .resolvingSymlinksInPath()
            .path
        XCTAssertTrue(candidates.contains(expectedClaude))
    }

    // MARK: - JSONL probe (token reconciliation)

    func test_jsonlProbe_sumsUsageAcrossRecentSessions() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-jsonl-probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("project-a", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sessionURL = projectDir.appendingPathComponent("session-1.jsonl")
        let lines = [
            #"{"message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10}}}"#,
            #"{"message":{"usage":{"input_tokens":5,"output_tokens":5}}}"#,
            #"{"type":"summary"}"#
        ]
        try lines.joined(separator: "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let probe = ClaudeCodeJSONLUsageProbe(projectsDirectory: root, recencyCutoff: 60 * 60)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.totalTokens, 100 + 50 + 10 + 5 + 5)
    }

    func test_jsonlProbe_changedSessions_detectsGrowth() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-jsonl-changed-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("project-b", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sessionURL = projectDir.appendingPathComponent("turn.jsonl")
        try #"{"message":{"usage":{"input_tokens":10,"output_tokens":10}}}"#
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let probe = ClaudeCodeJSONLUsageProbe(projectsDirectory: root, recencyCutoff: 60 * 60)
        let before = probe.snapshot()

        let appended = [
            #"{"message":{"usage":{"input_tokens":10,"output_tokens":10}}}"#,
            #"{"message":{"usage":{"input_tokens":40,"output_tokens":40}}}"#
        ].joined(separator: "\n")
        try appended.write(to: sessionURL, atomically: true, encoding: .utf8)
        let after = probe.snapshot()

        XCTAssertEqual(after.totalTokens - before.totalTokens, 80)
        XCTAssertEqual(ClaudeCodeJSONLUsageProbe.changedSessions(before: before, after: after), ["turn.jsonl"])
    }

    // MARK: - ANSI stripping (PTYInteractiveSession)

    func test_stripANSI_removesColorAndCursorSequences() {
        let input = "\u{1B}[1;32mPONG\u{1B}[0m\u{1B}[2K done"
        XCTAssertEqual(PTYInteractiveSession.stripANSI(input), "PONG done")
    }

    func test_stripANSI_removesOSCAndCarriageReturns() {
        let input = "\u{1B}]0;title\u{07}line1\rline2"
        XCTAssertEqual(PTYInteractiveSession.stripANSI(input), "line1line2")
    }

    func test_stripANSI_keepsPlainText() {
        XCTAssertEqual(PTYInteractiveSession.stripANSI("hello world"), "hello world")
    }
}
