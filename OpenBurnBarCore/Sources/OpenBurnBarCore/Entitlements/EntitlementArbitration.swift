// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// MARK: - Entitlement product catalog
//
// The commercial StoreKit product-ID → tier table shared by the Apple
// entitlement surfaces (Wave-5 §2.3). This is pure data — the platform-side
// `MacCloudStoreKitProductCatalog` delegates here so the mac app, the pure
// arbitration below, and cross-platform contract vectors all read the same
// single source of truth. Keep in parity with the iOS commercial IDs (see
// `MacMediaCapabilityGateTests.testMacCloudStoreKitCatalogMatchesIOSCommercialEntitlementIDs`).

public enum EntitlementProductCatalog {
    public static let cloudMonthlyProductID = "com.openburnbar.pro.monthly"
    public static let cloudAnnualProductID = "com.openburnbar.pro.annual"
    public static let cloudProMonthlyProductID = "com.openburnbar.proMax.v2.monthly"
    public static let cloudProAnnualProductID = "com.openburnbar.proMax.annual"
    public static let cloudUltraMonthlyProductID = "com.openburnbar.ultra.monthly"
    public static let cloudUltraAnnualProductID = "com.openburnbar.ultra.annual.v2"
    public static let legacyCloudUltraAnnualProductID = "com.openburnbar.ultra.annual"
    public static let legacyHostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"
    public static let legacyHostedQuotaOriginalProductID = "com.openburnbar.hostedQuotaSync.monthly"
    public static let legacyHostedComputerUseProductID = "com.openburnbar.hostedComputerUseSync.monthly"
    public static let legacyComputerUseProductID = "com.openburnbar.computerUse.monthly"
    public static let legacyProMaxProductID = "com.openburnbar.proMax.monthly"
    public static let legacyProMaxBundleProductID = "com.openburnbar.proMax.bundle.monthly"

    public static let cloudProductIDs: Set<String> = [
        cloudMonthlyProductID,
        cloudAnnualProductID,
        legacyHostedQuotaProductID,
        legacyHostedQuotaOriginalProductID
    ]

    public static let proProductIDs: Set<String> = [
        cloudProMonthlyProductID,
        cloudProAnnualProductID,
        legacyComputerUseProductID,
        legacyHostedComputerUseProductID,
        legacyProMaxProductID,
        legacyProMaxBundleProductID
    ]

    public static let ultraProductIDs: Set<String> = [
        cloudUltraMonthlyProductID,
        cloudUltraAnnualProductID,
        legacyCloudUltraAnnualProductID
    ]

    public static let entitlementProductIDs = cloudProductIDs
        .union(proProductIDs)
        .union(ultraProductIDs)

    /// Maps a StoreKit product ID (current or legacy) to the tier it grants.
    /// Unknown / nil product IDs resolve to `nil` — callers fail closed.
    public static func tier(for productID: String?) -> CloudTier? {
        guard let productID else { return nil }
        if ultraProductIDs.contains(productID) { return .ultra }
        if proProductIDs.contains(productID) { return .pro }
        if cloudProductIDs.contains(productID) { return .cloud }
        return nil
    }
}

// MARK: - Entitlement arbitration (pure, Wave-5 §2.3)
//
// The mac entitlement-precedence contract extracted from
// `MacCloudEntitlementStore` as a pure, deterministic function of
// (inputs, now). No Firestore, no StoreKit, no I/O, no ambient clock.
//
// The N3 invariants this encodes structurally:
//   1. Any ACTIVE cloud entitlement wins wholesale over StoreKit — the two
//      source sets never mix per-tier.
//   2. A present-but-LAPSED cloud doc is invisible: the precedence guard is
//      "any cloud entitlement active", never "any cloud doc present", so a
//      lapsed doc must not suppress a valid local StoreKit entitlement.
//   3. StoreKit snapshots are validated by the platform caller (revocation,
//      expiry, appAccountToken → Firebase-UID binding), but the value type
//      carries `uidBound`/`revoked` and this function excludes any snapshot
//      that is not UID-bound, revoked, expired, or unmapped — fail closed,
//      defense in depth.
//   4. Per-tier merge keeps the grant with the later expiry.
//   5. Tier implication is Ultra ⇒ Pro ⇒ Cloud: a grant at a higher tier
//      also activates every lower paid tier.

public enum EntitlementArbitration {
    // MARK: Inputs

    /// One server-authored cloud entitlement doc, already parsed from its
    /// raw Firestore shapes into plain values by the platform caller.
    public struct CloudDocState: Equatable, Sendable {
        /// Doc key under `users/{uid}/entitlements/` (e.g. `hosted_quota_sync`).
        /// Informational — precedence never keys off presence of a doc.
        public let key: String
        /// The raw `active` flag as written by Cloud Functions. Effective
        /// activity is `active && !expired(now)`, computed here.
        public let active: Bool
        /// Optional `productID` field; when it maps in the catalog it
        /// overrides `fallbackTier`.
        public let productID: String?
        public let expiry: Date?
        public let purchase: Date?
        /// Tier granted when the doc carries no (or an unmapped) product ID —
        /// the doc key's contractual tier (`hosted_quota_sync` → `.cloud`,
        /// `hosted_computer_use_sync`/`burnbar_pro_max` → `.pro`,
        /// `burnbar_ultra` → `.ultra`).
        public let fallbackTier: CloudTier

        public init(
            key: String,
            active: Bool,
            productID: String? = nil,
            expiry: Date? = nil,
            purchase: Date? = nil,
            fallbackTier: CloudTier
        ) {
            self.key = key
            self.active = active
            self.productID = productID
            self.expiry = expiry
            self.purchase = purchase
            self.fallbackTier = fallbackTier
        }
    }

    /// One locally verified StoreKit 2 transaction, snapshotted into plain
    /// values by the platform caller. The caller performs the authoritative
    /// validation (signature verification, revocation, expiry, appAccountToken
    /// binding to the signed-in Firebase UID) — the flags here exist so this
    /// function can fail closed if an unvalidated snapshot ever leaks through.
    public struct StoreKitState: Equatable, Sendable {
        public let productID: String
        /// True only when the transaction's appAccountToken is bound to the
        /// currently signed-in Firebase UID. False ⇒ excluded (fail closed).
        public let uidBound: Bool
        public let revoked: Bool
        public let expiry: Date?
        public let purchase: Date?

        public init(
            productID: String,
            uidBound: Bool,
            revoked: Bool = false,
            expiry: Date? = nil,
            purchase: Date? = nil
        ) {
            self.productID = productID
            self.uidBound = uidBound
            self.revoked = revoked
            self.expiry = expiry
            self.purchase = purchase
        }
    }

    // MARK: Outputs

    /// The resolved grant for one paid tier: whether it is active right now
    /// and, when active, the winning expiry/purchase dates. Inactive grants
    /// carry no dates — a lapsed source never surfaces its metadata.
    public struct TierGrant: Equatable, Sendable {
        public let isActive: Bool
        public let expiry: Date?
        public let purchase: Date?

        public init(isActive: Bool, expiry: Date? = nil, purchase: Date? = nil) {
            self.isActive = isActive
            self.expiry = expiry
            self.purchase = purchase
        }

        public static let inactive = TierGrant(isActive: false)

        /// Port of `MacEntitlementActiveState.preferred(over:)`: an active
        /// grant beats an inactive one; between two active grants the later
        /// expiry wins, a dated expiry beats an undated one, and ties keep
        /// the candidate.
        func preferred(over existing: TierGrant) -> TierGrant {
            guard isActive else { return existing }
            guard existing.isActive else { return self }
            switch (expiry, existing.expiry) {
            case let (candidate?, current?):
                return candidate > current ? self : existing
            case (_?, nil):
                return self
            case (nil, _?):
                return existing
            case (nil, nil):
                return self
            }
        }
    }

    /// Which source set won the wholesale precedence decision.
    public enum Source: Equatable, Sendable {
        case cloudDocs
        case storeKit
        case none
    }

    /// The full arbitration result `MacCloudEntitlementStore` publishes:
    /// the effective (highest active) tier plus per-tier activity, expiry,
    /// and purchase info, and which source set produced them.
    public struct Arbitration: Equatable, Sendable {
        public let effectiveTier: CloudTier
        public let source: Source
        public let cloud: TierGrant
        public let pro: TierGrant
        public let ultra: TierGrant

        public init(
            effectiveTier: CloudTier,
            source: Source,
            cloud: TierGrant,
            pro: TierGrant,
            ultra: TierGrant
        ) {
            self.effectiveTier = effectiveTier
            self.source = source
            self.cloud = cloud
            self.pro = pro
            self.ultra = ultra
        }

        public static let free = Arbitration(
            effectiveTier: .none,
            source: .none,
            cloud: .inactive,
            pro: .inactive,
            ultra: .inactive
        )
    }

    // MARK: Arbitration

    /// Resolves the effective membership from the cloud entitlement docs and
    /// the locally verified StoreKit snapshots. Deterministic given
    /// (`cloud`, `storeKit`, `now`); on tie-breaks, earlier elements of each
    /// input array win (callers pass docs in their canonical listener order).
    public static func effectiveTier(
        cloud: [CloudDocState],
        storeKit: [StoreKitState],
        now: Date
    ) -> Arbitration {
        let cloudMembership = membership(fromCloudDocs: cloud, now: now)
        // N3: the guard is "any cloud entitlement ACTIVE" — a merely present
        // (lapsed) cloud doc contributes nothing and must not suppress a
        // valid StoreKit grant.
        if !cloudMembership.isEmpty {
            return arbitration(from: cloudMembership, source: .cloudDocs)
        }
        let storeKitMembership = membership(fromStoreKit: storeKit, now: now)
        if !storeKitMembership.isEmpty {
            return arbitration(from: storeKitMembership, source: .storeKit)
        }
        return .free
    }

    // MARK: Internals

    /// Port of `MacMembershipEntitlementState`: the per-tier accumulator with
    /// Ultra ⇒ Pro ⇒ Cloud implication encoded in `merge`.
    private struct Membership {
        var cloud: TierGrant = .inactive
        var pro: TierGrant = .inactive
        var ultra: TierGrant = .inactive

        var isEmpty: Bool {
            !cloud.isActive && !pro.isActive && !ultra.isActive
        }

        mutating func merge(_ grant: TierGrant, tier: CloudTier) {
            switch tier {
            case .none:
                return
            case .cloud:
                cloud = grant.preferred(over: cloud)
            case .pro:
                cloud = grant.preferred(over: cloud)
                pro = grant.preferred(over: pro)
            case .ultra:
                cloud = grant.preferred(over: cloud)
                pro = grant.preferred(over: pro)
                ultra = grant.preferred(over: ultra)
            }
        }
    }

    private static func membership(fromCloudDocs docs: [CloudDocState], now: Date) -> Membership {
        var membership = Membership()
        for doc in docs {
            let notExpired = doc.expiry.map { $0 > now } ?? true
            let grant = TierGrant(
                isActive: doc.active && notExpired,
                expiry: doc.expiry,
                purchase: doc.purchase
            )
            let tier = EntitlementProductCatalog.tier(for: doc.productID) ?? doc.fallbackTier
            membership.merge(grant, tier: tier)
        }
        return membership
    }

    private static func membership(fromStoreKit states: [StoreKitState], now: Date) -> Membership {
        var membership = Membership()
        for state in states {
            // Fail closed: anything revoked, expired, not bound to the
            // signed-in UID, or not mapping to a commercial tier is invisible.
            guard state.uidBound,
                  !state.revoked,
                  state.expiry.map({ $0 > now }) ?? true,
                  let tier = EntitlementProductCatalog.tier(for: state.productID)
            else {
                continue
            }
            membership.merge(
                TierGrant(isActive: true, expiry: state.expiry, purchase: state.purchase),
                tier: tier
            )
        }
        return membership
    }

    private static func arbitration(from membership: Membership, source: Source) -> Arbitration {
        let effectiveTier: CloudTier = {
            if membership.ultra.isActive { return .ultra }
            if membership.pro.isActive { return .pro }
            if membership.cloud.isActive { return .cloud }
            return .none
        }()
        return Arbitration(
            effectiveTier: effectiveTier,
            source: source,
            cloud: membership.cloud,
            pro: membership.pro,
            ultra: membership.ultra
        )
    }
}
