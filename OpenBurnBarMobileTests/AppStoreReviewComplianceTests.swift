import XCTest

final class AppStoreReviewComplianceTests: XCTestCase {
    func testMobileInfoPlistDeclaresPrivacyUsageDescriptionsForReviewScannedCapabilities() throws {
        let plistURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let requiredDescriptions: [String: [String]] = [
            "NSCameraUsageDescription": ["Take Photo", "Mercury video call"],
            "NSMicrophoneUsageDescription": ["voice commands", "Mercury audio call"],
            "NSSpeechRecognitionUsageDescription": ["voice command", "spoken command"],
            "NSPhotoLibraryUsageDescription": ["Photo Library", "Hermes chat"],
            "NSPhotoLibraryAddUsageDescription": ["received media", "Save"],
            "NSMotionUsageDescription": ["device motion", "dashboard"],
            "NSLocalNetworkUsageDescription": ["trusted Mac", "Hermes relay"]
        ]

        for (key, expectedFragments) in requiredDescriptions {
            let description = try XCTUnwrap(plist[key] as? String, "\(key) must be present for App Store ITMS-90683 validation")
            XCTAssertGreaterThan(description.count, 20, "\(key) should explain the user-facing reason")
            for fragment in expectedFragments {
                XCTAssertTrue(
                    description.localizedCaseInsensitiveContains(fragment),
                    "\(key) should mention \(fragment)"
                )
            }
        }
    }

    func testAppStoreMetadataContainsSubscriptionDisclosureAndLegalLinks() throws {
        let ascURL = repoRoot()
            .appendingPathComponent("tools")
            .appendingPathComponent("app-store-connect")
            .appendingPathComponent("asc-api.js")
        let metadata = try String(contentsOf: ascURL, encoding: .utf8)

        XCTAssertTrue(metadata.contains("OpenBurnBar Cloud Monthly"))
        XCTAssertTrue(metadata.contains("1 month, auto-renews monthly"))
        XCTAssertTrue(metadata.contains("Hosted Codex quota refresh"))
        XCTAssertTrue(metadata.contains("Privacy Policy: ${LEGAL_URLS.privacy}"))
        XCTAssertTrue(metadata.contains("Terms of Use: ${LEGAL_URLS.terms}"))
        XCTAssertTrue(metadata.contains("https://burnbar.ai/support"))
        XCTAssertFalse(metadata.contains("github.com/Ajnunezg/OpenBurnBar/issues"))
        XCTAssertFalse(metadata.contains("https://openburnbar.com/legal"))
        XCTAssertTrue(metadata.contains("Guideline 2.1(a) camera crash fix"))
    }

    func testCloudStoreUsesFunctionalBurnBarLegalLinksAndDoesNotDisableSubscribeForProductMetadata() throws {
        let storeURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("Store")
            .appendingPathComponent("CloudStoreView.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)

        XCTAssertTrue(source.contains("https://burnbar.ai/legal/privacy-policy"))
        XCTAssertTrue(source.contains("https://burnbar.ai/legal/terms"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("SubscriptionStoreView(productIDs: HostedQuotaSubscriptionStore.appStoreReviewVisibleProductIDs)"))
        XCTAssertTrue(source.contains("OpenBurnBar Computer Use Monthly"))
        XCTAssertTrue(source.contains("OpenBurnBar Pro Max Monthly"))
        XCTAssertTrue(source.contains("All App Store Connect subscriptions for this app are available here"))
        XCTAssertTrue(source.contains(".storeButton(.visible, for: .restorePurchases)"))
        XCTAssertTrue(source.contains(".subscriptionStorePolicyDestination(url: CloudStoreLegalURLs.privacy, for: .privacyPolicy)"))
        XCTAssertTrue(source.contains(".subscriptionStorePolicyDestination(url: CloudStoreLegalURLs.terms, for: .termsOfService)"))
        XCTAssertTrue(source.contains(".onInAppPurchaseCompletion"))
        XCTAssertFalse(source.contains("https://openburnbar.com"))
        XCTAssertFalse(source.contains("Task { await store.purchase() }"))
        XCTAssertFalse(source.contains(".disabled(store.isLoading || store.product == nil)"))
    }

    func testHostedQuotaStoreKeepsReviewVisibleProductsInLockstepWithAppStoreConnectCatalog() throws {
        let storeURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Models")
            .appendingPathComponent("HostedQuotaSubscriptionStore.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)

        XCTAssertTrue(source.contains("static let appStoreReviewVisibleProductIDs"))
        XCTAssertTrue(source.contains("com.openburnbar.hostedQuotaSync.cloud.monthly"))
        XCTAssertTrue(source.contains("com.openburnbar.hostedQuotaSync.monthly"))
        XCTAssertTrue(source.contains("com.openburnbar.hostedComputerUseSync.monthly"))
        XCTAssertTrue(source.contains("com.openburnbar.proMax.monthly"))
        XCTAssertTrue(source.contains("fetchProducts(Self.appStoreReviewVisibleProductIDs)"))
    }

    func testTakePhotoFlowPreflightsPermissionAndUsesFullScreenCameraPresentation() throws {
        let hermesURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("Hermes")
            .appendingPathComponent("HermesTabView.swift")
        let source = try String(contentsOf: hermesURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import AVFoundation"))
        XCTAssertTrue(source.contains(".fullScreenCover(isPresented: $showCameraSheet)"))
        XCTAssertTrue(source.contains("prepareTakePhotoAttachment()"))
        XCTAssertTrue(source.contains("AVCaptureDevice.authorizationStatus(for: .video)"))
        XCTAssertTrue(source.contains("AVCaptureDevice.requestAccess(for: .video)"))
        XCTAssertTrue(source.contains("presentCameraAfterMenuDismissal()"))
        XCTAssertFalse(source.contains("if UIImagePickerController.isSourceTypeAvailable(.camera) {\n                    showCameraSheet = true"))
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "BurnBar", url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url
    }
}
