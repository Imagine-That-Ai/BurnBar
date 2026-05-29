import XCTest
@testable import OpenBurnBarDaemon

final class ClaudeInteractiveHandoffServiceTests: XCTestCase {

    // MARK: - Project path encoding

    func test_claudeProjectDirectory_encodesSlashesAsDashes() {
        let url = ClaudeInteractiveHandoffService.claudeProjectDirectory(for: "/Users/me/code/app")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "-Users-me-code-app")
        XCTAssertTrue(url?.path.hasSuffix(".claude/projects/-Users-me-code-app") == true)
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
}
