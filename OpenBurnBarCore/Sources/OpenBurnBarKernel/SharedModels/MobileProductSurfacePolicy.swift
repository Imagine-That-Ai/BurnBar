import Foundation

public enum MobileProductCardDisposition: String, Sendable, Equatable {
    case real
    case removed
    case gated
}

/// Interactive card actions must be real, gated, or removed — never decorative.
public enum MobileProductSurfacePolicy {
    public static func disposition(
        actionId: String,
        catalogPresent: Bool = true,
        entitlement: MobileStoreEntitlementState = .none
    ) -> MobileProductCardDisposition {
        switch actionId {
        case "decorative.stop", "fake.cancel", "silent.discard":
            return .removed
        case "store.purchase", "store.restore":
            if !catalogPresent { return .removed }
            return .real
        case "budget.enforce", "surface.budget-enforce":
            return entitlement == .active ? .real : .gated
        case "inbox.archive", "inbox.snooze", "inbox.feedback", "inbox.open-route",
             "store.open", "pulse.retry", "streams.retry":
            return .real
        default:
            return .removed
        }
    }

    public static func mayEnforceBudget(_ entitlement: MobileStoreEntitlementState) -> Bool {
        entitlement == .active
    }
}
