import StoreKit
import StoreKitTest
import UIKit
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

private let burnBarProProductID = "com.openburnbar.pro.monthly"
private let burnBarProMaxProductID = "com.openburnbar.proMax.v2.monthly"
private let burnBarUltraProductID = "com.openburnbar.ultra.monthly"

@MainActor
final class HostedQuotaSubscriptionStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UltraTierBridge.shared.tier = nil
    }

    override func tearDown() {
        UltraTierBridge.shared.tier = nil
        super.tearDown()
    }

    func testCatalogMatchesLockedCommercialProductIDs() {
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudMonthlyProductID, "com.openburnbar.pro.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudAnnualProductID, "com.openburnbar.pro.annual")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudProMonthlyProductID, "com.openburnbar.proMax.v2.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudProAnnualProductID, "com.openburnbar.proMax.annual")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudUltraMonthlyProductID, "com.openburnbar.ultra.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudUltraAnnualProductID, "com.openburnbar.ultra.annual.v2")
        XCTAssertEqual(OpenBurnBarProductCatalog.googlePlayCloudProMonthlyProductID, "com.openburnbar.promax.v2.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.googlePlayCloudProAnnualProductID, "com.openburnbar.promax.annual")
        XCTAssertEqual(OpenBurnBarProductCatalog.googlePlayCloudUltraAnnualProductID, "com.openburnbar.ultra.annual")
        XCTAssertEqual(OpenBurnBarProductCatalog.agentControl100ActionsProductID, "com.openburnbar.agentControl.actions100")
        XCTAssertEqual(OpenBurnBarProductCatalog.flooRelay50GBProductID, "com.openburnbar.floo.relay50gb")
        XCTAssertEqual(OpenBurnBarProductCatalog.elderWandSearches100ProductID, "com.openburnbar.elderWand.searches100")
        XCTAssertEqual(OpenBurnBarProductCatalog.elderWandSearches500ProductID, "com.openburnbar.elderWand.searches500")
        XCTAssertEqual(OpenBurnBarProductCatalog.legacyHostedQuotaProductID, "com.openburnbar.hostedQuotaSync.cloud.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.legacyProMaxBundleProductID, "com.openburnbar.proMax.bundle.monthly")

        XCTAssertEqual(OpenBurnBarProductCatalog.subscriptions.map(\.id), [
            "com.openburnbar.pro.monthly",
            "com.openburnbar.pro.annual",
            "com.openburnbar.proMax.v2.monthly",
            "com.openburnbar.proMax.annual",
            "com.openburnbar.ultra.monthly",
            "com.openburnbar.ultra.annual.v2"
        ])
        XCTAssertEqual(OpenBurnBarProductCatalog.subscriptions.map(\.fallbackDisplayPrice), [
            "$7.99",
            "$79",
            "$24.99",
            "$249",
            "$59.99",
            "$599"
        ])
        XCTAssertEqual(OpenBurnBarProductCatalog.subscriptions.map(\.entitlementID), [
            "burnbar_pro",
            "burnbar_pro",
            "burnbar_pro_max",
            "burnbar_pro_max",
            "burnbar_ultra",
            "burnbar_ultra"
        ])
        XCTAssertEqual(OpenBurnBarProductCatalog.topUps.map(\.id), [
            "com.openburnbar.agentControl.actions100",
            "com.openburnbar.floo.relay50gb",
            "com.openburnbar.elderWand.searches100",
            "com.openburnbar.elderWand.searches500"
        ])
        XCTAssertEqual(OpenBurnBarProductCatalog.topUps.map(\.fallbackDisplayPrice), ["$4.99", "$4.99", "$4.99", "$19.99"])
        XCTAssertEqual(OpenBurnBarProductCatalog.topUps.map(\.topUpKind), [
            "agent_control_actions_100",
            "floo_relay_50gb",
            "elder_wand_searches_100",
            "elder_wand_searches_500"
        ])
        // Storefront honesty: only packs whose units something can actually
        // SPEND are sold. Agent Control and Floo relay reserves have no client
        // callers yet, so their packs stay off sale (while remaining in the
        // catalog for restores and credit display).
        XCTAssertEqual(OpenBurnBarProductCatalog.purchasableTopUps.map(\.topUpKind), [
            "elder_wand_searches_100",
            "elder_wand_searches_500"
        ])
        XCTAssertFalse(OpenBurnBarProductCatalog.visibleProductIDs.contains("com.openburnbar.hostedQuotaSync.cloud.monthly"))
        XCTAssertFalse(OpenBurnBarProductCatalog.visibleProductIDs.contains("com.openburnbar.proMax.bundle.monthly"))
        XCTAssertFalse(OpenBurnBarProductCatalog.visibleProductIDs.contains("com.openburnbar.proMax.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.hostedQuotaSync.cloud.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.proMax.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.proMax.bundle.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.promax.v2.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.promax.annual"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.ultra.annual"))
    }

    func testCatalogCopyAvoidsStaticTrialPromisesAndMatchesCurrentUltraLimits() {
        XCTAssertFalse(
            OpenBurnBarProductCatalog.subscriptions.contains {
                $0.disclosure.localizedCaseInsensitiveContains("14-day")
            }
        )
        let ultraMonthly = OpenBurnBarProductCatalog.product(
            for: OpenBurnBarProductCatalog.cloudUltraMonthlyProductID
        )
        XCTAssertEqual(
            ultraMonthly?.included.contains("100 sources, 500,000 chunks, 10 GB"),
            true
        )
        XCTAssertTrue(
            OpenBurnBarProductCatalog.topUps.allSatisfy {
                $0.disclosure.contains("Cloud Pro or Ultra")
            }
        )
    }

    func testLoadReadsPaidTierProductsFromStoreKitConfiguration() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        let store = makeHostedQuotaSubscriptionStore(functions: service)

        await store.load()

        XCTAssertNil(store.error)
        XCTAssertEqual(store.product?.id, HostedQuotaSubscriptionStore.productID)
        XCTAssertEqual(store.productsByID.count, HostedQuotaSubscriptionStore.appStoreReviewVisibleProductIDs.count)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.cloudAnnualProductID)?.id, HostedQuotaSubscriptionStore.cloudAnnualProductID)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.cloudProMonthlyProductID)?.id, HostedQuotaSubscriptionStore.cloudProMonthlyProductID)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.cloudProAnnualProductID)?.id, HostedQuotaSubscriptionStore.cloudProAnnualProductID)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.agentControl100ActionsProductID)?.id, HostedQuotaSubscriptionStore.agentControl100ActionsProductID)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.flooRelay50GBProductID)?.id, HostedQuotaSubscriptionStore.flooRelay50GBProductID)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.elderWandSearches100ProductID)?.id, HostedQuotaSubscriptionStore.elderWandSearches100ProductID)
        XCTAssertEqual(store.storeProduct(for: HostedQuotaSubscriptionStore.elderWandSearches500ProductID)?.id, HostedQuotaSubscriptionStore.elderWandSearches500ProductID)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(service.restoreRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testPurchaseCloudProAnnualMintsBindingForSelectedTier() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponse: .burnBarProMax(active: true, expiresAt: expiresAt)
        )
        var purchasedProductID: String?
        var didFinishTransaction = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { product, _ in
                purchasedProductID = product.id
                return .success(
                    signedTransactionJWS: "signed-pro-annual-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { true }
        )
        await store.load()

        await store.purchase(productID: HostedQuotaSubscriptionStore.cloudProAnnualProductID)

        XCTAssertNil(store.error)
        XCTAssertEqual(purchasedProductID, HostedQuotaSubscriptionStore.cloudProAnnualProductID)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActivePro)
        XCTAssertEqual(store.activeProductID, burnBarProMaxProductID)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(service.bindingRequests.first?.productID, HostedQuotaSubscriptionStore.cloudProAnnualProductID)
        XCTAssertEqual(service.verifyRequests.first?.productID, HostedQuotaSubscriptionStore.cloudProAnnualProductID)
    }

    func testPurchaseUltraMonthlyMintsBindingForSelectedTier() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponse: .burnBarUltra(active: true, expiresAt: expiresAt)
        )
        var purchasedProductID: String?
        var didFinishTransaction = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { product, _ in
                purchasedProductID = product.id
                return .success(
                    signedTransactionJWS: "signed-ultra-monthly-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { true }
        )
        await store.load()

        await store.purchase(productID: HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID)

        XCTAssertNil(store.error)
        XCTAssertEqual(purchasedProductID, HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActivePro)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(service.bindingRequests.first?.productID, HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID)
        XCTAssertEqual(service.verifyRequests.first?.productID, HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID)
    }

    func testPurchaseRecoversUltraDirectEntitlementAfterStoreKitFailure() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 4_102_444_799)
        let service = FakeHostedQuotaEntitlementService()
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarUltra(active: true, expiresAt: expiresAt)
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            purchaseProduct: { _, _ in throw TestHostedQuotaError.storeKitInternal },
            isSignedIn: { true }
        )

        await store.purchase()

        XCTAssertNil(store.error)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActivePro)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(directReader.fetchCount, 1)
        XCTAssertEqual(service.bindingRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testPurchaseRecoversUltraServerTierAfterStoreKitFailureWhenDirectReadUnavailable() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        let tierReader = FakeHostedQuotaTierReader(tier: "ultra")
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            tierReader: tierReader,
            purchaseProduct: { _, _ in throw TestHostedQuotaError.storeKitInternal },
            isSignedIn: { true }
        )

        await store.purchase()

        XCTAssertNil(store.error)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActivePro)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertNil(store.expirationDate)
        XCTAssertEqual(tierReader.fetchCount, 1)
        XCTAssertEqual(service.bindingRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testPurchaseCloudProTopUpCreditsAllowance() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .burnBarProMax(active: true, expiresAt: Date(timeIntervalSince1970: 2_000_000_000)),
            topUpResponse: CloudProTopUpCreditResponse(
                credited: true,
                monthKey: "2026-05",
                units: 100,
                kind: "agent_control_actions_100"
            )
        )
        var purchasedProductID: String?
        var didFinishTransaction = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { product, _ in
                purchasedProductID = product.id
                return .success(
                    signedTransactionJWS: "signed-actions-topup-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { true }
        )
        await store.load()

        await store.purchase(productID: HostedQuotaSubscriptionStore.agentControl100ActionsProductID)

        XCTAssertNil(store.error)
        XCTAssertEqual(purchasedProductID, HostedQuotaSubscriptionStore.agentControl100ActionsProductID)
        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(service.bindingRequests.last?.productID, HostedQuotaSubscriptionStore.agentControl100ActionsProductID)
        XCTAssertEqual(service.topUpRequests.count, 1)
        XCTAssertEqual(service.topUpRequests.first?.signedTransactionJWS, "signed-actions-topup-jws")
        XCTAssertEqual(service.topUpRequests.first?.productID, HostedQuotaSubscriptionStore.agentControl100ActionsProductID)
        XCTAssertEqual(store.lastTopUpCredit?.credited, true)
        XCTAssertEqual(store.lastTopUpCredit?.units, 100)
    }

    func testPurchaseMintsBindingAndTrustsServerEntitlementResponse() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        var didFinishTransaction = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { _, _ in
                .success(
                    signedTransactionJWS: "signed-transaction-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { true }
        )
        await store.load()

        await store.purchase()

        XCTAssertNil(store.error)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(service.bindingRequests.count, 1)
        XCTAssertEqual(service.bindingRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
        let expectedPlatform = UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        XCTAssertEqual(service.bindingRequests.first?.clientPlatform, expectedPlatform)
        XCTAssertEqual(service.verifyRequests.count, 1)
        XCTAssertEqual(service.verifyRequests.first?.signedTransactionJWS, "signed-transaction-jws")
        XCTAssertEqual(service.verifyRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testRefreshFallsBackToServerEntitlementWhenNoLocalTransactionExists() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        let store = makeHostedQuotaSubscriptionStore(functions: service)

        try await store.refreshEntitlement()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertNil(service.restoreRequests.first?.signedTransactionJWS)
    }

    func testRefreshPrefersUltraAcrossMultipleCurrentEntitlements() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let now = Date()
        let ultraExpires = now.addingTimeInterval(3_600)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponsesByProductID: [
                HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID:
                    .burnBarUltra(active: true, expiresAt: ultraExpires)
            ]
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            currentEntitlementReader: {
                [
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.productID,
                        signedTransactionJWS: "cloud-jws",
                        expirationDate: now.addingTimeInterval(86_400),
                        purchaseDate: now.addingTimeInterval(-100),
                        transactionID: 30
                    ),
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "ultra-jws",
                        expirationDate: ultraExpires,
                        purchaseDate: now.addingTimeInterval(-300),
                        transactionID: 10
                    ),
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.cloudProMonthlyProductID,
                        signedTransactionJWS: "pro-jws",
                        expirationDate: now.addingTimeInterval(172_800),
                        purchaseDate: now.addingTimeInterval(-200),
                        transactionID: 20
                    )
                ]
            }
        )

        try await store.refreshEntitlement()

        XCTAssertEqual(service.verifyRequests.map(\.productID), [
            HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID
        ])
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID)
        XCTAssertEqual(store.expirationDate, ultraExpires)
        XCTAssertEqual(store.purchaseDate, now.addingTimeInterval(-300))
        XCTAssertEqual(store.latestTransactionID, 10)
    }

    func testRefreshUsesExpirationThenPurchaseRecencyWithinSameTier() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let now = Date()
        let laterExpiration = now.addingTimeInterval(172_800)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponsesByProductID: [
                HostedQuotaSubscriptionStore.cloudUltraAnnualProductID:
                    .subscription(
                        productID: HostedQuotaSubscriptionStore.cloudUltraAnnualProductID,
                        active: true,
                        expiresAt: laterExpiration
                    )
            ]
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            currentEntitlementReader: {
                [
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "ultra-monthly-jws",
                        expirationDate: now.addingTimeInterval(3_600),
                        purchaseDate: now.addingTimeInterval(-10),
                        transactionID: 200
                    ),
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.cloudUltraAnnualProductID,
                        signedTransactionJWS: "ultra-annual-jws",
                        expirationDate: laterExpiration,
                        purchaseDate: now.addingTimeInterval(-1_000),
                        transactionID: 100
                    )
                ]
            }
        )

        try await store.refreshEntitlement()

        XCTAssertEqual(service.verifyRequests.map(\.productID), [
            HostedQuotaSubscriptionStore.cloudUltraAnnualProductID
        ])
        XCTAssertEqual(store.activeProductID, HostedQuotaSubscriptionStore.cloudUltraAnnualProductID)
        XCTAssertEqual(store.expirationDate, laterExpiration)
        XCTAssertEqual(store.latestTransactionID, 100)
    }

    func testLowerTierTransactionUpdateDoesNotDowngradeWhileUltraRefreshIsPending() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSinceNow: 3_600)
        let gate = HostedQuotaEntitlementReaderGate(
            entitlements: [
                HostedQuotaCurrentEntitlement(
                    productID: HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID,
                    signedTransactionJWS: "ultra-current-jws",
                    expirationDate: expiresAt,
                    purchaseDate: Date(timeIntervalSinceNow: -600),
                    transactionID: 900
                )
            ]
        )
        let secondReadStarted = expectation(description: "aggregate StoreKit refresh started")
        gate.onSecondRead = { secondReadStarted.fulfill() }
        let service = FakeHostedQuotaEntitlementService(
            verifyResponsesByProductID: [
                HostedQuotaSubscriptionStore.productID:
                    .burnBarPro(active: true, expiresAt: expiresAt),
                HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID:
                    .burnBarUltra(active: true, expiresAt: expiresAt)
            ]
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            currentEntitlementReader: { await gate.read() }
        )
        try await store.refreshEntitlement()
        XCTAssertEqual(store.cloudTier, .ultra)

        var didFinish = false
        let updateTask = Task {
            await store.reconcileTransactionUpdate(
                signedTransactionJWS: "cloud-update-jws",
                productID: HostedQuotaSubscriptionStore.productID,
                finish: { didFinish = true }
            )
        }
        await fulfillment(of: [secondReadStarted], timeout: 1.0)

        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID)
        XCTAssertFalse(didFinish)

        gate.releaseSecondRead()
        await updateTask.value

        XCTAssertNil(store.error)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(service.verifyRequests.map(\.productID), [
            HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID,
            HostedQuotaSubscriptionStore.productID,
            HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID
        ])
    }

    func testRestorePrefersUltraWhenMultipleCurrentEntitlementsExist() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSinceNow: 3_600)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .burnBarUltra(active: true, expiresAt: expiresAt)
        )
        var didSyncAppStore = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            syncAppStore: { didSyncAppStore = true },
            currentEntitlementReader: {
                [
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.productID,
                        signedTransactionJWS: "cloud-restore-jws",
                        expirationDate: Date(timeIntervalSinceNow: 86_400),
                        purchaseDate: nil,
                        transactionID: 1
                    ),
                    HostedQuotaCurrentEntitlement(
                        productID: HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "ultra-restore-jws",
                        expirationDate: expiresAt,
                        purchaseDate: nil,
                        transactionID: 2
                    )
                ]
            }
        )

        await store.restorePurchases()

        XCTAssertTrue(didSyncAppStore)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(
            service.restoreRequests.first?.productID,
            HostedQuotaSubscriptionStore.cloudUltraMonthlyProductID
        )
        XCTAssertEqual(service.restoreRequests.first?.signedTransactionJWS, "ultra-restore-jws")
    }

    func testLoadRefreshesEntitlementWhenProductCatalogFails() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            fetchProducts: { _ in throw TestHostedQuotaError.productCatalogUnavailable },
            isSignedIn: { true }
        )

        await store.load()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
    }

    func testRefreshUsesBurnBarProDirectEntitlementBeforeServerReplay() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarPro(active: true, expiresAt: expiresAt)
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            isSignedIn: { true }
        )

        try await store.refreshEntitlement()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(directReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testRefreshUsesServerSeededUltraDirectEntitlementForMembershipBadge() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 4_102_444_799)
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarUltra(active: true, expiresAt: expiresAt)
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            isSignedIn: { true }
        )

        try await store.refreshEntitlement()

        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActivePro)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(directReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testRefreshUsesServerResolvedUltraTierWhenDirectReadIsUnavailable() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let tierReader = FakeHostedQuotaTierReader(tier: "ultra")
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            tierReader: tierReader,
            isSignedIn: { true }
        )

        try await store.refreshEntitlement()

        XCTAssertNil(store.error)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActivePro)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertNil(store.expirationDate)
        XCTAssertEqual(tierReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testSignedOutRefreshClearsPreviouslyResolvedUltraTier() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        var isSignedIn = true
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let tierReader = FakeHostedQuotaTierReader(tier: "ultra")
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            tierReader: tierReader,
            isSignedIn: { isSignedIn }
        )

        try await store.refreshEntitlement()
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(UltraTierBridge.shared.tier, "ultra")

        isSignedIn = false
        try await store.refreshEntitlement()

        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.activeProductID)
        XCTAssertNil(store.expirationDate)
        XCTAssertNil(store.purchaseDate)
        XCTAssertNil(store.latestTransactionID)
        XCTAssertNil(UltraTierBridge.shared.tier)
        XCTAssertEqual(store.cloudTier, .none)
    }

    func testUnsupportedServerTierClearsStaleUltraState() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        UltraTierBridge.shared.tier = "ultra"
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let tierReader = FakeHostedQuotaTierReader(tier: "enterprise")
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            tierReader: tierReader,
            isSignedIn: { true }
        )

        try await store.refreshEntitlement()

        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.activeProductID)
        XCTAssertNil(UltraTierBridge.shared.tier)
        XCTAssertEqual(store.cloudTier, .none)
    }

    func testRefreshIgnoresSandboxDirectEntitlementWhenRuntimeRejectsEnvironment() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarPro(active: true, expiresAt: expiresAt, environment: "Sandbox")
        )
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            isSignedIn: { true },
            acceptsEntitlementEnvironment: { $0 != "Sandbox" }
        )

        try await store.refreshEntitlement()

        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.activeProductID)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(directReader.fetchCount, 2)
    }

    func testRestoreFallsBackToServerWhenStoreKitHasNoCurrentEntitlement() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        var didSyncAppStore = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            syncAppStore: { didSyncAppStore = true },
            isSignedIn: { true }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(service.restoreRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testRestoreUsesUltraDirectEntitlementBeforeCloudFallbackWhenNoStoreKitTransaction() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 4_102_444_799)
        let service = FakeHostedQuotaEntitlementService()
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarUltra(active: true, expiresAt: expiresAt)
        )
        var didSyncAppStore = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            syncAppStore: { didSyncAppStore = true },
            isSignedIn: { true }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(directReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testRestoreUsesServerResolvedUltraTierBeforeCloudFallbackWhenNoStoreKitTransaction() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        let tierReader = FakeHostedQuotaTierReader(tier: "ultra")
        var didSyncAppStore = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            tierReader: tierReader,
            syncAppStore: { didSyncAppStore = true },
            isSignedIn: { true }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertNil(store.expirationDate)
        XCTAssertEqual(tierReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testRestoreRecoversUltraDirectEntitlementWhenAppStoreSyncFails() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 4_102_444_799)
        let service = FakeHostedQuotaEntitlementService()
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarUltra(active: true, expiresAt: expiresAt)
        )
        var didSyncAppStore = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            syncAppStore: {
                didSyncAppStore = true
                throw TestHostedQuotaError.storeKitInternal
            },
            isSignedIn: { true }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.isActiveUltra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertEqual(store.activeProductID, burnBarUltraProductID)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(directReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
    }

    func testRestoreDoesNotApplySandboxServerResponseWhenRuntimeRejectsEnvironment() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .burnBarPro(active: true, expiresAt: expiresAt, environment: "Sandbox")
        )
        var didSyncAppStore = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            syncAppStore: { didSyncAppStore = true },
            isSignedIn: { true },
            acceptsEntitlementEnvironment: { $0 != "Sandbox" }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.activeProductID)
        XCTAssertEqual(service.restoreRequests.count, 1)
    }

    func testSignedOutSubscriptionDoesNotStartStoreKitPurchase() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        var didCallPurchase = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { _, _ in
                didCallPurchase = true
                return .pending
            },
            isSignedIn: { false }
        )
        await store.load()

        await store.purchase()

        XCTAssertFalse(didCallPurchase)
        XCTAssertEqual(service.bindingRequests.count, 0)
        XCTAssertEqual(service.verifyRequests.count, 0)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.error?.contains("Sign in to OpenBurnBar"), true)
        XCTAssertEqual(store.error?.localizedCaseInsensitiveContains("Unauthenticated"), false)
    }

    func testSignedOutTopUpDoesNotStartConsumablePurchase() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        var didCallPurchase = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { _, _ in
                didCallPurchase = true
                return .pending
            },
            isSignedIn: { false }
        )
        await store.load()

        await store.purchase(productID: HostedQuotaSubscriptionStore.flooRelay50GBProductID)

        XCTAssertFalse(didCallPurchase)
        XCTAssertEqual(service.bindingRequests.count, 0)
        XCTAssertEqual(service.topUpRequests.count, 0)
        XCTAssertEqual(store.error?.contains("Sign in to OpenBurnBar"), true)
    }

    func testPurchaseFetchesProductWhenLoadHasNotCompleted() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        var purchasedProductID: String?
        var didFinishTransaction = false
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { product, _ in
                purchasedProductID = product.id
                return .success(
                    signedTransactionJWS: "purchase-before-load-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { true }
        )

        await store.purchase()

        XCTAssertNil(store.error)
        XCTAssertEqual(purchasedProductID, HostedQuotaSubscriptionStore.productID)
        XCTAssertEqual(store.product?.id, HostedQuotaSubscriptionStore.productID)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(service.bindingRequests.count, 1)
        XCTAssertEqual(service.verifyRequests.count, 1)
    }

    private func makeCleanStoreKitSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "OpenBurnBarPaidTiers")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    // MARK: - Annual value framing (store sheet price math)

    func testMonthlyEquivalentUsesCurrencyNativePrecision() {
        // Zero-fraction currencies must not grow bogus sub-units (JPY ¥658,
        // not ¥658.33); two-fraction currencies keep their cents.
        let jpy = Decimal.FormatStyle.Currency(code: "JPY", locale: Locale(identifier: "ja_JP"))
        let jpyLine = HostedQuotaSubscriptionStore.monthlyEquivalent(annualPrice: 7900, format: jpy)
        XCTAssertTrue(jpyLine.contains("658"), jpyLine)
        XCTAssertFalse(jpyLine.contains("."), "JPY must not render sub-unit decimals: \(jpyLine)")

        let usd = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(HostedQuotaSubscriptionStore.monthlyEquivalent(annualPrice: 249, format: usd), "$20.75")
    }

    func testAnnualSealTextSelection() {
        XCTAssertEqual(CloudTierCard.annualSealText(freeMonths: nil), "BEST VALUE")
        XCTAssertEqual(CloudTierCard.annualSealText(freeMonths: 1), "1 MONTH FREE")
        XCTAssertEqual(CloudTierCard.annualSealText(freeMonths: 2), "2 MONTHS FREE")
    }

    func testMonthlyEquivalentDisplayPriceFallsBackToCatalogPrices() {
        let store = makeHostedQuotaSubscriptionStore(
            functions: FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        )
        func plan(_ id: String) -> OpenBurnBarStoreProduct {
            OpenBurnBarProductCatalog.subscriptions.first { $0.id == id }!
        }

        // No StoreKit products loaded → catalog fallback math.
        XCTAssertEqual(
            store.monthlyEquivalentDisplayPrice(for: plan(OpenBurnBarProductCatalog.cloudAnnualProductID)),
            "$6.58"
        )
        XCTAssertEqual(
            store.monthlyEquivalentDisplayPrice(for: plan(OpenBurnBarProductCatalog.cloudProAnnualProductID)),
            "$20.75"
        )
        XCTAssertEqual(
            store.monthlyEquivalentDisplayPrice(for: plan(OpenBurnBarProductCatalog.cloudUltraAnnualProductID)),
            "$49.92"
        )
        // Monthly plans never show an equivalence line.
        XCTAssertNil(
            store.monthlyEquivalentDisplayPrice(for: plan(OpenBurnBarProductCatalog.cloudProMonthlyProductID))
        )
    }

    func testAnnualFreeMonthsDerivedFromCatalogFallbackPrices() {
        let store = makeHostedQuotaSubscriptionStore(
            functions: FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        )
        func plan(_ id: String) -> OpenBurnBarStoreProduct {
            OpenBurnBarProductCatalog.subscriptions.first { $0.id == id }!
        }

        // Every current SKU pair hands back two whole months on annual:
        // $79 vs $7.99×12, $249 vs $24.99×12, $599 vs $59.99×12.
        XCTAssertEqual(
            store.annualFreeMonths(
                monthly: plan(OpenBurnBarProductCatalog.cloudMonthlyProductID),
                annual: plan(OpenBurnBarProductCatalog.cloudAnnualProductID)
            ),
            2
        )
        XCTAssertEqual(
            store.annualFreeMonths(
                monthly: plan(OpenBurnBarProductCatalog.cloudProMonthlyProductID),
                annual: plan(OpenBurnBarProductCatalog.cloudProAnnualProductID)
            ),
            2
        )
        XCTAssertEqual(
            store.annualFreeMonths(
                monthly: plan(OpenBurnBarProductCatalog.cloudUltraMonthlyProductID),
                annual: plan(OpenBurnBarProductCatalog.cloudUltraAnnualProductID)
            ),
            2
        )
    }

    private func makeHostedQuotaSubscriptionStore(
        functions: any HostedQuotaEntitlementServicing,
        directReader: (any HostedQuotaEntitlementDirectReading)? = nil,
        tierReader: (any HostedQuotaTierReading)? = nil,
        purchaseProduct: @escaping HostedQuotaProductPurchaseExecutor = { _, _ in
            throw TestHostedQuotaError.productCatalogUnavailable
        },
        syncAppStore: @escaping HostedQuotaAppStoreSync = {},
        fetchProducts: @escaping HostedQuotaProductCatalogFetcher = { identifiers in
            let products = try await Product.products(for: identifiers)
            return products.map {
                HostedQuotaStoreProduct(id: $0.id, displayPrice: $0.displayPrice, storeKitProduct: $0)
            }
        },
        isSignedIn: @escaping HostedQuotaAuthStateReader = { true },
        acceptsEntitlementEnvironment: @escaping HostedQuotaEntitlementEnvironmentFilter = { _ in true },
        currentEntitlementReader: @escaping HostedQuotaCurrentEntitlementReader = { [] }
    ) -> HostedQuotaSubscriptionStore {
        HostedQuotaSubscriptionStore(
            functions: functions,
            directReader: directReader,
            tierReader: tierReader,
            purchaseProduct: purchaseProduct,
            syncAppStore: syncAppStore,
            fetchProducts: fetchProducts,
            isSignedIn: isSignedIn,
            acceptsEntitlementEnvironment: acceptsEntitlementEnvironment,
            currentEntitlementReader: currentEntitlementReader,
            observeTransactionUpdates: false
        )
    }
}

final class HermesMobileSetupWizardGateTests: XCTestCase {
    func testDoesNotAutoPresentWhenHermesIsAlreadyReachable() {
        let shouldPresent = HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: false,
            didAutoPresent: false,
            hasUsableSetup: true
        )

        XCTAssertFalse(shouldPresent)
    }

    func testAutoPresentsOnlyForFirstUnconfiguredVisit() {
        XCTAssertTrue(HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: false,
            didAutoPresent: false,
            hasUsableSetup: false
        ))
        XCTAssertFalse(HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: true,
            didAutoPresent: false,
            hasUsableSetup: false
        ))
        XCTAssertFalse(HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: false,
            didAutoPresent: true,
            hasUsableSetup: false
        ))
    }

    func testUsableSetupIncludesReachabilitySelectedRelayOrSuggestedRelay() {
        let selectedRelay = HermesConnectionRecord(
            id: "relay-selected",
            displayName: "Selected Relay",
            mode: .relayLink,
            status: .online
        )
        let suggestedRelay = HermesConnectionRecord(
            id: "relay-suggested",
            displayName: "Suggested Relay",
            mode: .relayLink,
            status: .online
        )

        XCTAssertTrue(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: true,
            selectedConnection: .localDefault,
            suggestedRelayConnection: nil
        ))
        XCTAssertTrue(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: false,
            selectedConnection: selectedRelay,
            suggestedRelayConnection: nil
        ))
        XCTAssertTrue(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: false,
            selectedConnection: .localDefault,
            suggestedRelayConnection: suggestedRelay
        ))
        XCTAssertFalse(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: false,
            selectedConnection: .localDefault,
            suggestedRelayConnection: nil
        ))
    }
}

private enum TestHostedQuotaError: Error {
    case replayUnavailable
    case productCatalogUnavailable
    case storeKitInternal
}

@MainActor
private final class HostedQuotaEntitlementReaderGate {
    let entitlements: [HostedQuotaCurrentEntitlement]
    var onSecondRead: (() -> Void)?

    private var readCount = 0
    private var secondReadContinuation: CheckedContinuation<Void, Never>?

    init(entitlements: [HostedQuotaCurrentEntitlement]) {
        self.entitlements = entitlements
    }

    func read() async -> [HostedQuotaCurrentEntitlement] {
        readCount += 1
        if readCount == 2 {
            onSecondRead?()
            await withCheckedContinuation { continuation in
                secondReadContinuation = continuation
            }
        }
        return entitlements
    }

    func releaseSecondRead() {
        secondReadContinuation?.resume()
        secondReadContinuation = nil
    }
}

@MainActor
private final class FakeHostedQuotaEntitlementService: HostedQuotaEntitlementServicing {
    struct BindingRequest: Equatable {
        let productID: String
        let clientPlatform: String?
    }

    struct VerifyRequest: Equatable {
        let signedTransactionJWS: String
        let signedRenewalInfoJWS: String?
        let productID: String?
    }

    struct RestoreRequest: Equatable {
        let productID: String?
        let signedTransactionJWS: String?
    }

    struct TopUpRequest: Equatable {
        let signedTransactionJWS: String
        let productID: String
    }

    private let bindingToken: String
    private let verifyResponse: HostedQuotaEntitlementResponse
    private let verifyResponsesByProductID: [String: HostedQuotaEntitlementResponse]
    private let restoreResponse: HostedQuotaEntitlementResponse
    private let topUpResponse: CloudProTopUpCreditResponse
    private let restoreError: Error?

    private(set) var bindingRequests: [BindingRequest] = []
    private(set) var verifyRequests: [VerifyRequest] = []
    private(set) var restoreRequests: [RestoreRequest] = []
    private(set) var topUpRequests: [TopUpRequest] = []

    init(
        bindingToken: String = "00000000-0000-4000-8000-000000000001",
        verifyResponse: HostedQuotaEntitlementResponse = .hostedQuota(active: false),
        verifyResponsesByProductID: [String: HostedQuotaEntitlementResponse] = [:],
        restoreResponse: HostedQuotaEntitlementResponse = .hostedQuota(active: false),
        topUpResponse: CloudProTopUpCreditResponse = CloudProTopUpCreditResponse(
            credited: false,
            monthKey: "2026-05",
            units: 0,
            kind: "agent_control_actions_100"
        ),
        restoreError: Error? = nil
    ) {
        self.bindingToken = bindingToken
        self.verifyResponse = verifyResponse
        self.verifyResponsesByProductID = verifyResponsesByProductID
        self.restoreResponse = restoreResponse
        self.topUpResponse = topUpResponse
        self.restoreError = restoreError
    }

    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String?
    ) async throws -> String {
        bindingRequests.append(BindingRequest(productID: productID, clientPlatform: clientPlatform))
        return bindingToken
    }

    func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        signedRenewalInfoJWS: String?,
        productID: String?
    ) async throws -> HostedQuotaEntitlementResponse {
        verifyRequests.append(
            VerifyRequest(
                signedTransactionJWS: signedTransactionJWS,
                signedRenewalInfoJWS: signedRenewalInfoJWS,
                productID: productID
            )
        )
        return productID.flatMap { verifyResponsesByProductID[$0] } ?? verifyResponse
    }

    func restoreHostedQuotaEntitlement(
        productID: String?,
        signedTransactionJWS: String?
    ) async throws -> HostedQuotaEntitlementResponse {
        restoreRequests.append(
            RestoreRequest(
                productID: productID,
                signedTransactionJWS: signedTransactionJWS
            )
        )
        if let restoreError {
            throw restoreError
        }
        return restoreResponse
    }

    func verifyCloudProTopUp(
        signedTransactionJWS: String,
        productID: String
    ) async throws -> CloudProTopUpCreditResponse {
        topUpRequests.append(TopUpRequest(signedTransactionJWS: signedTransactionJWS, productID: productID))
        return topUpResponse
    }
}

@MainActor
private final class FakeHostedQuotaDirectReader: HostedQuotaEntitlementDirectReading {
    private let response: HostedQuotaEntitlementResponse?
    private(set) var fetchCount = 0

    init(response: HostedQuotaEntitlementResponse?) {
        self.response = response
    }

    func fetchHostedQuotaEntitlement() async throws -> HostedQuotaEntitlementResponse? {
        fetchCount += 1
        return response
    }
}

@MainActor
private final class FakeHostedQuotaTierReader: HostedQuotaTierReading {
    private let tier: String?
    private(set) var fetchCount = 0

    init(tier: String?) {
        self.tier = tier
    }

    func fetchHostedQuotaTier() async throws -> String? {
        fetchCount += 1
        return tier
    }
}

private extension HostedQuotaEntitlementResponse {
    static func subscription(
        productID: String,
        active: Bool,
        expiresAt: Date? = nil,
        environment: String = "Xcode"
    ) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: productID,
            transactionID: active ? "test-\(productID)-transaction" : nil,
            originalTransactionID: active ? "test-\(productID)-original-transaction" : nil,
            environment: environment,
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }

    static func hostedQuota(
        active: Bool,
        expiresAt: Date? = nil,
        environment: String = "Xcode"
    ) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: HostedQuotaSubscriptionStore.legacyHostedQuotaProductID,
            transactionID: active ? "test-transaction" : nil,
            originalTransactionID: active ? "test-original-transaction" : nil,
            environment: environment,
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }

    static func burnBarPro(
        active: Bool,
        expiresAt: Date? = nil,
        environment: String = "Xcode"
    ) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: burnBarProProductID,
            transactionID: active ? "test-pro-transaction" : nil,
            originalTransactionID: active ? "test-pro-original-transaction" : nil,
            environment: environment,
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }

    static func burnBarProMax(
        active: Bool,
        expiresAt: Date? = nil,
        environment: String = "Xcode"
    ) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: burnBarProMaxProductID,
            transactionID: active ? "test-pro-max-transaction" : nil,
            originalTransactionID: active ? "test-pro-max-original-transaction" : nil,
            environment: environment,
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }

    static func burnBarUltra(
        active: Bool,
        expiresAt: Date? = nil,
        environment: String = "Xcode"
    ) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: burnBarUltraProductID,
            transactionID: active ? "test-ultra-transaction" : nil,
            originalTransactionID: active ? "test-ultra-original-transaction" : nil,
            environment: environment,
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }
}
