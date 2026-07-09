// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import OpenBurnBarCore

/// Direct Core coverage for `EntitlementArbitration` — the pure entitlement-precedence
/// core extracted from `MacCloudEntitlementStore` (Wave-5 §2.3). These tests pin the
/// five N3 invariants as a cheap cross-platform harness: active-cloud-wins-wholesale,
/// lapsed-cloud-is-invisible, StoreKit fails closed on any unvalidated snapshot,
/// per-tier max-expiry merge, and the Ultra ⇒ Pro ⇒ Cloud implication. The mac app's
/// `MacMediaCapabilityGateTests` remains the platform-integration proof that the store
/// feeds this function correctly.
final class EntitlementArbitrationTests: XCTestCase {

    // A fixed clock so expiry comparisons are deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    private var future: Date { now.addingTimeInterval(86_400) }      // +1 day
    private var past: Date { now.addingTimeInterval(-86_400) }       // -1 day
    private var farFuture: Date { now.addingTimeInterval(864_000) }  // +10 days

    // MARK: - Empty inputs

    func testNoSourcesResolvesToFree() {
        let result = EntitlementArbitration.effectiveTier(cloud: [], storeKit: [], now: now)
        XCTAssertEqual(result, .free)
        XCTAssertEqual(result.effectiveTier, .none)
        XCTAssertEqual(result.source, .none)
        XCTAssertFalse(result.cloud.isActive)
        XCTAssertFalse(result.pro.isActive)
        XCTAssertFalse(result.ultra.isActive)
    }

    // MARK: - Active cloud wins wholesale (invariant 1)

    func testActiveCloudDocWinsOverStoreKit() {
        // Cloud grants Cloud tier; StoreKit would grant Ultra. Active cloud must
        // win the WHOLE decision — StoreKit is never consulted, so effective is Cloud.
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: future, fallbackTier: .cloud
            )
        ]
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudUltraMonthlyProductID,
                uidBound: true, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: storeKit, now: now)
        XCTAssertEqual(result.source, .cloudDocs)
        XCTAssertEqual(result.effectiveTier, .cloud)
        XCTAssertTrue(result.cloud.isActive)
        XCTAssertFalse(result.ultra.isActive, "StoreKit ultra must not leak in while cloud is active")
    }

    // MARK: - Lapsed cloud is invisible (invariant 2 — the N3 fix)

    func testLapsedCloudDocDoesNotSuppressValidStoreKit() {
        // A present-but-EXPIRED cloud doc must not suppress a valid local StoreKit
        // entitlement — the precedence guard is "any cloud ACTIVE", not "any cloud present".
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "burnbar_ultra", active: true, expiry: past, fallbackTier: .ultra
            )
        ]
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudProMonthlyProductID,
                uidBound: true, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: storeKit, now: now)
        XCTAssertEqual(result.source, .storeKit, "lapsed cloud must fall through to StoreKit")
        XCTAssertEqual(result.effectiveTier, .pro)
        XCTAssertTrue(result.pro.isActive)
    }

    func testInactiveCloudFlagDoesNotSuppressStoreKit() {
        // active:false (not merely expired) is equally invisible.
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: false, expiry: future, fallbackTier: .cloud
            )
        ]
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudMonthlyProductID,
                uidBound: true, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: storeKit, now: now)
        XCTAssertEqual(result.source, .storeKit)
        XCTAssertEqual(result.effectiveTier, .cloud)
    }

    // MARK: - StoreKit fails closed (invariant 3)

    func testUnboundStoreKitIsExcluded() {
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudUltraMonthlyProductID,
                uidBound: false, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: [], storeKit: storeKit, now: now)
        XCTAssertEqual(result, .free, "an appAccountToken not bound to the signed-in UID must fail closed")
    }

    func testRevokedStoreKitIsExcluded() {
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudMonthlyProductID,
                uidBound: true, revoked: true, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: [], storeKit: storeKit, now: now)
        XCTAssertEqual(result, .free)
    }

    func testExpiredStoreKitIsExcluded() {
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudMonthlyProductID,
                uidBound: true, expiry: past
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: [], storeKit: storeKit, now: now)
        XCTAssertEqual(result, .free)
    }

    func testUnmappedStoreKitProductIsExcluded() {
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: "com.openburnbar.not.a.real.product",
                uidBound: true, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: [], storeKit: storeKit, now: now)
        XCTAssertEqual(result, .free)
    }

    func testValidStoreKitOnlyResolves() {
        let storeKit = [
            EntitlementArbitration.StoreKitState(
                productID: EntitlementProductCatalog.cloudProAnnualProductID,
                uidBound: true, expiry: future
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: [], storeKit: storeKit, now: now)
        XCTAssertEqual(result.source, .storeKit)
        XCTAssertEqual(result.effectiveTier, .pro)
    }

    // MARK: - Per-tier max-expiry merge (invariant 4)

    func testMergeKeepsLaterExpiryForSameTier() {
        // Two active cloud docs at the same tier — the later expiry survives.
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: future, fallbackTier: .cloud
            ),
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: farFuture, fallbackTier: .cloud
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        XCTAssertEqual(result.effectiveTier, .cloud)
        XCTAssertEqual(result.cloud.expiry, farFuture, "the later of two same-tier expiries must win")
    }

    func testMergeKeepsExistingDatedExpiryWhenCandidateExpiresSooner() {
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: farFuture, fallbackTier: .cloud
            ),
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: future, fallbackTier: .cloud
            )
        ]

        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)

        XCTAssertEqual(result.cloud.expiry, farFuture, "a shorter candidate expiry must not downgrade the tier grant")
    }

    func testMergeKeepsExistingGrantWhenDatedExpiriesTie() {
        let existingPurchase = now.addingTimeInterval(-7_200)
        let candidatePurchase = now.addingTimeInterval(-3_600)
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync",
                active: true,
                expiry: future,
                purchase: existingPurchase,
                fallbackTier: .cloud
            ),
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync",
                active: true,
                expiry: future,
                purchase: candidatePurchase,
                fallbackTier: .cloud
            )
        ]

        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)

        XCTAssertEqual(result.cloud.expiry, future)
        XCTAssertEqual(result.cloud.purchase, existingPurchase, "dated-expiry ties match the macOS store and keep existing")
    }

    func testDatedExpiryBeatsUndatedForSameTierInBothOrders() {
        // An undated (perpetual-looking) grant should not erase a concrete expiry;
        // preferred(over:) keeps the dated one in either input order.
        let undatedFirst = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: nil, fallbackTier: .cloud
            ),
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: future, fallbackTier: .cloud
            )
        ]
        let datedFirst = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: future, fallbackTier: .cloud
            ),
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync", active: true, expiry: nil, fallbackTier: .cloud
            )
        ]

        let undatedFirstResult = EntitlementArbitration.effectiveTier(cloud: undatedFirst, storeKit: [], now: now)
        let datedFirstResult = EntitlementArbitration.effectiveTier(cloud: datedFirst, storeKit: [], now: now)

        XCTAssertTrue(undatedFirstResult.cloud.isActive)
        XCTAssertEqual(undatedFirstResult.cloud.expiry, future)
        XCTAssertEqual(datedFirstResult.cloud.expiry, future)
    }

    func testBothUndatedSameTierKeepsLatestCandidate() {
        let firstPurchase = now.addingTimeInterval(-7_200)
        let secondPurchase = now.addingTimeInterval(-3_600)
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync",
                active: true,
                expiry: nil,
                purchase: firstPurchase,
                fallbackTier: .cloud
            ),
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync",
                active: true,
                expiry: nil,
                purchase: secondPurchase,
                fallbackTier: .cloud
            )
        ]

        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)

        XCTAssertTrue(result.cloud.isActive)
        XCTAssertNil(result.cloud.expiry)
        XCTAssertEqual(result.cloud.purchase, secondPurchase, "both-undated ties keep the candidate grant")
    }

    // MARK: - Ultra ⇒ Pro ⇒ Cloud implication (invariant 5)

    func testUltraGrantActivatesEveryLowerTier() {
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "burnbar_ultra", active: true, expiry: future, fallbackTier: .ultra
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        XCTAssertEqual(result.effectiveTier, .ultra)
        XCTAssertTrue(result.ultra.isActive)
        XCTAssertTrue(result.pro.isActive, "Ultra implies Pro")
        XCTAssertTrue(result.cloud.isActive, "Ultra implies Cloud")
    }

    func testProGrantActivatesCloudButNotUltra() {
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "burnbar_pro_max", active: true, expiry: future, fallbackTier: .pro
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        XCTAssertEqual(result.effectiveTier, .pro)
        XCTAssertTrue(result.pro.isActive)
        XCTAssertTrue(result.cloud.isActive, "Pro implies Cloud")
        XCTAssertFalse(result.ultra.isActive, "Pro must not imply Ultra")
    }

    // MARK: - Product-ID overrides doc fallback tier

    func testProductIDOverridesFallbackTier() {
        // Doc key would fall back to Cloud, but its productID maps to Ultra — the
        // catalog wins, and Ultra implication lights up all three tiers.
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "hosted_quota_sync",
                active: true,
                productID: EntitlementProductCatalog.cloudUltraAnnualProductID,
                expiry: future,
                fallbackTier: .cloud
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        XCTAssertEqual(result.effectiveTier, .ultra)
        XCTAssertTrue(result.ultra.isActive)
    }

    func testUnmappedProductIDUsesFallbackTier() {
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "burnbar_pro_max",
                active: true,
                productID: "com.openburnbar.unknown.sku",
                expiry: future,
                fallbackTier: .pro
            )
        ]
        let result = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        XCTAssertEqual(result.effectiveTier, .pro)
    }

    // MARK: - Catalog (single cross-platform source of truth)

    func testCatalogTierMapping() {
        XCTAssertEqual(EntitlementProductCatalog.tier(for: EntitlementProductCatalog.cloudMonthlyProductID), .cloud)
        XCTAssertEqual(EntitlementProductCatalog.tier(for: EntitlementProductCatalog.cloudProMonthlyProductID), .pro)
        XCTAssertEqual(EntitlementProductCatalog.tier(for: EntitlementProductCatalog.cloudUltraMonthlyProductID), .ultra)
        // Legacy IDs still resolve.
        XCTAssertEqual(EntitlementProductCatalog.tier(for: EntitlementProductCatalog.legacyHostedQuotaProductID), .cloud)
        XCTAssertEqual(EntitlementProductCatalog.tier(for: EntitlementProductCatalog.legacyComputerUseProductID), .pro)
        XCTAssertEqual(EntitlementProductCatalog.tier(for: EntitlementProductCatalog.legacyCloudUltraAnnualProductID), .ultra)
        // Unknown / nil fail closed.
        XCTAssertNil(EntitlementProductCatalog.tier(for: "com.openburnbar.nope"))
        XCTAssertNil(EntitlementProductCatalog.tier(for: nil))
    }

    func testCatalogTierSetsAreDisjointAndComplete() {
        let cloud = EntitlementProductCatalog.cloudProductIDs
        let pro = EntitlementProductCatalog.proProductIDs
        let ultra = EntitlementProductCatalog.ultraProductIDs
        XCTAssertTrue(cloud.isDisjoint(with: pro), "a product ID must map to exactly one tier")
        XCTAssertTrue(cloud.isDisjoint(with: ultra))
        XCTAssertTrue(pro.isDisjoint(with: ultra))
        XCTAssertEqual(
            EntitlementProductCatalog.entitlementProductIDs,
            cloud.union(pro).union(ultra),
            "the aggregate set must be exactly the three tier sets"
        )
        XCTAssertFalse(cloud.isEmpty)
        XCTAssertFalse(pro.isEmpty)
        XCTAssertFalse(ultra.isEmpty)
    }

    // MARK: - Determinism

    func testDeterministicForFixedInputs() {
        let cloud = [
            EntitlementArbitration.CloudDocState(
                key: "burnbar_pro_max", active: true, expiry: future, fallbackTier: .pro
            )
        ]
        let a = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        let b = EntitlementArbitration.effectiveTier(cloud: cloud, storeKit: [], now: now)
        XCTAssertEqual(a, b)
    }
}
