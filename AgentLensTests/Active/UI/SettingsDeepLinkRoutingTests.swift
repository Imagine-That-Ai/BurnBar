import Foundation
import XCTest
@testable import OpenBurnBar

/// Deep-link plumbing behind the new "Customize quota popover" affordance:
/// `SettingsDeepLinkRouting` (Views/Settings/Search/SettingsRouter.swift)
/// parks the item in UserDefaults for a cold Settings open AND posts the
/// live-routing notification for an already-open window, and the
/// `agents.quotaDisplay` manifest item must stay searchable and anchored.
@MainActor
final class SettingsDeepLinkRoutingTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingItemKey)
        UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingTabKey)
        super.tearDown()
    }

    // MARK: - item(matching:)

    func test_itemMatchingResolvesKnownIDAndNormalizesWhitespace() {
        XCTAssertEqual(
            SettingsDeepLinkRouting.item(matching: "agents.quotaDisplay")?.id,
            "agents.quotaDisplay"
        )
        XCTAssertEqual(
            SettingsDeepLinkRouting.item(matching: "  agents.quotaDisplay\n")?.id,
            "agents.quotaDisplay",
            "surrounding whitespace must not break deep links"
        )
    }

    func test_itemMatchingRejectsNilEmptyAndUnknownIDs() {
        XCTAssertNil(SettingsDeepLinkRouting.item(matching: nil))
        XCTAssertNil(SettingsDeepLinkRouting.item(matching: ""))
        XCTAssertNil(SettingsDeepLinkRouting.item(matching: "   "))
        XCTAssertNil(SettingsDeepLinkRouting.item(matching: "agents.doesNotExist"))
    }

    // MARK: - route(to:)

    func test_routeToKnownItemParksPendingIDAndPostsNotification() {
        let received = expectation(description: "openSettingsItem notification")
        let observer = NotificationCenter.default.addObserver(
            forName: SettingsDeepLinkRouting.openSettingsItemNotification,
            object: nil,
            queue: nil
        ) { notification in
            XCTAssertEqual(notification.object as? String, "agents.quotaDisplay")
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(SettingsDeepLinkRouting.route(to: "agents.quotaDisplay"))
        // The parked ID survives for a cold Settings-window open.
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsDeepLinkRouting.pendingItemKey),
            "agents.quotaDisplay"
        )
        wait(for: [received], timeout: 1.0)
    }

    func test_routeToUnknownItemFailsAndClearsAnyStalePendingID() {
        UserDefaults.standard.set("stale.item", forKey: SettingsDeepLinkRouting.pendingItemKey)
        XCTAssertFalse(SettingsDeepLinkRouting.route(to: "agents.doesNotExist"))
        XCTAssertNil(
            UserDefaults.standard.string(forKey: SettingsDeepLinkRouting.pendingItemKey),
            "a failed route must not leave a stale pending deep link behind"
        )
    }

    func test_routeToQuotaDisplayUsesTheQuotaDisplayItem() {
        SettingsDeepLinkRouting.routeToQuotaDisplay()
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsDeepLinkRouting.pendingItemKey),
            SettingsDeepLinkRouting.quotaDisplayItemID
        )
    }

    // MARK: - Manifest invariants for the new quota-display destination

    func test_quotaDisplayManifestItemIsSearchableAndAnchored() throws {
        let item = try XCTUnwrap(
            SettingsManifest.all.first { $0.id == SettingsDeepLinkRouting.quotaDisplayItemID },
            "the quota popover destination must exist in the settings manifest"
        )
        XCTAssertEqual(item.anchorID, SettingsAnchor.agentsQuotaDisplay)
        XCTAssertEqual(item.tab, .agents)
        // Users will hunt for it with these words from the popover context.
        for keyword in ["quota", "popover", "menu bar", "hide"] {
            XCTAssertTrue(
                item.keywords.contains(keyword),
                "missing search keyword \(keyword)"
            )
        }
    }
}
