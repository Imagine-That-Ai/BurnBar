import Foundation

// MARK: - Ultra tier bridge
//
// Pensieve's higher caps (15 sources / 50k chunks / 250 MB) are gated on the
// BurnBar Ultra entitlement, which is server-reconciled and has NO Apple
// product id (so StoreKit alone cannot see it). The authoritative tier comes
// from `getDataDomainUsage().tier` (resolved server-side from the
// `burnbar_ultra` entitlement doc). This extension lets the membership store
// carry that resolved tier so the Control Center and any gated surface can ask
// `subscriptionStore.isActiveUltra` without re-plumbing the callable.
//
// `isActivePro` already exists on the store for the Cloud Pro (proMax) tier;
// Ultra is strictly above it (Ultra ⇒ Pro), so the convenience predicates here
// compose cleanly.

extension HostedQuotaSubscriptionStore {
    /// The data tier the server resolved for this member, mirrored from the
    /// Data & Privacy Control Center's `getDataDomainUsage` read. `nil` until a
    /// surface that reads usage has run. Stored out-of-band (no @Observable
    /// field churn on the store) via an associated holder.
    var resolvedDataTier: String? {
        get { UltraTierBridge.shared.tier }
        set { UltraTierBridge.shared.tier = newValue }
    }

    /// True when the member holds the BurnBar Ultra entitlement (server-resolved
    /// tier == "ultra"). Falls back to `false` when the tier has not been read.
    var isActiveUltra: Bool {
        resolvedDataTier == "ultra"
    }

    /// True when the member can use Pensieve at all (Cloud Pro or Ultra). Prefers
    /// the server-resolved tier; falls back to the StoreKit-known Pro state so
    /// the predicate is still meaningful before usage has loaded.
    var isPensieveEligible: Bool {
        if let tier = resolvedDataTier { return tier == "pro" || tier == "ultra" }
        return isActivePro
    }
}

/// Process-wide holder for the server-resolved data tier. Kept separate from the
/// `@Observable` store so writing it from a usage read doesn't invalidate every
/// view observing the store; surfaces that care read it explicitly on refresh.
@MainActor
final class UltraTierBridge {
    static let shared = UltraTierBridge()
    var tier: String?
    private init() {}
}
