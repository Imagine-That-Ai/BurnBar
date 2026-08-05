import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Builders for detector shapes the shared fixtures do not parameterize
/// (custom PR titles, custom commit subjects). Kept top-level and private so
/// SwiftLint's `test_case_accessibility` stays satisfied and the shared
/// `AIInboxFixtures` enum keeps owning the common cases.
private enum DetectorBreadthSupport {
    static func workspace(
        path: String = "/tmp/burnbar",
        dirtyFileCount: Int = 0,
        untrackedCount: Int = 0,
        githubSlug: String? = "Ajnunezg/BurnBar",
        recentCommitSubjects: [String] = ["feat: something"]
    ) -> BurnBarAIInboxWorkspaceSnapshot {
        BurnBarAIInboxWorkspaceSnapshot(
            path: path,
            isGitRepository: true,
            branch: "main",
            headSHA: "abc123",
            headSubject: recentCommitSubjects.first,
            headCommittedAt: Date(),
            dirtyFiles: (0..<dirtyFileCount).map { "file\($0).swift" },
            untrackedCount: untrackedCount,
            aheadCount: 0,
            behindCount: 0,
            githubSlug: githubSlug,
            recentCommitSubjects: recentCommitSubjects
        )
    }

    static func pullRequest(
        number: Int,
        title: String,
        state: String,
        updatedAt: Date?,
        mergedAt: Date? = nil,
        isDraft: Bool = false,
        reviewDecision: String? = nil
    ) -> BurnBarGitHubPullRequest {
        BurnBarGitHubPullRequest(
            number: number,
            title: title,
            state: state,
            isDraft: isDraft,
            headRefName: "feature/x",
            author: "alberto",
            url: "https://github.com/Ajnunezg/BurnBar/pull/\(number)",
            createdAt: updatedAt?.addingTimeInterval(-86_400),
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            closedAt: nil,
            additions: 10,
            deletions: 2,
            reviewDecision: reviewDecision
        )
    }

    static func usage(project: String, model: String, calls: Int, cost: Double) -> BurnBarAIInboxUsageAggregate {
        BurnBarAIInboxUsageAggregate(
            projectName: project,
            model: model,
            provider: "anthropic",
            callCount: calls,
            totalTokens: 10_000,
            costUSD: cost
        )
    }
}

/// Breadth coverage for the deterministic detectors: the moderate CI-waste
/// band, promised-but-not-landed in both directions, the uncommitted-work
/// nudge, cost anomalies against a robust baseline, index health, and the
/// small text/number helpers every summary sentence leans on.
final class AIInboxDetectorsBreadthTests: XCTestCase {
    // MARK: - CI waste: the moderate band

    /// A workflow wasting half its runs, but only a few minutes of compute,
    /// is worth knowing about without interrupting anyone.
    func test_moderateWasteRateWithLowMinutesIsP3() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(workflow: "ci.yml", total: 10, wasted: 5, minutesEach: 2, now: now)
            )],
            now: now
        )

        let finding = try XCTUnwrap(BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack).first)
        XCTAssertEqual(finding.kind, .ciWaste)
        XCTAssertEqual(finding.priority, .p3, "50% waste over 10 short minutes is background info")
        XCTAssertEqual(finding.metrics["wasted_runs"], "5")
        XCTAssertEqual(finding.metrics["total_runs"], "10")
    }

    // MARK: - Promised but not landed

    func test_completionClaimWithNoMatchingCommitOrPRProducesFinding() throws {
        let now = Date()
        let workspace = AIInboxFixtures.workspace(dirty: 5)
        let conversation = AIInboxFixtures.conversation(
            body: "Refactored the auth middleware. I have committed and pushed the fix.",
            workspacePath: workspace.path
        )
        let repository = AIInboxFixtures.repository(
            slug: "Ajnunezg/BurnBar",
            runs: [],
            openPullRequests: [
                // Title shares no meaningful tokens with the session's task.
                DetectorBreadthSupport.pullRequest(
                    number: 7,
                    title: "Bump dependency versions",
                    state: "OPEN",
                    updatedAt: now
                )
            ]
        )
        let pack = AIInboxFixtures.pack(
            repositories: [repository],
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )

        let findings = BurnBarAIInboxDetectors(now: now).detectPromisedNotLanded(pack: pack)
        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)

        XCTAssertEqual(finding.kind, .promisedNotLanded)
        XCTAssertTrue(finding.title.contains("may not have landed"), finding.title)
        XCTAssertTrue(finding.title.contains("Auth middleware refactor"))
        XCTAssertEqual(finding.priority, .p2, "A dirty tree corroborates the claim, so it is P2")
        XCTAssertEqual(finding.confidence, 0.7, accuracy: 0.001)
        XCTAssertTrue(finding.needsVerification, "Text matching must go through adversarial verification")
        XCTAssertNil(finding.deterministicVerification)
        XCTAssertTrue(finding.fingerprint.hasPrefix("promised_not_landed:"))

        XCTAssertTrue(finding.evidenceIDs.contains(conversation.evidenceID))
        XCTAssertTrue(finding.evidenceIDs.contains("workspace:\(workspace.path)"))
        XCTAssertTrue(
            finding.evidenceIDs.contains("pr:Ajnunezg/BurnBar#7"),
            "Open PRs are cited so the user can rule them out: \(finding.evidenceIDs)"
        )

        XCTAssertEqual(finding.metrics["dirty_files"], "5")
        XCTAssertEqual(finding.metrics["branch"], "main")
        XCTAssertTrue(finding.summaryMarkdown.contains("recent commit or pull request"))

        let primary = try XCTUnwrap(finding.actions.first(where: \.isPrimary))
        XCTAssertEqual(primary.kind, .resumeConversation)
        XCTAssertEqual(primary.value, conversation.conversationID)
        XCTAssertTrue(finding.actions.contains { $0.kind == .openSessionLog })
    }

    func test_cleanWorktreeLowersPriorityAndConfidence() throws {
        let now = Date()
        let workspace = DetectorBreadthSupport.workspace(dirtyFileCount: 0, untrackedCount: 0)
        let conversation = AIInboxFixtures.conversation(workspacePath: workspace.path)
        let pack = AIInboxFixtures.pack(
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )

        let finding = try XCTUnwrap(
            BurnBarAIInboxDetectors(now: now).detectPromisedNotLanded(pack: pack).first
        )
        XCTAssertEqual(finding.priority, .p3, "A clean tree is ambiguous, not damning")
        XCTAssertEqual(finding.confidence, 0.45, accuracy: 0.001)
        XCTAssertTrue(finding.summaryMarkdown.contains("worth a glance"))
    }

    func test_matchingCommitSubjectSuppressesTheFinding() {
        let now = Date()
        // The commit subject overlaps the session title heavily, so the work landed.
        let workspace = DetectorBreadthSupport.workspace(
            dirtyFileCount: 2,
            recentCommitSubjects: ["auth middleware refactor complete"]
        )
        let conversation = AIInboxFixtures.conversation(workspacePath: workspace.path)
        let pack = AIInboxFixtures.pack(
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )

        XCTAssertTrue(
            BurnBarAIInboxDetectors(now: now).detectPromisedNotLanded(pack: pack).isEmpty,
            "A commit matching the task means the promise was kept"
        )
    }

    func test_matchingMergedPullRequestSuppressesTheFinding() {
        let now = Date()
        let workspace = AIInboxFixtures.workspace(dirty: 4)
        let conversation = AIInboxFixtures.conversation(workspacePath: workspace.path)
        let repository = AIInboxFixtures.repository(
            slug: "Ajnunezg/BurnBar",
            runs: [],
            mergedPullRequests: [
                DetectorBreadthSupport.pullRequest(
                    number: 12,
                    title: "Auth middleware refactor",
                    state: "MERGED",
                    updatedAt: now,
                    mergedAt: now
                )
            ]
        )
        let pack = AIInboxFixtures.pack(
            repositories: [repository],
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )

        XCTAssertTrue(
            BurnBarAIInboxDetectors(now: now).detectPromisedNotLanded(pack: pack).isEmpty,
            "A merged PR matching the task means the promise was kept"
        )
    }

    func test_conversationWithoutCompletionClaimStaysQuiet() {
        let now = Date()
        let workspace = AIInboxFixtures.workspace(dirty: 5)
        let conversation = AIInboxFixtures.conversation(
            body: "Explored a few approaches to the auth middleware. Still deciding.",
            workspacePath: workspace.path
        )
        let pack = AIInboxFixtures.pack(
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )
        XCTAssertTrue(BurnBarAIInboxDetectors(now: now).detectPromisedNotLanded(pack: pack).isEmpty)
    }

    func test_completionClaimDetectionMatchesRealPhrasingsOnly() {
        let claims = [
            "I have committed and pushed the fix.",
            "I've now merged the change into main.",
            "The fix has been shipped to production.",
            "The PR is merged.",
            "All tests pass and we pushed the branch."
        ]
        for claim in claims {
            XCTAssertTrue(
                BurnBarAIInboxDetectors.containsCompletionClaim(claim),
                "Should read as a completion claim: \(claim)"
            )
        }

        let nonClaims = [
            "I will commit this once the tests pass.",
            "We should open a PR for this tomorrow.",
            "The commit history looks messy here."
        ]
        for text in nonClaims {
            XCTAssertFalse(
                BurnBarAIInboxDetectors.containsCompletionClaim(text),
                "Should NOT read as a completion claim: \(text)"
            )
        }
    }

    // MARK: - Uncommitted work

    func test_dirtyWorkspaceWithQuietSessionIsFlagged() throws {
        let now = Date()
        let workspace = AIInboxFixtures.workspace(dirty: 5)
        let conversation = AIInboxFixtures.conversation(
            workspacePath: workspace.path,
            endedAt: now.addingTimeInterval(-3_600)
        )
        let pack = AIInboxFixtures.pack(
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )

        let finding = try XCTUnwrap(
            BurnBarAIInboxDetectors(now: now).detectUncommittedWork(pack: pack).first
        )
        XCTAssertEqual(finding.kind, .uncommittedWork)
        XCTAssertEqual(finding.title, "5 uncommitted changes in burnbar")
        XCTAssertEqual(finding.priority, .p3)
        XCTAssertEqual(finding.metrics["dirty_files"], "5")
        XCTAssertEqual(finding.metrics["untracked_files"], "0")
        XCTAssertEqual(finding.metrics["branch"], "main")
        XCTAssertEqual(finding.evidenceIDs, ["workspace:\(workspace.path)"])
        XCTAssertTrue(finding.summaryMarkdown.contains("went quiet 1 hour ago"))
        XCTAssertTrue(finding.summaryMarkdown.contains("`file0.swift`"), "Changed files are sampled in prose")
        XCTAssertEqual(finding.deterministicVerification?.verdict, .deterministic)

        let action = try XCTUnwrap(finding.actions.first)
        XCTAssertEqual(action.kind, .openProject)
        XCTAssertEqual(action.value, workspace.path)
    }

    func test_manyUncommittedChangesEscalateToP2() throws {
        let now = Date()
        let workspace = AIInboxFixtures.workspace(dirty: 16)
        let conversation = AIInboxFixtures.conversation(
            workspacePath: workspace.path,
            endedAt: now.addingTimeInterval(-2 * 3_600)
        )
        let pack = AIInboxFixtures.pack(
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )
        let finding = try XCTUnwrap(
            BurnBarAIInboxDetectors(now: now).detectUncommittedWork(pack: pack).first
        )
        XCTAssertEqual(finding.priority, .p2, "15+ changed files is a real chunk of work at risk")
    }

    func test_recentActivityMeansNoNudge() {
        let now = Date()
        let workspace = AIInboxFixtures.workspace(dirty: 8)
        // The session is still active: last activity 10 minutes ago.
        let conversation = AIInboxFixtures.conversation(
            workspacePath: workspace.path,
            endedAt: now.addingTimeInterval(-600)
        )
        let pack = AIInboxFixtures.pack(
            conversations: [conversation],
            workspaces: [workspace],
            now: now
        )
        XCTAssertTrue(
            BurnBarAIInboxDetectors(now: now).detectUncommittedWork(pack: pack).isEmpty,
            "Nudging mid-edit is worse than useless"
        )
    }

    func test_fewChangedFilesAndNoSessionStayQuiet() {
        let now = Date()
        let detectors = BurnBarAIInboxDetectors(now: now)

        // Below the minimum file count.
        let small = AIInboxFixtures.pack(
            conversations: [AIInboxFixtures.conversation(endedAt: now.addingTimeInterval(-3_600))],
            workspaces: [AIInboxFixtures.workspace(dirty: 2)],
            now: now
        )
        XCTAssertTrue(detectors.detectUncommittedWork(pack: small).isEmpty)

        // No conversation touched this workspace, so there is no quiet moment to measure.
        let orphan = AIInboxFixtures.pack(
            workspaces: [AIInboxFixtures.workspace(dirty: 9)],
            now: now
        )
        XCTAssertTrue(detectors.detectUncommittedWork(pack: orphan).isEmpty)
    }

    // MARK: - Cost anomaly

    func test_extremeSpendSpikeAgainstFlatBaselineIsP2() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            usage: [
                DetectorBreadthSupport.usage(project: "BurnBar", model: "claude-fable-5", calls: 40, cost: 3.5),
                DetectorBreadthSupport.usage(project: "BurnBar", model: "gpt-5.6-luna", calls: 10, cost: 1.5)
            ],
            now: now
        )
        let baselines = [
            "BurnBar": BurnBarAIInboxDetectors.CostBaseline(
                samples: [1.0, 1.0, 1.0, 1.0, 1.0],
                updatedAt: now
            )
        ]

        let findings = BurnBarAIInboxDetectors(now: now)
            .detectCostAnomaly(pack: pack, baselines: baselines)
        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)

        XCTAssertEqual(finding.kind, .costAnomaly)
        XCTAssertEqual(finding.priority, .p2, "A z-score this extreme is a today problem")
        XCTAssertTrue(finding.title.contains("Spend in BurnBar"))
        XCTAssertTrue(finding.title.contains("5.0"), "The multiple over baseline belongs in the title")
        XCTAssertTrue(finding.summaryMarkdown.contains("$5.00"), "Window spend is quantified")
        XCTAssertTrue(finding.summaryMarkdown.contains("$1.00"), "Baseline is quantified")
        XCTAssertTrue(
            finding.summaryMarkdown.contains("claude-fable-5"),
            "The dominant model is named: \(finding.summaryMarkdown)"
        )
        XCTAssertEqual(finding.metrics["window_cost_usd"], "5.0000")
        XCTAssertEqual(finding.metrics["baseline_median_usd"], "1.0000")
        XCTAssertEqual(finding.projectName, "BurnBar")
        XCTAssertEqual(
            finding.evidenceIDs.first,
            "usage:BurnBar:claude-fable-5",
            "Evidence points at the usage aggregates behind the number"
        )
        XCTAssertEqual(finding.deterministicVerification?.verdict, .deterministic)
        XCTAssertTrue(finding.fingerprint.hasPrefix("cost_anomaly:"))
    }

    func test_moderateSpikeIsP3() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            usage: [DetectorBreadthSupport.usage(project: "BurnBar", model: "claude-fable-5", calls: 8, cost: 1.6)],
            now: now
        )
        // Median 1.0, MAD 0.1 -> scale 0.14826 -> z just above 4.
        let baselines = [
            "BurnBar": BurnBarAIInboxDetectors.CostBaseline(
                samples: [1.0, 1.2, 0.9, 1.1, 1.0],
                updatedAt: now
            )
        ]
        let finding = try XCTUnwrap(
            BurnBarAIInboxDetectors(now: now).detectCostAnomaly(pack: pack, baselines: baselines).first
        )
        XCTAssertEqual(finding.priority, .p3)
        let zScore = try XCTUnwrap(finding.metrics["z_score"].flatMap(Double.init))
        XCTAssertGreaterThanOrEqual(zScore, BurnBarAIInboxDetectors.costAnomalyZThreshold)
        XCTAssertLessThan(zScore, 6)
    }

    func test_costAnomalyStaysQuietWithoutStrongEvidence() {
        let now = Date()
        let detectors = BurnBarAIInboxDetectors(now: now)
        let flatBaseline = [
            "BurnBar": BurnBarAIInboxDetectors.CostBaseline(
                samples: [1.0, 1.0, 1.0, 1.0, 1.0],
                updatedAt: now
            )
        ]

        // Below the absolute dollar floor, even at an infinite multiple.
        let tiny = AIInboxFixtures.pack(
            usage: [DetectorBreadthSupport.usage(project: "BurnBar", model: "m", calls: 2, cost: 0.5)],
            now: now
        )
        XCTAssertTrue(detectors.detectCostAnomaly(pack: tiny, baselines: flatBaseline).isEmpty)

        // No baseline for the project at all.
        let unknown = AIInboxFixtures.pack(
            usage: [DetectorBreadthSupport.usage(project: "BurnBar", model: "m", calls: 2, cost: 9)],
            now: now
        )
        XCTAssertTrue(detectors.detectCostAnomaly(pack: unknown, baselines: [:]).isEmpty)

        // A baseline that has not accumulated enough samples yet.
        let thin = [
            "BurnBar": BurnBarAIInboxDetectors.CostBaseline(samples: [1.0, 1.0], updatedAt: now)
        ]
        XCTAssertTrue(detectors.detectCostAnomaly(pack: unknown, baselines: thin).isEmpty)

        // Spend well within the noise band of a spread-out baseline.
        let noisy = [
            "BurnBar": BurnBarAIInboxDetectors.CostBaseline(
                samples: [1.0, 2.0, 3.0, 4.0, 5.0],
                updatedAt: now
            )
        ]
        let ordinary = AIInboxFixtures.pack(
            usage: [DetectorBreadthSupport.usage(project: "BurnBar", model: "m", calls: 2, cost: 3.5)],
            now: now
        )
        XCTAssertTrue(detectors.detectCostAnomaly(pack: ordinary, baselines: noisy).isEmpty)
    }

    // MARK: - Index health

    func test_indexHealthStaysQuietWhenConversationsAreIndexed() {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            conversations: [AIInboxFixtures.conversation()],
            now: now
        )
        XCTAssertTrue(BurnBarAIInboxDetectors(now: now).detectIndexHealth(pack: pack).isEmpty)
    }

    /// Plants a session-log file that changed inside the window but not in the
    /// last minute, so "logs moved but nothing is indexed" is directly observable.
    func test_indexHealthFlagsUnindexedRecentAgentActivity() throws {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let parent = home.appendingPathComponent(".hermes", isDirectory: true)
        let root = home.appendingPathComponent(".hermes/sessions", isDirectory: true)
        let parentExisted = manager.fileExists(atPath: parent.path)
        let rootExisted = manager.fileExists(atPath: root.path)
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw XCTSkip("Home directory is not writable in this environment: \(error)")
        }

        let marker = root.appendingPathComponent("ai-inbox-index-health-\(UUID().uuidString).jsonl")
        defer {
            try? manager.removeItem(at: marker)
            if rootExisted == false { try? manager.removeItem(at: root) }
            if parentExisted == false { try? manager.removeItem(at: parent) }
        }

        let now = Date()
        try Data("session activity".utf8).write(to: marker)
        // Inside the 2-hour pack window, outside the trailing 60-second slice.
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)],
            ofItemAtPath: marker.path
        )

        let pack = AIInboxFixtures.emptyPack(now: now)
        let findings = BurnBarAIInboxDetectors(now: now).detectIndexHealth(pack: pack)

        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.kind, .indexHealth)
        XCTAssertEqual(finding.priority, .p4, "A lagging index is informational, never an interruption")
        XCTAssertEqual(finding.title, "Recent agent activity is not indexed yet")
        XCTAssertTrue(finding.summaryMarkdown.contains("this brief may be incomplete"))
        XCTAssertEqual(finding.deterministicVerification?.verdict, .deterministic)
        XCTAssertFalse(finding.needsVerification)
    }

    // MARK: - Text and number helpers

    func test_significantTokensDropStopWordsAndShortFragments() {
        XCTAssertEqual(
            BurnBarAIInboxDetectors.significantTokens("Fix the auth middleware for the API"),
            ["auth", "middleware"]
        )
        XCTAssertEqual(BurnBarAIInboxDetectors.significantTokens("a to of in"), [])
        XCTAssertEqual(
            BurnBarAIInboxDetectors.significantTokens("retry-loop in api/client.ts"),
            ["retry", "loop", "client"]
        )
    }

    func test_overlapScoreIsFractionOfTheSmallerSet() {
        XCTAssertEqual(BurnBarAIInboxDetectors.overlapScore([], ["alpha"]), 0)
        XCTAssertEqual(BurnBarAIInboxDetectors.overlapScore(["alpha"], []), 0)
        XCTAssertEqual(
            BurnBarAIInboxDetectors.overlapScore(["alpha", "beta", "gamma"], ["beta"]),
            1.0,
            accuracy: 0.001,
            "A short subject fully contained in a long title is a full match"
        )
        XCTAssertEqual(
            BurnBarAIInboxDetectors.overlapScore(["alpha", "beta"], ["beta", "delta"]),
            0.5,
            accuracy: 0.001
        )
    }

    func test_medianHandlesOddEvenAndEmptyInputs() {
        XCTAssertEqual(BurnBarAIInboxDetectors.median([]), 0)
        XCTAssertEqual(BurnBarAIInboxDetectors.median([3, 1, 2]), 2)
        XCTAssertEqual(BurnBarAIInboxDetectors.median([4, 1, 3, 2]), 2.5, accuracy: 0.001)
    }

    func test_samePathNormalizesEquivalentForms() {
        XCTAssertTrue(BurnBarAIInboxDetectors.samePath("/tmp/a/../b", "/tmp/b"))
        XCTAssertTrue(BurnBarAIInboxDetectors.samePath("/tmp/b/", "/tmp/b"))
        XCTAssertFalse(BurnBarAIInboxDetectors.samePath("/tmp/a", "/tmp/b"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(BurnBarAIInboxDetectors.samePath("~/projects", home + "/projects"))
    }

    func test_displayPathAbbreviatesTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(BurnBarAIInboxDetectors.displayPath(home + "/code/burnbar"), "~/code/burnbar")
        XCTAssertEqual(BurnBarAIInboxDetectors.displayPath("/opt/work"), "/opt/work")
    }

    func test_lastPathComponentExtractsTheDirectoryName() {
        XCTAssertEqual(BurnBarAIInboxDetectors.lastPathComponent("/tmp/burnbar"), "burnbar")
        XCTAssertEqual(BurnBarAIInboxDetectors.lastPathComponent("solo"), "solo")
    }

    func test_truncateShortensLongTextWithAnEllipsis() {
        let long = String(repeating: "x", count: 100)
        let truncated = BurnBarAIInboxDetectors.truncate(long, 60)
        XCTAssertEqual(truncated.count, 60)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertEqual(BurnBarAIInboxDetectors.truncate("short", 60), "short")
    }

    func test_currencyUsesMorePrecisionUnderADollar() {
        XCTAssertEqual(BurnBarAIInboxDetectors.currency(2.0), "$2.00")
        XCTAssertEqual(BurnBarAIInboxDetectors.currency(0.5), "$0.500")
    }

    func test_multiplierDescriptionCoversEveryBand() {
        XCTAssertEqual(BurnBarAIInboxDetectors.multiplierDescription(5, 0), "well above")
        XCTAssertTrue(BurnBarAIInboxDetectors.multiplierDescription(25, 2).contains("more than 10"))
        XCTAssertTrue(BurnBarAIInboxDetectors.multiplierDescription(3, 2).contains("1.5"))
    }

    func test_relativeDescriptionReadsLikeAHuman() {
        let now = Date()
        XCTAssertEqual(BurnBarAIInboxDetectors.relativeDescription(from: nil, to: now), "at an unknown time")
        XCTAssertEqual(
            BurnBarAIInboxDetectors.relativeDescription(from: now.addingTimeInterval(-30), to: now),
            "just now"
        )
        XCTAssertEqual(
            BurnBarAIInboxDetectors.relativeDescription(from: now.addingTimeInterval(-600), to: now),
            "10 minutes ago"
        )
        XCTAssertEqual(
            BurnBarAIInboxDetectors.relativeDescription(from: now.addingTimeInterval(-3_600), to: now),
            "1 hour ago"
        )
        XCTAssertEqual(
            BurnBarAIInboxDetectors.relativeDescription(from: now.addingTimeInterval(-86_400), to: now),
            "1 day ago"
        )
        XCTAssertEqual(
            BurnBarAIInboxDetectors.relativeDescription(from: now.addingTimeInterval(-3 * 86_400), to: now),
            "3 days ago"
        )
    }
}
