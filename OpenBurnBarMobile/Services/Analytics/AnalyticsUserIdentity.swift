import Foundation
import CryptoKit

/// Derives the Amplitude `user_id` from an authenticated account uid.
///
/// The taxonomy requires `user_id` to be set **only after verified sign-in**, to a
/// **stable account uid hash** — never the raw uid (a raw id is PII-adjacent and
/// off-limits as a value). We SHA-256 the Firebase uid so the identifier is stable
/// per account (the same user maps to the same Amplitude id across devices) but the
/// raw uid never leaves the device. No salt is needed for this purpose: we want a
/// deterministic, irreversible, stable map, and the uid is already an opaque
/// Firebase identifier, not a user secret.
enum AnalyticsUserIdentity {
    static func amplitudeUserId(forAccountUID uid: String) -> String? {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
