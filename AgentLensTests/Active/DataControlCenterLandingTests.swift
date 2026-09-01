import XCTest
@testable import OpenBurnBar

/// Pins the Data & Privacy landing's deep-link contract: a deep link that
/// targets the Control Center (Settings search, the Memory walkthrough's
/// "Show me" / "Open the Pensieve") opens the Pensieve workbench outright when
/// the member holds the vault tier, and never traps a free user in a sheet —
/// the locked landing stays up with the free on-device options visible.
final class DataControlCenterLandingTests: XCTestCase {

    func testDeepLinkAutoOpensWorkbenchWhenEntitled() {
        XCTAssertTrue(
            DataControlCenterLandingPolicy.shouldAutoOpen(
                pendingAnchor: SettingsAnchor.dataControlCenterInventory,
                isUnlocked: true
            ),
            "A Control Center deep link with the vault tier held must open the workbench, not park on the landing"
        )
    }

    func testDeepLinkDoesNotOpenSheetWhenLocked() {
        XCTAssertFalse(
            DataControlCenterLandingPolicy.shouldAutoOpen(
                pendingAnchor: SettingsAnchor.dataControlCenterInventory,
                isUnlocked: false
            ),
            "Free members must land on the unlock veil plus free options, never an auto-presented dead end"
        )
    }

    func testPlainSidebarNavigationNeverAutoOpens() {
        XCTAssertFalse(
            DataControlCenterLandingPolicy.shouldAutoOpen(
                pendingAnchor: nil,
                isUnlocked: true
            ),
            "Selecting the Data & Privacy tab by hand must not fling a sheet open"
        )
    }

    func testUnrelatedDeepLinkDoesNotAutoOpen() {
        XCTAssertFalse(
            DataControlCenterLandingPolicy.shouldAutoOpen(
                pendingAnchor: SettingsAnchor.cloudOverview,
                isUnlocked: true
            ),
            "A pending anchor for another page must not trigger the workbench"
        )
    }
}
