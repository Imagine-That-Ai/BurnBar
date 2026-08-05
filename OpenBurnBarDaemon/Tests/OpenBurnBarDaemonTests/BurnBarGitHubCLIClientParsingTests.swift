import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// A process runner that serves fully specified canned results (exit code,
/// stdout, stderr) or typed thrown errors, keyed by a substring of the joined
/// command line, and records every invocation.
///
/// This complements the existing fakes instead of duplicating them:
/// `FakeInboxProcessRunner` can only answer "exit 0 with stdout" or "exit 1",
/// and `CountingProcessRunner` only counts. The gh client's degradation paths
/// need canned stderr (rate limits) and typed process errors, which is what
/// this fake adds.
struct ScriptedInboxProcessRunner: BurnBarAIInboxProcessRunning {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var commandLines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
    }

    let results: [(key: String, result: BurnBarAIInboxProcessResult)]
    let errors: [(key: String, error: BurnBarAIInboxProcessError)]
    /// Keys that throw a non-process error, exercising the generic catch paths.
    let genericErrorKeys: Set<String>
    let recorder = Recorder()

    init(
        results: [(key: String, result: BurnBarAIInboxProcessResult)] = [],
        errors: [(key: String, error: BurnBarAIInboxProcessError)] = [],
        genericErrorKeys: Set<String> = []
    ) {
        self.results = results
        self.errors = errors
        self.genericErrorKeys = genericErrorKeys
    }

    static func success(_ output: String) -> BurnBarAIInboxProcessResult {
        BurnBarAIInboxProcessResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(exitCode: Int32, standardError: String) -> BurnBarAIInboxProcessResult {
        BurnBarAIInboxProcessResult(exitCode: exitCode, standardOutput: "", standardError: standardError)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval,
        environmentOverrides: [String: String]
    ) async throws -> BurnBarAIInboxProcessResult {
        let joined = ([executable] + arguments).joined(separator: " ")
        recorder.record(joined)
        for key in genericErrorKeys where joined.contains(key) {
            throw CancellationError()
        }
        for entry in errors where joined.contains(entry.key) {
            throw entry.error
        }
        for entry in results where joined.contains(entry.key) {
            return entry.result
        }
        return BurnBarAIInboxProcessResult(exitCode: 1, standardOutput: "", standardError: "no fixture")
    }
}

/// Behavior of the gh-CLI client's fetch paths, driven entirely through an
/// injected runner: parsing canned JSON into repository models, degrading on
/// non-zero exits, malformed payloads and thrown process errors, and caching
/// the availability probe.
final class BurnBarGitHubCLIClientParsingTests: XCTestCase {
    private func makeClient(_ runner: any BurnBarAIInboxProcessRunning) -> BurnBarGitHubCLIClient {
        BurnBarGitHubCLIClient(runner: runner, logger: BurnBarDaemonLogger(category: "test"))
    }

    // MARK: - Model classification

    func test_workflowRunClassifiesSuccessAndWaste() {
        let now = Date()
        let succeeded = AIInboxFixtures.run(id: 1, workflow: "ci.yml", sha: "a", conclusion: "success", minutes: 5, now: now)
        let failed = AIInboxFixtures.run(id: 2, workflow: "ci.yml", sha: "b", conclusion: "failure", minutes: 5, now: now)

        XCTAssertTrue(succeeded.isSuccess)
        XCTAssertFalse(succeeded.isWasted)
        XCTAssertFalse(failed.isSuccess)
        XCTAssertTrue(failed.isWasted)

        let pending = BurnBarGitHubWorkflowRun(
            id: 3,
            name: "CI",
            workflowName: "ci.yml",
            headSHA: "c",
            headBranch: "main",
            status: "in_progress",
            conclusion: nil,
            event: "push",
            createdAt: now,
            updatedAt: nil,
            runStartedAt: now,
            url: "https://example.com/3"
        )
        XCTAssertFalse(pending.isSuccess, "A run without a conclusion is not a success")
        XCTAssertFalse(pending.isFinished)
    }

    // MARK: - Availability explanations

    func test_availabilityExplanationsGuideTheUser() {
        XCTAssertNil(BurnBarGitHubAvailability.available.explanation)
        XCTAssertEqual(
            BurnBarGitHubAvailability.binaryMissing.explanation?.contains("gh auth login"),
            true,
            "A missing binary must tell the user how to fix it"
        )
        XCTAssertEqual(
            BurnBarGitHubAvailability.notAuthenticated.explanation?.contains("gh auth login"),
            true
        )
        XCTAssertEqual(
            BurnBarGitHubAvailability.failed("rate limited").explanation,
            "GitHub checks are unavailable: rate limited"
        )
    }

    // MARK: - Section fetches through the fake runner

    func test_pullRequestsFetchesAndParsesCannedJSON() async throws {
        let runner = ScriptedInboxProcessRunner(results: [
            ("pr list", ScriptedInboxProcessRunner.success(Self.openPullRequestJSON))
        ])
        let client = makeClient(runner)

        let pullRequests = await client.pullRequests(slug: "octo/repo", state: "open")

        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests.first?.number, 12)
        XCTAssertEqual(pullRequests.first?.author, "alberto")
        XCTAssertEqual(pullRequests.first?.headRefName, "fix/retry")
        XCTAssertEqual(pullRequests.first?.isOpen, true)
        XCTAssertEqual(pullRequests.first?.isMerged, false)

        let command = try XCTUnwrap(runner.recorder.commandLines.first)
        XCTAssertTrue(command.contains("--repo octo/repo"))
        XCTAssertTrue(command.contains("--state open"))
        XCTAssertTrue(command.contains("--limit 30"), "The PR page must stay bounded")
    }

    func test_openIssuesFetchesAndParsesLabels() async throws {
        let runner = ScriptedInboxProcessRunner(results: [
            ("issue list", ScriptedInboxProcessRunner.success(Self.issueJSON))
        ])
        let client = makeClient(runner)

        let issues = await client.openIssues(slug: "octo/repo")

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.number, 7)
        XCTAssertEqual(issues.first?.title, "Retry loop drops jobs")
        XCTAssertEqual(issues.first?.labels, ["bug", "ci"], "Nested label objects flatten to names")
        XCTAssertNotNil(issues.first?.createdAt)

        let command = try XCTUnwrap(runner.recorder.commandLines.first)
        XCTAssertTrue(command.contains("--limit 20"))
    }

    func test_workflowRunsUseTheCachedRestEndpointWithADayFilter() async throws {
        let runner = ScriptedInboxProcessRunner(results: [
            ("actions/runs", ScriptedInboxProcessRunner.success(Self.workflowRunsJSON))
        ])
        let client = makeClient(runner)

        let runs = await client.workflowRuns(slug: "octo/repo", since: Date(timeIntervalSince1970: 1_780_000_000))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, 1)
        XCTAssertEqual(runs.first?.workflowName, "CI")
        XCTAssertEqual(runs.first?.conclusion, "failure")

        let command = try XCTUnwrap(runner.recorder.commandLines.first)
        XCTAssertTrue(command.contains("--cache 300s"), "Runs must be served through gh's HTTP cache")
        XCTAssertTrue(command.contains("repos/octo/repo/actions/runs?per_page=100"))
        XCTAssertTrue(command.contains("created=>="), "The lookback must bound the REST query")
    }

    // MARK: - Degradation

    func test_failedCallDegradesToEmptyList() async {
        // The default scripted response is exit 1 with no fixture.
        let client = makeClient(ScriptedInboxProcessRunner())
        let pullRequests = await client.pullRequests(slug: "octo/repo", state: "open")
        XCTAssertTrue(pullRequests.isEmpty, "A failed gh call must degrade, never throw")
    }

    func test_rateLimitedCallDegradesToEmptyList() async {
        let runner = ScriptedInboxProcessRunner(results: [
            ("pr list", ScriptedInboxProcessRunner.failure(exitCode: 1, standardError: "API rate limit exceeded"))
        ])
        let client = makeClient(runner)
        let pullRequests = await client.pullRequests(slug: "octo/repo", state: "open")
        XCTAssertTrue(pullRequests.isEmpty, "Rate limiting is a normal operating state, not a crash")
    }

    func test_thrownProcessErrorsDegradeToEmptyLists() async {
        let runner = ScriptedInboxProcessRunner(errors: [
            ("pr list", .executableNotFound("gh")),
            ("issue list", .timedOut("gh")),
            ("actions/runs", .launchFailed("gh", "spawn failed"))
        ])
        let client = makeClient(runner)

        let pullRequests = await client.pullRequests(slug: "octo/repo", state: "open")
        let issues = await client.openIssues(slug: "octo/repo")
        let runs = await client.workflowRuns(slug: "octo/repo", since: Date().addingTimeInterval(-3_600))

        XCTAssertTrue(pullRequests.isEmpty)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertTrue(runs.isEmpty)

        let generic = makeClient(ScriptedInboxProcessRunner(genericErrorKeys: ["pr list"]))
        let fromGenericError = await generic.pullRequests(slug: "octo/repo", state: "open")
        XCTAssertTrue(fromGenericError.isEmpty, "A non-process error must degrade the same way")
    }

    func test_invalidDatesFailTheDecodeClosed() {
        let json = """
            [{"number": 12, "title": "Fix", "state": "OPEN", "isDraft": false,
              "headRefName": "fix", "author": {"login": "alberto"},
              "url": "https://github.com/octo/repo/pull/12", "createdAt": "yesterday",
              "updatedAt": null, "mergedAt": null, "closedAt": null,
              "additions": 1, "deletions": 1, "reviewDecision": null}]
            """
        XCTAssertTrue(
            BurnBarGitHubCLIClient.decodePullRequests(json).isEmpty,
            "An unparseable timestamp must drop the payload rather than crash the tick"
        )
    }

    // MARK: - Snapshot assembly

    func test_snapshotRefusesInvalidSlug() async {
        let runner = ScriptedInboxProcessRunner()
        let client = makeClient(runner)
        let snapshot = await client.snapshot(slug: "octo/repo/../evil", runLookback: 3_600)
        XCTAssertNil(snapshot)
        XCTAssertTrue(runner.recorder.commandLines.isEmpty, "A refused slug must never reach a subprocess")
    }

    func test_snapshotReturnsNilWhenGhIsUnavailable() async {
        let client = makeClient(ScriptedInboxProcessRunner(errors: [("auth status", .timedOut("gh"))]))
        let snapshot = await client.snapshot(slug: "octo/repo", runLookback: 3_600)
        XCTAssertNil(snapshot, "An unavailable gh must degrade to no snapshot")
    }

    func test_availabilityFailureIsExplainedWhetherGhIsInstalledOrNot() async {
        let client = makeClient(ScriptedInboxProcessRunner(errors: [("auth status", .launchFailed("gh", "denied"))]))
        let availability = await client.availability()

        if BurnBarAIInboxProcessRunner.locate("gh") == nil {
            XCTAssertEqual(availability, .binaryMissing)
        } else {
            XCTAssertEqual(availability, .failed("launch_failed"), "The reason must be redacted to the error kind")
        }
        XCTAssertNotNil(availability.explanation)
        XCTAssertFalse(availability.isAvailable)
    }

    func test_snapshotAssemblesAllSectionsAndCachesAvailability() async throws {
        guard BurnBarAIInboxProcessRunner.locate("gh") != nil else {
            throw XCTSkip("The availability probe requires a gh binary on this machine")
        }
        let runner = ScriptedInboxProcessRunner(results: [
            ("auth status", ScriptedInboxProcessRunner.success("")),
            ("--state open", ScriptedInboxProcessRunner.success(Self.openPullRequestJSON)),
            ("--state merged", ScriptedInboxProcessRunner.success(Self.mergedPullRequestJSON)),
            ("issue list", ScriptedInboxProcessRunner.success(Self.issueJSON)),
            ("actions/runs", ScriptedInboxProcessRunner.success(Self.workflowRunsJSON))
        ])
        let client = makeClient(runner)

        let maybeSnapshot = await client.snapshot(slug: "octo/repo", runLookback: 3 * 24 * 3_600)
        let snapshot = try XCTUnwrap(maybeSnapshot)

        XCTAssertEqual(snapshot.slug, "octo/repo")
        XCTAssertEqual(snapshot.openPullRequests.map(\.number), [12])
        XCTAssertEqual(snapshot.recentlyMergedPullRequests.map(\.number), [13])
        XCTAssertEqual(snapshot.recentlyMergedPullRequests.first?.isMerged, true)
        XCTAssertEqual(snapshot.openIssues.map(\.number), [7])
        XCTAssertEqual(snapshot.recentRuns.map(\.id), [1])

        // The probe is cached: the second availability call (inside snapshot)
        // and this explicit one must not spawn another subprocess.
        let availability = await client.availability()
        XCTAssertEqual(availability, .available)
        let probes = runner.recorder.commandLines.filter { $0.contains("auth status") }
        XCTAssertEqual(probes.count, 1, "A healthy availability result must be cached, not re-probed")
    }

    // MARK: - Canned payloads

    private static let openPullRequestJSON = """
        [{"number": 12, "title": "Fix the retry loop", "state": "OPEN", "isDraft": false,
          "headRefName": "fix/retry", "author": {"login": "alberto"},
          "url": "https://github.com/octo/repo/pull/12", "createdAt": "2026-08-01T10:00:00Z",
          "updatedAt": "2026-08-02T10:00:00Z", "mergedAt": null, "closedAt": null,
          "additions": 40, "deletions": 3, "reviewDecision": "APPROVED"}]
        """

    private static let mergedPullRequestJSON = """
        [{"number": 13, "title": "Land the parser", "state": "MERGED", "isDraft": false,
          "headRefName": "feat/parser", "author": {"login": "alberto"},
          "url": "https://github.com/octo/repo/pull/13", "createdAt": "2026-08-01T08:00:00Z",
          "updatedAt": "2026-08-03T09:00:00Z", "mergedAt": "2026-08-03T09:00:00Z", "closedAt": "2026-08-03T09:00:00Z",
          "additions": 120, "deletions": 8, "reviewDecision": "APPROVED"}]
        """

    private static let issueJSON = """
        [{"number": 7, "title": "Retry loop drops jobs", "state": "OPEN",
          "url": "https://github.com/octo/repo/issues/7",
          "createdAt": "2026-08-01T10:00:00Z", "updatedAt": "2026-08-02T10:00:00Z",
          "labels": [{"name": "bug"}, {"name": "ci"}]}]
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
