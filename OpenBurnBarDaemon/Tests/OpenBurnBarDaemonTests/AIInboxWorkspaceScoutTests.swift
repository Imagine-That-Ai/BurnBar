import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Behavior of the workspace scout's git evidence collection, driven through
/// canned git output: snapshot assembly (branch, HEAD, dirty files, divergence,
/// GitHub slug), degradation when individual git queries fail, workspace
/// de-duplication, and the gate signature.
final class AIInboxWorkspaceScoutTests: XCTestCase {
    private var workspaceURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-scout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceURL { try? FileManager.default.removeItem(at: workspaceURL) }
        try super.tearDownWithError()
    }

    private func makeScout(_ runner: any BurnBarAIInboxProcessRunning) -> BurnBarAIInboxWorkspaceScout {
        BurnBarAIInboxWorkspaceScout(runner: runner, logger: BurnBarDaemonLogger(category: "test"))
    }

    /// Canned output for every git query the scout issues. Keys are chosen so
    /// exactly one matches each command; `%H` vs `%s` disambiguates the two
    /// `git log` calls.
    private static func fullGitRunner() -> FakeInboxProcessRunner {
        FakeInboxProcessRunner(responses: [
            "--is-inside-work-tree": "true\n",
            "--abbrev-ref": "feature/inbox\n",
            "--pretty=format:%H": "aabbccddee\u{1f}feat: land the retry fix\u{1f}2026-08-04T10:00:00Z\n",
            "status --porcelain": " M Sources/A.swift\n?? Notes.md\nMM Sources/B.swift\n",
            "remote.origin.url": "git@github.com:octo/repo.git\n",
            "--pretty=format:%s": "feat: land the retry fix\ntest: cover the scout\n",
            "rev-list": "2\t1"
        ])
    }

    // MARK: - Full snapshot

    func test_snapshotReadsFullGitStateFromCannedOutputs() async throws {
        let scout = makeScout(Self.fullGitRunner())

        let maybeSnapshot = await scout.snapshot(for: workspaceURL.path)
        let snapshot = try XCTUnwrap(maybeSnapshot)

        XCTAssertTrue(snapshot.isGitRepository)
        XCTAssertEqual(snapshot.branch, "feature/inbox")
        XCTAssertEqual(snapshot.headSHA, "aabbccddee")
        XCTAssertEqual(snapshot.headSubject, "feat: land the retry fix")
        XCTAssertEqual(snapshot.headCommittedAt, BurnBarAIInboxTimestamp.date(from: "2026-08-04T10:00:00Z"))
        XCTAssertEqual(snapshot.dirtyFiles, ["Sources/A.swift", "Sources/B.swift"])
        XCTAssertEqual(snapshot.untrackedCount, 1, "?? lines count as untracked, not dirty")
        XCTAssertEqual(snapshot.aheadCount, 2)
        XCTAssertEqual(snapshot.behindCount, 1)
        XCTAssertEqual(snapshot.githubSlug, "octo/repo")
        XCTAssertEqual(snapshot.recentCommitSubjects, ["feat: land the retry fix", "test: cover the scout"])
        XCTAssertTrue(snapshot.isDirty)
    }

    /// Every optional git query failing must still produce a usable snapshot:
    /// a missing upstream or a detached HEAD is a normal state, not an error.
    func test_snapshotDegradesWhenEveryOptionalGitQueryFails() async throws {
        let runner = FakeInboxProcessRunner(responses: ["--is-inside-work-tree": "true\n"])
        let scout = makeScout(runner)

        let maybeSnapshot = await scout.snapshot(for: workspaceURL.path)
        let snapshot = try XCTUnwrap(maybeSnapshot)

        XCTAssertTrue(snapshot.isGitRepository)
        XCTAssertNil(snapshot.branch)
        XCTAssertNil(snapshot.headSHA)
        XCTAssertNil(snapshot.headSubject)
        XCTAssertNil(snapshot.headCommittedAt)
        XCTAssertTrue(snapshot.dirtyFiles.isEmpty)
        XCTAssertEqual(snapshot.untrackedCount, 0)
        XCTAssertEqual(snapshot.aheadCount, 0)
        XCTAssertEqual(snapshot.behindCount, 0)
        XCTAssertNil(snapshot.githubSlug)
        XCTAssertTrue(snapshot.recentCommitSubjects.isEmpty)
        XCTAssertFalse(snapshot.isDirty)
    }

    func test_snapshotReturnsNilForNonRepositoriesAndMissingPaths() async {
        let missing = workspaceURL.appendingPathComponent("does-not-exist").path
        let notARepo = makeScout(FakeInboxProcessRunner(responses: ["--is-inside-work-tree": "false\n"]))
        let gitBroken = makeScout(FakeInboxProcessRunner(failing: ["rev-parse"]))

        let fromMissingPath = await notARepo.snapshot(for: missing)
        XCTAssertNil(fromMissingPath, "A path that does not exist must not spawn git")

        let fromNonRepo = await notARepo.snapshot(for: workspaceURL.path)
        XCTAssertNil(fromNonRepo, "A directory outside a work tree is skipped")

        let fromFailingGit = await gitBroken.snapshot(for: workspaceURL.path)
        XCTAssertNil(fromFailingGit, "A broken git must degrade to no snapshot, not fail the tick")
    }

    // MARK: - snapshots(for:)

    func test_snapshotsDeduplicatesAndSkipsUnusablePaths() async {
        let scout = makeScout(Self.fullGitRunner())
        let paths = [
            workspaceURL.path,
            workspaceURL.path + "/",
            "  ",
            "/",
            workspaceURL.appendingPathComponent("missing").path
        ]

        let snapshots = await scout.snapshots(for: paths)

        XCTAssertEqual(snapshots.count, 1, "Duplicates and unusable paths collapse to one snapshot")
        XCTAssertEqual(snapshots.first?.githubSlug, "octo/repo")
    }

    // MARK: - Gate signature

    func test_gateSignatureTracksSnapshotIdentity() {
        let base = AIInboxFixtures.workspace(dirty: 2)
        let same = AIInboxFixtures.workspace(dirty: 2)
        XCTAssertEqual(base.gateSignature, same.gateSignature, "Identical state must hash identically")

        let moved = BurnBarAIInboxWorkspaceSnapshot(
            path: base.path,
            isGitRepository: true,
            branch: base.branch,
            headSHA: "fedcba",
            headSubject: base.headSubject,
            headCommittedAt: base.headCommittedAt,
            dirtyFiles: base.dirtyFiles,
            untrackedCount: base.untrackedCount,
            aheadCount: base.aheadCount,
            behindCount: base.behindCount,
            githubSlug: base.githubSlug,
            recentCommitSubjects: base.recentCommitSubjects
        )
        XCTAssertNotEqual(base.gateSignature, moved.gateSignature, "A new HEAD must open the gate")
    }

    // MARK: - GitHub slug edge cases

    func test_githubSlugRejectsCaseMismatchedHostAndHostileSegments() {
        XCTAssertEqual(
            BurnBarAIInboxWorkspaceScout.githubSlug(fromRemoteURL: "https://github.com/octo/repo"),
            "octo/repo"
        )
        XCTAssertNil(
            BurnBarAIInboxWorkspaceScout.githubSlug(fromRemoteURL: "https://GitHub.com/octo/repo"),
            "A host that only matches case-insensitively is refused rather than misparsed"
        )
        XCTAssertNil(
            BurnBarAIInboxWorkspaceScout.githubSlug(fromRemoteURL: "git@github.com:oc$to/repo.git"),
            "A segment outside the safe character set must never reach a gh api path"
        )
    }
}
