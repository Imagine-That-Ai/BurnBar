import Foundation
@preconcurrency import FirebaseAuth

// MARK: - AccountManaging

/// Protocol abstracting the account management surface needed by CloudSync.
@MainActor
protocol AccountManaging: AnyObject {
    var isFirebaseAvailable: Bool { get }
    var isSignedIn: Bool { get }
    var isCloudSyncEnabled: Bool { get }
    var deviceId: String { get }
    var currentUser: User? { get }
    var currentUID: String? { get }
}

// MARK: - AccountManager Conformance

extension AccountManager: AccountManaging {
    var currentUID: String? {
        guard isFirebaseAvailable, isSignedIn else { return nil }
        return currentUser?.uid
    }
}
