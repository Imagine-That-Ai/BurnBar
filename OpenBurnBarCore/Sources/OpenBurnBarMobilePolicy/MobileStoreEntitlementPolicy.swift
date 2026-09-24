import Foundation

/// StoreKit / Play product IDs that must stay semantically aligned.
public enum MobileStoreProductRole: String, Sendable, Equatable, CaseIterable {
    case cloudMonthly
    case cloudAnnual
    case proMonthly
    case proAnnual
    case ultraMonthly
    case ultraAnnual
    case agentControlTopUp
    case flooRelayTopUp
    case elderWand100
    case elderWand500
}

public enum MobileStoreEntitlementState: String, Sendable, Equatable, CaseIterable {
    case none
    case active
    case expired
    case refunded
    case revoked
    case missingCatalog = "missing-catalog"
    case restorePending = "restore-pending"
}

public enum MobileStorePriceDisplay: Sendable, Equatable {
    case live(String)
    case unavailable

    public var customerFacingText: String {
        switch self {
        case .live(let price): return price
        case .unavailable: return MobileStoreEntitlementPolicy.unavailablePriceLabel
        }
    }

    public var isLivePrice: Bool {
        if case .live = self { return true }
        return false
    }
}

public enum MobileStoreEntitlementPolicy {
    /// Not a price. Shown only when StoreKit / Play has not returned ProductDetails.
    public static let unavailablePriceLabel = "Price unavailable"

    public static let appleCloudMonthly = "com.openburnbar.pro.monthly"
    public static let appleCloudAnnual = "com.openburnbar.pro.annual"
    public static let appleProMonthly = "com.openburnbar.proMax.v2.monthly"
    public static let appleProAnnual = "com.openburnbar.proMax.annual"
    public static let appleUltraMonthly = "com.openburnbar.ultra.monthly"
    public static let appleUltraAnnual = "com.openburnbar.ultra.annual.v2"
    public static let appleAgentControl = "com.openburnbar.agentControl.actions100"
    public static let appleFlooRelay = "com.openburnbar.floo.relay50gb"
    public static let appleElderWand100 = "com.openburnbar.elderWand.searches100"
    public static let appleElderWand500 = "com.openburnbar.elderWand.searches500"

    public static let playCloudMonthly = "com.openburnbar.pro.monthly"
    public static let playCloudAnnual = "com.openburnbar.pro.annual"
    public static let playProMonthly = "com.openburnbar.promax.v2.monthly"
    public static let playProAnnual = "com.openburnbar.promax.annual"
    public static let playUltraMonthly = "com.openburnbar.ultra.monthly"
    public static let playUltraAnnual = "com.openburnbar.ultra.annual"
    public static let playAgentControl = "com.openburnbar.agentcontrol.actions100"
    public static let playFlooRelay = "com.openburnbar.floo.relay50gb"
    public static let playElderWand100 = "com.openburnbar.elderwand.searches100"
    public static let playElderWand500 = "com.openburnbar.elderwand.searches500"

    public static func role(for productID: String) -> MobileStoreProductRole? {
        switch productID {
        case appleCloudMonthly, playCloudMonthly: return .cloudMonthly
        case appleCloudAnnual, playCloudAnnual: return .cloudAnnual
        case appleProMonthly, playProMonthly: return .proMonthly
        case appleProAnnual, playProAnnual: return .proAnnual
        case appleUltraMonthly, playUltraMonthly: return .ultraMonthly
        case appleUltraAnnual, playUltraAnnual: return .ultraAnnual
        case appleAgentControl, playAgentControl: return .agentControlTopUp
        case appleFlooRelay, playFlooRelay: return .flooRelayTopUp
        case appleElderWand100, playElderWand100: return .elderWand100
        case appleElderWand500, playElderWand500: return .elderWand500
        default: return nil
        }
    }

    public static func displayPrice(livePrice: String?) -> MobileStorePriceDisplay {
        let trimmed = livePrice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != unavailablePriceLabel else {
            return .unavailable
        }
        return .live(trimmed)
    }

    public static func classify(
        catalogPresent: Bool,
        restoring: Bool,
        revoked: Bool,
        refunded: Bool,
        expired: Bool,
        active: Bool
    ) -> MobileStoreEntitlementState {
        if !catalogPresent { return .missingCatalog }
        if restoring { return .restorePending }
        if revoked { return .revoked }
        if refunded { return .refunded }
        if expired { return .expired }
        if active { return .active }
        return .none
    }
}
