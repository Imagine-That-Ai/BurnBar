import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class BurnBarProfileAvatarTests: XCTestCase {

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
    }

    func testExtractInitialsFromDisplayName() {
        XCTAssertEqual(
            BurnBarProfileAvatar.extractInitials(displayName: "Alberto Nunez", email: nil),
            "AN"
        )
        XCTAssertEqual(
            BurnBarProfileAvatar.extractInitials(displayName: "OpenBurnBar", email: nil),
            "OP"
        )
        XCTAssertEqual(
            BurnBarProfileAvatar.extractInitials(displayName: "  Ada Lovelace  ", email: nil),
            "AL"
        )
        XCTAssertEqual(
            BurnBarProfileAvatar.extractInitials(displayName: "Grace", email: nil),
            "GR"
        )
    }

    func testExtractInitialsFallbackToEmail() {
        XCTAssertEqual(
            BurnBarProfileAvatar.extractInitials(displayName: nil, email: "alberto@burnbar.app"),
            "AL"
        )
        XCTAssertEqual(
            BurnBarProfileAvatar.extractInitials(displayName: "", email: "developer@openburnbar.com"),
            "DE"
        )
    }

    func testExtractInitialsNilWhenEmpty() {
        XCTAssertNil(BurnBarProfileAvatar.extractInitials(displayName: nil, email: nil))
        XCTAssertNil(BurnBarProfileAvatar.extractInitials(displayName: "", email: ""))
        XCTAssertNil(BurnBarProfileAvatar.extractInitials(displayName: "   ", email: "   "))
    }

    func testAvatarSizesAreProportional() {
        let compact = BurnBarProfileAvatarSize.compact
        let toolbar = BurnBarProfileAvatarSize.toolbar
        let medium = BurnBarProfileAvatarSize.medium
        let header = BurnBarProfileAvatarSize.header
        let large = BurnBarProfileAvatarSize.large

        XCTAssertLessThan(compact.diameter, toolbar.diameter)
        XCTAssertLessThan(toolbar.diameter, medium.diameter)
        XCTAssertLessThan(medium.diameter, header.diameter)
        XCTAssertLessThan(header.diameter, large.diameter)

        XCTAssertLessThan(compact.badgeDiameter, toolbar.badgeDiameter)
        XCTAssertLessThan(toolbar.badgeDiameter, medium.badgeDiameter)
        XCTAssertLessThan(medium.badgeDiameter, header.badgeDiameter)
        XCTAssertLessThan(header.badgeDiameter, large.badgeDiameter)
    }

    func testAccessibilityIdentifiersAreConsistent() {
        XCTAssertEqual(OBBAccessibilityID.dashboardProfileAvatarButton, "dashboard.profileAvatarButton")
        XCTAssertEqual(OBBAccessibilityID.popoverProfileAvatarButton, "popover.profileAvatarButton")
        XCTAssertEqual(OBBAccessibilityID.dashboardSettingsButton, "dashboard.settingsButton")
        XCTAssertEqual(OBBAccessibilityID.popoverSettingsButton, "popover.settingsButton")
    }

    func testTierOrderingAndComparison() {
        XCTAssertTrue(MacCloudTier.free < MacCloudTier.cloud)
        XCTAssertTrue(MacCloudTier.cloud < MacCloudTier.pro)
        XCTAssertTrue(MacCloudTier.pro < MacCloudTier.ultra)
    }
}
