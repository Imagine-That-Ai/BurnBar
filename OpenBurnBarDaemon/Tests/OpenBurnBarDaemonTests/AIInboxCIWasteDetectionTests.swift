import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The marquee case.
///
/// Alberto discovered a workflow wasting 95% of his CI cycles only by digging
/// manually. Each individual red run looked like a normal flake; only the
/// aggregate revealed the pattern. This suite proves the AI Inbox catches
/// exactly that shape automatically, with the evidence attached, and — critically
/// — **without any model call**, so the detection works even with egress off.
final class AIInboxCIWasteDetectionTests: XCTestCase {
    // MARK: - The 95% case

    func test_detectsWorkflowWastingNinetyFivePercentOfRuns() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(
                    workflow: ".github/workflows/nightly-matrix.yml",
                    total: 40,
                    wasted: 38,
                    minutesEach: 8,
                    now: now
                )
            )],
            now: now
        )

        let findings = BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack)

        XCTAssertEqual(findings.count, 1, "Exactly one workflow should be flagged")
        let finding = try XCTUnwrap(findings.first)

        XCTAssertEqual(finding.kind, .ciWaste)
        XCTAssertEqual(finding.priority, .p1, "38/40 wasted over 5 hours of compute is a top-priority alert")
        XCTAssertEqual(finding.source, .detector, "Detected deterministically — no model involved")
        XCTAssertEqual(finding.metrics["wasted_runs"], "38")
        XCTAssertEqual(finding.metrics["total_runs"], "40")
        XCTAssertEqual(finding.metrics["workflow"], "nightly-matrix")

        let wasteRate = try XCTUnwrap(finding.metrics["waste_rate"].flatMap(Double.init))
        XCTAssertEqual(wasteRate, 0.95, accuracy: 0.001)

        // 38 wasted runs × 8 minutes = 304 minutes of burned compute.
        let wastedMinutes = try XCTUnwrap(finding.metrics["wasted_minutes"].flatMap(Double.init))
        XCTAssertEqual(wastedMinutes, 304, accuracy: 1.0)

        // The number a human would act on has to be in the text, not just metrics.
        XCTAssertTrue(finding.title.contains("95%"), "Title should lead with the rate: \(finding.title)")
        XCTAssertTrue(finding.title.contains("nightly-matrix"))
        XCTAssertTrue(finding.summaryMarkdown.contains("304"), "Summary should quantify the waste")

        // Evidence must point at real runs so the user can verify the claim.
        XCTAssertFalse(finding.evidenceIDs.isEmpty)
        for id in finding.evidenceIDs {
            XCTAssertTrue(id.hasPrefix("run:Ajnunezg/BurnBar#"), "Unexpected evidence id: \(id)")
            XCTAssertTrue(pack.validEvidenceIDs.contains(id), "Evidence must resolve against the pack")
        }

        XCTAssertEqual(
            finding.deterministicVerification?.verdict,
            .deterministic,
            "Arithmetic over fetched records needs no adversarial verification"
        )
    }

    /// The whole point of the feature: this happens with zero egress and zero spend.
    func test_ciWasteIsDetectedWithEgressOffAndNoModelCalls() async throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(
                    workflow: "ci.yml",
                    total: 20,
                    wasted: 19,
                    minutesEach: 10,
                    now: now
                )
            )],
            now: now
        )

        let detectors = BurnBarAIInboxDetectors(now: now)
        let findings = detectors.run(
            pack: pack,
            config: BurnBarInboxConfig(enabled: true, egressMode: .off)
        )

        XCTAssertTrue(
            findings.contains { $0.kind == .ciWaste && $0.priority == .p1 },
            "The CI-waste pattern must surface at P1 with egress off"
        )
        XCTAssertTrue(
            findings.allSatisfy { $0.source == .detector },
            "Egress-off findings must all be deterministic"
        )
    }

    // MARK: - Thresholds and false-positive resistance

    func test_ignoresHealthyWorkflow() {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                runs: AIInboxFixtures.runs(workflow: "ci.yml", total: 40, wasted: 2, minutesEach: 8, now: now)
            )],
            now: now
        )
        XCTAssertTrue(
            BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack).isEmpty,
            "A 5% failure rate is normal and must stay silent"
        )
    }

    func test_ignoresSmallSampleEvenAtTotalFailure() {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                // 100% failure, but only 3 runs — almost certainly someone
                // iterating on a workflow file, not a standing pattern.
                runs: AIInboxFixtures.runs(workflow: "ci.yml", total: 3, wasted: 3, minutesEach: 9, now: now)
            )],
            now: now
        )
        XCTAssertTrue(
            BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack).isEmpty,
            "Below the minimum sample size, stay quiet"
        )
    }

    func test_highRateButTrivialDurationIsNotP1() throws {
        let now = Date()
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar",
                // 100% failure but each run is 6 seconds — annoying, not a fire.
                runs: AIInboxFixtures.runs(workflow: "lint.yml", total: 12, wasted: 12, minutesEach: 0.1, now: now)
            )],
            now: now
        )
        let finding = try XCTUnwrap(BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack).first)
        XCTAssertEqual(
            finding.priority,
            .p2,
            "A high rate with negligible compute is worth knowing, not worth interrupting for"
        )
    }

    func test_ignoresInProgressRuns() {
        let now = Date()
        var runs = AIInboxFixtures.runs(workflow: "ci.yml", total: 8, wasted: 8, minutesEach: 8, now: now)
        runs = runs.map {
            BurnBarGitHubWorkflowRun(
                id: $0.id, name: $0.name, workflowName: $0.workflowName, headSHA: $0.headSHA,
                headBranch: $0.headBranch, status: "in_progress", conclusion: nil, event: $0.event,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt, runStartedAt: $0.runStartedAt, url: $0.url
            )
        }
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: runs)],
            now: now
        )
        XCTAssertTrue(
            BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack).isEmpty,
            "Runs still executing have not wasted anything yet"
        )
    }

    /// Two workflows in one repo must be judged independently — a healthy one
    /// must not dilute a broken one, and vice versa.
    func test_separatesWorkflowsWithinOneRepository() throws {
        let now = Date()
        let broken = AIInboxFixtures.runs(workflow: "nightly.yml", total: 20, wasted: 19, minutesEach: 8, now: now)
        let healthy = AIInboxFixtures.runs(workflow: "ci.yml", total: 20, wasted: 1, minutesEach: 8, now: now, idOffset: 1_000)
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: broken + healthy)],
            now: now
        )

        let findings = BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.metrics["workflow"], "nightly")
    }

    /// Duplicate runs on one commit are the redundant-trigger smell — the second
    /// half of the "bad workflow config" story.
    func test_reportsDuplicateRunsOnSameCommit() throws {
        let now = Date()
        var runs: [BurnBarGitHubWorkflowRun] = []
        // 10 commits, each built twice, all failing.
        for index in 0..<20 {
            runs.append(
                AIInboxFixtures.run(
                    id: index,
                    workflow: "ci.yml",
                    sha: "sha\(index / 2)",
                    conclusion: "failure",
                    minutes: 5,
                    now: now
                )
            )
        }
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: runs)],
            now: now
        )

        let finding = try XCTUnwrap(BurnBarAIInboxDetectors(now: now).detectCIWaste(pack: pack).first)
        XCTAssertEqual(finding.metrics["duplicate_runs"], "10")
        XCTAssertTrue(
            finding.summaryMarkdown.contains("repeat runs"),
            "The duplicate-trigger signal should be explained in prose"
        )
    }

    func test_workflowDisplayNameStripsPathAndExtension() {
        XCTAssertEqual(
            BurnBarAIInboxDetectors.workflowDisplayName(".github/workflows/nightly-matrix.yml"),
            "nightly-matrix"
        )
        XCTAssertEqual(BurnBarAIInboxDetectors.workflowDisplayName("ci.yaml"), "ci")
        XCTAssertEqual(BurnBarAIInboxDetectors.workflowDisplayName("Build and Test"), "Build and Test")
    }

    // MARK: - Volume control

    /// A repository with a long tail of stale PRs must not become the inbox.
    ///
    /// This is the failure mode that would quietly ruin the product: 30 stale
    /// open PRs is ordinary on an active project, and because each one dedupes
    /// on its own fingerprint, all 30 would persist tick after tick. The inbox
    /// stops being "what needs you" and becomes a backlog listing nobody reads.
    func test_aLongTailOfStalledPRsCollapsesIntoOneSummaryRow() throws {
        let now = Date()
        let stale = (1...30).map { number in
            AIInboxFixtures.pullRequest(
                number: number,
                state: "OPEN",
                updatedAt: now.addingTimeInterval(-Double(number + 6) * 86_400)
            )
        }
        let pack = AIInboxFixtures.pack(
            repositories: [
                AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: [], openPullRequests: stale)
            ],
            now: now
        )

        let findings = BurnBarAIInboxDetectors(now: now).detectStuckPullRequests(pack: pack)

        // 5 individual + 1 summary, not 30.
        XCTAssertEqual(findings.count, BurnBarAIInboxDetectors.maxIndividualStuckPRs + 1)

        let summary = try XCTUnwrap(findings.last)
        XCTAssertEqual(summary.metrics["additional_stalled"], "25")
        XCTAssertTrue(summary.title.contains("25 more stalled PRs"))
        XCTAssertLessThanOrEqual(
            summary.evidenceIDs.count,
            5,
            "The summary cites a sample, not all 25"
        )

        // The summary's identity must not move with the count, or every newly
        // stale PR mints another summary row beside the last one.
        let fewer = AIInboxFixtures.pack(
            repositories: [
                AIInboxFixtures.repository(
                    slug: "Ajnunezg/BurnBar",
                    runs: [],
                    openPullRequests: Array(stale.prefix(20))
                )
            ],
            now: now
        )
        let refreshed = BurnBarAIInboxDetectors(now: now).detectStuckPullRequests(pack: fewer)
        XCTAssertEqual(
            refreshed.last?.fingerprint,
            summary.fingerprint,
            "The overflow row updates in place as the count changes"
        )
    }

    /// Below the cap, every stalled PR still gets its own row — the summary only
    /// appears when it is actually earning its place.
    func test_aFewStalledPRsAreListedIndividually() {
        let now = Date()
        let stale = (1...3).map { number in
            AIInboxFixtures.pullRequest(
                number: number,
                state: "OPEN",
                updatedAt: now.addingTimeInterval(-Double(number + 6) * 86_400)
            )
        }
        let pack = AIInboxFixtures.pack(
            repositories: [
                AIInboxFixtures.repository(slug: "Ajnunezg/BurnBar", runs: [], openPullRequests: stale)
            ],
            now: now
        )

        let findings = BurnBarAIInboxDetectors(now: now).detectStuckPullRequests(pack: pack)
        XCTAssertEqual(findings.count, 3)
        XCTAssertFalse(findings.contains { $0.title.contains("more stalled") })
    }
}
