import Foundation

/// A **bounded, enum-only** code for a cloud/auth error, safe to send as an
/// analytics property. Critically, the `.other(message:)` case collapses to the
/// literal `"other"` — the raw message (free text, potentially PII) is NEVER sent.
/// Every other case is a fixed snake_case literal from a closed set.
extension CloudErrorClassification {
    var analyticsCode: String {
        switch self {
        case .firebaseUnavailable: return "firebase_unavailable"
        case .firestoreUnavailable: return "firestore_unavailable"
        case .appCheckBlocked: return "app_check_blocked"
        case .permissionDenied: return "permission_denied"
        case .networkUnavailable: return "network_unavailable"
        case .accountMismatch: return "account_mismatch"
        case .notAuthenticated: return "not_authenticated"
        case .rateLimited: return "rate_limited"
        case .decodingFailed: return "decoding_failed"
        case .other: return "other" // raw message deliberately dropped — no free text
        }
    }
}
