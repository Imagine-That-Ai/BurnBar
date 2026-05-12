import Foundation

public enum CloudErrorClassification: Sendable, Equatable {
    case firebaseUnavailable, firestoreUnavailable, appCheckBlocked
    case permissionDenied, networkUnavailable, accountMismatch, notAuthenticated
    case rateLimited, decodingFailed, other(message: String)

    public var label: String {
        switch self {
        case .firebaseUnavailable: return "Firebase unavailable"
        case .firestoreUnavailable: return "Firestore unavailable"
        case .appCheckBlocked: return "App Check blocked"
        case .permissionDenied: return "Permission denied"
        case .networkUnavailable: return "Offline"
        case .accountMismatch: return "Account mismatch"
        case .notAuthenticated: return "Not signed in"
        case .rateLimited: return "Rate limited"
        case .decodingFailed: return "Decoding failed"
        case .other(let m): return m
        }
    }

    public var recoveryHint: String {
        switch self {
        case .firebaseUnavailable: return "OpenBurnBar could not reach Firebase. Check your network and try again."
        case .firestoreUnavailable: return "Firestore is unreachable. Synced stats will resume once it returns."
        case .appCheckBlocked: return "App Check rejected this device."
        case .permissionDenied: return "Sign out and sign back in with the same account you use on Mac."
        case .networkUnavailable: return "You appear to be offline."
        case .accountMismatch: return "This device is signed into a different Firebase account."
        case .notAuthenticated: return "Sign in to view OpenBurnBar stats from your Mac."
        case .rateLimited: return "Too many requests. Try again shortly."
        case .decodingFailed: return "Could not parse cloud data. Tap refresh to retry."
        case .other(let m): return m
        }
    }

    static func permissionDeniedClassification(message: String) -> CloudErrorClassification {
        let normalized = message.replacingOccurrences(of: " ", with: "").lowercased()
        if normalized.contains("appcheck") || normalized.contains("attestation") {
            return .appCheckBlocked
        }
        return .permissionDenied
    }
}
