import XCTest

final class MacAppStoreReviewComplianceTests: XCTestCase {
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
        XCTAssertEqual(plist["com.apple.developer.applesignin"] as? [String], ["Default"])
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
        XCTAssertTrue(source.contains("Settings -> Account -> Subscription -> Upgrade"))
        XCTAssertTrue(source.contains("Subscribe with App Store"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("AuthenticationServices error 1000"))
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
