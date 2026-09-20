import Foundation
@preconcurrency import FirebaseAuth

// MARK: - AccountManaging

/// Protocol abstracting the account management surface needed by CloudSync.
@MainActor
protocol AccountManaging: AnyObject, Sendable {
    var isFirebaseAvailable: Bool { get }
    var isSignedIn: Bool { get }
    var isCloudSyncEnabled: Bool { get }
    var deviceId: String { get }
    var currentUser: User? { get }
    var currentUID: String? { get }

    /// Registers `observer` to run whenever the signed-in identity CHANGES — a
    /// sign-in, a sign-out, or a switch from one member to another — with the
    /// new uid (nil when signed out). Same-uid callbacks (token refreshes) do
    /// not fire it.
    ///
    /// Exists for Memory Blind Sync: the device-sync consent marker and the
    /// plaintext inbox it authorises are claims about *who is signed in*, and
    /// before this the only thing that re-evaluated them was the refresh tick
    /// (600 s by default) and the Settings toggle. A sign-out therefore left the
    /// marker standing for up to a full interval — and for ever if the app quit
    /// first, because the daemon that honours it outlives the app. See
    /// `MemoryDeviceSyncInboxGuard.enforceAccountTransition`.
    ///
    /// Observers are retained for the process's lifetime, so callers pass a
    /// closure that captures its subject weakly.
    func observeAccountIdentityChanges(_ observer: @escaping @MainActor @Sendable (String?) -> Void)
}

// MARK: - AccountManager Conformance

extension AccountManager: AccountManaging {
    var currentUID: String? {
        guard isFirebaseAvailable, isSignedIn else { return nil }
        return currentUser?.uid
    }
}
