import XCTest

final class MacAppStoreReviewComplianceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Static source-scan tests; fail fast if the XCTest host wedges.
        executionTimeAllowance = 30
    }
    func testMASEntitlementsIncludeSandboxAndSignInWithApple() throws {
        let entitlementsURL = try bundledResourceURL(named: "OpenBurnBarMAS", extension: "entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.network.server"])
        XCTAssertEqual(plist["com.apple.developer.applesignin"] as? [String], ["Default"])
    }

    func testMacPopoverUsesStandardVisibleQuitCommandName() throws {
        let source = try bundledTextResource(named: "MenuBarPopoverView")

        XCTAssertTrue(source.contains("title: \"Quit OpenBurnBar\""))
        XCTAssertTrue(source.contains("NSApplication.shared.terminate(nil)"))
    }

    func testMacCloudStoreHasNativeStoreKitPurchaseAndLegalLinks() throws {
        let source = try bundledTextResource(named: "CloudStoreSettingsView")

        XCTAssertTrue(source.contains("import StoreKit"))
        XCTAssertTrue(source.contains("guard let productID = tier.monthlyProductID"))
        XCTAssertTrue(source.contains("Product.products(for: [productID])"))
        XCTAssertTrue(source.contains("purchaseTarget.purchase(options: purchaseOptions)"))
        XCTAssertTrue(source.contains("beginEntitlementBinding"))
        XCTAssertTrue(source.contains("verifyHostedQuotaEntitlement"))
        XCTAssertTrue(source.contains("Restore Purchases"))
        XCTAssertTrue(source.contains("Privacy Policy"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("macCloudStore.subscriptionDisclosure"))
        XCTAssertFalse(source.contains("Continue on iPhone"))
    }

    func testIOSActiveCloudMembersCanRestorePurchasesFromMemberCard() throws {
        let source = try bundledTextResource(named: "CloudStoreView")

        XCTAssertTrue(source.contains("CloudStoreMemberCard(store: store)"))
        XCTAssertTrue(source.contains("Task { await store.restorePurchases() }"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"cloudStore.member.restore\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Restore purchases\")"))
    }

    func testMacAccountUpgradeRoutesToInAppCloudPurchaseSurface() throws {
        let settingsSource = try bundledTextResource(named: "SettingsView")
        let accountSource = try bundledTextResource(named: "AccountSettingsView")

        XCTAssertTrue(settingsSource.contains("router.selectedTab = .cloud"))
        XCTAssertTrue(settingsSource.contains("router.path.removeAll()"))
        XCTAssertTrue(accountSource.contains("account.subscriptionLegalLinks"))
        XCTAssertTrue(accountSource.contains("OpenBurnBar Cloud Monthly is an optional 1 month auto-renewable subscription"))
        XCTAssertFalse(settingsSource.contains("https://apps.apple.com/app/id6766366964"))
    }

    func testReviewNotesDescribeMacIAPLocationAndLegalLinks() throws {
        let source = try bundledTextResource(named: "asc-api", extension: "js")

        XCTAssertTrue(source.contains("macOS Guideline 2.1(a), 2.1(b), and 3.1.2(c) fixes"))
        XCTAssertTrue(source.contains("Account -> Subscription -> Upgrade"))
        XCTAssertTrue(source.contains("Subscribe with App Store"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("AuthenticationServices.AuthorizationError error 1000"))
        XCTAssertTrue(source.contains("com.apple.security.network.server"))
        XCTAssertTrue(source.contains("Quit OpenBurnBar"))
    }

    private func bundledTextResource(named name: String, extension ext: String = "txt") throws -> String {
        let url = try bundledResourceURL(named: name, extension: ext)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func bundledResourceURL(named name: String, extension ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(
            bundle.url(forResource: name, withExtension: ext),
            "Missing bundled compliance fixture: \(name).\(ext)"
        )
    }
}
