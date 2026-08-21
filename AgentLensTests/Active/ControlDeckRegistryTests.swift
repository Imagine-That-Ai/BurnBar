import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Guards the two promises the deck's registry makes:
///
///  1. every shipped tile carries the metadata its chrome depends on, and
///  2. the deck and the Settings sidebar agree about which features this build
///     ships — the drift `OpenBurnBarBuildGates` exists to prevent.
@MainActor
final class ControlDeckRegistryTests: XCTestCase {

    // MARK: Metadata completeness

    func test_everyKindCarriesEditorialCopy() {
        for kind in ControlKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind.rawValue) has no title")
            XCTAssertFalse(kind.whyItMatters.isEmpty, "\(kind.rawValue) has no microcopy")
            XCTAssertFalse(kind.systemImage.isEmpty, "\(kind.rawValue) has no symbol")
            XCTAssertFalse(kind.searchKeywords.isEmpty, "\(kind.rawValue) is unreachable from ⌘K")
        }
    }

    /// The headline budget: at four columns a tile is roughly 274pt wide and the
    /// headline is `lineLimit(1)`. The *title* is the eyebrow, so it must stay
    /// short enough to sit beside a control without truncating.
    func test_titlesFitTheEyebrow() {
        for kind in ControlKind.allCases {
            XCTAssertLessThanOrEqual(kind.title.count, 22, "\(kind.rawValue) title is too long")
        }
    }

    func test_spansAreWithinTheGrid() {
        for kind in ControlKind.allCases {
            XCTAssertGreaterThanOrEqual(kind.defaultSpan, 1, "\(kind.rawValue)")
            XCTAssertLessThanOrEqual(kind.defaultSpan, ControlDeckLayout.maxSpan, "\(kind.rawValue)")
        }
    }

    func test_settingsItemIDsResolveToRealManifestItems() {
        let manifestIDs = Set(SettingsManifest.all.map(\.id))
        for kind in ControlKind.allCases {
            guard let itemID = kind.settingsItemID else { continue }
            XCTAssertTrue(
                manifestIDs.contains(itemID),
                "\(kind.rawValue) deep-links to \"\(itemID)\", which is not in the settings manifest"
            )
        }
    }

    func test_rawValuesAreStableIdentifiers() {
        // The raw value is the persistence key inside `controlDeck.layout.v1`.
        // Renaming one silently drops a user's arrangement for that tile.
        XCTAssertEqual(
            ControlKind.allCases.map(\.rawValue).sorted(),
            [
                "aiInbox", "alerts", "appearance", "charts", "engineRoom", "fleet",
                "memoryMCP", "modelRouter", "pets", "textExpansion", "updates", "wand"
            ]
        )
    }

    /// The six bands are the information architecture, and a band with no tile
    /// is a band the user never learns exists. REACH is the one that has not
    /// shipped a tile yet — its members are the controls that can grant trust
    /// or reach off-device — and `populatedGroups` hides it rather than
    /// rendering an empty header. Any *other* empty band is a bug.
    func test_onlyTheUnshippedReachBandIsEmpty() {
        let empty = ControlGroup.allCases.filter { group in
            ControlKind.visibleKinds.contains { $0.group == group } == false
        }
        XCTAssertEqual(empty, [.reach], "an unexpected band renders nothing")
    }

    /// CAST exists only because Model Router and The Wand landed. Losing either
    /// would silently delete a whole band from the page.
    func test_theCastBandCarriesTheRoutingAndFanOutTiles() {
        XCTAssertEqual(
            ControlKind.visibleKinds.filter { $0.group == .cast },
            [.modelRouter, .wand]
        )
    }

    // MARK: Build-gate parity

    func test_deckAndSettingsAgreeOnUpdatesAvailability() {
        let settingsShowsUpdates = SettingsTab.visibleTabs.contains(.updates)
        let deckShowsUpdates = ControlKind.visibleKinds.contains(.updates)
        XCTAssertEqual(
            settingsShowsUpdates,
            deckShowsUpdates,
            "Settings and the Control Deck disagree about whether this build ships Updates"
        )
        XCTAssertEqual(settingsShowsUpdates, OpenBurnBarBuildGates.updatesAvailable)
    }

    func test_agentControlGateMatchesTheSettingsSidebar() {
        XCTAssertEqual(
            SettingsTab.visibleTabs.contains(.computerUse),
            OpenBurnBarBuildGates.agentControlAvailable
        )
    }

    func test_gatesAgreeWithTheCompiledBuildConfiguration() {
        #if DISTRIBUTION_MAS
        XCTAssertFalse(OpenBurnBarBuildGates.updatesAvailable)
        XCTAssertFalse(OpenBurnBarBuildGates.agentControlAvailable)
        XCTAssertFalse(OpenBurnBarBuildGates.globalTextExpansionAvailable)
        #else
        XCTAssertTrue(OpenBurnBarBuildGates.updatesAvailable)
        XCTAssertTrue(OpenBurnBarBuildGates.agentControlAvailable)
        XCTAssertTrue(OpenBurnBarBuildGates.globalTextExpansionAvailable)
        #endif
    }

    // MARK: Readout

    func test_readoutCountsNothingOnAColdMachine() {
        let readout = ControlDeckReadout(inputs: .init())
        // Appearance has no off state, so it is the only thing on by default.
        XCTAssertEqual(readout.on, [.appearance])
    }

    func test_readoutTreatsEitherExpansionSurfaceAsOn() {
        XCTAssertTrue(
            ControlDeckReadout(inputs: .init(textExpansionInApp: true)).isOn(.textExpansion)
        )
        XCTAssertTrue(
            ControlDeckReadout(inputs: .init(textExpansionEverywhere: true)).isOn(.textExpansion)
        )
        XCTAssertFalse(ControlDeckReadout(inputs: .init()).isOn(.textExpansion))
    }

    func test_readoutTreatsAMissingThresholdAsOff() {
        XCTAssertFalse(ControlDeckReadout(inputs: .init(spendAlertThreshold: nil)).isOn(.alerts))
        XCTAssertTrue(ControlDeckReadout(inputs: .init(spendAlertThreshold: 25)).isOn(.alerts))
    }

    func test_readoutCountsPerBand() {
        let readout = ControlDeckReadout(
            inputs: .init(chartsAIInsights: true, spendAlertThreshold: 25)
        )
        XCTAssertEqual(readout.onCount(in: .spend, among: [.charts, .alerts]), 2)
        XCTAssertEqual(readout.onCount(in: .house, among: [.charts, .alerts]), 0)
    }

    func test_readoutNeverReportsAKindThisBuildDoesNotShip() {
        let readout = ControlDeckReadout(inputs: .init(updatesAutomaticChecks: true))
        if !OpenBurnBarBuildGates.updatesAvailable {
            XCTAssertFalse(readout.isOn(.updates))
        }
    }

    func test_readoutReadsTheDaemonsInboxFlagNotTheAppsWish() {
        XCTAssertFalse(ControlDeckReadout(inputs: .init()).isOn(.aiInbox))
        XCTAssertTrue(ControlDeckReadout(inputs: .init(aiInboxEnabled: true)).isOn(.aiInbox))
    }

    func test_readoutTreatsTheWandAsOnOnlyWhileCasting() {
        XCTAssertFalse(ControlDeckReadout(inputs: .init(wandCastsRunning: 0)).isOn(.wand))
        XCTAssertTrue(ControlDeckReadout(inputs: .init(wandCastsRunning: 2)).isOn(.wand))
    }

    func test_readoutTreatsAnUncheckedMCPRosterAsOff() {
        // Nil is "not read yet", not "nothing connected" — and neither counts
        // as on, because the header must never claim a connection it has not
        // seen.
        XCTAssertFalse(ControlDeckReadout(inputs: .init(memoryMCPConnectedCount: nil)).isOn(.memoryMCP))
        XCTAssertFalse(ControlDeckReadout(inputs: .init(memoryMCPConnectedCount: 0)).isOn(.memoryMCP))
        XCTAssertTrue(ControlDeckReadout(inputs: .init(memoryMCPConnectedCount: 3)).isOn(.memoryMCP))
    }

    func test_readoutReadsTheGatewayPreferenceNotAProbe() {
        // The header count must not depend on a network round trip: a gateway
        // configured on is "on" even while the probe is still in flight.
        XCTAssertTrue(ControlDeckReadout(inputs: .init(modelRouterEnabled: true)).isOn(.modelRouter))
        XCTAssertFalse(ControlDeckReadout(inputs: .init()).isOn(.modelRouter))
    }

    // MARK: - AI Inbox live facts
    //
    // The tile's whole claim is that it renders a fact, never a label. These
    // fixtures are the proof, and the `couldNotRun` case is the one that
    // matters most: a dead analyst is invisible everywhere else in the app.

    func test_inboxHeadlineIsSpendAgainstBudgetWithUnread() {
        let facts = InboxDeckFacts(
            unreadCount: 4,
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud, dailyBudgetUSD: 2.00),
            runs: [],
            todaySpendUSD: 0.62,
            unavailableReason: nil
        )
        XCTAssertEqual(facts.headline, "4 unread · $0.62 of $2.00")
        XCTAssertTrue(facts.isEnabled)
        XCTAssertTrue(facts.isReachable)
        XCTAssertLessThanOrEqual(facts.headline.count, 28, "headline budget")
    }

    func test_inboxKeepsItsLocalCountWhenTheDaemonIsUnreachable() {
        let facts = InboxDeckFacts(
            unreadCount: 4,
            config: nil,
            runs: [],
            todaySpendUSD: nil,
            unavailableReason: "The app could not authenticate to the daemon."
        )
        // Never blank, and never a fake zero: the unread count is a local read
        // that survives a dead daemon.
        XCTAssertEqual(facts.headline, "4 unread · daemon offline")
        XCTAssertFalse(facts.isReachable)
    }

    func test_inboxNeverInventsAZeroUnreadCount() {
        let facts = InboxDeckFacts(
            unreadCount: nil,
            config: nil,
            runs: [],
            todaySpendUSD: nil,
            unavailableReason: nil
        )
        XCTAssertEqual(facts.headline, "Reading the inbox…")
        XCTAssertFalse(facts.headline.contains("0"))
    }

    func test_inboxNamesAnAnalystThatCouldNotRun() {
        // The signature of the bug this tile exists to surface: a substantive
        // tick that produced items while making zero model calls, with egress
        // wide open. The brief the user is reading came from the rule engine.
        let facts = InboxDeckFacts(
            unreadCount: 2,
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud, dailyBudgetUSD: 1.50),
            runs: [Self.run(gate: .localChanged, llmCalls: 0, egress: .cloud)],
            todaySpendUSD: 0,
            unavailableReason: nil
        )
        XCTAssertEqual(facts.analyst, .couldNotRun)
        XCTAssertTrue(facts.analyst.isAlarming)
        XCTAssertEqual(facts.analyst.label, "Analyst could not run")
    }

    func test_inboxDoesNotCryWolfWhenEgressIsDeliberatelyOff() {
        let facts = InboxDeckFacts(
            unreadCount: 2,
            config: BurnBarInboxConfig(enabled: true, egressMode: .off, dailyBudgetUSD: 1.50),
            runs: [Self.run(gate: .localChanged, llmCalls: 0, egress: .off)],
            todaySpendUSD: 0,
            unavailableReason: nil
        )
        XCTAssertEqual(facts.analyst, .ruleBasedByDesign)
        XCTAssertFalse(facts.analyst.isAlarming, "the setting working is not a fault")
    }

    func test_inboxReportsAHealthyAnalystWithItsCallCount() {
        let facts = InboxDeckFacts(
            unreadCount: 1,
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud, dailyBudgetUSD: 1.50),
            runs: [
                Self.run(gate: .skippedUnchanged, llmCalls: 0, egress: .cloud, minutesAgo: 5),
                Self.run(gate: .remotePhase, llmCalls: 3, egress: .cloud, minutesAgo: 10)
            ],
            todaySpendUSD: 0.04,
            unavailableReason: nil
        )
        // The newest *substantive* tick decides, not the newest skip.
        XCTAssertEqual(facts.analyst, .healthy(calls: 3))
        XCTAssertEqual(facts.skipSummary, "50% of 2 checks idle")
    }

    func test_inboxSurfacesAFailedTickWithTheDaemonsOwnReason() {
        let facts = InboxDeckFacts(
            unreadCount: 0,
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud, dailyBudgetUSD: 1.50),
            runs: [Self.run(gate: .failed, llmCalls: 0, egress: .cloud, error: "analyst provider unreachable")],
            todaySpendUSD: 0,
            unavailableReason: nil
        )
        XCTAssertEqual(facts.analyst, .failed("analyst provider unreachable"))
        XCTAssertTrue(facts.analyst.isAlarming)
    }

    func test_inboxWithOnlySkippedTicksReadsAsIdleNotBroken() {
        let facts = InboxDeckFacts(
            unreadCount: 0,
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud, dailyBudgetUSD: 1.50),
            runs: [Self.run(gate: .skippedUnchanged, llmCalls: 0, egress: .cloud)],
            todaySpendUSD: 0,
            unavailableReason: nil
        )
        XCTAssertEqual(facts.analyst, .idle)
        XCTAssertFalse(facts.analyst.isAlarming)
        XCTAssertEqual(facts.skipSummary, "100% of 1 checks idle")
    }

    private static func run(
        gate: BurnBarInboxRunTelemetry.GateResult,
        llmCalls: Int,
        egress: BurnBarInboxEgressMode,
        minutesAgo: Int = 1,
        error: String? = nil
    ) -> BurnBarInboxRunTelemetry {
        BurnBarInboxRunTelemetry(
            tickID: "tick-\(minutesAgo)-\(gate.rawValue)",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo * 60)),
            gateResult: gate,
            egressMode: egress,
            llmCalls: llmCalls,
            itemsNew: gate == .localChanged || gate == .remotePhase ? 1 : 0,
            error: error
        )
    }

    // MARK: - Model Router live facts

    func test_routerHeadlineCountsTheModelsTheGatewayActuallyServes() {
        let facts = RouterDeckFacts(
            enabled: true,
            host: "127.0.0.1",
            port: 8317,
            tokenConfigured: true,
            allowsUnauthenticatedLoopback: false,
            probe: .served(advertised: 12, total: 18)
        )
        XCTAssertEqual(facts.headline, "12 of 18 models served")
        XCTAssertEqual(facts.endpoint, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(facts.posture, .tokenEnforced)
        XCTAssertLessThanOrEqual(facts.headline.count, 28, "headline budget")
    }

    func test_routerOffStillShowsThePortItWouldServe() {
        let facts = RouterDeckFacts(
            enabled: false,
            host: "",
            port: 0,
            tokenConfigured: false,
            allowsUnauthenticatedLoopback: false,
            probe: nil
        )
        // `.off` is never blank, and an empty host/port falls back to the
        // gateway's own defaults rather than rendering "http://:0/v1".
        XCTAssertEqual(facts.headline, "Gateway off · port 8317")
        XCTAssertEqual(facts.endpoint, "http://127.0.0.1:8317/v1")
        XCTAssertNil(facts.servedModelCount)
    }

    func test_routerSaysSoWhenTheGatewayDoesNotAnswer() {
        let facts = RouterDeckFacts(
            enabled: true,
            host: "127.0.0.1",
            port: 8317,
            tokenConfigured: true,
            allowsUnauthenticatedLoopback: false,
            probe: .failed("Nothing is listening on that port.")
        )
        XCTAssertEqual(facts.headline, "Gateway not answering")
        XCTAssertNil(facts.servedModelCount)
    }

    func test_routerFlagsAnOpenLoopbackAsTheOneAlarmingPosture() {
        let open = RouterDeckFacts(
            enabled: true, host: "127.0.0.1", port: 8317,
            tokenConfigured: true, allowsUnauthenticatedLoopback: true, probe: nil
        )
        XCTAssertEqual(open.posture, .loopbackOpen)
        XCTAssertTrue(open.posture.isAlarming, "any same-host process could spend the user's credits")

        let closed = RouterDeckFacts(
            enabled: true, host: "127.0.0.1", port: 8317,
            tokenConfigured: false, allowsUnauthenticatedLoopback: false, probe: nil
        )
        XCTAssertEqual(closed.posture, .tokenIssuedAtLaunch)
        XCTAssertFalse(closed.posture.isAlarming)
    }

    // MARK: - The Wand live facts

    func test_wandCeilingIsTheRealTierLadder() {
        XCTAssertEqual(Self.wand(tier: .none).ceiling, 1)
        XCTAssertEqual(Self.wand(tier: .cloud).ceiling, 3)
        XCTAssertEqual(Self.wand(tier: .pro).ceiling, 8)
        XCTAssertEqual(Self.wand(tier: .ultra).ceiling, 16)
        XCTAssertEqual(Self.wand(tier: .none).tierLabel, "Free tier")
        XCTAssertEqual(Self.wand(tier: .pro).tierLabel, "Cloud Pro")
    }

    func test_wandHeadlineCountsCastsInFlight() {
        let facts = Self.wand(tier: .pro, casting: 2, totalMissions: 5, burnUSD: 4.12)
        XCTAssertEqual(facts.headline, "8 workers · 2 casting")
        XCTAssertEqual(facts.burnLabel, "$4.12 cast")
        XCTAssertLessThanOrEqual(facts.headline.count, 28, "headline budget")
    }

    func test_wandDistinguishesIdleFromNeverCast() {
        XCTAssertEqual(Self.wand(tier: .pro, totalMissions: 0).headline, "8 workers · nothing cast")
        XCTAssertEqual(Self.wand(tier: .pro, totalMissions: 5).headline, "8 workers · idle")
        XCTAssertEqual(Self.wand(tier: .none, totalMissions: 0).headline, "1 worker · nothing cast")
    }

    private static func wand(
        tier: CloudTier,
        casting: Int = 0,
        totalMissions: Int = 0,
        burnUSD: Double = 0
    ) -> WandDeckFacts {
        WandDeckFacts(
            tier: tier,
            casting: casting,
            awaitingApproval: 0,
            blocked: 0,
            totalMissions: totalMissions,
            burnUSD: burnUSD
        )
    }

    // MARK: - Memory MCP live facts
    //
    // Four different ways to be honestly empty, and the design says each one
    // gets its own sentence.

    func test_mcpSaysWhenCloudIsNotConfiguredOnThisMac() {
        let facts = Self.mcp(cloudConfigured: false, signedIn: false, unlocked: false)
        XCTAssertEqual(facts.availability, .cloudNotConfigured)
        XCTAssertEqual(facts.availability.reason, "Cloud is not configured on this Mac")
        XCTAssertEqual(facts.headline, "Cloud not configured")
        XCTAssertNil(facts.connectedCount)
    }

    func test_mcpSaysWhenNobodyIsSignedIn() {
        let facts = Self.mcp(cloudConfigured: true, signedIn: false, unlocked: false)
        XCTAssertEqual(facts.availability, .signedOut)
        XCTAssertEqual(facts.availability.reason, "Sign in to view connected MCP clients")
        XCTAssertEqual(facts.headline, "Not signed in")
    }

    func test_mcpLocksBehindTheRealHostedMCPTier() {
        let facts = Self.mcp(cloudConfigured: true, signedIn: true, unlocked: false)
        XCTAssertEqual(facts.availability, .tierLocked)
        XCTAssertEqual(facts.headline, "Hosted MCP needs Pro")
        XCTAssertEqual(ControlKind.memoryMCP.gatedFeature, .hostedMCP)
    }

    func test_mcpNeverPretendsToHaveCheckedTheRoster() {
        // The deck refuses to open a Firestore listener on a cold visit, so an
        // unchecked roster says so instead of rendering a zero.
        let facts = Self.mcp(cloudConfigured: true, signedIn: true, unlocked: true)
        XCTAssertEqual(facts.availability, .ready)
        XCTAssertEqual(facts.headline, "Signed in · not checked")
        XCTAssertNil(facts.connectedCount)
        XCTAssertTrue(facts.checkedLabel.isEmpty)
    }

    func test_mcpRendersTheRosterOnceItHasBeenRead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let facts = Self.mcp(
            cloudConfigured: true,
            signedIn: true,
            unlocked: true,
            reading: .init(
                activeCount: 3,
                revokedCount: 1,
                lastUsedAt: now.addingTimeInterval(-7_200),
                checkedAt: now
            ),
            now: now
        )
        XCTAssertEqual(facts.connectedCount, 3)
        XCTAssertTrue(facts.headline.hasPrefix("3 connected · "), facts.headline)
        XCTAssertFalse(facts.checkedLabel.isEmpty, "a stamped reading must say when")
        XCTAssertEqual(facts.endpoint, "https://mcp.burnbar.ai/mcp")
    }

    func test_mcpDistinguishesNoClientsFromNotChecked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let facts = Self.mcp(
            cloudConfigured: true,
            signedIn: true,
            unlocked: true,
            reading: .init(activeCount: 0, revokedCount: 0, lastUsedAt: nil, checkedAt: now),
            now: now
        )
        XCTAssertEqual(facts.headline, "No agents connected")
        XCTAssertEqual(facts.connectedCount, 0)
    }

    private static func mcp(
        cloudConfigured: Bool,
        signedIn: Bool,
        unlocked: Bool,
        reading: MCPDeckFacts.Reading? = nil,
        errorMessage: String? = nil,
        now: Date = Date()
    ) -> MCPDeckFacts {
        MCPDeckFacts(
            cloudConfigured: cloudConfigured,
            signedIn: signedIn,
            tierUnlocked: unlocked,
            reading: reading,
            errorMessage: errorMessage,
            now: now
        )
    }
}
