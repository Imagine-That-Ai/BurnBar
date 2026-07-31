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
        let supportSource = try bundledTextResource(named: "CloudStoreSettingsView+Support")
        let purchaseSource = source + "\n" + supportSource
        let linksSource = try bundledTextResource(named: "MacCloudStoreLegalLinks")

        XCTAssertTrue(purchaseSource.contains("import StoreKit"))
        XCTAssertTrue(purchaseSource.contains("guard let productID = tier.productID(for: billingPeriod)"))
        XCTAssertTrue(purchaseSource.contains("cloudAnnualProductID"))
        XCTAssertTrue(purchaseSource.contains("cloudProAnnualProductID"))
        XCTAssertTrue(purchaseSource.contains("cloudUltraAnnualProductID"))
        XCTAssertTrue(purchaseSource.contains("Product.products(for: [productID])"))
        XCTAssertTrue(purchaseSource.contains("purchaseTarget.purchase(options: purchaseOptions)"))
        XCTAssertTrue(purchaseSource.contains("MacHostedQuotaPurchaseError.signedOutSubscriptionPurchase"))
        XCTAssertTrue(purchaseSource.contains("beginEntitlementBinding"))
        XCTAssertTrue(purchaseSource.contains("verifyHostedQuotaEntitlement"))
        XCTAssertTrue(source.contains("Restore Purchases"))
        XCTAssertTrue(linksSource.contains("Privacy Policy"))
        XCTAssertTrue(linksSource.contains("Terms of Use (EULA)"))
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
        // Disclosure must name the auto-renewable subscriptions and Apple
        // billing next to the upgrade entry point (Guideline 3.1.2). The
        // account panel now shows the live entitlement tier, so the copy
        // covers all three tiers instead of the retired Cloud-Monthly-only
        // sentence.
        XCTAssertTrue(accountSource.contains("BurnBar Cloud, Cloud Pro, and Cloud Ultra are optional auto-renewable subscriptions billed through the App Store."))
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

    func testMacProjectCarriesAppCheckDebugTokenReleaseGuards() throws {
        let source = try bundledTextResource(named: "project", extension: "yml")

        // The July 2026 security remediation (#1959) deleted the debug-token
        // injection build phase outright, so the compliance property is no
        // longer "injection is gated behind an env var": it is that no build
        // phase can stage a debug App Check token at all, while the release
        // artifact verifier still blocks any token that slips in some other
        // way. The release blocker exits early for Debug configurations only,
        // with no OPENBURNBAR_USE_DEBUG_APP_CHECK escape hatch. Mirrors the
        // iOS assertions in OpenBurnBarMobileTests/AppStoreReviewComplianceTests.
        XCTAssertFalse(source.contains("Inject Internal Mac App Check Debug Token"))
        XCTAssertFalse(source.contains("OPENBURNBAR_USE_DEBUG_APP_CHECK"))
        XCTAssertFalse(source.contains("FIRAAppCheckDebugToken"))
        XCTAssertFalse(source.contains("FirebaseAppCheckDebugToken"))
        XCTAssertTrue(source.contains("Block Mac App Check Debug Token In Release"))
        XCTAssertTrue(source.contains("if [[ \"${CONFIGURATION:-}\" == \"Debug\" ]]; then"))
        XCTAssertTrue(source.contains("AgentLens/Resources/GoogleService-Info.plist"))
        XCTAssertTrue(source.contains("scripts/ci/verify-apple-appcheck-release-artifact.sh"))
    }

    func testMacRuntimeGatesDebugAppCheckBehindSharedPolicy() throws {
        let appSource = try bundledTextResource(named: "AgentLensApp")
        let factorySource = try bundledTextResource(named: "OpenBurnBarAppCheckProviderFactory")

        XCTAssertFalse(appSource.contains("AppCheckDebugTokenEnvironment.configureIfAvailable(firebasePlistPath: path)"))
        XCTAssertTrue(factorySource.contains("debugAppCheckAllowed("))
        XCTAssertTrue(factorySource.contains("availableToken("))
        XCTAssertTrue(factorySource.contains("debugAppCheckAllowed: true"))
        XCTAssertFalse(factorySource.contains("configureIfAvailable(firebasePlistPath: firebasePlistPath)"))
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
