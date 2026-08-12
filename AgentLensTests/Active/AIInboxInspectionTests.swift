import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the pure inspection layer behind the AI Inbox detail pane: metric
/// humanizing, per-unit formatting, drill-through resolution, action readiness,
/// and occurrence arithmetic.
///
/// This is the named companion evidence for the SwiftUI layout that consumes it
/// (waived in `scripts/diff-coverage.sh`), and the regression guard for the two
/// presentation bugs this work fixed: a raw metric key rendered as a label
/// ("Spend usd") and money rendered to three decimals ("$90.964").
@MainActor
final class AIInboxInspectionTests: XCTestCase {

    // MARK: - Label humanizing

    func testCuratedLabelsNeverLeakARawKey() {
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "spend_usd"), "Spend")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "with_messages"), "With messages")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "dirty_workspaces"), "Dirty workspaces")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "sessions"), "Sessions")

        // The bug in the screenshot: the unit suffix rendered as a word.
        XCTAssertFalse(InboxMetricInspector.humanizedLabel(for: "spend_usd").contains("usd"))
        XCTAssertFalse(InboxMetricInspector.humanizedLabel(for: "spend_usd").lowercased().contains("usd"))
    }

    func testGenericHumanizerStripsUnitsAndRespectsAcronyms() {
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "ci_failure_rate"), "CI failure rate")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "queued_minutes"), "Queued")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "retry_count"), "Retry")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "api_calls"), "API calls")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "wasted_ms"), "Wasted")
    }

    func testHumanizerKeepsAKeyThatIsNothingButAUnit() {
        // Stripping would leave an empty label, so the token survives.
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: "usd"), "USD")
        XCTAssertEqual(InboxMetricInspector.humanizedLabel(for: ""), "")
    }

    // MARK: - Value formatting

    func testMoneyNeverRendersThreeDecimals() {
        // The exact value from the reported screenshot.
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "spend_usd", rawValue: "90.964"), "$90.96")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "spend_usd", rawValue: "90.9678"), "$90.97")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "spend_usd", rawValue: "0"), "$0.00")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "spend_usd", rawValue: "1234.5"), "$1,234.50")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "spend_usd", rawValue: "-2.5"), "-$2.50")
    }

    func testSubCentSpendStaysVisibleInsteadOfRoundingToZero() {
        // Rounding a real charge to "$0.00" would read as "free"; four decimals
        // below a cent is the same rule the rest of the app uses.
        XCTAssertEqual(InboxMetricInspector.currency(0.0042), "$0.0042")
        XCTAssertEqual(InboxMetricInspector.currency(0), "$0.00")
    }

    func testCountsCarryThousandsSeparators() {
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "sessions", rawValue: "16"), "16")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "sessions", rawValue: "1204"), "1,204")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "messages", rawValue: "1048576"), "1,048,576")
    }

    func testRatesRenderAsPercentages() {
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "waste_rate", rawValue: "0.95"), "95%")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "failure_rate", rawValue: "0.043"), "4.3%")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "coverage_pct", rawValue: "72"), "72%")
    }

    func testDurationsRenderAsHumanSpans() {
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "wasted_minutes", rawValue: "45"), "45m")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "wasted_minutes", rawValue: "192"), "3h 12m")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "wasted_minutes", rawValue: "180"), "3h")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "idle_days", rawValue: "2.25"), "2d 6h")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "build_seconds", rawValue: "42"), "42s")
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "latency_ms", rawValue: "820"), "820ms")
    }

    func testNonNumericMetricsSurviveUntouched() {
        XCTAssertEqual(InboxMetricInspector.formattedValue(key: "branch", rawValue: "main"), "main")
        XCTAssertEqual(InboxMetricInspector.unit(for: "branch", rawValue: "main"), .text)
    }

    // MARK: - Metric assembly

    func testMetricsAreHumanizedFormattedAndOrderedWithMoneyFirst() {
        let payload = BurnBarInboxItemPayload(
            evidence: Self.briefEvidence(),
            metrics: [
                "sessions": "16",
                "with_messages": "12",
                "projects": "3",
                "dirty_workspaces": "1",
                "spend_usd": "90.964",
                "calibration_note": "Costs are estimated from token counts."
            ]
        )
        let metrics = InboxMetricInspector.metrics(payload: payload, summary: Self.summary())

        // Prose is not a stat chip.
        XCTAssertFalse(metrics.contains { $0.key == "calibration_note" })
        XCTAssertEqual(metrics.count, 5)
        XCTAssertEqual(metrics.first?.key, "spend_usd", "money leads the block")
        XCTAssertEqual(metrics.first?.label, "Spend")
        XCTAssertEqual(metrics.first?.value, "$90.96")

        // Every metric explains itself, whether or not it has rows.
        for metric in metrics {
            XCTAssertFalse(metric.explanation.isEmpty, "\(metric.key) must explain itself in words")
            XCTAssertFalse(metric.label.contains("_"), "\(metric.key) leaked a raw key into its label")
        }
    }

    func testSessionsDrillsThroughToEveryCitedConversation() throws {
        let payload = BurnBarInboxItemPayload(evidence: Self.briefEvidence(), metrics: ["sessions": "16"])
        let sessions = try XCTUnwrap(
            InboxMetricInspector.metrics(payload: payload, summary: Self.summary())
                .first { $0.key == "sessions" }
        )
        XCTAssertEqual(sessions.rows.count, 2)
        XCTAssertEqual(sessions.rows.first?.target, .sessionLog(conversationID: "d5cda153"))
        // 2 rows for a count of 16 — the gap is stated, never hidden.
        XCTAssertEqual(sessions.coverageNote, "2 of 16 are cited here — items carry a capped set of citations.")
    }

    func testWithMessagesExcludesEmptyShells() {
        let payload = BurnBarInboxItemPayload(
            evidence: Self.briefEvidence(),
            metrics: ["sessions": "16", "with_messages": "12"]
        )
        let metrics = InboxMetricInspector.metrics(payload: payload, summary: Self.summary())
        let withMessages = metrics.first { $0.key == "with_messages" }
        XCTAssertEqual(withMessages?.rows.count, 1, "the empty shell is not a session with messages")
        XCTAssertEqual(withMessages?.rows.first?.id, "conv:d5cda153")
        XCTAssertTrue(withMessages?.explanation.contains("4 of 16") ?? false, "the shell count is spelled out")
    }

    func testDirtyWorkspaceReachesTheFolderOnDisk() {
        let payload = BurnBarInboxItemPayload(evidence: Self.briefEvidence(), metrics: ["dirty_workspaces": "1"])
        let metric = InboxMetricInspector.metrics(payload: payload, summary: Self.summary())
            .first { $0.key == "dirty_workspaces" }
        XCTAssertEqual(metric?.rows.count, 1)
        XCTAssertEqual(metric?.rows.first?.target, .reveal(path: "/Users/dev/Code/BurnBar"))
        XCTAssertNil(metric?.coverageNote, "a complete breakdown needs no apology")
    }

    func testSpendBreaksDownByModelAndProjectAndReachesCharts() throws {
        let payload = BurnBarInboxItemPayload(evidence: Self.briefEvidence(), metrics: ["spend_usd": "90.964"])
        let metric = try XCTUnwrap(
            InboxMetricInspector.metrics(payload: payload, summary: Self.summary())
                .first { $0.key == "spend_usd" }
        )
        XCTAssertEqual(metric.target, .charts)
        XCTAssertEqual(metric.rows.count, 2)
        // Ranked by contribution, with an honest share of the itemized subtotal.
        let top = try XCTUnwrap(metric.rows.first)
        XCTAssertEqual(top.title, "gpt-5.6-luna in BurnBar")
        XCTAssertEqual(try XCTUnwrap(top.share), 60.0 / 75.0, accuracy: 0.001)
        XCTAssertEqual(top.target, .charts)
    }

    func testProjectsNameWhatTheyCanAndAdmitTheRest() {
        let payload = BurnBarInboxItemPayload(evidence: Self.briefEvidence(), metrics: ["projects": "3"])
        let metric = InboxMetricInspector.metrics(payload: payload, summary: Self.summary())
            .first { $0.key == "projects" }
        let titles = metric?.rows.map(\.title) ?? []
        XCTAssertEqual(titles, ["BurnBar", "DataJockey"], "named once each, from spend and from disk")
        XCTAssertNotNil(metric?.coverageNote, "2 named against a count of 3 must be disclosed")
    }

    func testAMetricWithNoBreakdownStillExplainsItself() throws {
        let payload = BurnBarInboxItemPayload(evidence: [], metrics: ["queued_minutes": "192"])
        let metric = try XCTUnwrap(
            InboxMetricInspector.metrics(payload: payload, summary: Self.summary()).first
        )
        XCTAssertEqual(metric.label, "Queued")
        XCTAssertEqual(metric.value, "3h 12m")
        XCTAssertTrue(metric.rows.isEmpty)
        XCTAssertNil(metric.coverageNote)
        XCTAssertFalse(metric.explanation.isEmpty, "a mute number is the bug; words are the floor")
    }

    // MARK: - Detail parsing

    func testMessageCountParsingIsToleratedNotGuessed() {
        XCTAssertEqual(InboxMetricInspector.messageCount(fromDetail: "Claude Code · 341 messages"), 341)
        XCTAssertEqual(InboxMetricInspector.messageCount(fromDetail: "Claude Code · 1 message"), 1)
        XCTAssertEqual(InboxMetricInspector.messageCount(fromDetail: "Factory · empty shell (not indexed yet)"), 0)
        XCTAssertNil(InboxMetricInspector.messageCount(fromDetail: "no numbers here"))
        XCTAssertNil(InboxMetricInspector.messageCount(fromDetail: nil))
    }

    func testCostParsingHandlesGroupedThousands() {
        XCTAssertEqual(InboxMetricInspector.cost(fromDetail: "12 calls · $4.20"), 4.20)
        XCTAssertEqual(InboxMetricInspector.cost(fromDetail: "9 calls · $1,234.56"), 1234.56)
        XCTAssertNil(InboxMetricInspector.cost(fromDetail: "9 calls"))
        XCTAssertNil(InboxMetricInspector.cost(fromDetail: nil))
    }

    func testProjectNameParsingTakesTheLastSeparator() {
        XCTAssertEqual(InboxMetricInspector.projectName(fromUsageLabel: "gpt-5.6-luna in BurnBar"), "BurnBar")
        XCTAssertEqual(
            InboxMetricInspector.projectName(fromUsageLabel: "model in a box in DataJockey"),
            "DataJockey"
        )
        XCTAssertNil(InboxMetricInspector.projectName(fromUsageLabel: "gpt-5.6-luna"))
    }

    // MARK: - Evidence targets

    func testEvidenceTargetsResolveEveryReachableShape() {
        XCTAssertEqual(
            InboxEvidenceInspector.target(for: Self.conversation(id: "conv:abc", url: "openburnbar://sessions/abc")),
            .sessionLog(conversationID: "abc")
        )
        XCTAssertEqual(
            InboxEvidenceInspector.target(
                for: BurnBarInboxEvidence(id: "pr:o/r#1", kind: .pullRequest, label: "#1", url: "https://x.test/1")
            ),
            .web(url: "https://x.test/1")
        )
        // Previously dead in the UI: no url, but the id carries the real path.
        XCTAssertEqual(
            InboxEvidenceInspector.target(
                for: BurnBarInboxEvidence(id: "workspace:/tmp/repo", kind: .file, label: "repo")
            ),
            .reveal(path: "/tmp/repo")
        )
        // Also previously dead: spend has a home on the Charts surface.
        XCTAssertEqual(
            InboxEvidenceInspector.target(
                for: BurnBarInboxEvidence(id: "usage:P:M", kind: .usage, label: "M in P")
            ),
            .charts
        )
    }

    func testUnreachableEvidenceGetsAReasonRatherThanADeadControl() {
        let evidence = BurnBarInboxEvidence(id: "sha:abc123", kind: .commit, label: "abc123")
        XCTAssertEqual(InboxEvidenceInspector.target(for: evidence), .none)
        XCTAssertFalse(InboxEvidenceInspector.inertReason(for: evidence).isEmpty)
        XCTAssertNil(InboxDrillTarget.none.activationLabel)
    }

    func testUnsupportedSchemesAreNotTreatedAsWebLinks() {
        // A `file://` or `javascript:` url must never route through the browser.
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.test", ""] {
            let evidence = BurnBarInboxEvidence(id: "e", kind: .issue, label: "l", url: raw)
            XCTAssertEqual(InboxEvidenceInspector.target(for: evidence), .none, "\(raw) must not be openable")
        }
    }

    func testTruncationLikelihoodDrivesTheDisclosureCue() {
        let long = "find and resume: d5cda153-0f1e-4a2b-9c8d-7e6f5a4b3c2d — Zenith validation lane"
        XCTAssertTrue(InboxEvidenceInspector.isTruncationLikely(long))
        XCTAssertFalse(InboxEvidenceInspector.isTruncationLikely("short label"))
    }

    func testEveryReachableTargetNamesItsOutcomeBeforeTheClick() {
        let targets: [InboxDrillTarget] = [
            .sessionLog(conversationID: "a"), .web(url: "https://x.test"), .reveal(path: "/tmp"), .charts
        ]
        for target in targets {
            XCTAssertNotNil(target.activationLabel, "\(target) must say what it does")
            XCTAssertFalse(target.symbol.isEmpty)
            XCTAssertTrue(target.isReachable)
        }
    }

    // MARK: - Action readiness

    func testRunCommandNeverPromisesToExecute() {
        let action = BurnBarInboxAction(id: "a", kind: .runCommand, title: "Commit the work", value: "git status")
        let readiness = InboxActionInspector.readiness(for: action, settingsAvailable: true, pathExists: { _ in true })
        XCTAssertTrue(readiness.isCopyOnly)
        XCTAssertTrue(readiness.effect.contains("Nothing runs"))
        XCTAssertNil(readiness.caution)
    }

    func testDestructiveCommandsAreFlagged() {
        for command in [
            "rm -rf build", "git reset --hard origin/main", "git push --force", "sudo rm x", "DROP TABLE runs"
        ] {
            XCTAssertTrue(InboxActionInspector.looksDestructive(command), "\(command) should be flagged")
        }
        for command in ["git status", "npm test", "xcodebuild build"] {
            XCTAssertFalse(InboxActionInspector.looksDestructive(command), "\(command) should not be flagged")
        }

        let action = BurnBarInboxAction(id: "a", kind: .runCommand, title: "Reset", value: "git reset --hard")
        let readiness = InboxActionInspector.readiness(for: action, settingsAvailable: true, pathExists: { _ in true })
        XCTAssertNotNil(readiness.caution)
        XCTAssertTrue(readiness.isEnabled, "a caution explains, it does not block")
    }

    func testDisabledActionsExplainThemselvesInsteadOfHiding() {
        let badLink = BurnBarInboxAction(id: "a", kind: .openURL, title: "Open", value: "not a url")
        let linkReadiness = InboxActionInspector.readiness(
            for: badLink, settingsAvailable: true, pathExists: { _ in true }
        )
        XCTAssertFalse(linkReadiness.isEnabled)
        XCTAssertNotNil(linkReadiness.disabledReason)

        let goneFolder = BurnBarInboxAction(id: "b", kind: .openProject, title: "Open", value: "~/gone")
        let folderReadiness = InboxActionInspector.readiness(
            for: goneFolder, settingsAvailable: true, pathExists: { _ in false }
        )
        XCTAssertFalse(folderReadiness.isEnabled)
        XCTAssertTrue(folderReadiness.disabledReason?.contains("no longer on disk") ?? false)

        let settings = BurnBarInboxAction(id: "c", kind: .openSettings, title: "Settings", value: "ai-inbox")
        XCTAssertFalse(
            InboxActionInspector.readiness(for: settings, settingsAvailable: false, pathExists: { _ in true })
                .isEnabled
        )
    }

    func testEveryActionKindProducesAnOutcomeSentence() {
        for kind in BurnBarInboxAction.Kind.allCases {
            let action = BurnBarInboxAction(id: kind.rawValue, kind: kind, title: "t", value: "https://x.test/a")
            let readiness = InboxActionInspector.readiness(
                for: action, settingsAvailable: true, pathExists: { _ in true }
            )
            XCTAssertFalse(readiness.effect.isEmpty, "\(kind) must describe its effect")
        }
    }

    func testExactlyOneActionIsPrimary() {
        let actions = [
            BurnBarInboxAction(id: "a", kind: .openSessionLog, title: "Resume", value: "x", isPrimary: true),
            BurnBarInboxAction(id: "b", kind: .runCommand, title: "Commit", value: "git commit", isPrimary: true),
            BurnBarInboxAction(id: "c", kind: .openSettings, title: "Settings", value: "ai")
        ]
        let split = InboxActionInspector.partition(actions)
        XCTAssertEqual(split.primary?.id, "a")
        XCTAssertEqual(split.secondary.map(\.id), ["b", "c"])

        // No explicit primary: the first action leads rather than none.
        let unmarked = [BurnBarInboxAction(id: "z", kind: .openSettings, title: "Settings", value: "ai")]
        XCTAssertEqual(InboxActionInspector.partition(unmarked).primary?.id, "z")
        XCTAssertNil(InboxActionInspector.partition([]).primary)
    }

    // MARK: - Occurrence

    func testOccurrenceSummaryDescribesSpanAndCadence() {
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        let summary = InboxOccurrenceInspector.summarize(
            summary: Self.summary(
                occurrenceCount: 161,
                firstSeenAt: first,
                lastSeenAt: first.addingTimeInterval(22 * 3_600)
            )
        )
        XCTAssertEqual(summary.count, 161)
        XCTAssertEqual(summary.span, "22h")
        XCTAssertEqual(summary.cadence, "about 7 times an hour")
        XCTAssertTrue(summary.explanation.contains("161"))
    }

    func testCadenceStaysSilentWithoutEnoughSignal() {
        XCTAssertNil(InboxOccurrenceInspector.cadence(count: 1, interval: 90_000))
        XCTAssertNil(InboxOccurrenceInspector.cadence(count: 9, interval: 10))
        XCTAssertEqual(InboxOccurrenceInspector.cadence(count: 3, interval: 86_400), "about 3 times a day")
        XCTAssertEqual(InboxOccurrenceInspector.cadence(count: 2, interval: 30 * 86_400), "less than once a day")
    }

    func testSpanNeverGoesNegativeOnASkewedRow() {
        let last = Date(timeIntervalSince1970: 1_780_000_000)
        let summary = InboxOccurrenceInspector.summarize(
            summary: Self.summary(
                occurrenceCount: 4,
                firstSeenAt: last.addingTimeInterval(3_600),
                lastSeenAt: last
            )
        )
        XCTAssertFalse(summary.span.hasPrefix("-"))
    }

    // MARK: - Navigation guard

    func testChartsDrillThroughDowngradesWhereThereIsNoRouter() {
        let routed = InboxDrillNavigator(chartsAvailable: true)
        XCTAssertEqual(routed.resolve(.charts), .charts)

        let detached = InboxDrillNavigator(chartsAvailable: false)
        XCTAssertEqual(detached.resolve(.charts), .none)
        XCTAssertEqual(detached.resolve(.sessionLog(conversationID: "a")), .sessionLog(conversationID: "a"))
    }

    // MARK: - Layout

    func testListPaneYieldsToTheReadingPaneOnNarrowWindows() {
        XCTAssertEqual(InboxView.listPaneWidth(forTotalWidth: 1_600), 380)
        XCTAssertEqual(InboxView.listPaneWidth(forTotalWidth: 1_000), 320)
        XCTAssertEqual(InboxView.listPaneWidth(forTotalWidth: 700), 260)
        XCTAssertEqual(InboxView.listPaneWidth(forTotalWidth: 0), 380, "an unmeasured pane keeps the default")
    }

    // MARK: - Fixtures

    /// Mirrors the real payload shape from the reported screenshot: two cited
    /// conversations (one an empty shell), one dirty workspace, two usage rows.
    private static func briefEvidence() -> [BurnBarInboxEvidence] {
        [
            conversation(
                id: "conv:d5cda153",
                url: "openburnbar://sessions/d5cda153",
                label: "find and resume: d5cda153-0f1e-4a2b-9c8d-7e6f5a4b3c2d",
                detail: "Claude Code · 341 messages"
            ),
            conversation(
                id: "conv:zenith",
                url: "openburnbar://sessions/zenith",
                label: "# Zenith Worker — validation lane",
                detail: "Factory · empty shell (not indexed yet)"
            ),
            BurnBarInboxEvidence(
                id: "workspace:/Users/dev/Code/BurnBar",
                kind: .file,
                label: "~/Code/BurnBar",
                detail: "main · 7 modified, 2 untracked"
            ),
            BurnBarInboxEvidence(
                id: "usage:BurnBar:gpt-5.6-luna",
                kind: .usage,
                label: "gpt-5.6-luna in BurnBar",
                detail: "412 calls · $60.00"
            ),
            BurnBarInboxEvidence(
                id: "usage:DataJockey:deepseek-chat",
                kind: .usage,
                label: "deepseek-chat in DataJockey",
                detail: "88 calls · $15.00"
            )
        ]
    }

    private static func conversation(
        id: String,
        url: String?,
        label: String = "session",
        detail: String? = "Claude Code · 8 messages"
    ) -> BurnBarInboxEvidence {
        BurnBarInboxEvidence(id: id, kind: .conversation, label: label, detail: detail, url: url)
    }

    private static func summary(
        occurrenceCount: Int = 161,
        firstSeenAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_780_079_200)
    ) -> BurnBarInboxItemSummary {
        BurnBarInboxItemSummary(
            id: "inb_1",
            fingerprint: "fp_1",
            kind: .brief,
            priority: .p4,
            state: .updated,
            title: "16 sessions across BurnBar + DataJockey",
            projectID: nil,
            projectName: nil,
            occurrenceCount: occurrenceCount,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            modelProvenance: "openai:gpt-5.6-luna"
        )
    }
}
