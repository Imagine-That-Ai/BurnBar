import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Behavior of the evidence pack builder against a real temp store: which
/// conversations, workspaces, repositories, and usage aggregates end up in a
/// pack, how bodies are truncated, how the remote phase is gated, and how the
/// pack reports its own staleness and citation surface.
final class AIInboxEvidencePackBuilderTests: XCTestCase {
    private var databaseURL: URL!
    private var workspaceURL: URL!
    private var store: BurnBarAIInboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let unique = UUID().uuidString
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-pack-\(unique).sqlite")
        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-pack-workspace-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        store = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    override func tearDownWithError() throws {
        store = nil
        if let databaseURL { try? FileManager.default.removeItem(at: databaseURL) }
        if let workspaceURL { try? FileManager.default.removeItem(at: workspaceURL) }
        try super.tearDownWithError()
    }

    // MARK: - Building blocks

    /// Canned git output that makes the seeded workspace look like a healthy
    /// clone of github.com/octo/repo on `main`.
    private func gitRunner() -> FakeInboxProcessRunner {
        FakeInboxProcessRunner(responses: [
            "--is-inside-work-tree": "true\n",
            "--abbrev-ref": "main\n",
            "--pretty=format:%H": "aabbccddee\u{1f}feat: land the retry fix\u{1f}2026-08-04T10:00:00Z\n",
            "status --porcelain": " M api/client.ts\n?? notes.md\n",
            "remote.origin.url": "git@github.com:octo/repo.git\n",
            "--pretty=format:%s": "feat: land the retry fix\n",
            "rev-list": "1\t0"
        ])
    }

    private func makeBuilder(githubRunner: any BurnBarAIInboxProcessRunning) -> BurnBarAIInboxEvidencePackBuilder {
        let logger = BurnBarDaemonLogger(category: "test")
        return BurnBarAIInboxEvidencePackBuilder(
            store: store,
            workspaceScout: BurnBarAIInboxWorkspaceScout(runner: gitRunner(), logger: logger),
            github: BurnBarGitHubCLIClient(runner: githubRunner, logger: logger),
            logger: logger
        )
    }

    /// Inserts a conversation exactly as GRDB writes it (space-separated
    /// timestamps), pointing at the temp workspace so the scout runs.
    private func seedConversation(id: String, endedAt: Date, fullText: String) throws {
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY, provider TEXT, sessionId TEXT, projectName TEXT,
                startTime DATETIME, endTime DATETIME, messageCount INTEGER,
                inferredTaskTitle TEXT, lastAssistantMessage TEXT, summary TEXT,
                workingDirectory TEXT, indexedAt DATETIME, keyFiles TEXT,
                keyCommands TEXT, fullText TEXT
            )
            """,
            []
        )
        let stored = BurnBarAIInboxStore.grdbString(from: endedAt)
        try store.execute(
            """
            INSERT INTO conversations (
                id, provider, sessionId, projectName, startTime, endTime, messageCount,
                inferredTaskTitle, lastAssistantMessage, summary, workingDirectory,
                indexedAt, keyFiles, keyCommands, fullText
            ) VALUES (?, 'Claude Code', 'sess-1', 'BurnBar', ?, ?, 12, 'Retry loop fix', '', '',
                      ?, ?, '["api/client.ts"]', '["npm test"]', ?)
            """,
            [
                .text(id),
                .text(stored),
                .text(stored),
                .text(workspaceURL.path),
                .text(stored),
                .text(fullText)
            ]
        )
    }

    private func seedUsage(at date: Date) throws {
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS token_usage (
                id TEXT PRIMARY KEY, provider TEXT, projectName TEXT, model TEXT,
                totalTokens INTEGER, cost REAL, startTime DATETIME
            )
            """,
            []
        )
        try store.execute(
            """
            INSERT INTO token_usage (id, provider, projectName, model, totalTokens, cost, startTime)
            VALUES ('u1', 'anthropic', 'BurnBar', 'claude-fable-5', 12000, 2.35, ?)
            """,
            [.text(BurnBarAIInboxStore.grdbString(from: date))]
        )
    }

    private func conversationRow(id: String, endTime: Date) -> BurnBarAIInboxConversationRow {
        BurnBarAIInboxConversationRow(
            id: id,
            provider: "Claude Code",
            sessionID: nil,
            projectName: "BurnBar",
            startTime: endTime.addingTimeInterval(-60),
            endTime: endTime,
            messageCount: 3,
            inferredTaskTitle: "Task",
            lastAssistantMessage: nil,
            summary: nil,
            workingDirectory: nil,
            indexedAt: endTime,
            keyFiles: [],
            keyCommands: [],
            fullTextByteCount: 0
        )
    }

    // MARK: - Local phase

    func test_buildAssemblesLocalEvidenceWithoutRemoteCalls() async throws {
        let now = Date()
        try seedConversation(id: "conv-local", endedAt: now.addingTimeInterval(-600), fullText: "Implemented the retry loop and pushed.")
        try seedUsage(at: now.addingTimeInterval(-600))
        let githubRunner = ScriptedInboxProcessRunner()
        let builder = makeBuilder(githubRunner: githubRunner)

        let pack = await builder.build(
            tickID: "tick_test",
            config: BurnBarInboxConfig(enabled: true, egressMode: .off),
            includeRemote: false,
            now: now
        )

        XCTAssertEqual(pack.tickID, "tick_test")
        XCTAssertEqual(pack.windowStart.timeIntervalSince(now), -7_200, accuracy: 1, "Default lookback is 120 minutes")
        XCTAssertFalse(pack.isEmpty)

        let excerpt = try XCTUnwrap(pack.conversations.first)
        XCTAssertEqual(pack.conversations.count, 1)
        XCTAssertEqual(excerpt.evidenceID, "conv:conv-local:12")
        XCTAssertEqual(excerpt.provider, "Claude Code")
        XCTAssertEqual(excerpt.title, "Retry loop fix")
        XCTAssertEqual(excerpt.body, "Implemented the retry loop and pushed.")
        XCTAssertEqual(excerpt.workspacePath, workspaceURL.path)
        XCTAssertEqual(excerpt.keyFiles, ["api/client.ts"])
        XCTAssertEqual(excerpt.keyCommands, ["npm test"])
        XCTAssertFalse(excerpt.wasTruncated)

        let workspace = try XCTUnwrap(pack.workspaces.first)
        XCTAssertEqual(pack.workspaces.count, 1)
        XCTAssertEqual(workspace.branch, "main")
        XCTAssertEqual(workspace.githubSlug, "octo/repo")
        XCTAssertEqual(workspace.dirtyFiles, ["api/client.ts"])

        XCTAssertEqual(pack.usage.count, 1)
        XCTAssertEqual(pack.usage.first?.costUSD ?? 0, 2.35, accuracy: 0.001)
        XCTAssertEqual(pack.usage.first?.model, "claude-fable-5")

        XCTAssertTrue(pack.repositories.isEmpty)
        XCTAssertEqual(pack.githubAvailability, .available)
        XCTAssertEqual(pack.droppedConversationCount, 0)
        XCTAssertGreaterThan(pack.estimatedPromptTokens, 0)
        XCTAssertTrue(
            githubRunner.recorder.commandLines.isEmpty,
            "A local phase must never spawn gh"
        )
    }

    func test_buildDisclosesDisabledGitHubChecks() async throws {
        let now = Date()
        try seedConversation(id: "conv-nogh", endedAt: now.addingTimeInterval(-300), fullText: "Worked offline.")
        let builder = makeBuilder(githubRunner: ScriptedInboxProcessRunner())

        let pack = await builder.build(
            tickID: "tick_test",
            config: BurnBarInboxConfig(enabled: true, egressMode: .off, githubEnabled: false),
            includeRemote: true,
            now: now
        )

        XCTAssertEqual(
            pack.githubAvailability,
            .failed("GitHub checks are turned off in settings."),
            "A disabled integration must be disclosed, not silently empty"
        )
        XCTAssertTrue(pack.repositories.isEmpty)
    }

    func test_buildTruncatesOversizedConversationBodies() async throws {
        let now = Date()
        let sentence = "The retry loop was refactored and the full suite was rerun afterwards. "
        try seedConversation(
            id: "conv-long",
            endedAt: now.addingTimeInterval(-300),
            fullText: String(repeating: sentence, count: 500)
        )
        let builder = makeBuilder(githubRunner: ScriptedInboxProcessRunner())

        let pack = await builder.build(
            tickID: "tick_test",
            config: BurnBarInboxConfig(enabled: true, egressMode: .off),
            includeRemote: false,
            now: now
        )

        let excerpt = try XCTUnwrap(pack.conversations.first)
        XCTAssertTrue(excerpt.wasTruncated, "A transcript beyond the byte cap must be marked truncated")
        XCTAssertTrue(excerpt.body.contains("bytes omitted"), "Truncation must be visible inside the body")
        XCTAssertLessThan(
            excerpt.body.utf8.count,
            BurnBarAIInboxEvidencePackBuilder.maxConversationBodyBytes + 64,
            "The clipped body must respect the per-conversation cap"
        )
    }

    // MARK: - Remote phase

    func test_buildFetchesRepositorySnapshotsOnTheRemotePhase() async throws {
        guard BurnBarAIInboxProcessRunner.locate("gh") != nil else {
            throw XCTSkip("The availability probe requires a gh binary on this machine")
        }
        let now = Date()
        try seedConversation(id: "conv-remote", endedAt: now.addingTimeInterval(-300), fullText: "Pushed the fix.")
        let githubRunner = ScriptedInboxProcessRunner(results: [
            ("auth status", ScriptedInboxProcessRunner.success("")),
            ("--state open", ScriptedInboxProcessRunner.success(Self.openPullRequestJSON)),
            ("--state merged", ScriptedInboxProcessRunner.success("[]")),
            ("issue list", ScriptedInboxProcessRunner.success("[]")),
            ("actions/runs", ScriptedInboxProcessRunner.success(Self.workflowRunsJSON))
        ])
        let builder = makeBuilder(githubRunner: githubRunner)

        let pack = await builder.build(
            tickID: "tick_test",
            config: BurnBarInboxConfig(enabled: true, egressMode: .off),
            includeRemote: true,
            now: now
        )

        XCTAssertEqual(pack.githubAvailability, .available)
        let repository = try XCTUnwrap(pack.repositories.first)
        XCTAssertEqual(pack.repositories.count, 1)
        XCTAssertEqual(repository.slug, "octo/repo", "The repo comes from the workspace's origin remote")
        XCTAssertEqual(repository.openPullRequests.map(\.number), [12])
        XCTAssertTrue(repository.recentlyMergedPullRequests.isEmpty)
        XCTAssertEqual(repository.recentRuns.map(\.id), [1])

        let ids = pack.validEvidenceIDs
        XCTAssertTrue(ids.contains("conv:conv-remote:12"))
        XCTAssertTrue(ids.contains("pr:octo/repo#12"))
        XCTAssertTrue(ids.contains("run:octo/repo#1"))
    }

    // MARK: - Citation surface and emptiness

    func test_validEvidenceIDsEnumerateEverySection() {
        let now = Date()
        let repository = BurnBarGitHubRepositorySnapshot(
            slug: "octo/repo",
            openPullRequests: [AIInboxFixtures.pullRequest(number: 12, state: "OPEN", updatedAt: now)],
            recentlyMergedPullRequests: [
                AIInboxFixtures.pullRequest(number: 13, state: "MERGED", updatedAt: now, mergedAt: now)
            ],
            openIssues: [
                BurnBarGitHubIssue(
                    number: 7,
                    title: "Retry loop drops jobs",
                    state: "OPEN",
                    url: "https://github.com/octo/repo/issues/7",
                    createdAt: now,
                    updatedAt: now,
                    labels: ["bug"]
                )
            ],
            recentRuns: [
                AIInboxFixtures.run(id: 1, workflow: "ci.yml", sha: "abc", conclusion: "failure", minutes: 5, now: now)
            ],
            fetchedAt: now
        )
        let usage = BurnBarAIInboxUsageAggregate(
            projectName: "BurnBar",
            model: "claude-fable-5",
            provider: "anthropic",
            callCount: 3,
            totalTokens: 900,
            costUSD: 0.4
        )
        let workspace = AIInboxFixtures.workspace(dirty: 2)
        let pack = AIInboxFixtures.pack(
            repositories: [repository],
            conversations: [AIInboxFixtures.conversation()],
            workspaces: [workspace],
            usage: [usage],
            now: now
        )

        let ids = pack.validEvidenceIDs
        XCTAssertTrue(ids.contains("conv:conv-1:12"))
        XCTAssertTrue(ids.contains("pr:octo/repo#12"))
        XCTAssertTrue(ids.contains("pr:octo/repo#13"), "Merged PRs are citable too")
        XCTAssertTrue(ids.contains("issue:octo/repo#7"))
        XCTAssertTrue(ids.contains("run:octo/repo#1"))
        XCTAssertTrue(ids.contains("workspace:\(workspace.path)"))
        XCTAssertTrue(ids.contains("usage:BurnBar:claude-fable-5"))

        XCTAssertFalse(pack.isEmpty)
        XCTAssertTrue(AIInboxFixtures.emptyPack(now: now).isEmpty)
    }

    // MARK: - Budgeting

    func test_budgetEstimateChargesRepositoryStructure() {
        let now = Date()
        let repository = AIInboxFixtures.repository(
            slug: "octo/repo",
            runs: AIInboxFixtures.runs(workflow: "ci.yml", total: 20, wasted: 5, minutesEach: 4, now: now),
            openPullRequests: [AIInboxFixtures.pullRequest(number: 12, state: "OPEN", updatedAt: now)],
            mergedPullRequests: [AIInboxFixtures.pullRequest(number: 13, state: "MERGED", updatedAt: now, mergedAt: now)]
        )
        let conversations = [AIInboxFixtures.conversation()]
        let lean = BurnBarAIInboxEvidencePackBuilder.budgeted(
            AIInboxFixtures.pack(conversations: conversations, now: now),
            tokenCap: 100_000
        )
        let heavy = BurnBarAIInboxEvidencePackBuilder.budgeted(
            AIInboxFixtures.pack(repositories: [repository], conversations: conversations, now: now),
            tokenCap: 100_000
        )

        XCTAssertGreaterThan(
            heavy.estimatedPromptTokens,
            lean.estimatedPromptTokens,
            "PRs, issues, and runs must count against the prompt budget"
        )
        XCTAssertEqual(heavy.conversations.count, 1, "A generous cap drops nothing")
        XCTAssertEqual(heavy.droppedConversationCount, 0)
    }

    // MARK: - Index freshness measurement

    func test_indexLagMeasuresTheGapBetweenLogsAndTheIndex() throws {
        // Plant a real agent-log write under the first watched root so the
        // sweep has something to find on any machine.
        let root = try XCTUnwrap(BurnBarAIInboxChangeGate.watchedLogRoots.first)
        let probeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent("burnbar-coverage-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        } catch {
            throw XCTSkip("The home directory is not writable in this environment")
        }
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        try "probe".write(
            to: probeDirectory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let newest = try XCTUnwrap(
            BurnBarAIInboxEvidencePackBuilder.newestAgentLogWrite(),
            "The sweep must see the freshly written log"
        )
        let now = newest.addingTimeInterval(120)

        // No indexed rows: the lag is at least the age of the newest write.
        let withoutRows = try XCTUnwrap(BurnBarAIInboxEvidencePackBuilder.indexLag(rows: [], now: now))
        XCTAssertEqual(withoutRows, 120, accuracy: 10)

        // An index ahead of the files clamps to zero rather than going negative.
        let fresh = conversationRow(id: "fresh", endTime: newest.addingTimeInterval(600))
        let freshLag = try XCTUnwrap(BurnBarAIInboxEvidencePackBuilder.indexLag(rows: [fresh], now: now))
        XCTAssertEqual(freshLag, 0, accuracy: 10)

        // An index behind the files reports the actual gap.
        let stale = conversationRow(id: "stale", endTime: newest.addingTimeInterval(-600))
        let staleLag = try XCTUnwrap(BurnBarAIInboxEvidencePackBuilder.indexLag(rows: [stale], now: now))
        XCTAssertEqual(staleLag, 600, accuracy: 10)
    }

    // MARK: - Canned payloads

    private static let openPullRequestJSON = """
        [{"number": 12, "title": "Fix the retry loop", "state": "OPEN", "isDraft": false,
          "headRefName": "fix/retry", "author": {"login": "alberto"},
          "url": "https://github.com/octo/repo/pull/12", "createdAt": "2026-08-01T10:00:00Z",
          "updatedAt": "2026-08-02T10:00:00Z", "mergedAt": null, "closedAt": null,
          "additions": 40, "deletions": 3, "reviewDecision": "APPROVED"}]
        """

    private static let workflowRunsJSON = """
        {"total_count": 1, "workflow_runs": [
          {"id": 1, "name": "CI", "display_title": "fix: retry", "head_sha": "abc",
           "head_branch": "main", "status": "completed", "conclusion": "failure", "event": "push",
           "created_at": "2026-08-04T10:00:00Z", "updated_at": "2026-08-04T10:08:00Z",
           "run_started_at": "2026-08-04T10:00:00Z", "html_url": "https://example.com/runs/1",
           "path": ".github/workflows/ci.yml"}
        ]}
        """
}
