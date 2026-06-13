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
    func testCatalogMatchesLockedCommercialProductIDs() {
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudMonthlyProductID, "com.openburnbar.pro.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudAnnualProductID, "com.openburnbar.pro.annual")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudProMonthlyProductID, "com.openburnbar.proMax.v2.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudProAnnualProductID, "com.openburnbar.proMax.annual")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudUltraMonthlyProductID, "com.openburnbar.ultra.monthly")
        XCTAssertEqual(OpenBurnBarProductCatalog.cloudUltraAnnualProductID, "com.openburnbar.ultra.annual.v2")
        XCTAssertEqual(OpenBurnBarProductCatalog.agentControl100ActionsProductID, "com.openburnbar.agentControl.actions100")
        XCTAssertEqual(OpenBurnBarProductCatalog.flooRelay50GBProductID, "com.openburnbar.floo.relay50gb")
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
            "com.openburnbar.floo.relay50gb"
        ])
        XCTAssertEqual(OpenBurnBarProductCatalog.topUps.map(\.fallbackDisplayPrice), ["$4.99", "$4.99"])
        XCTAssertEqual(OpenBurnBarProductCatalog.topUps.map(\.topUpKind), [
            "agent_control_actions_100",
            "floo_relay_50gb"
        ])
        XCTAssertFalse(OpenBurnBarProductCatalog.visibleProductIDs.contains("com.openburnbar.hostedQuotaSync.cloud.monthly"))
        XCTAssertFalse(OpenBurnBarProductCatalog.visibleProductIDs.contains("com.openburnbar.proMax.bundle.monthly"))
        XCTAssertFalse(OpenBurnBarProductCatalog.visibleProductIDs.contains("com.openburnbar.proMax.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.hostedQuotaSync.cloud.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.proMax.monthly"))
        XCTAssertTrue(OpenBurnBarProductCatalog.entitlementProductIDs.contains("com.openburnbar.proMax.bundle.monthly"))
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

    func testSignedOutPurchaseStillPresentsStoreKitAndFinishesWithActionableRecovery() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        var didFinishTransaction = false
        var capturedOptions: Set<Product.PurchaseOption>?
        let store = makeHostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { _, options in
                capturedOptions = options
                return .success(
                    signedTransactionJWS: "signed-out-transaction-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { false }
        )
        await store.load()

        await store.purchase()

        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(capturedOptions, [])
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
        currentEntitlementReader: @escaping HostedQuotaCurrentEntitlementReader = { nil }
    ) -> HostedQuotaSubscriptionStore {
        HostedQuotaSubscriptionStore(
            functions: functions,
            directReader: directReader,
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
        return verifyResponse
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

private extension HostedQuotaEntitlementResponse {
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
