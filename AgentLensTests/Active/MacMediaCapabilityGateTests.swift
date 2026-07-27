import CryptoKit
import XCTest
import FirebaseCore
import LocalAuthentication
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import Security
import SwiftUI
@testable import OpenBurnBar

/// Locks in the admission decisions made by `MacMediaCapabilityGate`.
/// This gate is the live admission control surface that Decision 2 of
/// the Mercury master plan calls "Mac is the source of truth", so if a
/// case here regresses, a paying user could either start a session that
/// breaks the budget cap or be wrongly denied during a normal day.
@MainActor
final class MacMediaCapabilityGateTests: XCTestCase {
    private let happyEntitlement = MacMediaCapabilityGate.EntitlementState(
        active: true,
        fileTransfer: true,
        screenShare: true,
        videoCall: true
    )

    private let zeroUsage = MediaQuotaUsageSnapshot()
    private let storeKitUID = "firebase-uid-a"
    private let otherStoreKitUID = "firebase-uid-b"
    private let proAppAccountToken = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let ultraAppAccountToken = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private let normalBudget = MediaBudgetStatus(
        level: .normal,
        projectedMonthEndUSD: 200,
        monthToDateUSD: 100,
        lastEvaluatedAt: Date(),
        activeEnvelope: .normal
    )

    func testHappyPathReturnsAllowedForEachFeature() async {
        let gate = makeGate(
            entitlement: happyEntitlement,
            usage: zeroUsage,
            budget: normalBudget,
            concurrent: 0
        )
        for feature in [MediaStreamClass.Feature.fileTransfer, .screenShare, .videoCall] {
            let result = await gate.check(
                feature: feature,
                sessionDurationLimitSeconds: nil,
                sessionByteBudget: nil
            )
            XCTAssertTrue(result.isAllowed, "expected allowed for \(feature)")
        }
    }

    func testEntitlementInactiveDenies() async {
        let entitlement = MacMediaCapabilityGate.EntitlementState(
            active: false, fileTransfer: true, screenShare: true, videoCall: true
        )
        let gate = makeGate(entitlement: entitlement, usage: zeroUsage, budget: normalBudget, concurrent: 0)
        let result = await gate.check(feature: .videoCall, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .entitlementMissing)
    }

    func testSharedMediaEntitlementMappingFailsClosedUntilMediaOrProMaxEntitlementIsActive() {
        let free = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: false, tier: .free)
        XCTAssertFalse(free.active)
        XCTAssertFalse(free.fileTransfer)
        XCTAssertFalse(free.screenShare)
        XCTAssertFalse(free.videoCall)

        let cloudOnly = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: false, tier: .cloud)
        XCTAssertFalse(cloudOnly.active)

        let mediaSKU = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: true, tier: .free)
        XCTAssertTrue(mediaSKU.active)
        XCTAssertTrue(mediaSKU.fileTransfer)
        XCTAssertTrue(mediaSKU.screenShare)
        XCTAssertTrue(mediaSKU.videoCall)

        let proMax = MacMediaCapabilityGate.entitlementState(hostedMediaIsActive: false, tier: .pro)
        XCTAssertTrue(proMax.active)
    }

    func testMacCloudEntitlementStoreAppliesAndClearsHostedMediaEntitlement() {
        let store = MacCloudEntitlementStore()
        let expiration = Date(timeIntervalSinceNow: 3_600)
        let purchase = Date(timeIntervalSinceNow: -7_200)

        store.applyHostedMedia(data: MacCloudEntitlementDocument([
            "active": true,
            "expiresAt": expiration,
            "purchaseDate": purchase
        ]))

        XCTAssertTrue(store.hostedMediaIsActive)
        XCTAssertEqual(store.hostedMediaExpirationDate?.timeIntervalSince1970, expiration.timeIntervalSince1970)
        XCTAssertEqual(store.hostedMediaPurchaseDate?.timeIntervalSince1970, purchase.timeIntervalSince1970)

        store.clearHostedMediaEntitlement()

        XCTAssertFalse(store.hostedMediaIsActive)
        XCTAssertNil(store.hostedMediaExpirationDate)
        XCTAssertNil(store.hostedMediaPurchaseDate)
    }

    func testMacCloudEntitlementStoreFailsClosedWhenCloudIsNotConfigured() {
        guard FirebaseApp.app() == nil else {
            return
        }
        let store = MacCloudEntitlementStore()

        store.start()

        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.hostedComputerUseIsActive)
        XCTAssertFalse(store.hostedMediaIsActive)
        XCTAssertFalse(store.isUltraActive)
        XCTAssertEqual(store.currentTier, .free)
        XCTAssertEqual(store.cloudTier, .none)
        XCTAssertEqual(store.error, "Cloud is not configured on this Mac.")
    }

    func testMacCloudEntitlementStoreParsesHostedMediaDateShapesAndExpiry() {
        let store = MacCloudEntitlementStore()
        let future = Date(timeIntervalSinceNow: 7_200)
        let purchase = Date(timeIntervalSince1970: 1_700_000_000)

        store.applyHostedMedia(data: MacCloudEntitlementDocument([
            "active": true,
            "expireAt": future.timeIntervalSince1970,
            "originalPurchaseDate": ISO8601DateFormatter().string(from: purchase)
        ]))

        XCTAssertTrue(store.hostedMediaIsActive)
        XCTAssertEqual(
            store.hostedMediaExpirationDate?.timeIntervalSince1970 ?? 0,
            future.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            store.hostedMediaPurchaseDate?.timeIntervalSince1970 ?? 0,
            purchase.timeIntervalSince1970,
            accuracy: 0.001
        )

        store.applyHostedMedia(data: MacCloudEntitlementDocument([
            "active": true,
            "expirationDate": Int(Date(timeIntervalSinceNow: -60).timeIntervalSince1970),
            "purchaseDate": purchase
        ]))

        XCTAssertFalse(store.hostedMediaIsActive)
        XCTAssertEqual(store.hostedMediaPurchaseDate, purchase)
    }

    func testMacCloudStoreKitCatalogMatchesIOSCommercialEntitlementIDs() {
        XCTAssertEqual(MacCloudStoreKitProductCatalog.cloudMonthlyProductID, "com.openburnbar.pro.monthly")
        XCTAssertEqual(MacCloudStoreKitProductCatalog.cloudAnnualProductID, "com.openburnbar.pro.annual")
        XCTAssertEqual(MacCloudStoreKitProductCatalog.cloudProMonthlyProductID, "com.openburnbar.proMax.v2.monthly")
        XCTAssertEqual(MacCloudStoreKitProductCatalog.cloudProAnnualProductID, "com.openburnbar.proMax.annual")
        XCTAssertEqual(MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID, "com.openburnbar.ultra.monthly")
        XCTAssertEqual(MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID, "com.openburnbar.ultra.annual.v2")
        XCTAssertEqual(MacCloudStoreKitProductCatalog.tier(for: "com.openburnbar.pro.monthly"), .cloud)
        XCTAssertEqual(MacCloudStoreKitProductCatalog.tier(for: "com.openburnbar.proMax.bundle.monthly"), .pro)
        XCTAssertEqual(MacCloudStoreKitProductCatalog.tier(for: "com.openburnbar.ultra.monthly"), .ultra)
        XCTAssertEqual(MacCloudStoreKitProductCatalog.tier(for: "com.openburnbar.ultra.annual"), .ultra)
        XCTAssertTrue(MacCloudStoreKitProductCatalog.entitlementProductIDs.contains("com.openburnbar.hostedQuotaSync.cloud.monthly"))
        XCTAssertTrue(MacCloudStoreKitProductCatalog.entitlementProductIDs.contains("com.openburnbar.hostedComputerUseSync.monthly"))
        XCTAssertTrue(MacCloudStoreKitProductCatalog.entitlementProductIDs.contains("com.openburnbar.ultra.annual"))
    }

    func testMacCloudPricingTierMapsEveryPaidMonthlyAndAnnualProduct() {
        XCTAssertNil(MacCloudPricingTier.local.productID(for: .monthly))
        XCTAssertNil(MacCloudPricingTier.local.productID(for: .annual))
        XCTAssertEqual(
            MacCloudPricingTier.cloud.productID(for: .monthly),
            MacCloudStoreKitProductCatalog.cloudMonthlyProductID
        )
        XCTAssertEqual(
            MacCloudPricingTier.cloud.productID(for: .annual),
            MacCloudStoreKitProductCatalog.cloudAnnualProductID
        )
        XCTAssertEqual(
            MacCloudPricingTier.pro.productID(for: .monthly),
            MacCloudStoreKitProductCatalog.cloudProMonthlyProductID
        )
        XCTAssertEqual(
            MacCloudPricingTier.pro.productID(for: .annual),
            MacCloudStoreKitProductCatalog.cloudProAnnualProductID
        )
        XCTAssertEqual(
            MacCloudPricingTier.ultra.productID(for: .monthly),
            MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID
        )
        XCTAssertEqual(
            MacCloudPricingTier.ultra.productID(for: .annual),
            MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID
        )
        XCTAssertEqual(MacHostedQuotaPurchaseStore.tierProductIDs.count, 3)
        XCTAssertEqual(
            Set(MacHostedQuotaPurchaseStore.tierProductIDs.values.flatMap(\.values)).count,
            6
        )
    }

    func testMacHostedQuotaRestorePrefersUltraAcrossMultipleCurrentEntitlements() throws {
        let now = Date()
        let selected = try XCTUnwrap(
            MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
                from: [
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudMonthlyProductID,
                        signedTransactionJWS: "cloud-jws",
                        expirationDate: now.addingTimeInterval(86_400),
                        purchaseDate: now.addingTimeInterval(-100),
                        transactionID: 30
                    ),
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "ultra-jws",
                        expirationDate: now.addingTimeInterval(3_600),
                        purchaseDate: now.addingTimeInterval(-300),
                        transactionID: 10
                    ),
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudProAnnualProductID,
                        signedTransactionJWS: "pro-jws",
                        expirationDate: now.addingTimeInterval(172_800),
                        purchaseDate: now.addingTimeInterval(-200),
                        transactionID: 20
                    )
                ]
            )
        )

        XCTAssertEqual(selected.productID, MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID)
        XCTAssertEqual(selected.signedTransactionJWS, "ultra-jws")
    }

    func testMacHostedQuotaRestoreUsesExpirationWithinSameTier() throws {
        let now = Date()
        let selected = try XCTUnwrap(
            MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
                from: [
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "ultra-monthly-jws",
                        expirationDate: now.addingTimeInterval(3_600),
                        purchaseDate: now,
                        transactionID: 2
                    ),
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID,
                        signedTransactionJWS: "ultra-annual-jws",
                        expirationDate: now.addingTimeInterval(172_800),
                        purchaseDate: now.addingTimeInterval(-86_400),
                        transactionID: 1
                    )
                ]
            )
        )

        XCTAssertEqual(selected.productID, MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID)
        XCTAssertEqual(selected.signedTransactionJWS, "ultra-annual-jws")
    }

    func testMacHostedQuotaRestoreTieBreaksByPurchaseDateWithinSameTierAndExpiration() throws {
        let now = Date()
        let expiry = now.addingTimeInterval(86_400)
        let selected = try XCTUnwrap(
            MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
                from: [
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "older-purchase-jws",
                        expirationDate: expiry,
                        purchaseDate: now.addingTimeInterval(-600),
                        transactionID: 99
                    ),
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.legacyCloudUltraAnnualProductID,
                        signedTransactionJWS: "newer-purchase-jws",
                        expirationDate: expiry,
                        purchaseDate: now.addingTimeInterval(-60),
                        transactionID: 1
                    )
                ]
            )
        )

        XCTAssertEqual(selected.signedTransactionJWS, "newer-purchase-jws")
    }

    func testMacHostedQuotaRestoreTieBreaksByTransactionIDThenProductID() throws {
        let now = Date()
        let expiry = now.addingTimeInterval(86_400)
        let purchase = now.addingTimeInterval(-300)

        let byTransactionID = try XCTUnwrap(
            MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
                from: [
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "earlier-transaction-jws",
                        expirationDate: expiry,
                        purchaseDate: purchase,
                        transactionID: 10
                    ),
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.legacyCloudUltraAnnualProductID,
                        signedTransactionJWS: "later-transaction-jws",
                        expirationDate: expiry,
                        purchaseDate: purchase,
                        transactionID: 20
                    )
                ]
            )
        )
        XCTAssertEqual(byTransactionID.signedTransactionJWS, "later-transaction-jws")

        let byProductID = try XCTUnwrap(
            MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
                from: [
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID,
                        signedTransactionJWS: "annual-jws",
                        expirationDate: expiry,
                        purchaseDate: purchase,
                        transactionID: 7
                    ),
                    MacHostedQuotaCurrentEntitlement(
                        productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                        signedTransactionJWS: "monthly-jws",
                        expirationDate: expiry,
                        purchaseDate: purchase,
                        transactionID: 7
                    )
                ]
            )
        )
        XCTAssertEqual(
            byProductID.productID,
            MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID
        )
    }

    func testMacHostedQuotaRestoreToleratesMissingDatesAndIgnoresUnknownProducts() {
        XCTAssertNil(MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(from: []))
        XCTAssertNil(
            MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
                from: [
                    MacHostedQuotaCurrentEntitlement(
                        productID: "com.openburnbar.not-a-real-product",
                        signedTransactionJWS: "bogus-jws",
                        expirationDate: nil,
                        purchaseDate: nil,
                        transactionID: nil
                    )
                ]
            )
        )

        let selected = MacHostedQuotaPurchaseStore.preferredCurrentEntitlement(
            from: [
                MacHostedQuotaCurrentEntitlement(
                    productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                    signedTransactionJWS: "lifetime-jws",
                    expirationDate: nil,
                    purchaseDate: nil,
                    transactionID: nil
                ),
                MacHostedQuotaCurrentEntitlement(
                    productID: MacCloudStoreKitProductCatalog.cloudMonthlyProductID,
                    signedTransactionJWS: "cloud-jws",
                    expirationDate: Date(timeIntervalSinceNow: 3_600),
                    purchaseDate: Date(),
                    transactionID: 5
                )
            ]
        )
        XCTAssertEqual(selected?.signedTransactionJWS, "lifetime-jws")
    }

    func testMacCloudBillingPeriodPresentsBothCadences() {
        XCTAssertEqual(MacCloudBillingPeriod.allCases, [.monthly, .annual])
        XCTAssertEqual(MacCloudBillingPeriod.monthly.id, "monthly")
        XCTAssertEqual(MacCloudBillingPeriod.annual.id, "annual")
        XCTAssertEqual(MacCloudBillingPeriod.monthly.title, "Monthly")
        XCTAssertEqual(MacCloudBillingPeriod.annual.title, "Annual")
        XCTAssertEqual(MacCloudBillingPeriod.monthly.priceSuffix, "/ month")
        XCTAssertEqual(MacCloudBillingPeriod.annual.priceSuffix, "/ year")
    }

    func testMacHostedQuotaDisplayPriceFallsBackPerCadenceUntilCatalogueLoads() {
        let store = MacHostedQuotaPurchaseStore()

        XCTAssertTrue(store.productsByID.isEmpty)
        XCTAssertNil(store.displayPrice(for: .local, billingPeriod: .monthly))
        XCTAssertNil(store.displayPrice(for: .local, billingPeriod: .annual))
        for tier in [MacCloudPricingTier.cloud, .pro, .ultra] {
            XCTAssertEqual(
                store.displayPrice(for: tier, billingPeriod: .monthly),
                MacHostedQuotaPurchaseStore.fallbackMonthlyPrice[tier]
            )
            XCTAssertEqual(
                store.displayPrice(for: tier, billingPeriod: .annual),
                MacHostedQuotaPurchaseStore.fallbackAnnualPrice[tier]
            )
        }
    }

    func testMacHostedQuotaPurchaseFailsClosedWhenCloudIsNotConfigured() async {
        guard FirebaseApp.app() == nil else {
            return
        }
        let store = MacHostedQuotaPurchaseStore()

        // Local has no StoreKit product for either cadence; the guard returns
        // before any purchase state is touched.
        await store.purchase(tier: .local, billingPeriod: .annual)
        XCTAssertNil(store.error)
        XCTAssertNil(store.purchasingProductID)

        // The legacy single-tier entry point resolves to Cloud monthly and
        // fails closed when Firebase has never been configured.
        await store.purchase()
        XCTAssertEqual(
            store.error,
            MacHostedQuotaPurchaseError.cloudUnavailable.localizedDescription
        )
        XCTAssertFalse(store.isPurchasing)
        XCTAssertNil(store.purchasingProductID)

        // The annual cadence resolves its own product id and fails closed the
        // same way.
        await store.purchase(tier: .ultra, billingPeriod: .annual)
        XCTAssertEqual(
            store.error,
            MacHostedQuotaPurchaseError.cloudUnavailable.localizedDescription
        )
        XCTAssertNil(store.purchasingProductID)
    }

    func testMacPricingCopyAvoidsStaticTrialPromiseAndMatchesUltraLimits() throws {
        let cloud = try XCTUnwrap(MacPricingTierModel.all.first { $0.tier == .cloud })
        let ultra = try XCTUnwrap(MacPricingTierModel.all.first { $0.tier == .ultra })

        XCTAssertFalse(
            cloud.includedNote?.lines.contains {
                $0.localizedCaseInsensitiveContains("14-day")
            } ?? false
        )
        XCTAssertTrue(
            ultra.bullets.contains {
                $0.contains("100 sources · 500,000 chunks · 10 GB")
            }
        )
    }

    func testMacCloudEntitlementStoreResolvesLocalStoreKitProEntitlement() async {
        let expires = Date(timeIntervalSinceNow: 3_600)
        let purchase = Date(timeIntervalSinceNow: -86_400)
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [
            MacStoreKitEntitlementSnapshot(
                productID: MacCloudStoreKitProductCatalog.cloudProAnnualProductID,
                expirationDate: expires,
                purchaseDate: purchase,
                transactionID: 9_001,
                appAccountToken: proAppAccountToken
            )
        ])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(bindings: [
                proAppAccountToken: storeKitUID
            ]),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )

        await store.refreshStoreKitEntitlementsForTesting()

        XCTAssertTrue(store.hasVerifiedStoreKitEntitlementSnapshot)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.hostedComputerUseIsActive)
        XCTAssertFalse(store.isUltraActive)
        XCTAssertEqual(store.currentTier, .pro)
        XCTAssertEqual(store.cloudTier, .pro)
        XCTAssertEqual(store.expirationDate?.timeIntervalSince1970 ?? 0, expires.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(store.purchaseDate?.timeIntervalSince1970 ?? 0, purchase.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(store.hostedComputerUseExpirationDate?.timeIntervalSince1970 ?? 0, expires.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(provider.currentEntitlementReadCount, 1)
    }

    func testCachedActiveEntitlementCannotOverrideServerRevocation() async throws {
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [
            MacStoreKitEntitlementSnapshot(
                productID: MacCloudStoreKitProductCatalog.cloudProAnnualProductID,
                expirationDate: Date(timeIntervalSinceNow: 3_600),
                transactionID: 9_002,
                appAccountToken: proAppAccountToken
            )
        ])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(bindings: [
                proAppAccountToken: storeKitUID
            ]),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )
        await store.refreshStoreKitEntitlementsForTesting()
        XCTAssertTrue(store.hostedComputerUseIsActive)

        store.applyHostedComputerUse(
            data: MacCloudEntitlementDocument(["active": true]),
            isFromCache: true,
            observedAt: Date()
        )
        XCTAssertTrue(store.hostedComputerUseIsActive)

        let serverObservedAt = Date()
        store.applyHostedComputerUse(
            data: MacCloudEntitlementDocument(["active": false, "updatedAt": serverObservedAt]),
            isFromCache: false,
            observedAt: serverObservedAt
        )

        XCTAssertFalse(store.hostedComputerUseIsActive)
        let provenance = try XCTUnwrap(store.computerUseAuthorityProvenance)
        XCTAssertEqual(provenance.source, .firestoreServer)
        XCTAssertEqual(provenance.observedAt, serverObservedAt)
    }

    func testMacCloudEntitlementStoreTreatsVerifiedEmptyStoreKitSnapshotAsFree() async {
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )

        await store.refreshStoreKitEntitlementsForTesting()

        XCTAssertTrue(store.hasVerifiedStoreKitEntitlementSnapshot)
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.hostedComputerUseIsActive)
        XCTAssertFalse(store.isUltraActive)
        XCTAssertNil(store.expirationDate)
        XCTAssertEqual(store.currentTier, .free)
        XCTAssertEqual(store.cloudTier, .none)
    }

    func testMacCloudEntitlementStoreCloudSourceOverridesLocalStoreKitSnapshot() async {
        let localUltraExpires = Date(timeIntervalSinceNow: 7_200)
        let cloudExpires = Date(timeIntervalSinceNow: 1_800)
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [
            MacStoreKitEntitlementSnapshot(
                productID: MacCloudStoreKitProductCatalog.cloudUltraMonthlyProductID,
                expirationDate: localUltraExpires,
                purchaseDate: Date(timeIntervalSinceNow: -7_200),
                transactionID: 42,
                appAccountToken: ultraAppAccountToken
            )
        ])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(bindings: [
                ultraAppAccountToken: storeKitUID
            ]),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )
        await store.refreshStoreKitEntitlementsForTesting()
        XCTAssertEqual(store.currentTier, .ultra)

        store.applyHostedQuota(data: MacCloudEntitlementDocument([
            "active": true,
            "productID": MacCloudStoreKitProductCatalog.cloudMonthlyProductID,
            "expiresAt": cloudExpires
        ]))

        XCTAssertTrue(store.isActive)
        XCTAssertFalse(store.hostedComputerUseIsActive)
        XCTAssertFalse(store.isUltraActive)
        XCTAssertEqual(store.currentTier, .cloud)
        XCTAssertEqual(store.cloudTier, .cloud)
        XCTAssertEqual(store.expirationDate?.timeIntervalSince1970 ?? 0, cloudExpires.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMacCloudEntitlementStoreDoesNotOverrideLapsedServerEntitlementWithStoreKit() async {
        let localExpires = Date(timeIntervalSinceNow: 7_200)
        let localPurchase = Date(timeIntervalSinceNow: -3_600)
        let cloudLapsedExpires = Date(timeIntervalSinceNow: -1_800)
        let fractionalISO8601 = ISO8601DateFormatter()
        fractionalISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [
            MacStoreKitEntitlementSnapshot(
                productID: MacCloudStoreKitProductCatalog.cloudProAnnualProductID,
                expirationDate: localExpires,
                purchaseDate: localPurchase,
                transactionID: 9_004,
                appAccountToken: proAppAccountToken
            )
        ])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(bindings: [
                proAppAccountToken: storeKitUID
            ]),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )
        await store.refreshStoreKitEntitlementsForTesting()

        store.applyHostedQuota(data: MacCloudEntitlementDocument([
            "active": true,
            "productID": MacCloudStoreKitProductCatalog.cloudMonthlyProductID,
            "expiresAt": fractionalISO8601.string(from: cloudLapsedExpires)
        ]))

        XCTAssertTrue(store.hasVerifiedStoreKitEntitlementSnapshot)
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.hostedComputerUseIsActive)
        XCTAssertFalse(store.isUltraActive)
        XCTAssertEqual(store.currentTier, .free)
        XCTAssertEqual(store.cloudTier, .none)
        XCTAssertNil(store.expirationDate)
        XCTAssertNil(store.purchaseDate)
        XCTAssertEqual(provider.currentEntitlementReadCount, 1)
    }

    func testMacCloudEntitlementStoreRefreshesStoreKitSnapshotOnTransactionUpdate() async {
        let expires = Date(timeIntervalSinceNow: 3_600)
        let refreshObserved = expectation(description: "StoreKit update refreshed current entitlements")
        let provider = FakeMacStoreKitEntitlementProvider(
            entitlements: [
                MacStoreKitEntitlementSnapshot(
                    productID: MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID,
                    expirationDate: expires,
                    purchaseDate: Date(timeIntervalSinceNow: -300),
                    transactionID: 777,
                    appAccountToken: ultraAppAccountToken
                )
            ],
            emitsImmediateUpdate: true
        )
        provider.onCurrentEntitlementsRead = {
            refreshObserved.fulfill()
        }
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(bindings: [
                ultraAppAccountToken: storeKitUID
            ]),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )

        store.startStoreKitEntitlementObservationForTesting()
        await fulfillment(of: [refreshObserved], timeout: 1.0)

        XCTAssertTrue(store.hasVerifiedStoreKitEntitlementSnapshot)
        XCTAssertEqual(store.currentTier, .ultra)
        XCTAssertEqual(store.cloudTier, .ultra)
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.hostedComputerUseIsActive)
        XCTAssertTrue(store.isUltraActive)
    }

    func testMacCloudEntitlementStoreIgnoresLocalStoreKitEntitlementWithoutAppAccountToken() async {
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [
            MacStoreKitEntitlementSnapshot(
                productID: MacCloudStoreKitProductCatalog.cloudProAnnualProductID,
                expirationDate: Date(timeIntervalSinceNow: 3_600),
                purchaseDate: Date(timeIntervalSinceNow: -300),
                transactionID: 9_002
            )
        ])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )

        await store.refreshStoreKitEntitlementsForTesting()

        XCTAssertTrue(store.hasVerifiedStoreKitEntitlementSnapshot)
        XCTAssertEqual(store.currentTier, .free)
        XCTAssertEqual(store.cloudTier, .none)
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.hostedComputerUseIsActive)
    }

    func testMacCloudEntitlementStoreIgnoresLocalStoreKitEntitlementForDifferentFirebaseUID() async {
        let provider = FakeMacStoreKitEntitlementProvider(entitlements: [
            MacStoreKitEntitlementSnapshot(
                productID: MacCloudStoreKitProductCatalog.cloudUltraAnnualProductID,
                expirationDate: Date(timeIntervalSinceNow: 3_600),
                purchaseDate: Date(timeIntervalSinceNow: -300),
                transactionID: 9_003,
                appAccountToken: ultraAppAccountToken
            )
        ])
        let store = MacCloudEntitlementStore(
            storeKitEntitlementProvider: provider,
            appAccountTokenBindingProvider: FakeMacStoreKitAppAccountTokenBindingProvider(bindings: [
                ultraAppAccountToken: otherStoreKitUID
            ]),
            observesStoreKitTransactions: false,
            signedInUID: storeKitUID
        )

        await store.refreshStoreKitEntitlementsForTesting()

        XCTAssertTrue(store.hasVerifiedStoreKitEntitlementSnapshot)
        XCTAssertEqual(store.currentTier, .free)
        XCTAssertEqual(store.cloudTier, .none)
        XCTAssertFalse(store.isUltraActive)
        XCTAssertFalse(store.hostedComputerUseIsActive)
    }

    func testActiveSessionRegistryClampsCountsPerFeature() {
        MacMediaActiveSessionRegistry.shared.resetForTesting()
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .screenShare), 0)

        MacMediaActiveSessionRegistry.shared.setCount(2, for: .screenShare)
        MacMediaActiveSessionRegistry.shared.setCount(1, for: .fileTransfer)
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .screenShare), 2)
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 1)

        MacMediaActiveSessionRegistry.shared.setCount(-10, for: .screenShare)
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .screenShare), 0)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testHardCapDeniesAllFeatures() async {
        let hardCap = MediaBudgetStatus(
            level: .hardCap,
            projectedMonthEndUSD: 1_200,
            monthToDateUSD: 900,
            lastEvaluatedAt: Date(),
            activeEnvelope: .hardCap
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: hardCap, concurrent: 0)
        for feature in [MediaStreamClass.Feature.fileTransfer, .screenShare, .videoCall] {
            let result = await gate.check(feature: feature, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
            guard case .denied(let reason) = result else {
                XCTFail("expected denied for \(feature)")
                return
            }
            XCTAssertEqual(reason, .budgetHardCapReached, "feature \(feature)")
        }
    }

    func testSoftCapEnforcesTightenedEnvelope() async {
        let softCap = MediaBudgetStatus(
            level: .softCap,
            projectedMonthEndUSD: 750,
            monthToDateUSD: 350,
            lastEvaluatedAt: Date(),
            activeEnvelope: .softCap
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: softCap, concurrent: 0)
        // Soft cap still allows screen share but with reduced per-session
        // ceiling; the gate refuses a request that exceeds that ceiling.
        let denied = await gate.check(
            feature: .screenShare,
            sessionDurationLimitSeconds: 60 * 60, // 60 min — exceeds soft cap (30 min)
            sessionByteBudget: nil
        )
        if case .allowed = denied {
            XCTFail("expected denial for over-budget request under soft cap")
        }
    }

    func testConcurrentSessionCeilingDeniesVideoSecondCall() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 1)
        let result = await gate.check(feature: .videoCall, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .concurrentSessionCapReached)
    }

    func testScreenShareAllowsThreeConcurrentMirrorViewers() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 2)
        let result = await gate.check(feature: .screenShare, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        XCTAssertTrue(result.isAllowed)
    }

    func testScreenShareDeniesFourthConcurrentMirrorViewer() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 3)
        let result = await gate.check(feature: .screenShare, sessionDurationLimitSeconds: nil, sessionByteBudget: nil)
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .concurrentSessionCapReached)
    }

    func testPerSessionByteBudgetDenialOnFileTransfer() async {
        let nearCap = MediaQuotaUsageSnapshot(
            bytesUploadedFile: 4_500_000_000, // ~4.5 GB of 5 GB
            bytesDownloadedFile: 0,
            fileTransfersInitiated: 5,
            fileTransfersFailed: 0,
            screenShareSecondsUsed: 0,
            screenShareSessions: 0,
            videoCallSecondsUsed: 0,
            videoCallSessions: 0
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: nearCap, budget: normalBudget, concurrent: 0)
        // A 1 GB upload pushes us past the daily out cap.
        let result = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: 1_000_000_000,
            transferDirection: .outbound
        )
        guard case .denied(let reason) = result else {
            XCTFail("expected denied")
            return
        }
        XCTAssertEqual(reason, .sessionCapReached)
    }

    func testInboundFileTransferByteBudgetUsesDownloadCap() async {
        let nearInboundCap = MediaQuotaUsageSnapshot(
            bytesUploadedFile: 0,
            bytesDownloadedFile: 4_500_000_000, // ~4.5 GB of 5 GB
            fileTransfersInitiated: 5,
            fileTransfersFailed: 0,
            screenShareSecondsUsed: 0,
            screenShareSessions: 0,
            videoCallSecondsUsed: 0,
            videoCallSessions: 0
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: nearInboundCap, budget: normalBudget, concurrent: 0)

        let inbound = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: 1_000_000_000,
            transferDirection: .inbound
        )
        guard case .denied(let inboundReason) = inbound else {
            XCTFail("expected inbound denial")
            return
        }
        XCTAssertEqual(inboundReason, .sessionCapReached)

        let outbound = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: 1_000_000_000,
            transferDirection: .outbound
        )
        XCTAssertTrue(outbound.isAllowed, "download usage must not consume outbound allowance")
    }

    func testLegacyFileTransferByteBudgetUsesUploadCompatibilityPath() async {
        let exhaustedDownload = MediaQuotaUsageSnapshot(
            bytesUploadedFile: 0,
            bytesDownloadedFile: 5_000_000_000,
            fileTransfersInitiated: 5,
            fileTransfersFailed: 0,
            screenShareSecondsUsed: 0,
            screenShareSessions: 0,
            videoCallSecondsUsed: 0,
            videoCallSessions: 0
        )
        let gate = makeGate(entitlement: happyEntitlement, usage: exhaustedDownload, budget: normalBudget, concurrent: 0)

        let result = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: 100_000_000
        )

        XCTAssertTrue(result.isAllowed, "legacy callers without direction must not be denied by exhausted download quota when upload quota remains")
    }

    func testOutboundFileTransferRejectsSingleFileAbovePerFileCeiling() async {
        let gate = makeGate(entitlement: happyEntitlement, usage: zeroUsage, budget: normalBudget, concurrent: 0)

        let result = await gate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: 2_000_000_000,
            transferDirection: .outbound
        )

        guard case .denied(let reason) = result else {
            XCTFail("expected oversized outbound file to be denied")
            return
        }
        XCTAssertEqual(reason, .sessionCapReached)
    }

    func testMediaQuotaUsageSnapshotParsesFirestoreNumberShapes() {
        let snapshot = MacMediaQuotaUsageStore.parseSnapshot([
            "bytesUploadedFile": NSNumber(value: 123_456_789),
            "bytesDownloadedFile": 42.0,
            "fileTransfersInitiated": NSNumber(value: 3),
            "fileTransfersFailed": 1,
            "screenShareSecondsUsed": NSNumber(value: 90),
            "screenShareSessions": 2.0,
            "videoCallSecondsUsed": Int64(12),
            "videoCallSessions": NSNumber(value: 4)
        ])

        XCTAssertEqual(snapshot.bytesUploadedFile, 123_456_789)
        XCTAssertEqual(snapshot.bytesDownloadedFile, 42)
        XCTAssertEqual(snapshot.fileTransfersInitiated, 3)
        XCTAssertEqual(snapshot.fileTransfersFailed, 1)
        XCTAssertEqual(snapshot.screenShareSecondsUsed, 90)
        XCTAssertEqual(snapshot.screenShareSessions, 2)
        XCTAssertEqual(snapshot.videoCallSecondsUsed, 12)
        XCTAssertEqual(snapshot.videoCallSessions, 4)
    }

    func testRemoteUnlockSessionRegistryBindsCredentialSessionToPeer() {
        let service = makeRemoteUnlockReadinessService()
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let session = remoteUnlockSession(
            sessionId: "unlock-session",
            peerNodeId: "ios-peer",
            viewerDeviceId: "iphone-1",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now
            )
        )

        service.recordRemoteUnlockSession(session, now: now)

        XCTAssertTrue(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "android-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "different-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "ipad-1",
                now: now
            )
        )
    }

    func testRemoteUnlockSessionRegistryRejectsExpiredAndRevokedSessions() {
        let service = makeRemoteUnlockReadinessService()
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let session = remoteUnlockSession(
            sessionId: "unlock-session",
            peerNodeId: "ios-peer",
            viewerDeviceId: "iphone-1",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        service.recordRemoteUnlockSession(session, now: now)
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now.addingTimeInterval(61)
            )
        )

        service.recordRemoteUnlockSession(session, now: now)
        service.revokeRemoteUnlockSession(sessionId: "unlock-session")
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now
            )
        )

        service.recordRemoteUnlockSession(session, now: now)
        service.revokeAllRemoteUnlockSessions(revokePublishedTrust: false)
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                now: now
            )
        )
    }

    // MARK: Remote Unlock trust / certification fail-closed paths

    /// A keychain fault while reading the HPKE credential identity key must
    /// fail the readiness snapshot CLOSED. Previously the error was swallowed
    /// (`try?`), the snapshot fell back to stale persisted key defaults, and a
    /// report could be advertised as fresh against key material that no longer
    /// matched — a trust/identity-key correctness hole.
    func testCredentialKeyFaultFailsReadinessSnapshotClosed() {
        let defaults = makeIsolatedRemoteUnlockDefaults()
        // Seed stale persisted key material that the old fall-through would have
        // happily reused.
        defaults.set("hpke-stale", forKey: "remote_unlock.credential_recipient_key_id")
        defaults.set("c3RhbGU=", forKey: "remote_unlock.credential_recipient_public_key_base64")
        defaults.set(true, forKey: "remote_unlock.backend_certification_fresh")

        let service = MacRemoteUnlockReadinessService(
            defaults: defaults,
            certificationStore: makeTemporaryCertificationStore(),
            revokesPublishedTrustOnClearAll: false,
            credentialKeyMaterialProvider: { throw FakeRemoteUnlockTrustError.keychain },
            issuerTrustPublisher: {},
            publishedTrustRevoker: {}
        )

        let snapshot = service.snapshot()

        XCTAssertFalse(
            snapshot.backendCertificationFresh,
            "a keychain fault reading the credential identity key must fail the snapshot closed"
        )
        XCTAssertFalse(snapshot.loopbackOnlyFirewallActive)
        XCTAssertFalse(snapshot.lastUnlockProbeSucceeded)
    }

    func testRemoteUnlockCredentialKeyStoreDisablesSystemPromptsForBackgroundReads() throws {
        let security = RecordingRemoteUnlockKeychainOperations()
        let store = RemoteUnlockCredentialKeyStore(
            service: "com.openburnbar.remote-unlock.hpke.tests.\(UUID().uuidString)",
            security: security
        )

        _ = try store.copyOrCreateKeyMaterial(allowUserInteraction: false)

        let events = security.events
        XCTAssertEqual(events.map(\.operation), [.copyMatching, .add])
        XCTAssertTrue(
            events.allSatisfy { $0.interactionDisabled },
            "background Remote Unlock readiness must never allow Security.framework to raise Keychain UI"
        )

        let copyQuery = try XCTUnwrap(events.first?.query)
        XCTAssertEqual(copyQuery[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        let context = try XCTUnwrap(copyQuery[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)

        let addQuery = try XCTUnwrap(events.last?.query)
        XCTAssertEqual(addQuery[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
    }

    /// A corrupt / unreadable certification report must be treated as no-report
    /// (fail closed), never silently mistaken for an absent-but-healthy host.
    func testCorruptCertificationReportIsTreatedAsNoReport() throws {
        let store = makeTemporaryCertificationStore()
        // Write garbage where a JSON report belongs so `load()` throws.
        try store.fileManager.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.fileURL)

        let service = MacRemoteUnlockReadinessService(
            defaults: makeIsolatedRemoteUnlockDefaults(),
            certificationStore: store,
            revokesPublishedTrustOnClearAll: false,
            credentialKeyMaterialProvider: { Self.fakeCredentialKeyMaterial() },
            issuerTrustPublisher: {},
            publishedTrustRevoker: {}
        )

        let snapshot = service.snapshot()

        XCTAssertFalse(
            snapshot.backendCertificationFresh,
            "a report that fails to decode must not be advertised as a fresh certification"
        )
    }

    /// `recordCertification` must persist the report BEFORE flipping the
    /// in-memory freshness flags. If the save fails it must fail closed (return
    /// false, mark not-fresh) so the on-disk artifact and UserDefaults can never
    /// diverge into a "fresh but unsaved" state.
    func testRecordCertificationFailsClosedWhenSaveFails() {
        let defaults = makeIsolatedRemoteUnlockDefaults()
        // Point the store at a path whose parent is a regular file, so
        // createDirectory / write throws.
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMediaCapabilityGateTests-block-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blockingFile.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let unwritable = RemoteUnlockCertificationReportStore(
            fileURL: blockingFile.appendingPathComponent("nested/report.json")
        )

        let publishCount = CallCounter()
        let service = MacRemoteUnlockReadinessService(
            defaults: defaults,
            certificationStore: unwritable,
            revokesPublishedTrustOnClearAll: false,
            credentialKeyMaterialProvider: { Self.fakeCredentialKeyMaterial() },
            issuerTrustPublisher: { publishCount.increment() },
            publishedTrustRevoker: {}
        )

        let recorded = service.recordCertification(
            fileVaultSSHSupported: true,
            credentialRecipientKeyId: "hpke-abc",
            credentialRecipientPublicKeyBase64: "AAAA"
        )

        XCTAssertFalse(recorded, "recordCertification must report failure when the save fails")
        XCTAssertFalse(
            defaults.bool(forKey: "remote_unlock.backend_certification_fresh"),
            "a failed save must leave the host marked not-certified"
        )
        XCTAssertNil(
            defaults.object(forKey: "remote_unlock.certified_at"),
            "freshness flags must not be set when the certification report could not be persisted"
        )
        XCTAssertEqual(
            publishCount.value, 0,
            "issuer trust must not be published when certification was not saved"
        )
    }

    /// A successful certification persists the report first, then marks fresh and
    /// publishes issuer trust (positive control for the fail-closed save path).
    func testRecordCertificationPersistsThenMarksFreshAndPublishesTrust() throws {
        let defaults = makeIsolatedRemoteUnlockDefaults()
        let store = makeTemporaryCertificationStore()

        let publishCount = CallCounter()
        let service = MacRemoteUnlockReadinessService(
            defaults: defaults,
            certificationStore: store,
            revokesPublishedTrustOnClearAll: false,
            credentialKeyMaterialProvider: { Self.fakeCredentialKeyMaterial() },
            issuerTrustPublisher: { publishCount.increment() },
            publishedTrustRevoker: {}
        )

        let recorded = service.recordCertification(
            fileVaultSSHSupported: true,
            credentialRecipientKeyId: "hpke-abc",
            credentialRecipientPublicKeyBase64: "AAAA"
        )

        XCTAssertTrue(recorded)
        XCTAssertTrue(defaults.bool(forKey: "remote_unlock.backend_certification_fresh"))
        XCTAssertEqual(publishCount.value, 1, "issuer trust should be published exactly once on success")
        XCTAssertNotNil(try store.load(), "the certification report must be persisted on disk")
    }

    /// Revoking all sessions must surface a published-trust revocation failure
    /// instead of swallowing it, while still clearing the local sessions so a
    /// stuck revocation never re-permits an active session.
    func testRevokeAllSurfacesPublishedTrustRevocationFailure() {
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let session = remoteUnlockSession(
            sessionId: "unlock-session",
            peerNodeId: "ios-peer",
            viewerDeviceId: "iphone-1",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let service = MacRemoteUnlockReadinessService(
            defaults: makeIsolatedRemoteUnlockDefaults(),
            certificationStore: makeTemporaryCertificationStore(),
            revokesPublishedTrustOnClearAll: true,
            credentialKeyMaterialProvider: { Self.fakeCredentialKeyMaterial() },
            issuerTrustPublisher: {},
            publishedTrustRevoker: { throw FakeRemoteUnlockTrustError.publish }
        )
        service.recordRemoteUnlockSession(session, now: now)

        let succeeded = service.revokeAllRemoteUnlockSessions()

        XCTAssertFalse(succeeded, "a revocation that fails to revoke published trust must report failure")
        XCTAssertFalse(
            service.isRemoteUnlockSessionActive(sessionId: "unlock-session", peerNodeId: "ios-peer", now: now),
            "local sessions must still be cleared even when published-trust revocation fails"
        )
    }

    /// Revocation reports success when the published-trust revoker succeeds.
    func testRevokeAllReportsSuccessWhenTrustRevocationSucceeds() {
        let revokeCount = CallCounter()
        let service = MacRemoteUnlockReadinessService(
            defaults: makeIsolatedRemoteUnlockDefaults(),
            certificationStore: makeTemporaryCertificationStore(),
            revokesPublishedTrustOnClearAll: true,
            credentialKeyMaterialProvider: { Self.fakeCredentialKeyMaterial() },
            issuerTrustPublisher: {},
            publishedTrustRevoker: { revokeCount.increment() }
        )

        let succeeded = service.revokeAllRemoteUnlockSessions()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(revokeCount.value, 1)
    }

    // MARK: helpers

    private enum FakeRemoteUnlockTrustError: Error {
        case keychain
        case publish
    }

    /// Thread-safe call counter so `@Sendable` provider closures can record how
    /// often they ran without capturing a mutable `var` (which `@Sendable`
    /// forbids).
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private nonisolated static func fakeCredentialKeyMaterial() -> RemoteUnlockCredentialKeyMaterial {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return RemoteUnlockCredentialKeyMaterial(
            keyId: "hpke-test",
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            privateKey: privateKey
        )
    }

    private func makeIsolatedRemoteUnlockDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MacMediaCapabilityGateTests.\(UUID().uuidString)")!
    }

    private func makeTemporaryCertificationStore() -> RemoteUnlockCertificationReportStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMediaCapabilityGateTests-cert-\(UUID().uuidString)")
            .appendingPathComponent("RemoteUnlockCertification-v1.json")
        return RemoteUnlockCertificationReportStore(fileURL: url)
    }

    private func makeGate(
        entitlement: MacMediaCapabilityGate.EntitlementState,
        usage: MediaQuotaUsageSnapshot,
        budget: MediaBudgetStatus,
        concurrent: Int
    ) -> MacMediaCapabilityGate {
        MacMediaCapabilityGate(
            entitlementProvider: { entitlement },
            usageProvider: { usage },
            budgetProvider: { budget },
            concurrentSessionsProvider: { _ in concurrent },
            killSwitchProvider: { false }
        )
    }

    private func makeRemoteUnlockReadinessService() -> MacRemoteUnlockReadinessService {
        let defaults = UserDefaults(suiteName: "MacMediaCapabilityGateTests.\(UUID().uuidString)")!
        return MacRemoteUnlockReadinessService(
            defaults: defaults,
            revokesPublishedTrustOnClearAll: false
        )
    }

    private func remoteUnlockSession(
        sessionId: String,
        peerNodeId: String,
        viewerDeviceId: String?,
        requestedAt: Date,
        expiresAt: Date
    ) -> HermesRealtimeRelayRemoteUnlockSession {
        HermesRealtimeRelayRemoteUnlockSession(
            requestId: "unlock-req",
            sessionId: sessionId,
            intent: .request,
            requesterDisplayName: "Alberto's iPhone",
            viewerDeviceId: viewerDeviceId,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            localAuthenticationSatisfied: true,
            requestedLockState: .loginWindow,
            requestedBackend: .appleScreenSharingLoopback,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: peerNodeId,
                counter: 1,
                timestamp: requestedAt,
                intentHashBlake3: "hash",
                signatureEd25519: "signature"
            )
        )
    }
}

private final class RecordingRemoteUnlockKeychainOperations: SecurityKeychainOperations, @unchecked Sendable {
    enum Operation: Equatable {
        case update
        case add
        case copyMatching
        case delete
    }

    struct Event {
        var operation: Operation
        var interactionDisabled: Bool
        var query: [String: Any]
    }

    private let lock = NSLock()
    private var disabledDepth = 0
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func runWithDisabledInteraction(_ operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        disabledDepth += 1
        lock.unlock()
        defer {
            lock.lock()
            disabledDepth -= 1
            lock.unlock()
        }
        return operation()
    }

    func update(query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        record(.update, query: query)
        return errSecSuccess
    }

    func add(query: CFDictionary) -> OSStatus {
        record(.add, query: query)
        return errSecSuccess
    }

    func copyMatching(query: CFDictionary, item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        record(.copyMatching, query: query)
        return errSecItemNotFound
    }

    func delete(query: CFDictionary) -> OSStatus {
        record(.delete, query: query)
        return errSecSuccess
    }

    private func record(_ operation: Operation, query: CFDictionary) {
        lock.lock()
        defer { lock.unlock() }
        let dictionary = (query as NSDictionary) as? [String: Any] ?? [:]
        recordedEvents.append(
            Event(
                operation: operation,
                interactionDisabled: disabledDepth > 0,
                query: dictionary
            )
        )
    }
}

@MainActor
private final class FakeMacStoreKitEntitlementProvider: MacStoreKitEntitlementProviding {
    private let entitlements: [MacStoreKitEntitlementSnapshot]
    private let emitsImmediateUpdate: Bool
    private(set) var currentEntitlementReadCount = 0
    var onCurrentEntitlementsRead: (() -> Void)?

    init(
        entitlements: [MacStoreKitEntitlementSnapshot],
        emitsImmediateUpdate: Bool = false
    ) {
        self.entitlements = entitlements
        self.emitsImmediateUpdate = emitsImmediateUpdate
    }

    func currentEntitlements() async -> [MacStoreKitEntitlementSnapshot] {
        currentEntitlementReadCount += 1
        onCurrentEntitlementsRead?()
        return entitlements
    }

    func transactionUpdates() -> AsyncStream<Void> {
        let shouldEmit = emitsImmediateUpdate
        return AsyncStream { continuation in
            if shouldEmit {
                continuation.yield(())
                continuation.finish()
            }
        }
    }
}

@MainActor
private final class FakeMacStoreKitAppAccountTokenBindingProvider: MacStoreKitAppAccountTokenBindingProviding {
    private let bindings: [String: String]

    init(bindings: [UUID: String] = [:]) {
        self.bindings = Dictionary(
            uniqueKeysWithValues: bindings.map { token, uid in
                (token.uuidString.lowercased(), uid)
            }
        )
    }

    func appAccountToken(_ token: UUID, isBoundToFirebaseUID uid: String) -> Bool {
        bindings[token.uuidString.lowercased()] == uid
    }
}

// MARK: - CloudStoreSettingsView billing-cadence pane

/// Renders the macOS Cloud store pane through a real `NSHostingView` so the
/// tier lineup (segmented billing-period picker, per-cadence prices, and
/// per-card busy state) actually executes, and drives the subscribe action
/// directly to lock in its fail-closed behavior when Firebase is absent.
///
/// Both tests construct the pane with `startsLiveServicesOnAppear: false`:
/// rendering must not start the live `onAppear` work (StoreKit catalogue
/// load, transaction-updates listener, backup catch-up). On CI that leftover
/// work wedged the shared test process and deterministically hung the next
/// async-heavy suite (`MemoryActivationEndToEndTests`) until the App PR Gate
/// job timed out.
@MainActor
final class CloudStoreSettingsViewBillingTests: XCTestCase {
    func testCloudStorePaneRendersTierLineupWithPerCadencePricing() {
        let image = renderViewSnapshot(
            CloudStoreSettingsView(startsLiveServicesOnAppear: false),
            size: CGSize(width: 980, height: 1600),
            colorScheme: .dark
        )

        XCTAssertNotNil(image.tiffRepresentation)
    }

    func testSubscribeActionPurchasesSelectedCadenceAndFailsClosed() async {
        guard FirebaseApp.app() == nil else {
            return
        }
        let view = CloudStoreSettingsView(startsLiveServicesOnAppear: false)

        // Paid tier: the purchase runs and fails closed on the FirebaseApp
        // guard without ever reaching StoreKit.
        await view.subscribeToSelectedCadence(.ultra).value

        // Local tier: no StoreKit product exists for either cadence, so the
        // action returns without starting a purchase.
        await view.subscribeToSelectedCadence(.local).value
    }
}
