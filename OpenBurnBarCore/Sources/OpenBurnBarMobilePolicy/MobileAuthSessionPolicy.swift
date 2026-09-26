import Foundation

/// Shared mobile auth session states. Firebase unavailable is not signed-out.
public enum MobileAuthSessionState: String, Sendable, Equatable, CaseIterable {
    case signedOut = "signed-out"
    case signingIn = "signing-in"
    case signedIn = "signed-in"
    case deletingAccount = "deleting-account"
    case firebaseUnavailable = "firebase-unavailable"
    case firestoreUnavailable = "firestore-unavailable"

    public var isSignedIn: Bool {
        switch self {
        case .signedIn, .deletingAccount: return true
        default: return false
        }
    }
}

/// Distinct user-visible auth failures. App Check is never collapsed into signed-out.
public enum MobileAuthErrorClass: String, Sendable, Equatable, CaseIterable {
    case none
    case appCheck = "app-check"
    case revokedAccount = "revoked-account"
    case expired
    case accountSwitch = "account-switch"
    case permissionDenied = "permission-denied"
    case firebaseUnavailable = "firebase-unavailable"
    case firestoreUnavailable = "firestore-unavailable"
    case network
    case malformed

    public var userVisibleLabel: String {
        switch self {
        case .none: return ""
        case .appCheck: return "App Check blocked"
        case .revokedAccount: return "Account revoked"
        case .expired: return "Session expired"
        case .accountSwitch: return "Account mismatch"
        case .permissionDenied: return "Permission denied"
        case .firebaseUnavailable: return "Firebase unavailable"
        case .firestoreUnavailable: return "Firestore unavailable"
        case .network: return "Offline"
        case .malformed: return "Could not complete sign-in"
        }
    }
}

/// UID + generation so late snapshots cannot land on a replacement account.
public struct MobileAuthSessionEpoch: Sendable, Equatable {
    public let uid: String?
    public let generation: Int

    public init(uid: String?, generation: Int) {
        self.uid = uid
        self.generation = generation
    }

    public func advanced(for nextUid: String?) -> MobileAuthSessionEpoch {
        MobileAuthSessionEpoch(uid: nextUid, generation: generation &+ 1)
    }
}

public enum MobileAuthSessionPolicy {
    /// Matches Android `ControllerAuthStatePolicy.shouldReconcile`.
    public static func shouldReconcile(previousUid: String?, nextUid: String?) -> Bool {
        previousUid != nextUid
    }

    /// Matches Android `ControllerAuthStatePolicy.isCurrent`.
    public static func isCurrent(
        expectedUid: String?,
        expectedGeneration: Int,
        currentUid: String?,
        currentGeneration: Int
    ) -> Bool {
        expectedUid == currentUid && expectedGeneration == currentGeneration
    }

    public static func isCurrent(expected: MobileAuthSessionEpoch, current: MobileAuthSessionEpoch) -> Bool {
        isCurrent(
            expectedUid: expected.uid,
            expectedGeneration: expected.generation,
            currentUid: current.uid,
            currentGeneration: current.generation
        )
    }

    public static func shouldServeCachedData(
        cacheUid: String?,
        activeUid: String?,
        cacheGeneration: Int,
        activeGeneration: Int
    ) -> Bool {
        guard let cacheUid, let activeUid, !cacheUid.isEmpty, cacheUid == activeUid else { return false }
        return cacheGeneration == activeGeneration
    }

    /// Firebase-unavailable is a configuration/backend class, never signed-out.
    public static func stateWhenFirebaseUnavailable() -> MobileAuthSessionState {
        .firebaseUnavailable
    }

    public static func stateAfterSignOut(firebaseAvailable: Bool) -> MobileAuthSessionState {
        firebaseAvailable ? .signedOut : .firebaseUnavailable
    }

    public static func classify(code: String, message: String? = nil) -> MobileAuthErrorClass {
        let haystack = [code, message ?? ""]
            .joined(separator: " ")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if haystack.contains("appcheck") || haystack.contains("attestation") {
            return .appCheck
        }
        if haystack.contains("user-disabled") || haystack.contains("userdisabled")
            || haystack.contains("revoked") {
            return .revokedAccount
        }
        if haystack.contains("id-token-expired") || haystack.contains("tokenexpired")
            || haystack.contains("sessionexpired") {
            return .expired
        }
        if haystack.contains("accountmismatch") || haystack.contains("account-switch")
            || haystack.contains("uid-changed") {
            return .accountSwitch
        }
        if haystack.contains("permission-denied") || haystack.contains("permissiondenied")
            || haystack.contains("missingorinsufficientpermissions") {
            return .permissionDenied
        }
        if haystack.contains("firebaseunavailable") || haystack.contains("firebase-unavailable")
            || haystack.contains("configuration_not_found") {
            return .firebaseUnavailable
        }
        if haystack.contains("firestoreunavailable") || haystack.contains("firestore-unavailable") {
            return .firestoreUnavailable
        }
        if haystack.contains("unavailable") || haystack.contains("network") || haystack.contains("offline")
            || haystack.contains("deadline-exceeded") {
            return .network
        }
        if haystack.contains("unauthenticated") || haystack.contains("notauthenticated") {
            return .none
        }
        return .malformed
    }
}
