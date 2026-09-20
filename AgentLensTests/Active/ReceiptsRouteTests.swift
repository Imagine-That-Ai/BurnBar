import XCTest
@testable import OpenBurnBar

/// The Receipts register's routing contract.
///
/// The load-bearing assertion here is `test_receiptsDeepLink_passesTheAppCommandRouterGate`.
/// `NavigationCoordinator.handleDeepLink` is only ever reached through
/// `AppCommandRouter.handle`, and a host missing from that router's dashboard
/// case list falls through to `default` and is handed to the Google Sign-In
/// fallback. A `.receipts` case in the coordinator alone is a declared,
/// unreachable route — exactly the trap the `home` comment in the router warns
/// about — so the gate gets its own fence.
@MainActor
final class ReceiptsRouteTests: XCTestCase {

    // MARK: - Route metadata

    func test_receiptsRoute_titleIconAndSubtitle() {
        let route = DashboardMainRoute.receipts
        XCTAssertEqual(route.title(), "Receipts")
        XCTAssertEqual(route.systemImage(), "doc.text.below.ecg")
        XCTAssertFalse(route.subtitle().isEmpty)
    }

    /// `primarySections` is positional and drives ⌘1–⌘8. Adding Receipts to it
    /// would renumber every existing user's keyboard shortcuts.
    func test_receiptsRoute_staysOutOfPrimarySections() {
        XCTAssertFalse(DashboardMainRoute.primarySections.contains(.receipts))
        XCTAssertNil(DashboardMainRoute.receipts.primarySectionIndex)
        XCTAssertEqual(DashboardMainRoute.primarySections.count, 8,
                       "The primary section count must not drift; ⌘1–⌘8 depends on it")
    }

    /// Persisted in `dashboard.quickAccess.v1`, so the identifier is a storage
    /// contract, not a cosmetic string.
    func test_receiptsRoute_quickAccessIdentifierRoundTrips() {
        XCTAssertEqual(DashboardMainRoute.quickAccessRoute(rawValue: "receipts"), .receipts)
    }

    /// Receipts renders its own stack-list + slip-inspector split, so a provider
    /// rail beside it would be a third column at the 1040pt window minimum.
    func test_receiptsRoute_doesNotWantTheProviderSidebar() {
        XCTAssertFalse(DashboardView.routeWantsProviderSidebar(.receipts))
    }

    // MARK: - Deep link

    func test_navigationCoordinator_routesReceiptsDeepLink() {
        let coordinator = NavigationCoordinator()
        let handled = coordinator.handleDeepLink(URL(string: "openburnbar://receipts")!)

        XCTAssertTrue(handled)
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: nil))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_navigationCoordinator_rejectsUnknownHost() {
        let coordinator = NavigationCoordinator()
        XCTAssertFalse(coordinator.handleDeepLink(URL(string: "openburnbar://receipt-register")!))
        XCTAssertNil(coordinator.dashboardRoute)
    }

    /// Without `receipts` in `AppCommandRouter.handle`'s dashboard case list the
    /// URL never reaches `NavigationCoordinator.handleDeepLink` at all.
    func test_receiptsDeepLink_passesTheAppCommandRouterGate() {
        let router = AppCommandRouter()
        var routed: URL?
        router.routeDashboardDeepLink = { url in
            routed = url
            return true
        }

        let url = URL(string: "openburnbar://receipts")!
        XCTAssertTrue(router.handle(url))
        XCTAssertEqual(routed, url)
    }

    /// End to end through both hops, the way the running app dispatches it.
    func test_receiptsDeepLink_landsOnTheDashboardSection() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        XCTAssertTrue(router.handle(URL(string: "openburnbar://receipts")!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: nil))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_receiptsDeepLink_chatLensQueryLandsOnChatTape() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        let url = ReceiptChatBridge.receiptURL(receiptID: "rcpt-1", lens: .transcript)
        XCTAssertTrue(router.handle(url!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: "rcpt-1"))
        XCTAssertEqual(coordinator.pendingReceiptLens, .transcript)
        XCTAssertEqual(
            NavigationCoordinator.receiptLens(from: URL(string: "openburnbar://receipts/rcpt-1?lens=CHAT")!),
            .transcript
        )
        XCTAssertNil(NavigationCoordinator.receiptLens(from: URL(string: "openburnbar://receipts/rcpt-1")!))
    }

    func test_receiptsDeepLink_landsOnTheNamedSlip() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        XCTAssertTrue(router.handle(URL(string: "openburnbar://receipts/rcpt-1")!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: "rcpt-1"))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_receiptsDeepLink_decodesAPercentEncodedReceiptID() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        let url = ReceiptChatBridge.receiptURL(receiptID: "rcpt with space")
        XCTAssertEqual(url?.absoluteString, "openburnbar://receipts/rcpt%20with%20space")
        XCTAssertTrue(router.handle(url!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: "rcpt with space"))
    }

    func test_pathIdentifier_skipsEmptySegmentsAndDecodes() {
        XCTAssertNil(NavigationCoordinator.pathIdentifier(from: URL(string: "openburnbar://receipts")!))
        XCTAssertNil(NavigationCoordinator.pathIdentifier(from: URL(string: "openburnbar://receipts/")!))
        XCTAssertEqual(
            NavigationCoordinator.pathIdentifier(from: URL(string: "openburnbar://receipts/rcpt-1")!),
            "rcpt-1"
        )
        XCTAssertEqual(
            NavigationCoordinator.pathIdentifier(from: URL(string: "openburnbar://sessions/conv%20with%20space")!),
            "conv with space"
        )
        XCTAssertEqual(
            NavigationCoordinator.pathIdentifier(
                from: URL(string: "openburnbar://receipts/parentSession/agentId")!
            ),
            "parentSession/agentId"
        )
    }

    func test_receiptsDeepLink_isCaseInsensitiveOnSchemeAndHost() {
        let coordinator = NavigationCoordinator()
        XCTAssertTrue(coordinator.handleDeepLink(URL(string: "OpenBurnBar://Receipts/rcpt-1")!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: "rcpt-1"))
    }

    func test_receiptsDeepLink_trailingSlashDoesNotInventAnEmptyID() {
        let coordinator = NavigationCoordinator()
        XCTAssertTrue(coordinator.handleDeepLink(URL(string: "openburnbar://receipts/")!))
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: nil))
    }

    func test_appCommandRouter_open_usesTheInAppDoorBeforeTheScheme() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        router.open(URL(string: "openburnbar://receipts/rcpt-1")!)
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: "rcpt-1"))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_receiptBannerTap_opensTheNamedSlipThroughTheRouterGate() {
        let receipt = ReceiptRecord(
            id: "rcpt-1",
            sessionId: "session-1",
            projectName: "OpenBurnBar",
            provider: .factory,
            modelName: "unknown"
        )
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        XCTAssertTrue(
            ReceiptNotificationRouter.handleTap(
                userInfo: ReceiptNotificationRouter.userInfo(for: receipt)
            ) { router.handle($0) }
        )
        XCTAssertEqual(coordinator.dashboardRoute, .receipts(receiptID: "rcpt-1"))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_registerFocus_pinsAMissingSlipAtTheTop() {
        let visible = ReceiptRecord(
            id: "rcpt-old",
            sessionId: "old",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol"
        )
        let focused = ReceiptRecord(
            id: "rcpt-new",
            sessionId: "new",
            projectName: "OpenBurnBar",
            provider: .factory,
            modelName: "unknown"
        )
        let merged = ReceiptRegisterFocus.inserting(focused, into: [visible])
        XCTAssertEqual(merged.map(\.id), ["rcpt-new", "rcpt-old"])
        XCTAssertEqual(ReceiptRegisterFocus.inserting(visible, into: merged).map(\.id), ["rcpt-new", "rcpt-old"])

        let missing = ReceiptRegisterFocus.focusAfterLookup(requestedID: "rcpt-gone", receipts: [visible])
        XCTAssertNil(missing.pinned)
        XCTAssertEqual(missing.selected, "rcpt-old")
        let hit = ReceiptRegisterFocus.focusAfterLookup(requestedID: "rcpt-old", receipts: [visible])
        XCTAssertEqual(hit.pinned, "rcpt-old")
        XCTAssertEqual(hit.selected, "rcpt-old")

        XCTAssertNil(
            ReceiptRegisterFocus.pinAfterManualSelection(
                selectedID: "rcpt-new",
                currentPin: "rcpt-old"
            ),
            "Clicking another slip must release the deep-link pin"
        )
        XCTAssertEqual(
            ReceiptRegisterFocus.pinAfterManualSelection(
                selectedID: "rcpt-old",
                currentPin: "rcpt-old"
            ),
            "rcpt-old",
            "Reselecting the linked slip keeps the pin"
        )
        XCTAssertNil(
            ReceiptRegisterFocus.pinAfterManualSelection(
                selectedID: "rcpt-new",
                currentPin: nil
            )
        )
    }

    func test_sessionsDeepLink_passesTheAppCommandRouterGate() {
        let router = AppCommandRouter()
        var routed: URL?
        router.routeDashboardDeepLink = { url in
            routed = url
            return true
        }

        let url = URL(string: "openburnbar://sessions/conv-1")!
        XCTAssertTrue(router.handle(url))
        XCTAssertEqual(routed, url)
    }

    func test_sessionsDeepLink_landsOnSessionLogsWithTheConversationID() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        XCTAssertTrue(router.handle(URL(string: "openburnbar://sessions/conv-1")!))
        XCTAssertEqual(coordinator.dashboardRoute, .sessionLogs(conversationID: "conv-1"))
        XCTAssertEqual(coordinator.pendingNavigation, .dashboard)
    }

    func test_sessionsDeepLink_decodesAPercentEncodedConversationID() {
        let coordinator = NavigationCoordinator()
        let router = AppCommandRouter()
        router.routeDashboardDeepLink = { coordinator.handleDeepLink($0) }

        let url = ReceiptChatBridge.sessionURL(conversationID: "conv with space")
        XCTAssertEqual(url?.absoluteString, "openburnbar://sessions/conv%20with%20space")
        XCTAssertTrue(router.handle(url!))
        XCTAssertEqual(coordinator.dashboardRoute, .sessionLogs(conversationID: "conv with space"))
    }
}
