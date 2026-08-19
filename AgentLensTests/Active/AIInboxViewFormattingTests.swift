import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the pure presentation logic behind the Inbox views — the markdown
/// preview, the kind/priority vocabulary, provenance formatting, the settings
/// copy helpers, the config mutation wrappers — plus the `openburnbar://inbox`
/// deep-link routing. The SwiftUI layout around these helpers is waived in
/// `scripts/diff-coverage.sh`; this suite is the named companion evidence.
@MainActor
final class AIInboxViewFormattingTests: XCTestCase {

    // MARK: - Row preview

    func testPlainPreviewStripsMarkdownAndCollapsesNewlines() {
        XCTAssertEqual(
            InboxRowView.plainPreview("**Bold** and `code`.\n\nSecond paragraph.\nSame line. "),
            "Bold and code. Second paragraph. Same line."
        )
        XCTAssertEqual(InboxRowView.plainPreview(""), "")
        XCTAssertEqual(InboxRowView.plainPreview("plain"), "plain")
    }

    // MARK: - Presentation vocabulary

    func testEveryItemKindHasACompletePresentation() {
        for kind in BurnBarInboxItemKind.allCases {
            XCTAssertFalse(InboxPresentation.icon(for: kind).isEmpty, "\(kind) needs an icon")
            XCTAssertFalse(InboxPresentation.kindLabel(kind).isEmpty, "\(kind) needs a label")
            _ = InboxPresentation.tint(for: kind)
        }
        // Spot-check the mappings the product copy depends on.
        XCTAssertEqual(InboxPresentation.icon(for: .ciWaste), "flame")
        XCTAssertEqual(InboxPresentation.kindLabel(.promisedNotLanded), "Possibly unfinished")
        XCTAssertEqual(InboxPresentation.kindLabel(.stuckPR), "Stalled PR")
        XCTAssertEqual(InboxPresentation.kindLabel(.costAnomaly), "Spend anomaly")
    }

    func testPriorityPresentationSpansTheWholeBand() {
        XCTAssertEqual(InboxPresentation.priorityLabel(.p1), "Urgent")
        XCTAssertEqual(InboxPresentation.priorityLabel(.p2), "Today")
        XCTAssertEqual(InboxPresentation.priorityLabel(.p3), "Worth knowing")
        XCTAssertEqual(InboxPresentation.priorityLabel(.p4), "Background")
        XCTAssertNotEqual(
            InboxPresentation.priorityColor(.p1),
            InboxPresentation.priorityColor(.p4),
            "urgent and background must not render alike"
        )
    }

    func testEvidenceAndActionIconsCoverEveryCase() {
        for kind in BurnBarInboxEvidence.Kind.allCases {
            XCTAssertFalse(InboxPresentation.evidenceIcon(for: kind).isEmpty, "\(kind) needs an icon")
        }
        for kind in BurnBarInboxAction.Kind.allCases {
            XCTAssertFalse(InboxPresentation.actionIcon(for: kind).isEmpty, "\(kind) needs an icon")
        }
        XCTAssertEqual(InboxPresentation.evidenceIcon(for: .pullRequest), "arrow.triangle.pull")
        XCTAssertEqual(InboxPresentation.actionIcon(for: .runCommand), "terminal")
    }

    // MARK: - Detail provenance

    func testFriendlyModelNamesDropsProviderPrefixes() {
        XCTAssertEqual(
            InboxItemDetailView.friendlyModelNames("deepseek:deepseek-v4-flash"),
            "deepseek-v4-flash"
        )
        XCTAssertEqual(
            InboxItemDetailView.friendlyModelNames("deepseek:deepseek-v4-flash+openai:gpt-5.6-luna"),
            "deepseek-v4-flash and gpt-5.6-luna"
        )
        XCTAssertEqual(InboxItemDetailView.friendlyModelNames("local-rules"), "local-rules")
    }

    // MARK: - Settings copy

    func testEgressExplanationsAreDistinctAndHonest() {
        let off = AIInboxSettingsView.egressExplanation(.off)
        let local = AIInboxSettingsView.egressExplanation(.local)
        let cloud = AIInboxSettingsView.egressExplanation(.cloud)
        XCTAssertEqual(Set([off, local, cloud]).count, 3)
        XCTAssertTrue(off.contains("No conversation text leaves this Mac"))
        XCTAssertTrue(local.contains("local"))
        XCTAssertTrue(cloud.contains("Redacted excerpts"))
    }

    func testCadenceLabelSwitchesToMinutesAtTwoMinutes() {
        XCTAssertEqual(AIInboxSettingsView.cadenceLabel(60), "60s")
        XCTAssertEqual(AIInboxSettingsView.cadenceLabel(119), "119s")
        XCTAssertEqual(AIInboxSettingsView.cadenceLabel(120), "2 min")
        XCTAssertEqual(AIInboxSettingsView.cadenceLabel(300), "5 min")
    }

    func testRunTintSeparatesSkipsFailuresAndWork() {
        XCTAssertEqual(
            AIInboxSettingsView.runTint(makeRun(gateResult: .skippedUnchanged)),
            AIInboxSettingsView.runTint(makeRun(gateResult: .skippedDisabled))
        )
        XCTAssertNotEqual(
            AIInboxSettingsView.runTint(makeRun(gateResult: .failed)),
            AIInboxSettingsView.runTint(makeRun(gateResult: .localChanged))
        )
        XCTAssertEqual(
            AIInboxSettingsView.runTint(makeRun(gateResult: .remotePhase)),
            AIInboxSettingsView.runTint(makeRun(gateResult: .forced))
        )
    }

    func testRunLabelStatesTheOutcomePlainly() {
        XCTAssertEqual(
            AIInboxSettingsView.runLabel(makeRun(gateResult: .skippedUnchanged)),
            "nothing had changed"
        )
        XCTAssertEqual(
            AIInboxSettingsView.runLabel(makeRun(gateResult: .skippedDisabled)),
            "turned off"
        )
        XCTAssertEqual(
            AIInboxSettingsView.runLabel(makeRun(gateResult: .failed)),
            "failed"
        )
        XCTAssertTrue(
            AIInboxSettingsView.runLabel(makeRun(gateResult: .failed, error: "provider timeout"))
                .hasPrefix("failed — provider timeout")
        )
        XCTAssertEqual(
            AIInboxSettingsView.runLabel(
                makeRun(gateResult: .localChanged, llmCalls: 0, itemsNew: 2, itemsUpdated: 1)
            ),
            "2 new, 1 updated, rule-based (egress off)"
        )
        XCTAssertEqual(
            AIInboxSettingsView.runLabel(
                makeRun(gateResult: .remotePhase, llmCalls: 2, itemsResolved: 3)
            ),
            "3 resolved"
        )
        XCTAssertEqual(
            AIInboxSettingsView.runLabel(makeRun(gateResult: .forced, llmCalls: 4)),
            "analyzed, nothing to report"
        )
    }

    // MARK: - Config mutation wrappers

    func testConfigWithOverridesOnlyTheNamedFieldAndKeepsTheClamps() {
        let base = BurnBarInboxConfig()

        let enabled = base.with(enabled: true)
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.egressMode, base.egressMode)
        XCTAssertEqual(enabled.tickSeconds, base.tickSeconds)
        XCTAssertEqual(enabled.analystModel, base.analystModel)
        XCTAssertEqual(enabled.verifierModel, base.verifierModel)
        XCTAssertEqual(enabled.lookbackMinutes, base.lookbackMinutes)

        let cloud = base.with(egressMode: .cloud)
        XCTAssertEqual(cloud.egressMode, .cloud)
        XCTAssertFalse(cloud.enabled)

        // The rebuilt config re-runs the init clamps.
        XCTAssertEqual(base.with(tickSeconds: 5).tickSeconds, BurnBarInboxConfig.minimumTickSeconds)
        XCTAssertEqual(base.with(dailyBudgetUSD: -3).dailyBudgetUSD, 0)

        let toggles = base.with(githubEnabled: false, notifyOnP1: false)
        XCTAssertFalse(toggles.githubEnabled)
        XCTAssertFalse(toggles.notifyOnP1)
    }

    // MARK: - Deep links

    func testInboxDeepLinkRoutesToTheDashboardInbox() throws {
        let coordinator = NavigationCoordinator()
        let url = try XCTUnwrap(URL(string: "openburnbar://inbox"))

        XCTAssertTrue(coordinator.handleDeepLink(url))
        XCTAssertEqual(coordinator.dashboardRoute, .inbox(itemID: nil))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func testInboxDeepLinkCarriesTheItemID() throws {
        let coordinator = NavigationCoordinator()
        let url = try XCTUnwrap(URL(string: "openburnbar://inbox/inb_42"))

        XCTAssertTrue(coordinator.handleDeepLink(url))
        XCTAssertEqual(coordinator.dashboardRoute, .inbox(itemID: "inb_42"))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func testQuotaDeepLinkRoutesToTheQuotaVault() throws {
        // The pre-limit alert's tap target. If this route dies, the product's
        // core loop ends at a notification with nowhere to land.
        let coordinator = NavigationCoordinator()
        let url = try XCTUnwrap(URL(string: "openburnbar://quota"))

        XCTAssertTrue(coordinator.handleDeepLink(url))
        XCTAssertEqual(coordinator.dashboardRoute, .quota)
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func testForeignSchemesAndUnknownHostsAreDeclined() throws {
        let coordinator = NavigationCoordinator()

        let https = try XCTUnwrap(URL(string: "https://inbox/inb_1"))
        XCTAssertFalse(coordinator.handleDeepLink(https))

        let unknownHost = try XCTUnwrap(URL(string: "openburnbar://not-a-surface"))
        XCTAssertFalse(coordinator.handleDeepLink(unknownHost))

        XCTAssertNil(coordinator.dashboardRoute)
        XCTAssertNil(coordinator.pendingNavigation)
    }

    // MARK: - Settings unavailable copy

    func testFriendlyUnavailableSurfacesAuthAndConnectDistinctly() {
        XCTAssertTrue(
            AIInboxSettingsModel.friendlyUnavailable(
                OpenBurnBarDaemonManagerError.rpcError("Unauthorized OpenBurnBar RPC request.")
            ).localizedCaseInsensitiveContains("authenticate")
        )
        XCTAssertTrue(
            AIInboxSettingsModel.friendlyUnavailable(
                OpenBurnBarDaemonManagerError.rpcError("Daemon socket connect failed: Connection refused")
            ).localizedCaseInsensitiveContains("not running")
        )
        XCTAssertTrue(
            AIInboxSettingsModel.friendlyUnavailable(
                OpenBurnBarDaemonManagerError.emptyResponse
            ).localizedCaseInsensitiveContains("code-signature")
        )
        XCTAssertTrue(
            AIInboxSettingsModel.friendlyUnavailable(
                OpenBurnBarDaemonManagerError.rpcTimedOut(seconds: 30)
            ).localizedCaseInsensitiveContains("time")
        )
        XCTAssertTrue(
            AIInboxSettingsModel.friendlyUnavailable(
                OpenBurnBarDaemonManagerError.rpcError(
                    "Failed to apply SQLCipher key to the daemon database: file is not a database"
                )
            ).localizedCaseInsensitiveContains("unlock the encrypted index")
        )
        XCTAssertTrue(
            AIInboxSettingsModel.friendlyUnavailable(
                OpenBurnBarDaemonManagerError.rpcError("Failed to open AI Inbox SQLite database: database is locked")
            ).localizedCaseInsensitiveContains("busy")
        )
    }

    // MARK: - Helpers

    private func makeRun(
        gateResult: BurnBarInboxRunTelemetry.GateResult,
        llmCalls: Int = 0,
        itemsNew: Int = 0,
        itemsUpdated: Int = 0,
        itemsResolved: Int = 0,
        error: String? = nil
    ) -> BurnBarInboxRunTelemetry {
        BurnBarInboxRunTelemetry(
            tickID: "tick-\(gateResult.rawValue)",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            gateResult: gateResult,
            egressMode: .off,
            llmCalls: llmCalls,
            itemsNew: itemsNew,
            itemsUpdated: itemsUpdated,
            itemsResolved: itemsResolved,
            error: error
        )
    }
}
