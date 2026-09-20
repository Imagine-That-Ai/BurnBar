import CoreGraphics
import XCTest
import OpenBurnBarCore
import OpenBurnBarKernel
@testable import OpenBurnBarMobile

/// UI Tests for iPad navigation flows.
/// These run on iPad Air simulator and verify the NavigationSplitView shell.
@MainActor
final class iPadNavigationUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Route Model

    func testDashboardNavigationModel_initialState() {
        let model = DashboardNavigationModel()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testDashboardNavigationModel_navigatePushesHistory() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)
        XCTAssertEqual(model.currentRoute, .quota)
        XCTAssertTrue(model.canGoBack)
    }

    func testDashboardNavigationModel_goBackRestoresPrevious() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)
        model.navigate(to: .activity)
        XCTAssertEqual(model.currentRoute, .activity)
        model.goBack()
        XCTAssertEqual(model.currentRoute, .quota)
        model.goBack()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testDashboardNavigationModel_resetToOverview() {
        let model = DashboardNavigationModel()
        model.navigate(to: .sessionLogs)
        model.navigate(to: .projects)
        model.resetToOverview()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    // MARK: - Settings Tab Identity

    func testiPadSettingsTabs_countAndNoDaemon() {
        let tabs = iPadSettingsTab.allCases
        XCTAssertEqual(tabs.count, 7)
        XCTAssertFalse(tabs.contains(where: { $0.rawValue == "daemon" }))
    }

    func testiPadSettingsTabs_titles() {
        XCTAssertEqual(iPadSettingsTab.general.title, "General")
        XCTAssertEqual(iPadSettingsTab.account.title, "Account")
        XCTAssertEqual(iPadSettingsTab.providers.title, "Providers")
        XCTAssertEqual(iPadSettingsTab.alerts.title, "Alerts")
        XCTAssertEqual(iPadSettingsTab.notifications.title, "Notifications")
        XCTAssertEqual(iPadSettingsTab.devicesAndSync.title, "Devices & Sync")
        XCTAssertEqual(iPadSettingsTab.switcher.title, "Account Switcher")
    }

    // MARK: - Auth Gate Branching

    func testAuthGateView_usesHorizontalSizeClass() {
        let view = AuthGateView()
        XCTAssertNotNil(view)
    }

    func testYouRouteIncludesEveryAccountCardDestination() {
        XCTAssertEqual(Set(YouRoute.allCases), [.settings, .dataVault, .sync, .providers, .devices, .computerUse, .memory])
    }

    // MARK: - iPad command desk IA

    func testiPadDesk_launchesInboxNotPulse() {
        XCTAssertEqual(IPadAwayDeskNavigation.launchDestination, .inbox)
        XCTAssertEqual(AppDestination.inbox.label, "Inbox")
        XCTAssertNotEqual(IPadAwayDeskNavigation.launchDestination, .pulse)
    }

    func testiPadDesk_primaryDestinationsAreInboxAgentsQuotaYou() {
        XCTAssertEqual(
            IPadAwayDeskNavigation.defaultPrimaryDestinations,
            [.inbox, .agents, .burn, .you]
        )
        XCTAssertFalse(IPadAwayDeskNavigation.defaultPrimaryDestinations.contains(.pulse))
        XCTAssertEqual(IPadAwayDeskNavigation.defaultPrimaryDestinations.count, 4)
        XCTAssertEqual(AppDestination.you.label, IPadAwayDeskNavigation.youLabel)
        XCTAssertEqual(AppDestination.you.label, "You")
        XCTAssertNotEqual(AppDestination.you.label, "Store")
        XCTAssertEqual(AppDestination.burn.label, "Quota")
        XCTAssertEqual(AppDestination.agents.label, "Agents")
    }

    func testiPadDesk_watchWindowIsNamedAgentWatch() {
        XCTAssertEqual(IPadAwayDeskNavigation.watchWindowID, "agent-watch")
        XCTAssertEqual(
            IPadAwayDeskNavigation.hardwareChord(
                key: "w", command: true, control: false, option: true, shift: false
            ),
            .openWatchWindow
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.hardwareChord(
                key: ".", command: true, control: false, option: false, shift: false
            ),
            .halt
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.hardwareChord(
                key: ".", command: true, control: true, option: true, shift: false
            ),
            .panic
        )
        XCTAssertNil(
            IPadAwayDeskNavigation.hardwareChord(
                key: "5", command: true, control: false, option: false, shift: false
            )
        )
    }

    func testiPadDesk_migratesLegacyPulseFirstSidebar() {
        XCTAssertEqual(
            IPadAwayDeskNavigation.resolvedPrimaryDestinations(nil),
            IPadAwayDeskNavigation.defaultPrimaryDestinations
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.resolvedPrimaryDestinations(
                IPadAwayDeskNavigation.legacyPrimaryDestinations
            ),
            IPadAwayDeskNavigation.defaultPrimaryDestinations
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.resolvedPrimaryDestinations([.inbox, .you]),
            [.inbox, .you]
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.resolvedSecondaryDestinations(
                [.you, .providers, .devices, .settings],
                primary: [.inbox, .agents, .burn, .you]
            ),
            [.providers, .devices, .settings]
        )
    }

    func testiPadDesk_youIsNotRepeatedInSecondary() {
        XCTAssertFalse(IPadAwayDeskNavigation.defaultSecondaryDestinations.contains(.you))
        XCTAssertFalse(IPadAwayDeskNavigation.defaultSecondaryDestinations.contains(.inbox))
    }

    func testiPadDesk_showInsightsTabSelectsInsights() {
        InsightsDeepLink.reset()
        InsightsDeepLink.open(slug: "today")
        XCTAssertTrue(InsightsDeepLink.hasPending)
        XCTAssertEqual(
            IPadAwayDeskNavigation.destinationAfterInsightsDeepLink(),
            .insights
        )
        XCTAssertEqual(AppDestination.insights.label, "Insights")
        _ = InsightsDeepLink.consume()
        InsightsDeepLink.reset()
    }

    func testiPadDesk_keyboardShortcutsMapToDeskDestinations() {
        XCTAssertEqual(IPadAwayDeskNavigation.destination(forCommandNumber: 1), .inbox)
        XCTAssertEqual(IPadAwayDeskNavigation.destination(forCommandNumber: 2), .agents)
        XCTAssertEqual(IPadAwayDeskNavigation.destination(forCommandNumber: 3), .burn)
        XCTAssertEqual(IPadAwayDeskNavigation.destination(forCommandNumber: 4), .you)
        XCTAssertNil(IPadAwayDeskNavigation.destination(forCommandNumber: 5))
        XCTAssertEqual(AppDestination.inbox.iPadCommandNumber, 1)
        XCTAssertNil(AppDestination.insights.iPadCommandNumber)
    }

    func testiPadDesk_agentsKeepsSidebarAndInboxUsesThreeColumns() {
        XCTAssertEqual(IPadAwayDeskNavigation.columnMode(for: .inbox), .threeColumn)
        XCTAssertEqual(IPadAwayDeskNavigation.columnMode(for: .agents), .threeColumn)
        XCTAssertEqual(IPadAwayDeskNavigation.columnMode(for: .burn), .threeColumn)
        XCTAssertEqual(IPadAwayDeskNavigation.columnMode(for: .you), .threeColumn)
        XCTAssertEqual(IPadAwayDeskNavigation.columnMode(for: .insights), .twoColumn)
        XCTAssertFalse(IPadAwayDeskNavigation.hidesDestinationSidebar(for: .agents))
        XCTAssertFalse(IPadAwayDeskNavigation.hidesDestinationSidebar(for: .inbox))
        XCTAssertTrue(AppDestination.you.isPrimary)
        XCTAssertTrue(AppDestination.inbox.isPrimary)
    }

    func testiPadDesk_appWideSearchCoversInboxAndAgents() {
        XCTAssertTrue(IPadAwayDeskNavigation.usesAppWideSearch(for: .inbox))
        XCTAssertTrue(IPadAwayDeskNavigation.usesAppWideSearch(for: .agents))
        XCTAssertTrue(IPadAwayDeskNavigation.usesAppWideSearch(for: .burn))
        XCTAssertTrue(IPadAwayDeskNavigation.usesAppWideSearch(for: .you))
        XCTAssertFalse(IPadAwayDeskNavigation.usesAppWideSearch(for: .insights))
        XCTAssertEqual(IPadAwayDeskNavigation.searchPrompt(for: .inbox), "Search inbox")
        XCTAssertEqual(IPadAwayDeskNavigation.searchPrompt(for: .agents), "Search agents")
    }

    func testiPadDesk_youRailGroupsAreDeskSettingsNotStore() {
        XCTAssertEqual(
            IPadAwayDeskNavigation.YouGroup.allCases.map(\.title),
            ["Pairing", "Keep Mac awake", "Devices", "Cloud", "Appearance", "Data Vault", "Labs"]
        )
        XCTAssertFalse(IPadAwayDeskNavigation.YouGroup.allCases.map(\.title).contains("Store"))
        XCTAssertFalse(IPadAwayDeskNavigation.YouGroup.allCases.map(\.title).contains("Grokd"))
        XCTAssertEqual(
            IPadAwayDeskNavigation.filteredYouGroups("vault").map(\.self),
            [.dataVault]
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.filteredYouGroups("awake").map(\.self),
            [.keepAwake]
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.filteredYouGroups("").count,
            IPadAwayDeskNavigation.YouGroup.allCases.count
        )
    }

    func testiPadDesk_quotaRailFiltersProviderKeys() {
        let keys = ["anthropic", "openai", "cursor"]
        XCTAssertEqual(
            IPadAwayDeskNavigation.filteredProviderKeys(keys, query: "open"),
            ["openai"]
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.filteredProviderKeys(keys, query: ""),
            keys
        )
    }

    func testiPadDesk_inboxPointerActionsMatchIA() {
        XCTAssertEqual(
            IPadAwayDeskNavigation.inboxPointerActions().map(\.title),
            ["Approve", "Open thread", "Archive", "Snooze", "Copy link"]
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.inboxItemLink(itemID: "item-1")?.absoluteString,
            "burnbar://inbox/item-1"
        )
        let resume = BurnBarInboxItemPayload(
            actions: [
                BurnBarInboxAction(
                    id: "a1",
                    kind: .resumeConversation,
                    title: "Open thread",
                    value: "hermes:abc"
                )
            ]
        )
        XCTAssertEqual(IPadAwayDeskNavigation.inboxOpenThreadValue(payload: resume), "hermes:abc")
        XCTAssertEqual(IPadAwayDeskNavigation.inboxPrimaryAction(payload: resume)?.kind, .resumeConversation)
        XCTAssertNil(IPadAwayDeskNavigation.inboxOpenThreadValue(payload: BurnBarInboxItemPayload()))
    }

    func testiPadDesk_clonedDeskSceneIsDestroyedWatchIsKept() {
        XCTAssertTrue(IPadAwayDeskNavigation.extraWindowIsWatchOnly)
        XCTAssertEqual(IPadAwayDeskNavigation.deskWindowID, "desk")
        XCTAssertEqual(IPadAwayDeskNavigation.watchWindowID, "agent-watch")
        XCTAssertTrue(
            IPadDeskSceneRegistry.shouldDestroyClonedDesk(
                incomingID: "desk-2",
                retainedDeskID: "desk-1",
                watchIDs: ["agent-watch-1"]
            )
        )
        XCTAssertFalse(
            IPadDeskSceneRegistry.shouldDestroyClonedDesk(
                incomingID: "desk-1",
                retainedDeskID: "desk-1",
                watchIDs: []
            )
        )
        XCTAssertFalse(
            IPadDeskSceneRegistry.shouldDestroyClonedDesk(
                incomingID: "agent-watch-1",
                retainedDeskID: "desk-1",
                watchIDs: ["agent-watch-1"]
            )
        )
    }

    func testiPadDesk_watchTwoPointerContract() {
        XCTAssertTrue(IPadAwayDeskNavigation.haltAlwaysVisible)
        XCTAssertEqual(
            IPadAwayDeskNavigation.pixelPresentation(hasLiveFrame: true, isLabeledStill: false),
            .live
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.pixelPresentation(hasLiveFrame: false, isLabeledStill: false),
            .honestEmpty
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.pixelPresentation(hasLiveFrame: false, isLabeledStill: true),
            .labeledStill
        )
        XCTAssertTrue(
            IPadAwayDeskNavigation.disablesHover(.hostPixels, presentation: .live)
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.disablesHover(.localChrome, presentation: .live)
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.disablesHover(.hostPixels, presentation: .honestEmpty)
        )
        XCTAssertTrue(IPadAwayDeskNavigation.usesMagnetism(.localChrome))
        XCTAssertFalse(IPadAwayDeskNavigation.usesMagnetism(.hostPixels))
        XCTAssertTrue(
            IPadAwayDeskNavigation.shouldDrawHostCursor(presentation: .live, hasCursorSample: true)
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.shouldDrawHostCursor(presentation: .live, hasCursorSample: false)
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.shouldDrawHostCursor(presentation: .honestEmpty, hasCursorSample: true)
        )
        XCTAssertEqual(IPadAwayDeskNavigation.haltAccessibilityID, "ipad.watch.halt")
        XCTAssertEqual(IPadAwayDeskNavigation.pixelsAccessibilityID, "ipad.watch.pixels")
        XCTAssertEqual(IPadAwayDeskNavigation.askToMirrorAccessibilityID, "ipad.watch.askToMirror")
        XCTAssertEqual(IPadAwayDeskNavigation.hostCursorAccessibilityID, "ipad.watch.hostCursor")
    }

    func testiPadDesk_driveModeStaysOnLivePixelsAndEscDoesNotHalt() {
        XCTAssertTrue(IPadAwayDeskNavigation.canEnterDriveMode(hasLiveFrame: true))
        XCTAssertFalse(IPadAwayDeskNavigation.canEnterDriveMode(hasLiveFrame: false))
        XCTAssertTrue(
            IPadAwayDeskNavigation.driveMode(current: false, chord: .space, hasLiveFrame: true)
        )
        XCTAssertTrue(
            IPadAwayDeskNavigation.driveMode(current: false, chord: .doubleClick, hasLiveFrame: true)
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.driveMode(current: false, chord: .space, hasLiveFrame: false)
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.driveMode(current: true, chord: .escape, hasLiveFrame: true)
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.mouseLockedCopy(isDriving: true),
            "Mouse on Mac · Esc releases"
        )
        XCTAssertNil(IPadAwayDeskNavigation.mouseLockedCopy(isDriving: false))

        let now = Date()
        XCTAssertTrue(
            IPadAwayDeskNavigation.isDrivingPillVisible(isDriving: true, lastInputAt: nil, now: now)
        )
        XCTAssertTrue(
            IPadAwayDeskNavigation.isDrivingPillVisible(
                isDriving: true,
                lastInputAt: now.addingTimeInterval(-0.4),
                now: now
            )
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.isDrivingPillVisible(
                isDriving: true,
                lastInputAt: now.addingTimeInterval(-2.5),
                now: now
            )
        )
        XCTAssertTrue(
            IPadAwayDeskNavigation.isDrivingPillVisible(
                isDriving: true,
                lastInputAt: now.addingTimeInterval(-5),
                now: now
            )
        )
        XCTAssertFalse(
            IPadAwayDeskNavigation.isDrivingPillVisible(isDriving: false, lastInputAt: nil, now: now)
        )

        let point = IPadAwayDeskNavigation.hostCursorPoint(
            x: 960,
            y: 540,
            in: CGSize(width: 400, height: 200)
        )
        XCTAssertEqual(point.x, 200, accuracy: 0.01)
        XCTAssertEqual(point.y, 100, accuracy: 0.01)
        XCTAssertEqual(
            IPadAwayDeskNavigation.hostCursorPoint(x: -10, y: 10_000, in: .zero),
            .zero
        )
        XCTAssertEqual(MercuryLiveEmbedStyle.deskInspector, .deskInspector)
        XCTAssertNotEqual(MercuryLiveEmbedStyle.deskInspector, .square)
    }

    func testiPadDesk_pinningWatchDoesNotStealSelection() {
        XCTAssertEqual(
            IPadAwayDeskNavigation.destinationAfterPinningWatch(current: .inbox),
            .inbox
        )
        XCTAssertEqual(
            IPadAwayDeskNavigation.destinationAfterPinningWatch(current: .agents),
            .agents
        )
    }

    func testCloudSyncHealthPresentationCopyIsActionable() {
        XCTAssertEqual(CloudSyncHealth.healthy.systemImageName, "checkmark.icloud.fill")
        XCTAssertEqual(CloudSyncHealth.macNotSyncing.systemImageName, "desktopcomputer.trianglebadge.exclamationmark")
        XCTAssertEqual(
            CloudSyncHealth.macNotSyncing.detailText,
            "OpenBurnBar on your Mac has not published recently. Open the Mac app to update cloud data."
        )
        XCTAssertEqual(CloudSyncHealth.offline.detailText, CloudErrorClassification.networkUnavailable.recoveryHint)
        XCTAssertEqual(CloudSyncHealth.permissionDenied.detailText, CloudErrorClassification.permissionDenied.recoveryHint)
    }

    func testCloudErrorClassifierSeparatesAppCheckFromRulesDenied() {
        XCTAssertEqual(
            CloudErrorClassification.permissionDeniedClassification(message: "Firebase App Check token is invalid."),
            .appCheckBlocked
        )
        XCTAssertEqual(
            CloudErrorClassification.permissionDeniedClassification(message: "Missing or insufficient permissions."),
            .permissionDenied
        )
        XCTAssertEqual(
            CloudErrorClassification.classify(message: "Your Mac relay is online but has not published live CLI model discovery yet."),
            .other(message: "Your Mac relay is online but has not published live CLI model discovery yet.")
        )
    }

    // MARK: - Provider Dashboard Store

    func testProviderDashboardStore_aggregatesWithRealisticData() {
        let store = ProviderDashboardStore(provider: .claudeCode)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        store.usages = [
            TokenUsage(
                provider: .claudeCode,
                sessionId: "sess-1",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 1000,
                outputTokens: 500,
                costUSD: 0.05,
                startTime: now,
                endTime: now
            ),
            TokenUsage(
                provider: .claudeCode,
                sessionId: "sess-2",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 2000,
                outputTokens: 1000,
                costUSD: 0.10,
                startTime: yesterday,
                endTime: yesterday
            )
        ]

        XCTAssertEqual(store.totalCost, 0.15, accuracy: 0.001)
        XCTAssertEqual(store.totalTokens, 4500)
        XCTAssertEqual(store.totalSessions, 2)
        XCTAssertEqual(store.inputTokens, 3000)
        XCTAssertEqual(store.outputTokens, 1500)
        XCTAssertEqual(store.dailyPoints.count, 2)
    }

    // MARK: - Hermes Service

    func testHermesService_streamingState() {
        let service = HermesService()
        service.sendMessage("Hello")
        XCTAssertTrue(service.isStreaming)
        service.sendMessage("Second")
        XCTAssertEqual(service.messages.filter { $0.role == .user }.map(\.text), ["Hello"])
    }

    func testHermesService_clearChatResetsState() {
        let service = HermesService()
        // Manually populate state to avoid async network race
        service.messages.append(HermesChatMessage(role: .user, text: "Test"))
        service.isStreaming = true
        service.lastError = "Some error"
        service.clearChat()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertFalse(service.isStreaming)
        XCTAssertNil(service.lastError)
    }

    func testHermesService_selectConnectionRejectsInvalidURLWithoutChangingSelection() {
        let service = HermesService()
        let invalid = HermesConnectionRecord(
            id: "bad",
            displayName: "Bad Host",
            mode: .directURL,
            status: .online,
            endpointURL: "https://token@example.com?secret=value"
        )

        XCTAssertFalse(service.selectConnection(invalid))
        XCTAssertEqual(service.selectedConnection.id, HermesConnectionRecord.localDefault.id)
        XCTAssertNotNil(service.lastError)
    }

    func testHermesService_selectConnectionResetsRuntimeStateOnHostChange() {
        let service = HermesService()
        service.selectedModelID = "old-model"
        service.selectedSessionID = "old-session"
        service.sessions = [HermesSessionSummary(id: "old-session")]
        service.modelOptions = [HermesRuntimeModelOption(providerID: "old", providerName: "Old", modelID: "old-model")]
        let connection = HermesConnectionRecord(
            id: "lan",
            displayName: "LAN Hermes",
            mode: .directURL,
            status: .online,
            endpointURL: "http://192.168.1.42:8642"
        )

        XCTAssertTrue(service.selectConnection(connection, refresh: false))
        XCTAssertEqual(service.selectedConnection.id, "lan")
        XCTAssertNil(service.selectedModelID)
        XCTAssertNil(service.selectedSessionID)
        XCTAssertTrue(service.sessions.isEmpty)
        XCTAssertTrue(service.modelOptions.isEmpty)
    }

    func testHermesService_validatedEndpointURLAcceptsHTTPSAndPrivateLANHTTP() {
        XCTAssertNotNil(HermesService.validatedEndpointURL("https://hermes.example.com"))
        XCTAssertNotNil(HermesService.validatedEndpointURL("http://127.0.0.1:8642"))
        XCTAssertNotNil(HermesService.validatedEndpointURL("http://192.168.1.42:8642"))
        XCTAssertNotNil(HermesService.validatedEndpointURL("http://10.0.0.5:8642"))
        XCTAssertNotNil(HermesService.validatedEndpointURL("http://172.16.0.5:8642"))
    }

    func testHermesService_validatedEndpointURLRejectsUnsafeURLs() {
        XCTAssertNil(HermesService.validatedEndpointURL("ftp://hermes.example.com"))
        XCTAssertNil(HermesService.validatedEndpointURL("http://8.8.8.8:8642"))
        XCTAssertNil(HermesService.validatedEndpointURL("https://token@example.com"))
        XCTAssertNil(HermesService.validatedEndpointURL("https://hermes.example.com?token=secret"))
    }

    // MARK: - Session Logs Search

    func testSessionLogs_filteredUsages_searchByModel() {
        let usage1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "s1",
            projectName: "P1",
            model: "gpt-4o",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let usage2 = TokenUsage(
            provider: .codex,
            sessionId: "s2",
            projectName: "P2",
            model: "claude-3",
            inputTokens: 200,
            outputTokens: 100,
            costUSD: 0.02,
            startTime: Date(),
            endTime: Date()
        )

        let usages = [usage1, usage2]
        let searchText = "gpt"
        let lower = searchText.lowercased()
        let filtered = usages.filter {
            $0.model.lowercased().contains(lower) ||
            $0.projectName.lowercased().contains(lower) ||
            $0.provider.rawValue.lowercased().contains(lower) ||
            $0.sessionId.lowercased().contains(lower)
        }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.model, "gpt-4o")
    }

    // MARK: - Deep Link URLs

    func testDeepLinkURL_dashboard() {
        let url = URL(string: "burnbar://dashboard")!
        XCTAssertEqual(url.scheme, "burnbar")
        XCTAssertEqual(url.host, "dashboard")
    }

    func testDeepLinkURL_settings() {
        let url = URL(string: "burnbar://settings")!
        XCTAssertEqual(url.host, "settings")
    }

    func testDeepLinkURL_chat() {
        let url = URL(string: "burnbar://chat")!
        XCTAssertEqual(url.host, "chat")
    }
}
