import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The adversarial verification pass, end to end against a fake executor.
///
/// The invariants proven here: a refuted claim never reaches the user, an
/// unclear one is demoted rather than passed, a missing or refused verifier
/// degrades to "published unverified" instead of losing findings, and
/// deterministic re-checks settle claims without spending a model call.
final class AIInboxVerifierTests: XCTestCase {
    // MARK: - Pass-through and deterministic settlement

    func test_detectorFindingsPassThroughWithoutAnyModelCall() async throws {
        let executor = FakeInboxProviderExecutor(responses: ["should never be consumed"])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let finding = makeFinding(kind: .ciWaste, fingerprint: "ci_waste:done", needsVerification: false)

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(),
            now: Date()
        )

        XCTAssertEqual(result.findings.map(\.fingerprint), ["ci_waste:done"])
        XCTAssertTrue(result.calls.isEmpty)
        XCTAssertTrue(result.suppressedFingerprints.isEmpty)
        let callCount = await executor.callCount
        XCTAssertEqual(callCount, 0, "Arithmetic must never be re-litigated by a model")
    }

    func test_mergedPRRefutesAStuckClaimWithoutAModelCall() async throws {
        let now = Date()
        let executor = FakeInboxProviderExecutor(responses: ["should never be consumed"])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let merged = AIInboxFixtures.pullRequest(number: 12, state: "MERGED", updatedAt: now, mergedAt: now)
        let pack = AIInboxFixtures.pack(
            repositories: [AIInboxFixtures.repository(
                slug: "Ajnunezg/BurnBar", runs: [], mergedPullRequests: [merged]
            )],
            now: now
        )
        let finding = makeFinding(
            kind: .stuckPR,
            fingerprint: "stuck_pr:12",
            evidenceIDs: ["pr:Ajnunezg/BurnBar#12"],
            needsVerification: true
        )

        let result = await verifier.verify(findings: [finding], pack: pack, config: makeConfig(), now: now)

        XCTAssertTrue(result.findings.isEmpty, "A merged PR is by definition not stuck")
        XCTAssertEqual(result.suppressedFingerprints, ["stuck_pr:12"])
        let callCount = await executor.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - Model verdicts

    func test_confirmedVerdictAttachesVerificationAndRevisedSummary() async throws {
        let executor = FakeInboxProviderExecutor(responses: [
            #"{"verdict":"confirm","reason":"checks out","revised_summary_md":"Tightened summary."}"#
        ])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let finding = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:x", needsVerification: true)

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(),
            now: Date()
        )

        let survivor = try XCTUnwrap(result.findings.first)
        let verification = try XCTUnwrap(survivor.deterministicVerification)
        XCTAssertEqual(verification.verdict, .confirmed)
        XCTAssertEqual(verification.reason, "checks out")
        XCTAssertTrue(try XCTUnwrap(verification.verifierModel).hasPrefix("zai:"))
        XCTAssertEqual(survivor.summaryMarkdown, "Tightened summary.")
        XCTAssertEqual(survivor.priority, finding.priority, "A confirmed claim keeps its priority")

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls.first?.role, "verifier")
        XCTAssertEqual(result.calls.first?.providerID, "zai")
    }

    func test_refutedVerdictSuppressesTheFinding() async throws {
        let executor = FakeInboxProviderExecutor(responses: [
            #"{"verdict":"refute","reason":"the commit exists"}"#
        ])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let finding = makeFinding(
            kind: .promisedNotLanded, fingerprint: "promised_not_landed:x", needsVerification: true
        )

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(),
            now: Date()
        )

        XCTAssertTrue(result.findings.isEmpty, "A refuted finding must never publish")
        XCTAssertEqual(result.suppressedFingerprints, ["promised_not_landed:x"])
        XCTAssertEqual(result.calls.count, 1, "The refutation is still accounted for")
    }

    func test_unclearVerdictDemotesInsteadOfPassing() async throws {
        let executor = FakeInboxProviderExecutor(responses: [#"{"verdict":"maybe"}"#])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let finding = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:y", needsVerification: true)

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(),
            now: Date()
        )

        let survivor = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(survivor.deterministicVerification?.verdict, .unclear)
        XCTAssertEqual(survivor.priority, .p3, "An unresolved P2 claim drops a band")
        XCTAssertLessThan(survivor.confidence, finding.confidence)
    }

    func test_executorFailurePublishesUnverifiedRatherThanDropping() async throws {
        let executor = FakeInboxProviderExecutor(responses: [])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let finding = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:z", needsVerification: true)

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(),
            now: Date()
        )

        let survivor = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(survivor.deterministicVerification?.verdict, .unverified)
        XCTAssertEqual(survivor.deterministicVerification?.reason, "The verification pass could not complete.")
    }

    func test_perTickBudgetCapsModelCallsAndMarksTheRestUnverified() async throws {
        let executor = FakeInboxProviderExecutor(responses: [#"{"verdict":"confirm"}"#])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let first = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:a", needsVerification: true)
        let second = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:b", needsVerification: true)

        let result = await verifier.verify(
            findings: [first, second],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(maxVerifierCalls: 1),
            now: Date()
        )

        XCTAssertEqual(result.findings.count, 2, "The budget must not lose findings")
        XCTAssertEqual(result.calls.count, 1)
        let capped = try XCTUnwrap(result.findings.first { $0.fingerprint == "cost_anomaly:b" })
        XCTAssertEqual(capped.deterministicVerification?.verdict, .unverified)
        XCTAssertEqual(
            capped.deterministicVerification?.reason,
            "The per-tick verification budget was reached."
        )
    }

    // MARK: - Route degradation

    func test_missingProviderDegradesToUnverified() async throws {
        let executor = FakeInboxProviderExecutor(responses: ["should never be consumed"])
        let verifier = makeVerifier(executor: executor, router: makeUnconfiguredRouter())
        let finding = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:noroute", needsVerification: true)

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(),
            now: Date()
        )

        let survivor = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(survivor.deterministicVerification?.verdict, .unverified)
        XCTAssertEqual(
            survivor.deterministicVerification?.reason,
            "No verifier model is configured, so this was published unverified."
        )
        let callCount = await executor.callCount
        XCTAssertEqual(callCount, 0)
    }

    func test_localEgressModeRefusesACloudVerifierEndpoint() async throws {
        let executor = FakeInboxProviderExecutor(responses: ["should never be consumed"])
        let verifier = makeVerifier(executor: executor, router: try await makeConfiguredRouter())
        let finding = makeFinding(kind: .costAnomaly, fingerprint: "cost_anomaly:egress", needsVerification: true)

        let result = await verifier.verify(
            findings: [finding],
            pack: AIInboxFixtures.emptyPack(now: Date()),
            config: makeConfig(egressMode: .local),
            now: Date()
        )

        let survivor = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(
            survivor.deterministicVerification?.verdict, .unverified,
            "The local-only promise must beat an available cloud route"
        )
        let callCount = await executor.callCount
        XCTAssertEqual(callCount, 0, "Not a single byte may reach the cloud endpoint")
        XCTAssertTrue(result.calls.isEmpty)
    }

    // MARK: - Fresh workspace re-checks

    func test_freshCommitContradictsAPromisedNotLandedClaim() async throws {
        let workspaceURL = try makeWorkspaceDirectory()
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let verifier = makeVerifier(
            executor: FakeInboxProviderExecutor(responses: []),
            router: makeUnconfiguredRouter(),
            runner: makeGitRunner(headSHA: "def456", porcelain: " M file0.swift")
        )
        let workspace = AIInboxFixtures.workspace(dirty: 3, path: workspaceURL.path)
        let finding = makeFinding(
            kind: .promisedNotLanded,
            fingerprint: "promised_not_landed:head",
            evidenceIDs: ["workspace:\(workspaceURL.path)"],
            needsVerification: true
        )
        let pack = AIInboxFixtures.pack(workspaces: [workspace], now: Date())

        let checks = await verifier.deterministicChecks(for: finding, pack: pack)

        let contradiction = try XCTUnwrap(checks.first { $0.outcome == .contradicts })
        XCTAssertTrue(contradiction.description.contains("A new commit landed"))
        XCTAssertEqual(
            BurnBarAIInboxVerifier.settleDeterministically(finding: finding, checks: checks, now: Date())?.verdict,
            .refuted
        )
    }

    func test_nowCleanWorktreeContradictsAPromisedNotLandedClaim() async throws {
        let workspaceURL = try makeWorkspaceDirectory()
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let verifier = makeVerifier(
            executor: FakeInboxProviderExecutor(responses: []),
            router: makeUnconfiguredRouter(),
            runner: makeGitRunner(headSHA: "abc123", porcelain: "")
        )
        let workspace = AIInboxFixtures.workspace(dirty: 3, path: workspaceURL.path)
        let finding = makeFinding(
            kind: .promisedNotLanded,
            fingerprint: "promised_not_landed:clean",
            evidenceIDs: ["workspace:\(workspaceURL.path)"],
            needsVerification: true
        )
        let pack = AIInboxFixtures.pack(workspaces: [workspace], now: Date())

        let checks = await verifier.deterministicChecks(for: finding, pack: pack)

        let contradiction = try XCTUnwrap(checks.first { $0.outcome == .contradicts })
        XCTAssertTrue(contradiction.description.contains("clean"))
    }

    func test_persistentDirtinessSupportsTheClaimWithoutSettlingIt() async throws {
        let workspaceURL = try makeWorkspaceDirectory()
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let verifier = makeVerifier(
            executor: FakeInboxProviderExecutor(responses: []),
            router: makeUnconfiguredRouter(),
            runner: makeGitRunner(headSHA: "abc123", porcelain: " M file0.swift\n?? scratch.txt")
        )
        let workspace = AIInboxFixtures.workspace(dirty: 3, path: workspaceURL.path)
        let finding = makeFinding(
            kind: .promisedNotLanded,
            fingerprint: "promised_not_landed:dirty",
            evidenceIDs: ["workspace:\(workspaceURL.path)"],
            needsVerification: true
        )
        let pack = AIInboxFixtures.pack(workspaces: [workspace], now: Date())

        let checks = await verifier.deterministicChecks(for: finding, pack: pack)

        let support = try XCTUnwrap(checks.first { $0.outcome == .supports })
        XCTAssertTrue(support.description.contains("1 modified and 1 untracked"))
        XCTAssertNil(
            BurnBarAIInboxVerifier.settleDeterministically(finding: finding, checks: checks, now: Date()),
            "Supporting evidence alone must not settle the claim for free"
        )
    }

    // MARK: - Egress guard host parsing

    func test_egressGuardRefusesEndpointsWithoutAResolvableHost() {
        let blank = BurnBarAIInboxEgressGuard.evaluate(baseURL: "   ", mode: .local)
        guard case .refused(let blankReason) = blank else {
            return XCTFail("A hostless endpoint must be refused in local mode")
        }
        XCTAssertTrue(blankReason.contains("no resolvable host"))

        let pathOnly = BurnBarAIInboxEgressGuard.evaluate(baseURL: "/", mode: .local)
        guard case .refused = pathOnly else {
            return XCTFail("A bare path must be refused in local mode")
        }
        XCTAssertNil(BurnBarAIInboxEgressGuard.host(from: "/"))
        XCTAssertNil(BurnBarAIInboxEgressGuard.host(from: ""))
    }

    // MARK: - Fixtures

    private func makeVerifier(
        executor: any BurnBarProviderExecuting,
        router: BurnBarProviderRouter,
        runner: any BurnBarAIInboxProcessRunning = FakeInboxProcessRunner()
    ) -> BurnBarAIInboxVerifier {
        BurnBarAIInboxVerifier(
            executor: executor,
            router: router,
            workspaceScout: BurnBarAIInboxWorkspaceScout(
                runner: runner,
                logger: BurnBarDaemonLogger(category: "test")
            ),
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    private func makeConfiguredRouter() async throws -> BurnBarProviderRouter {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "test")
        )
        try await configStore.setSecret("verifier-secret", for: "zai")
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        return BurnBarProviderRouter(configStore: configStore, logger: BurnBarDaemonLogger(category: "test"))
    }

    /// A router over a default snapshot: every provider disabled, no credential,
    /// so `route()` throws and the verifier must degrade.
    private func makeUnconfiguredRouter() -> BurnBarProviderRouter {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-verifier-empty-\(UUID().uuidString).json")
        let configStore = BurnBarConfigStore(
            fileURL: fileURL,
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "test")
        )
        return BurnBarProviderRouter(configStore: configStore, logger: BurnBarDaemonLogger(category: "test"))
    }

    private func makeConfig(
        egressMode: BurnBarInboxEgressMode = .cloud,
        maxVerifierCalls: Int = 3
    ) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: true,
            egressMode: egressMode,
            maxVerifierCallsPerTick: maxVerifierCalls,
            verifierProviderID: "zai",
            verifierModel: "glm-5"
        )
    }

    private func makeFinding(
        kind: BurnBarInboxItemKind,
        fingerprint: String,
        evidenceIDs: [String] = [],
        needsVerification: Bool
    ) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: kind,
            title: "claim \(fingerprint)",
            summaryMarkdown: "original summary",
            priority: .p2,
            confidence: 0.9,
            evidenceIDs: evidenceIDs,
            fingerprint: fingerprint,
            needsVerification: needsVerification,
            source: .analyst
        )
    }

    private func makeWorkspaceDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-scout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Canned `git` output for a fresh workspace snapshot. The `%H` and `%s`
    /// format keys disambiguate the two `git log` calls the scout makes.
    private func makeGitRunner(headSHA: String, porcelain: String) -> FakeInboxProcessRunner {
        FakeInboxProcessRunner(responses: [
            "--is-inside-work-tree": "true",
            "--abbrev-ref": "main",
            "format:%H": "\(headSHA)\u{1F}feat: something\u{1F}2026-08-05T00:00:00Z",
            "format:%s": "feat: something",
            "status --porcelain": porcelain,
            "remote.origin.url": "git@github.com:Ajnunezg/BurnBar.git",
            "rev-list": "0\t0"
        ])
    }
}
