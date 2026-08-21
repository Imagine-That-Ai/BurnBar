import OpenBurnBarCore
import OpenBurnBarInboxModels
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBar

// MARK: - Home signal digest tests
//
// Home used to read exactly one derivation — `HomeInboxDigest` — and that
// digest held nothing but AI-inbox rows, so all eight shells were rendering one
// table. The digest now carries the rest of the system, and every figure in it
// is a claim the product makes on its launch screen.
//
// Two contracts run through every test below:
//
//   1. **Every derived figure is pinned**, including the empty/first-run state.
//      A launch surface is exactly where a fabricated number does the most
//      damage, because it is the first thing a user believes.
//   2. **Unavailable is not zero.** A missing source reads `nil` or empty so a
//      shell can say "unknown" honestly; it never reads as a confident 0%, $0,
//      or "no agents running".

@MainActor
final class HomeSignalDigestTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Inbox payload

    /// The list query already loads `payload_json` for every row. These are the
    /// four things it contains, and Home discarded all four.
    func test_payload_rollsUpEvidenceActionsMetricsAndVerdicts() {
        let digest = HomeInboxDigest(rows: [
            makeRow(
                id: "a",
                payload: BurnBarInboxItemPayload(
                    evidence: [makeEvidence(id: "pr:1", occurredAt: now - 60)],
                    memoryCandidates: [makeMemoryCandidate(id: "m1")],
                    actions: [makeAction(id: "act-open", isPrimary: false)],
                    metrics: ["wasted_minutes": "12"],
                    verification: makeVerification(.confirmed)
                )
            ),
            makeRow(
                id: "b",
                payload: BurnBarInboxItemPayload(
                    evidence: [makeEvidence(id: "pr:2", occurredAt: now)],
                    actions: [makeAction(id: "act-resume", isPrimary: true)],
                    metrics: ["wasted_minutes": "30"],
                    verification: makeVerification(.deterministic)
                )
            ),
            // No verification block at all — a different fact from the
            // `.unverified` verdict, and counted separately.
            makeRow(id: "c", payload: BurnBarInboxItemPayload())
        ])

        XCTAssertEqual(digest.payload.evidence.map(\.id), ["pr:2", "pr:1"], "newest citation first")
        XCTAssertEqual(digest.payload.actions.map(\.id), ["act-resume", "act-open"], "primary action leads")
        XCTAssertEqual(digest.payload.leadAction?.id, "act-resume")
        XCTAssertEqual(digest.payload.metrics.map(\.key), ["wasted_minutes"])
        XCTAssertEqual(digest.payload.metrics.first?.rowCount, 2)
        XCTAssertEqual(digest.payload.metrics.first?.total, 42)
        XCTAssertEqual(digest.payload.corroboratedCount, 2, "confirmed + deterministic both stand behind a row")
        XCTAssertEqual(digest.payload.refutedCount, 0)
        XCTAssertEqual(digest.payload.unverifiedRowCount, 1)
        XCTAssertEqual(digest.payload.memoryCandidateCount, 1)
    }

    /// A recurring condition updates one row in place, but two different rows
    /// can cite the same PR. Counting it twice would inflate the evidence.
    func test_payload_dedupesEvidenceAndActionsByID() {
        let shared = makeEvidence(id: "pr:burnbar#2336", occurredAt: now)
        let sharedAction = makeAction(id: "act-open")
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "a", payload: BurnBarInboxItemPayload(evidence: [shared], actions: [sharedAction])),
            makeRow(id: "b", payload: BurnBarInboxItemPayload(evidence: [shared], actions: [sharedAction]))
        ])

        XCTAssertEqual(digest.payload.evidence.count, 1)
        XCTAssertEqual(digest.payload.actions.count, 1)
    }

    /// `metrics` is `[String: String]` because some detector metrics are not
    /// numbers. Summing the ones that parse and quietly dropping the rest would
    /// report a total that is smaller than the truth and looks exact.
    func test_payload_metricTotalIsNilUnlessEveryValueIsNumeric() {
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "a", payload: BurnBarInboxItemPayload(metrics: ["failure_rate": "0.5", "detector": "ci_waste"])),
            makeRow(id: "b", payload: BurnBarInboxItemPayload(metrics: ["failure_rate": "0.25", "detector": "ci_waste"]))
        ])

        let byKey = Dictionary(uniqueKeysWithValues: digest.payload.metrics.map { ($0.key, $0) })
        XCTAssertEqual(byKey["failure_rate"]?.total, 0.75)
        XCTAssertNil(byKey["detector"]?.total, "a non-numeric metric has no total, not a partial one")
        XCTAssertEqual(byKey["detector"]?.rowCount, 2, "…but it is still known to appear twice")
    }

    /// Citations without a timestamp exist. They sort last, deterministically,
    /// rather than shuffling between renders.
    func test_payload_undatedEvidenceSortsLastAndStably() {
        let digest = HomeInboxDigest(rows: [
            makeRow(id: "a", payload: BurnBarInboxItemPayload(evidence: [
                makeEvidence(id: "zeta", occurredAt: nil),
                makeEvidence(id: "alpha", occurredAt: nil),
                makeEvidence(id: "dated", occurredAt: now - 86_400)
            ]))
        ])

        XCTAssertEqual(digest.payload.evidence.map(\.id), ["dated", "alpha", "zeta"])
    }

    /// First run: no rows, so no evidence — never a "0 findings verified" claim
    /// dressed up as a verified zero.
    func test_payload_isEmptyOnAnEmptyInbox() {
        let digest = HomeInboxDigest(rows: [])
        XCTAssertEqual(digest.payload, HomeInboxPayloadDigest.empty)
        XCTAssertTrue(digest.payload.evidence.isEmpty)
        XCTAssertTrue(digest.payload.actions.isEmpty)
        XCTAssertTrue(digest.payload.metrics.isEmpty)
        XCTAssertNil(digest.payload.leadAction)
        XCTAssertEqual(digest.payload.corroboratedCount, 0)
        XCTAssertEqual(digest.payload.unverifiedRowCount, 0)
        XCTAssertEqual(digest.payload.memoryCandidateCount, 0)
    }

    // MARK: - Spend

    func test_spend_copiesTheWindowAndDerivesCacheHitRate() {
        let signal = HomeSpendSignal(
            cost: 12,
            tokens: 4_000,
            sessionCount: 6,
            activeProviderCount: 3,
            rollingDailyAverage: 8,
            cacheHitRate: CacheEfficiency(inputTokens: 100, cacheCreationTokens: 100, cacheReadTokens: 300).hitRate
        )

        XCTAssertEqual(signal.cost, 12)
        XCTAssertEqual(signal.tokens, 4_000)
        XCTAssertEqual(signal.sessionCount, 6)
        XCTAssertEqual(signal.activeProviderCount, 3)
        XCTAssertEqual(try XCTUnwrap(signal.cacheHitRate), 0.6, accuracy: 0.0001)
        XCTAssertTrue(signal.hasSpend)
    }

    /// The one piece of arithmetic on this surface: today against a typical day.
    func test_spend_deltaVsTypicalDayIsSignedAndNilWithoutABaseline() throws {
        let above = HomeSpendSignal(
            cost: 12, tokens: 0, sessionCount: 1, activeProviderCount: 1,
            rollingDailyAverage: 8, cacheHitRate: nil
        )
        XCTAssertEqual(try XCTUnwrap(above.deltaVsTypicalDay), 0.5, accuracy: 0.0001)

        let below = HomeSpendSignal(
            cost: 4, tokens: 0, sessionCount: 1, activeProviderCount: 1,
            rollingDailyAverage: 8, cacheHitRate: nil
        )
        XCTAssertEqual(try XCTUnwrap(below.deltaVsTypicalDay), -0.5, accuracy: 0.0001)

        // A first run has no typical day. Dividing by zero here is how a
        // launch screen tells a brand new user they are 100% over budget.
        let firstRun = HomeSpendSignal(
            cost: 4, tokens: 0, sessionCount: 1, activeProviderCount: 1,
            rollingDailyAverage: 0, cacheHitRate: nil
        )
        XCTAssertNil(firstRun.deltaVsTypicalDay)
        XCTAssertNil(
            HomeSpendSignal(
                cost: 0, tokens: 0, sessionCount: 0, activeProviderCount: 0,
                rollingDailyAverage: 0, cacheHitRate: nil
            ).deltaVsTypicalDay
        )
    }

    func test_spend_hasSpendIsFalseOnAQuietWindow() {
        let quiet = HomeSpendSignal(
            cost: 0, tokens: 0, sessionCount: 0, activeProviderCount: 0,
            rollingDailyAverage: 9, cacheHitRate: nil
        )
        XCTAssertFalse(quiet.hasSpend)
    }

    // MARK: - Quota

    func test_quota_derivesTheFleetWinnerAndOneWindowPerProvider() throws {
        let signal = HomeQuotaSignal.derive(
            from: [
                makeSnapshot(provider: "Claude Code", buckets: [
                    makeBucket(key: "weekly", label: "weekly", usedPercent: 20),
                    makeBucket(key: "5h", label: "5-hour window", usedPercent: 82)
                ]),
                makeSnapshot(provider: "Codex", buckets: [
                    makeBucket(key: "weekly", label: "weekly", usedPercent: 40)
                ])
            ],
            asOf: now
        )

        let tightest = try XCTUnwrap(signal.tightest)
        XCTAssertEqual(tightest.providerDisplayName, "Claude Code")
        XCTAssertEqual(tightest.windowLabel, "5-hour window")
        XCTAssertEqual(tightest.remainingPercent, 18, accuracy: 0.0001)
        XCTAssertEqual(tightest.pressure, .tightening)
        XCTAssertEqual(tightest.comparedProviderCount, 2, "the claim is counted, not asserted")

        XCTAssertEqual(signal.measuredProviderCount, 2)
        XCTAssertEqual(signal.unmeasuredProviderCount, 0)
        // Tightest provider first, and each entry is that provider's own worst
        // window — not its friendliest one.
        XCTAssertEqual(signal.perProvider.map(\.providerDisplayName), ["Claude Code", "Codex"])
        XCTAssertEqual(signal.perProvider.map(\.windowLabel), ["5-hour window", "weekly"])
        XCTAssertEqual(signal.perProvider.map(\.remainingPercent), [18, 60])
    }

    /// The honesty contract, inherited from `TightestQuotaWindow`: a provider
    /// with no real percentage is counted as unmeasured, never estimated into
    /// the comparison.
    func test_quota_countsProvidersWithNoRealPercentageAsUnmeasured() {
        let tokenPool = makeBucket(
            key: "token-pool",
            label: "token pool",
            windowKind: .custom,
            usedValue: 1_000,
            limitValue: nil,
            remainingValue: nil,
            usedPercent: nil,
            unit: .tokens
        )
        let signal = HomeQuotaSignal.derive(
            from: [
                makeSnapshot(provider: "Claude Code", buckets: [makeBucket(usedPercent: 30)]),
                makeSnapshot(provider: "Ollama", buckets: [tokenPool])
            ],
            asOf: now
        )

        XCTAssertEqual(signal.measuredProviderCount, 1)
        XCTAssertEqual(signal.unmeasuredProviderCount, 1)
        XCTAssertEqual(signal.tightest?.providerDisplayName, "Claude Code")
        XCTAssertEqual(signal.tightest?.comparedProviderCount, 1)
    }

    /// Snapshots exist but none of them can be measured: the signal is present
    /// (so a shell can say "2 agents, headroom unknown") and `tightest` is nil.
    func test_quota_signalSurvivesWithNoMeasurableWindowAnywhere() {
        let unmeasurable = makeBucket(
            key: "sessions",
            label: "sessions",
            windowKind: .custom,
            usedValue: 3,
            limitValue: nil,
            remainingValue: nil,
            usedPercent: nil,
            unit: .sessions
        )
        let signal = HomeQuotaSignal.derive(
            from: [makeSnapshot(provider: "Aider", buckets: [unmeasurable])],
            asOf: now
        )

        XCTAssertNil(signal.tightest)
        XCTAssertTrue(signal.perProvider.isEmpty)
        XCTAssertEqual(signal.unmeasuredProviderCount, 1)
    }

    /// A `.low`/`.stale` snapshot, or a bucket the adapter flagged, must carry
    /// the dagger forward — the UI is required to render it visibly.
    func test_quota_carriesTheEstimatedFlagForward() throws {
        let signal = HomeQuotaSignal.derive(
            from: [makeSnapshot(provider: "Factory", confidence: .low, buckets: [makeBucket(usedPercent: 70)])],
            asOf: now
        )
        XCTAssertTrue(try XCTUnwrap(signal.tightest).isEstimated)
    }

    // MARK: - Fleet

    func test_fleet_countsLivenessWithoutInventingIdle() {
        let signal = HomeFleetSignal(
            rows: [
                makeFleetRow(provider: .claudeCode, liveness: .wroteRecently(at: now, source: .sessionLogWrite("a.jsonl"))),
                makeFleetRow(provider: .codex, liveness: .quietSince(now - 3600, source: .parsedUsageRow)),
                makeFleetRow(provider: .cursor, liveness: .blocked(.exhausted)),
                makeFleetRow(provider: .aider, liveness: .unobservable(reason: "sandboxed build")),
                makeFleetRow(provider: .goose, liveness: .standingBy)
            ],
            hasRealTimeCoverage: true,
            lastScanAt: now,
            sleepGapReason: nil
        )

        XCTAssertEqual(signal.total, 5)
        XCTAssertEqual(signal.activeCount, 1, "only an observed recent write counts as active")
        XCTAssertEqual(signal.blockedCount, 1)
        XCTAssertEqual(signal.unobservableCount, 1)
        // Two rows carry evidence; only the watcher write is real-time.
        XCTAssertEqual(signal.realTimeCoverage, 0.2, accuracy: 0.0001)
        XCTAssertTrue(signal.hasRealTimeCoverage)
        XCTAssertEqual(signal.lastScanAt, now)
        XCTAssertNil(signal.sleepGapReason)
    }

    /// The count Home shows must be the count the rail shows.
    func test_fleet_activeCountMatchesLiveFleetModelsOwnDefinition() {
        let rows = [
            makeFleetRow(provider: .claudeCode, liveness: .workingHere(.streaming(since: now), location: "Tab 2")),
            // `.ready` is a pane sitting idle — present, but not working.
            makeFleetRow(provider: .codex, liveness: .workingHere(.ready, location: nil)),
            makeFleetRow(provider: .cursor, liveness: .wroteRecently(at: now, source: .parsedUsageRow))
        ]
        let signal = HomeFleetSignal(
            rows: rows, hasRealTimeCoverage: false, lastScanAt: nil, sleepGapReason: nil
        )
        XCTAssertEqual(signal.activeCount, rows.filter(\.liveness.isActive).count)
        XCTAssertEqual(signal.activeCount, 2)
    }

    /// No agents configured is a real state, and every ratio over it is 0
    /// rather than a division by zero.
    func test_fleet_emptyFleetReportsZeroesNotNaN() {
        XCTAssertEqual(HomeFleetSignal.empty.total, 0)
        XCTAssertEqual(HomeFleetSignal.empty.activeCount, 0)
        XCTAssertEqual(HomeFleetSignal.empty.blockedCount, 0)
        XCTAssertEqual(HomeFleetSignal.empty.unobservableCount, 0)
        XCTAssertEqual(HomeFleetSignal.empty.realTimeCoverage, 0)
        XCTAssertFalse(HomeFleetSignal.empty.hasRealTimeCoverage)
    }

    // MARK: - Projects, providers, harness

    func test_projects_rankByCostWithSharesThatSumToTheWindow() {
        let ranked = HomeProjectSignal.rank(
            [makeProjectSummary(name: "docs", cost: 1), makeProjectSummary(name: "burnbar", cost: 3)],
            totalCost: 4
        )

        XCTAssertEqual(ranked.map(\.projectName), ["burnbar", "docs"])
        XCTAssertEqual(ranked.map(\.costShare), [0.75, 0.25])
        XCTAssertEqual(ranked.map(\.id), ["burnbar", "docs"])
    }

    /// A window with rows but no cost (free local models) must not divide by
    /// zero, and must not promote one project to 100%.
    func test_projects_zeroCostWindowGivesEveryProjectAZeroShare() {
        let ranked = HomeProjectSignal.rank(
            [makeProjectSummary(name: "docs", cost: 0), makeProjectSummary(name: "burnbar", cost: 0)],
            totalCost: 0
        )
        XCTAssertEqual(ranked.map(\.costShare), [0, 0])
        // Tied on cost, so the order is alphabetical rather than arbitrary.
        XCTAssertEqual(ranked.map(\.projectName), ["burnbar", "docs"])
    }

    func test_providers_rankByCostAndCarryTheEstimatedFlag() {
        let ranked = HomeProviderSignal.rank(
            [
                makeProviderSummary(provider: .codex, cost: 2, isEstimated: true),
                makeProviderSummary(provider: .claudeCode, cost: 6, isEstimated: false)
            ],
            totalCost: 8
        )

        XCTAssertEqual(ranked.map(\.provider), [.claudeCode, .codex])
        XCTAssertEqual(ranked.map(\.costShare), [0.75, 0.25])
        XCTAssertEqual(ranked.map(\.isEstimated), [false, true])
    }

    /// The harness split nobody has ever shown on Home: `executionSourceKind`
    /// has been on every usage row since v57.
    func test_harness_splitsByExecutionSourceKindAndCountsDistinctSessions() {
        let ranked = HomeHarnessSignal.rank([
            makeUsage(sessionId: "s1", cost: 3, kind: .cli),
            makeUsage(sessionId: "s1", cost: 3, kind: .cli),
            makeUsage(sessionId: "s2", cost: 2, kind: .cli),
            makeUsage(sessionId: "s3", cost: 2, kind: .ide)
        ])

        XCTAssertEqual(ranked.map(\.kind), [.cli, .ide])
        XCTAssertEqual(ranked.map(\.cost), [8, 2])
        // Two sessions for the CLI, not the three rows they emitted.
        XCTAssertEqual(ranked.map(\.sessionCount), [2, 1])
        XCTAssertEqual(ranked.map(\.costShare), [0.8, 0.2])
        XCTAssertEqual(ranked.map(\.id), ["cli", "ide"])
    }

    func test_harness_emptyWindowProducesNoRows() {
        XCTAssertTrue(HomeHarnessSignal.rank([]).isEmpty)
    }

    /// Guards the fixture, not the code: a `TokenUsage` built without an
    /// explicit execution-source id silently ignores the kind it was asked for,
    /// which would turn the split test above into a test of nothing.
    func test_fixture_actuallyStampsTheRequestedKind() {
        XCTAssertEqual(makeUsage(sessionId: "s", cost: 1, kind: .ide).executionSourceKind, .ide)
        XCTAssertEqual(makeUsage(sessionId: "s", cost: 1, kind: .automation).executionSourceKind, .automation)
    }

    // MARK: - Assembly

    func test_derive_assemblesEverySectionFromOneWindow() throws {
        let window = makeWindow(
            usages: [makeUsage(sessionId: "s1", cost: 6, kind: .cli), makeUsage(sessionId: "s2", cost: 2, kind: .ide)],
            totalCost: 8,
            totalTokens: 900,
            sessionCount: 2,
            activeProviderCount: 2,
            providerSummaries: [makeProviderSummary(provider: .claudeCode, cost: 8)],
            projectSpendSummaries: [makeProjectSummary(name: "burnbar", cost: 8)],
            cacheEfficiency: CacheEfficiency(inputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 100)
        )

        let digest = HomeSignalDigest.derive(
            window: window,
            rollingDailyAverage: 4,
            isScanning: false,
            quotaSnapshots: [makeSnapshot(provider: "Claude Code", buckets: [makeBucket(usedPercent: 90)])],
            fleet: HomeFleetSignal(
                rows: [makeFleetRow(provider: .claudeCode, liveness: .wroteRecently(at: now, source: .parsedUsageRow))],
                hasRealTimeCoverage: false,
                lastScanAt: now,
                sleepGapReason: nil
            ),
            asOf: now
        )

        let spend = try XCTUnwrap(digest.spend)
        XCTAssertEqual(spend.cost, 8)
        XCTAssertEqual(spend.tokens, 900)
        XCTAssertEqual(spend.sessionCount, 2)
        XCTAssertEqual(spend.activeProviderCount, 2)
        XCTAssertEqual(try XCTUnwrap(spend.deltaVsTypicalDay), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(spend.cacheHitRate), 0.5, accuracy: 0.0001)

        XCTAssertEqual(try XCTUnwrap(digest.quota).tightest?.remainingPercent, 10)
        XCTAssertEqual(digest.quota?.tightest?.pressure, .critical)
        XCTAssertEqual(digest.fleet.activeCount, 1)
        XCTAssertEqual(digest.projects.map(\.projectName), ["burnbar"])
        XCTAssertEqual(digest.providers.map(\.provider), [.claudeCode])
        XCTAssertEqual(digest.harness.map(\.kind), [.cli, .ide])
        XCTAssertFalse(digest.isUnavailable)
    }

    /// First run, still scanning: "we cannot say yet" is not "$0 today".
    func test_derive_withholdsSpendWhileTheFirstScanIsStillRunning() {
        let scanning = HomeSignalDigest.derive(
            window: .empty,
            rollingDailyAverage: 0,
            isScanning: true,
            quotaSnapshots: [],
            fleet: .empty,
            asOf: now
        )
        XCTAssertNil(scanning.spend, "an unfinished scan has no spend to report, not a zero one")
        XCTAssertNil(scanning.quota)
        XCTAssertTrue(scanning.isUnavailable)
    }

    /// Scan finished and the machine genuinely spent nothing: that IS zero, and
    /// saying so is the honest answer.
    func test_derive_reportsARealZeroOnceTheScanHasFinished() throws {
        let quiet = HomeSignalDigest.derive(
            window: .empty,
            rollingDailyAverage: 3,
            isScanning: false,
            quotaSnapshots: [],
            fleet: .empty,
            asOf: now
        )
        let spend = try XCTUnwrap(quiet.spend)
        XCTAssertEqual(spend.cost, 0)
        XCTAssertFalse(spend.hasSpend)
        XCTAssertNil(spend.cacheHitRate, "no cache basis in the window means no rate, not 0%")
        XCTAssertEqual(try XCTUnwrap(spend.deltaVsTypicalDay), -1.0, accuracy: 0.0001)
    }

    /// Rows arriving before the scan flag clears must still be reported.
    func test_derive_reportsSpendWhileScanningOnceRowsExist() throws {
        let partial = HomeSignalDigest.derive(
            window: makeWindow(usages: [makeUsage(sessionId: "s1", cost: 5, kind: .cli)], totalCost: 5, sessionCount: 1),
            rollingDailyAverage: 0,
            isScanning: true,
            quotaSnapshots: [],
            fleet: .empty,
            asOf: now
        )
        XCTAssertEqual(try XCTUnwrap(partial.spend).cost, 5)
    }

    /// No provider has published a snapshot at all — a different state from
    /// "snapshots exist but none can be measured", and both must be reachable.
    func test_derive_quotaIsNilWhenNoProviderHasPublishedASnapshot() {
        let digest = HomeSignalDigest.derive(
            window: .empty,
            rollingDailyAverage: 0,
            isScanning: false,
            quotaSnapshots: [],
            fleet: .empty,
            asOf: now
        )
        XCTAssertNil(digest.quota)
    }

    // MARK: - Wiring

    /// The additive contract: the inbox-only initializer still compiles, still
    /// means what it meant, and reads unknown rather than zero for everything
    /// it was never given.
    func test_inboxOnlyInitializerCarriesTheUnavailablePlaceholder() {
        let digest = HomeInboxDigest(rows: [makeRow(id: "a")])
        XCTAssertEqual(digest.signals, HomeSignalDigest.unavailable)
        XCTAssertTrue(digest.signals.isUnavailable)
        XCTAssertNil(digest.signals.spend)
        XCTAssertNil(digest.signals.quota)
        XCTAssertEqual(digest.signals.fleet, HomeFleetSignal.empty)
        XCTAssertTrue(digest.signals.projects.isEmpty)
        XCTAssertTrue(digest.signals.providers.isEmpty)
        XCTAssertTrue(digest.signals.harness.isEmpty)
    }

    /// The digest is a value derived once per render pass, so two derivations
    /// over identical inputs must compare equal — that equality is what lets
    /// SwiftUI skip a redraw instead of re-rendering eight shells per tick.
    func test_digestIsAPureValueOverItsInputs() {
        let window = makeWindow(
            usages: [makeUsage(sessionId: "s1", cost: 4, kind: .cli)],
            totalCost: 4,
            sessionCount: 1,
            activeProviderCount: 1
        )
        let snapshots = [makeSnapshot(provider: "Claude Code", buckets: [makeBucket(usedPercent: 50)])]
        let fleet = HomeFleetSignal(
            rows: [makeFleetRow(provider: .claudeCode, liveness: .standingBy)],
            hasRealTimeCoverage: true,
            lastScanAt: now,
            sleepGapReason: nil
        )
        let rows = [makeRow(id: "a", payload: BurnBarInboxItemPayload(actions: [makeAction(id: "act")]))]

        func derive() -> HomeInboxDigest {
            HomeInboxDigest(
                rows: rows,
                signals: .derive(
                    window: window,
                    rollingDailyAverage: 2,
                    isScanning: false,
                    quotaSnapshots: snapshots,
                    fleet: fleet,
                    asOf: now
                )
            )
        }

        XCTAssertEqual(derive(), derive())
    }

    // MARK: - Fixtures

    private func makeRow(
        id: String,
        priority: BurnBarInboxPriority = .p3,
        payload: BurnBarInboxItemPayload = BurnBarInboxItemPayload()
    ) -> ControlPlaneStore.AIInboxRow {
        ControlPlaneStore.AIInboxRow(
            summary: BurnBarInboxItemSummary(
                id: id,
                fingerprint: "fp_\(id)",
                kind: .stuckPR,
                priority: priority,
                state: .new,
                title: "Item \(id)",
                projectName: "burnbar",
                firstSeenAt: now,
                lastSeenAt: now
            ),
            summaryMarkdown: "Body of \(id)",
            payload: payload,
            readAt: nil,
            archivedAt: nil,
            snoozedUntil: nil,
            feedback: nil
        )
    }

    private func makeEvidence(id: String, occurredAt: Date?) -> BurnBarInboxEvidence {
        BurnBarInboxEvidence(id: id, kind: .pullRequest, label: "PR \(id)", occurredAt: occurredAt)
    }

    private func makeAction(id: String, isPrimary: Bool = false) -> BurnBarInboxAction {
        BurnBarInboxAction(id: id, kind: .openURL, title: id, value: "https://example.invalid", isPrimary: isPrimary)
    }

    private func makeMemoryCandidate(id: String) -> BurnBarInboxMemoryCandidate {
        BurnBarInboxMemoryCandidate(
            id: id, text: "A durable fact", kind: "gotcha", confidence: 0.8, citationConversationIDs: []
        )
    }

    private func makeVerification(_ verdict: BurnBarInboxVerification.Verdict) -> BurnBarInboxVerification {
        BurnBarInboxVerification(verdict: verdict, checkedAt: now)
    }

    private func makeBucket(
        key: String = "weekly",
        label: String = "weekly",
        windowKind: ProviderQuotaWindowKind = .weekly,
        usedValue: Double? = nil,
        limitValue: Double? = nil,
        remainingValue: Double? = nil,
        usedPercent: Double? = nil,
        unit: ProviderQuotaUnit = .percent,
        isEstimated: Bool = false
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: usedValue,
            limitValue: limitValue,
            remainingValue: remainingValue,
            usedPercent: usedPercent,
            resetsAt: nil,
            unit: unit,
            isEstimated: isEstimated
        )
    }

    private func makeSnapshot(
        provider: String,
        confidence: ProviderQuotaConfidence = .high,
        buckets: [ProviderQuotaBucket]
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "snap-\(provider)",
            provider: provider,
            providerID: ProviderID(rawValue: provider),
            sourceKind: .provider,
            sourceId: "source-\(provider)",
            fetchedAt: now,
            source: "test",
            confidence: confidence,
            buckets: buckets,
            updatedAt: now
        )
    }

    private func makeFleetRow(provider: AgentProvider, liveness: FleetLiveness) -> FleetAgentRow {
        FleetAgentRow(provider: provider, backend: nil, liveness: liveness, context: nil)
    }

    /// `TokenUsage.init` routes the execution source through
    /// `UsageExecutionSourceResolver`, which **ignores an explicit kind unless an
    /// explicit source id comes with it**: a `.providerLog` row without an id is
    /// stamped with the provider's own inferred harness instead. Without the id
    /// below, every fixture here collapses onto `.cli` and the harness split
    /// silently tests nothing — so `test_fixture_actuallyStampsTheRequestedKind`
    /// pins it.
    private func makeUsage(
        sessionId: String,
        cost: Double,
        kind: UsageExecutionSourceKind
    ) -> TokenUsage {
        TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "burnbar",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: cost,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            executionSourceID: "harness-\(kind.rawValue)",
            executionSourceKind: kind
        )
    }

    private func makeProjectSummary(name: String, cost: Double) -> ProjectSpendSummary {
        ProjectSpendSummary(
            projectName: name,
            totalCost: cost,
            totalTokens: 100,
            totalInputTokens: 60,
            totalOutputTokens: 40,
            sessionCount: 1,
            providerBreakdown: [],
            modelBreakdown: [],
            provenanceConfidence: .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: false,
            cacheEfficiency: .zero
        )
    }

    private func makeProviderSummary(
        provider: AgentProvider,
        cost: Double,
        isEstimated: Bool = false
    ) -> ProviderSummary {
        ProviderSummary(
            provider: provider,
            totalCost: cost,
            totalTokens: 100,
            totalInputTokens: 60,
            totalOutputTokens: 40,
            sessionCount: 1,
            modelBreakdown: [],
            provenanceConfidence: isEstimated ? .highConfidenceEstimate : .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: isEstimated,
            cacheEfficiency: .zero
        )
    }

    private func makeWindow(
        usages: [TokenUsage] = [],
        totalCost: Double = 0,
        totalTokens: Int = 0,
        sessionCount: Int = 0,
        activeProviderCount: Int = 0,
        providerSummaries: [ProviderSummary] = [],
        projectSpendSummaries: [ProjectSpendSummary] = [],
        cacheEfficiency: CacheEfficiency = .zero
    ) -> DashboardUsageWindowSummary {
        DashboardUsageWindowSummary(
            usages: usages,
            totalCost: totalCost,
            totalTokens: totalTokens,
            sessionCount: sessionCount,
            activeProviderCount: activeProviderCount,
            providerSummaries: providerSummaries,
            modelSummaries: [],
            credentialSummaries: [],
            projectSpendSummaries: projectSpendSummaries,
            cacheEfficiency: cacheEfficiency
        )
    }
}
