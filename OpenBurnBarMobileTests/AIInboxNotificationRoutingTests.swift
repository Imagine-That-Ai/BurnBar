import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// The `ai_inbox_item` push shape is a cross-repo contract with
/// `functions/src/aiInboxNotifications.ts`. Drift in it produces no crash — the
/// notification simply stops opening the right thing — so it is pinned here.
/// `@MainActor` because `AIInboxDeepLink` owns a type-level pending-item stash
/// and is isolated to the main actor; these cases touch it directly.
@MainActor
final class AIInboxNotificationRoutingTests: XCTestCase {
    override func tearDown() {
        AIInboxDeepLink.resetPendingItemID()
        MobilePendingOsRouteStore.shared.clear()
        super.tearDown()
    }

    func testParsesAP1Push() throws {
        let payload = try XCTUnwrap(
            AIInboxNotificationPayload(userInfo: [
                "type": "ai_inbox_item",
                "event_id": "ai_inbox_inb_abc",
                "item_id": "inb_abc",
                "kind": "ci_waste",
                "priority": "1"
            ])
        )
        XCTAssertEqual(payload.itemID, "inb_abc")
        XCTAssertEqual(payload.kind, .ciWaste)
        XCTAssertEqual(payload.priority, .p1)
        XCTAssertEqual(payload.eventID, "ai_inbox_inb_abc")
        XCTAssertEqual(payload.title, "Wasted CI")
        XCTAssertEqual(payload.deepLink?.absoluteString, "burnbar://inbox/inb_abc")
    }

    func testIgnoresAgentReplyPushes() {
        // Both push families arrive through the same delegate. If this matched,
        // the inbox branch would swallow every agent reply.
        XCTAssertNil(
            AIInboxNotificationPayload(userInfo: [
                "type": "agent_reply",
                "event_id": "cli_session_t_a",
                "runtime": "codex"
            ])
        )
        XCTAssertNil(AIInboxNotificationPayload(userInfo: [:]))
    }

    func testBodyCarriesNoItemContent() throws {
        // The mirrored item is sealed, so the server cannot supply a summary.
        // Rendering a payload string as the body would make this a plaintext channel.
        let payload = try XCTUnwrap(
            AIInboxNotificationPayload(userInfo: [
                "type": "ai_inbox_item",
                "item_id": "inb_abc",
                "kind": "cost_anomaly",
                "title": "Spent $412 on Opus overnight",
                "preview": "38 of 40 nightly runs were cancelled"
            ])
        )
        XCTAssertEqual(payload.title, "Cost anomaly")
        XCTAssertEqual(payload.body, "Open OpenBurnBar to see what needs you.")
    }

    func testUnknownKindDegradesToSystemRatherThanDroppingTheAlert() throws {
        let payload = try XCTUnwrap(
            AIInboxNotificationPayload(userInfo: [
                "type": "ai_inbox_item",
                "item_id": "inb_abc",
                "kind": "kind_from_a_newer_mac"
            ])
        )
        XCTAssertEqual(payload.kind, .system)
        XCTAssertEqual(payload.title, "OpenBurnBar")
    }

    func testRejectsItemIDsThatCouldSpoofRenderedText() {
        for hostile in ["", "   ", String(repeating: "a", count: 161), "inb_\u{202E}abc", "inb\u{0007}"] {
            XCTAssertNil(
                AIInboxNotificationPayload(userInfo: ["type": "ai_inbox_item", "item_id": hostile]),
                "expected \(hostile.debugDescription) to be rejected"
            )
        }
    }

    func testEveryInboxKindHasATitle() {
        // A new Kernel case with no title would silently render as an empty
        // notification; the switch is exhaustive, so this fails to COMPILE if a
        // case is added, and the assertion catches an empty string.
        for kind in BurnBarInboxItemKind.allCases {
            XCTAssertFalse(AIInboxNotificationPayload.title(forKind: kind).isEmpty, "\(kind) has no title")
        }
    }

    // MARK: - Deep link

    func testParsesInboxURLs() throws {
        let url = try XCTUnwrap(URL(string: "burnbar://inbox/inb_abc"))
        XCTAssertEqual(AIInboxDeepLink.itemID(from: url), "inb_abc")

        let bare = try XCTUnwrap(URL(string: "burnbar://inbox"))
        XCTAssertNil(AIInboxDeepLink.itemID(from: bare))
    }

    func testIgnoresOtherDeepLinkHosts() throws {
        for other in ["burnbar://insights/all", "burnbar://assistants/hermes?threadId=t1", "https://burnbar.ai/inbox/x"] {
            let url = try XCTUnwrap(URL(string: other))
            XCTAssertNil(AIInboxDeepLink.itemID(from: url), other)
        }
    }

    func testURLsRoundTripThroughTheParser() throws {
        let url = try XCTUnwrap(AIInboxDeepLink.url(itemID: "inb_abc"))
        XCTAssertEqual(AIInboxDeepLink.itemID(from: url), "inb_abc")
        XCTAssertEqual(AIInboxDeepLink.url(itemID: nil)?.absoluteString, "burnbar://inbox")
    }

    func testPendingItemIsConsumedExactlyOnce() {
        // A re-render claims the stash again; the second read must be empty or
        // the app re-navigates away from wherever the user has since gone.
        AIInboxDeepLink.open(itemID: "inb_abc")
        XCTAssertEqual(AIInboxDeepLink.consumePendingItemID(), "inb_abc")
        XCTAssertNil(AIInboxDeepLink.consumePendingItemID())
    }

    /// Cold launch: the tap that STARTS the app posts its deep link during
    /// `didFinishLaunching`, before any SwiftUI root has subscribed to
    /// `notificationName`. The post is therefore observed by nobody and the
    /// stash is the only surviving record — which is exactly why the roots claim
    /// it from a `.task`. Without that claim the push opens the app to the
    /// default tab and the item is silently lost.
    func testStashSurvivesAPostThatNoObserverHeard() {
        // No observer registered: this models launch-time ordering.
        AIInboxDeepLink.open(itemID: "inb_cold")

        XCTAssertEqual(
            AIInboxDeepLink.consumePendingItemID(),
            "inb_cold",
            "A launch-time push must remain claimable after its post went unheard."
        )
    }

    /// The stash must not outlive a link that WAS delivered live. `open` parks
    /// the id for the cold-launch path, so a root that handled the notification
    /// drains it — otherwise a later `.task` would replay the navigation and
    /// yank the user back to an item they had already moved on from.
    func testAServedLinkCanBeDrainedSoItIsNotReplayed() {
        AIInboxDeepLink.open(itemID: "inb_live")
        // Stands in for the `onReceive` path draining the stash after routing.
        _ = AIInboxDeepLink.consumePendingItemID()

        XCTAssertNil(
            AIInboxDeepLink.consumePendingItemID(),
            "A link already served live must not be replayed by the cold-launch claim."
        )
    }

    // MARK: - Mission / Mercury-call cold launch

    /// A mission push that launches the app posts `ShowMissionConsole` during
    /// `didFinishLaunching`, before either root has subscribed, so the post is
    /// heard by nobody. Without the stash the tapped mission is simply lost.
    func testAColdLaunchMissionPushSurvivesHavingNoSubscriber() {
        MobileOsDeepLinkApplier.apply(
            MobileOsRouteDecision(destination: .mission, missionId: "msn_cold")
        )

        XCTAssertEqual(
            MobilePendingOsRouteStore.shared.consume(),
            .mission(missionId: "msn_cold"),
            "A launch-time mission push must remain claimable after its post went unheard."
        )
    }

    func testAColdLaunchMercuryCallPushSurvivesHavingNoSubscriber() {
        MobileOsDeepLinkApplier.apply(
            MobileOsRouteDecision(destination: .mercuryCall, connectionId: "conn_cold")
        )

        XCTAssertEqual(
            MobilePendingOsRouteStore.shared.consume(),
            .mercuryCall(connectionId: "conn_cold"),
            "A launch-time Mercury-call push must remain claimable after its post went unheard."
        )
    }

    /// One tap opens one surface once. The roots drain the stash on the live
    /// `onReceive` path too, so the cold-launch claim that runs afterwards must
    /// find nothing left to replay.
    func testAServedOsRouteIsDrainedSoItIsNotReplayed() {
        MobileOsDeepLinkApplier.apply(
            MobileOsRouteDecision(destination: .mercuryCall, connectionId: "conn_live")
        )
        // Stands in for the `onReceive` path draining the stash after routing.
        _ = MobilePendingOsRouteStore.shared.consume()

        XCTAssertNil(
            MobilePendingOsRouteStore.shared.consume(),
            "A route already served live must not be replayed by the cold-launch claim."
        )
    }

    func testNotificationCarriesTheSanitizedItemID() {
        let expectation = expectation(forNotification: AIInboxDeepLink.notificationName, object: nil) { note in
            AIInboxDeepLink.itemID(from: note) == "inb_abc"
        }
        AIInboxDeepLink.open(itemID: "  inb_abc  ")
        wait(for: [expectation], timeout: 1)
    }
}
