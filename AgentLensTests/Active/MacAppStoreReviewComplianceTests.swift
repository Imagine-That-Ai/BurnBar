import XCTest

final class MacAppStoreReviewComplianceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Static source-scan tests; fail fast if the XCTest host wedges.
        executionTimeAllowance = 30
    }
    func testMASEntitlementsIncludeSandboxAndSignInWithApple() throws {
        let entitlementsURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Resources")
            .appendingPathComponent("OpenBurnBarMAS.entitlements")
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
        let popoverURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Views")
            .appendingPathComponent("Popover")
            .appendingPathComponent("MenuBarPopoverView.swift")
        let source = try String(contentsOf: popoverURL, encoding: .utf8)

        XCTAssertTrue(source.contains("title: \"Quit OpenBurnBar\""))
        XCTAssertTrue(source.contains("NSApplication.shared.terminate(nil)"))
    }

    func testMacCloudStoreHasNativeStoreKitPurchaseAndLegalLinks() throws {
        let sourceURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Views")
            .appendingPathComponent("Settings")
            .appendingPathComponent("CloudStoreSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import StoreKit"))
        XCTAssertTrue(source.contains("Product.products(for: [Self.productID])"))
        XCTAssertTrue(source.contains("product.purchase(options: purchaseOptions)"))
        XCTAssertTrue(source.contains("beginEntitlementBinding"))
        XCTAssertTrue(source.contains("verifyHostedQuotaEntitlement"))
        XCTAssertTrue(source.contains("Restore Purchases"))
        XCTAssertTrue(source.contains("Privacy Policy"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("macCloudStore.subscriptionDisclosure"))
        XCTAssertFalse(source.contains("Continue on iPhone"))
    }

    func testIOSActiveCloudMembersCanRestorePurchasesFromMemberCard() throws {
        let sourceURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("Store")
            .appendingPathComponent("CloudStoreView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("CloudStoreMemberCard(store: store)"))
        XCTAssertTrue(source.contains("Task { await store.restorePurchases() }"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"cloudStore.member.restore\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Restore purchases\")"))
    }

    func testMacAccountUpgradeRoutesToInAppCloudPurchaseSurface() throws {
        let settingsURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Views")
            .appendingPathComponent("Settings")
            .appendingPathComponent("SettingsView.swift")
        let accountURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Views")
            .appendingPathComponent("Settings")
            .appendingPathComponent("AccountSettingsView.swift")
        let settingsSource = try String(contentsOf: settingsURL, encoding: .utf8)
        let accountSource = try String(contentsOf: accountURL, encoding: .utf8)

        XCTAssertTrue(settingsSource.contains("router.selectedTab = .cloud"))
        XCTAssertTrue(settingsSource.contains("router.path.removeAll()"))
        XCTAssertTrue(accountSource.contains("account.subscriptionLegalLinks"))
        XCTAssertTrue(accountSource.contains("OpenBurnBar Cloud Monthly is an optional 1 month auto-renewable subscription"))
        XCTAssertFalse(settingsSource.contains("https://apps.apple.com/app/id6766366964"))
    }

    func testReviewNotesDescribeMacIAPLocationAndLegalLinks() throws {
        let ascURL = repoRoot()
            .appendingPathComponent("tools")
            .appendingPathComponent("app-store-connect")
            .appendingPathComponent("asc-api.js")
        let source = try String(contentsOf: ascURL, encoding: .utf8)

        XCTAssertTrue(source.contains("macOS Guideline 2.1(a), 2.1(b), and 3.1.2(c) fixes"))
        XCTAssertTrue(source.contains("Account -> Subscription -> Upgrade"))
        XCTAssertTrue(source.contains("Subscribe with App Store"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("AuthenticationServices.AuthorizationError error 1000"))
        XCTAssertTrue(source.contains("com.apple.security.network.server"))
        XCTAssertTrue(source.contains("Quit OpenBurnBar"))
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        // AgentLensTests/Active/<this file> → repo root (no filesystem walk; avoids
        // rare hangs when FileManager probes network-backed paths under xcodebuild).
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
