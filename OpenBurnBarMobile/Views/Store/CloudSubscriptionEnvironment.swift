import SwiftUI

// MARK: - Cloud Subscription Environment
//
// Shares one `HostedQuotaSubscriptionStore` instance across the iOS app — the
// Settings → Cloud row, the Pulse upsell banner, and the dedicated store
// screen all read the same StoreKit observer. This avoids spawning multiple
// `Transaction.updates` listeners and keeps entitlement chrome in lock-step
// across surfaces.
//
// The onboarding-time picker continues to use its own local instance; that
// flow is short-lived and isn't affected by sharing.

private struct CloudSubscriptionStoreKey: EnvironmentKey {
    static let defaultValue: HostedQuotaSubscriptionStore? = nil
}

private struct MobileAuthStoreKey: EnvironmentKey {
    static let defaultValue: AuthStore? = nil
}

extension EnvironmentValues {
    /// Shared subscription store hoisted at `RootTabView`. `nil` only in
    /// previews and the rare surface that never sees the root.
    var cloudSubscriptionStore: HostedQuotaSubscriptionStore? {
        get { self[CloudSubscriptionStoreKey.self] }
        set { self[CloudSubscriptionStoreKey.self] = newValue }
    }

    /// Current mobile auth store, exposed so account-backed subflows can
    /// present sign-in from deep screens without rebuilding the app shell.
    var mobileAuthStore: AuthStore? {
        get { self[MobileAuthStoreKey.self] }
        set { self[MobileAuthStoreKey.self] = newValue }
    }
}
