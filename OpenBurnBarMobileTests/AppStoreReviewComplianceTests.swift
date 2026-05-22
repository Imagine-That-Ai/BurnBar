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

    func testMobileInfoPlistRegistersBurnBarDeepLinksUsedByWidgetsAndLiveActivities() throws {
        let plistURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { type -> [String] in
            type["CFBundleURLSchemes"] as? [String] ?? []
        }

        XCTAssertTrue(schemes.contains("burnbar"))
        XCTAssertTrue(schemes.contains(where: { $0.hasPrefix("com.googleusercontent.apps.") }))
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

    func testCloudStoreUsesFunctionalBurnBarLegalLinksAndUidBoundPurchasePath() throws {
        let storeURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("Store")
            .appendingPathComponent("CloudStoreView.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)

        XCTAssertTrue(source.contains("https://burnbar.ai/legal/privacy-policy"))
        XCTAssertTrue(source.contains("https://burnbar.ai/legal/terms"))
        XCTAssertTrue(source.contains("Terms of Use (EULA)"))
        XCTAssertTrue(source.contains("Task { await store.purchase() }"))
        XCTAssertTrue(source.contains(".disabled(store.isPurchasing)"))
        XCTAssertTrue(source.contains("Restore Purchases"))
        XCTAssertTrue(source.contains("onSignInRequired: { showSignIn = true }"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $showSignIn)"))
        XCTAssertTrue(source.contains("CloudStoreActionBar(\n                            store: store"))
        XCTAssertFalse(source.contains(".frame(maxHeight: .infinity, alignment: .bottom)"))
        XCTAssertFalse(source.contains(".ignoresSafeArea(edges: .bottom)"))
        XCTAssertFalse(source.contains("OpenBurnBar Computer Use Monthly - 1 month"))
        XCTAssertFalse(source.contains("OpenBurnBar Pro Max Monthly - 1 month"))
        XCTAssertTrue(source.contains("All App Store Connect subscriptions for this app are available here"))
        XCTAssertFalse(source.contains(".font(.system(size: 10"))
        XCTAssertTrue(source.contains("CloudStoreLegalLinks(alignment: .center, verboseLabels: true)"))
        XCTAssertFalse(source.contains("SubscriptionStoreView(productIDs: HostedQuotaSubscriptionStore.appStoreReviewVisibleProductIDs)"))
        XCTAssertFalse(source.contains(".onInAppPurchaseCompletion"))
        XCTAssertFalse(source.contains("https://openburnbar.com"))
        XCTAssertFalse(source.contains("Loading App Store price"))
        XCTAssertFalse(source.contains(".disabled(store.isPurchasing || store.product == nil)"))
    }

    func testCloudStoreHidesRootChromeWhilePurchaseScreenIsVisible() throws {
        let storeURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("Store")
            .appendingPathComponent("CloudStoreView.swift")
        let rootTabURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("RootTabView.swift")
        let authGateURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("App")
            .appendingPathComponent("AuthGateView.swift")

        let store = try String(contentsOf: storeURL, encoding: .utf8)
        let rootTab = try String(contentsOf: rootTabURL, encoding: .utf8)
        let authGate = try String(contentsOf: authGateURL, encoding: .utf8)

        XCTAssertTrue(store.contains("cloudStoreChromeVisibilityChanged"))
        XCTAssertTrue(rootTab.contains("isCloudStoreChromeHidden"))
        XCTAssertTrue(rootTab.contains("!isCloudStoreChromeHidden"))
        XCTAssertTrue(rootTab.contains(".environment(\\.mobileAuthStore, authStore)"))
        XCTAssertTrue(authGate.contains(".environment(\\.mobileAuthStore, authStore)"))
    }

    func testIPadRootInstallsAgentWatchLiveStageForScreenSharingParity() throws {
        let rootNavigationURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("RootNavigationView.swift")
        let source = try String(contentsOf: rootNavigationURL, encoding: .utf8)

        XCTAssertTrue(source.contains("AgentWatchOverlaySingleton.shared"))
        XCTAssertTrue(source.contains("AgentLiveStage("))
        XCTAssertTrue(source.contains("liveStageSingleton.configurePictureInPicture"))
        XCTAssertTrue(source.contains("liveStageSingleton.evaluate("))
        XCTAssertTrue(source.contains("ShowAgentWatch"))
        XCTAssertTrue(source.contains("openAgentWatchRoute()"))
    }

    func testReleaseAppCheckUsesAppAttestEntitlementForEnforcedFirestore() throws {
        let entitlementsURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Resources")
            .appendingPathComponent("OpenBurnBarMobile.entitlements")
        let appDelegateURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("App")
            .appendingPathComponent("AppDelegate.swift")

        let data = try Data(contentsOf: entitlementsURL)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let appDelegate = try String(contentsOf: appDelegateURL, encoding: .utf8)

        XCTAssertEqual(
            entitlements["com.apple.developer.devicecheck.appattest-environment"] as? String,
            "production"
        )
        XCTAssertTrue(appDelegate.contains("AppAttestProvider(app: app)"))
        XCTAssertTrue(appDelegate.contains("DeviceCheckProvider(app: app)"))
    }

    func testInternalTestFlightAppCheckBuildInjectsRuntimeSwitchAndDebugToken() throws {
        let projectURL = repoRoot().appendingPathComponent("project.yml")
        let source = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(source.contains("OPENBURNBAR_USE_DEBUG_APP_CHECK: \"NO\""))
        XCTAssertTrue(source.contains("if [[ \"${OPENBURNBAR_USE_DEBUG_APP_CHECK:-}\" != \"YES\" ]]; then"))
        XCTAssertTrue(source.contains("FIREBASE_APP_CHECK_DEBUG_TOKEN is required when OPENBURNBAR_USE_DEBUG_APP_CHECK=YES"))
        XCTAssertTrue(source.contains("BUILT_GOOGLE_PLIST=\"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GoogleService-Info.plist\""))
        XCTAssertTrue(source.contains("BUILT_INFO_PLIST=\"${TARGET_BUILD_DIR}/${INFOPLIST_PATH}\""))
        XCTAssertTrue(source.contains("Add :FirebaseAppCheckDebugToken string ${FIREBASE_APP_CHECK_DEBUG_TOKEN}"))
        XCTAssertTrue(source.contains("Add :FIRAAppCheckDebugToken string ${FIREBASE_APP_CHECK_DEBUG_TOKEN}"))
        XCTAssertTrue(source.contains("Add :OpenBurnBarUseDebugAppCheck string YES"))
        XCTAssertTrue(source.contains("$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"))
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
        XCTAssertTrue(source.contains("com.openburnbar.computerUse.monthly"))
        XCTAssertTrue(source.contains("com.openburnbar.proMax.bundle.monthly"))
        XCTAssertTrue(source.contains("legacyHostedComputerUseProductID"))
        XCTAssertTrue(source.contains("legacyProMaxProductID"))
        XCTAssertTrue(source.contains("Draft products stay out of this list until App"))
        XCTAssertFalse(source.contains("appStoreReviewVisibleProductIDs = [\n        productID,\n        legacyHostedQuotaProductID,\n        hostedComputerUseProductID"))
        XCTAssertTrue(source.contains("fetchProducts(Self.appStoreReviewVisibleProductIDs)"))
        XCTAssertTrue(source.contains("let result = try await purchaseProduct(product, purchaseOptions)"))
        XCTAssertTrue(source.contains("purchaseOptions = [.appAccountToken(token)]"))
        XCTAssertTrue(source.contains("purchaseOptions = []"))
        XCTAssertFalse(source.contains("nativeStorePurchaseStarted"))
        XCTAssertFalse(source.contains("handleNativeStorePurchaseCompletion"))
    }

    func testSharedTypographyMeetsReadableMobileFloorForAppReview() throws {
        let designSystemURL = repoRoot()
            .appendingPathComponent("OpenBurnBarCore")
            .appendingPathComponent("Sources")
            .appendingPathComponent("OpenBurnBarCore")
            .appendingPathComponent("Views")
            .appendingPathComponent("UnifiedDesignSystem.swift")
        let source = try String(contentsOf: designSystemURL, encoding: .utf8)

        XCTAssertTrue(source.contains("public static let body         = Font.system(size: 17"))
        XCTAssertTrue(source.contains("public static let caption      = Font.system(size: 15"))
        XCTAssertTrue(source.contains("public static let tiny         = Font.system(size: 14"))
        XCTAssertTrue(source.contains("public static let monoTiny  = Font.system(size: 13"))
    }

    func testMobileReviewSurfacesDoNotShipHardCodedMicroTypography() throws {
        let roots = [
            repoRoot().appendingPathComponent("OpenBurnBarMobile").appendingPathComponent("App"),
            repoRoot().appendingPathComponent("OpenBurnBarMobile").appendingPathComponent("Views"),
            repoRoot().appendingPathComponent("OpenBurnBarMobile").appendingPathComponent("Settings"),
            repoRoot().appendingPathComponent("OpenBurnBarCore").appendingPathComponent("Sources").appendingPathComponent("OpenBurnBarCore").appendingPathComponent("Views")
        ]
        let microFontPattern = try NSRegularExpression(pattern: #"font\(\.system\(size:\s*(?:5|6|7|7\.5|8|9|10|11)(?:\b|\s*\*)"#)

        for root in roots {
            let urls = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

            for url in urls {
                let source = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                XCTAssertNil(
                    microFontPattern.firstMatch(in: source, range: range),
                    "\(url.path) contains hard-coded type below 12pt"
                )
            }
        }
    }

    func testSignedOutUsersCanReachTheAppAndOnlyCloudAccountFeaturesAskForSignIn() throws {
        let authGateURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("App")
            .appendingPathComponent("AuthGateView.swift")
        let youURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("You")
            .appendingPathComponent("YouView.swift")
        let settingsURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Views")
            .appendingPathComponent("You")
            .appendingPathComponent("SettingsHubView.swift")

        let authGate = try String(contentsOf: authGateURL, encoding: .utf8)
        let you = try String(contentsOf: youURL, encoding: .utf8)
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(authGate.contains("case .signedOut, .signingIn, .firestoreUnavailable:\n            guestRootView"))
        XCTAssertTrue(authGate.contains("private var guestRootView: some View"))
        XCTAssertTrue(you.contains("Sign in for Cloud"))
        XCTAssertTrue(settings.contains("Sign in for Cloud"))
        XCTAssertTrue(authGate.contains(".environment(\\.mobileAuthStore, authStore)"))
        XCTAssertFalse(authGate.contains("case .signedOut, .signingIn, .firestoreUnavailable:\n            SignInScene"))
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
