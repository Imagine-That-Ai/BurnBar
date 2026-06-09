import Foundation

/// # F5 — at-rest sender-authentication downgrade policy
///
/// When a caller opens a **present** `CloudVaultSignalEnvelope` and
/// `OpenBurnBarSignalAtRest.openPayload(...)` throws, the historical contract was
/// "treat ANY throw as: fall back to the legacy `sealedPayload`". The legacy path
/// is HPKE-sealed to the recipient but carries **no sender authentication**, so a
/// blanket fallback lets an attacker who can write the Firestore doc strip or
/// forge `senderAuth` and have the recipient silently accept the payload — the
/// downgrade this remediation closes.
///
/// This policy classifies each failure so callers fall back **only** for cases
/// that are genuinely non-attacks (an unrecognized sender while the trusted-sender
/// set is still being resolved, or a structural error that is not a sender
/// downgrade) and **fail closed** — dropping/surfacing rather than decoding — for a
/// stripped/forged sender block or a relocated (binding-mismatched) envelope.
///
/// The classification is a pure function of the error and the caller's knowledge
/// of whether its trusted-sender set is complete, so it is fully unit-testable and
/// shared by every at-rest reader (Mac + Mobile chokepoints, and the in-flight
/// Hermes sender-trust resolver) for identical cross-platform behavior.
extension OpenBurnBarSignalCoreError {
    /// Whether a caller that hit this error opening a **present** at-rest envelope
    /// may safely fall back to the unauthenticated legacy `sealedPayload`.
    ///
    /// - Parameter senderSetComplete: pass `true` once the caller has resolved the
    ///   full set of trusted senders (every paired device's pinned key). When the
    ///   set is complete, an unrecognized sender (`.senderNotTrusted`) is treated
    ///   as an attack and fails closed; while the set is still incomplete it is a
    ///   rollout readiness gap and stays legacy-eligible so a legitimate
    ///   cross-device payload is not dropped.
    /// - Returns: `true` if a legacy fallback is safe, `false` if the caller must
    ///   fail closed (drop the payload / surface an error, never decode legacy).
    public func allowsLegacyAtRestFallback(senderSetComplete: Bool) -> Bool {
        switch self {
        case .senderSignatureInvalid, .senderAuthMissing, .bindingMismatch:
            // A forged signature, a stripped sender block, or an envelope whose
            // path binding does not match (a relocated/replayed doc) — never
            // downgrade to the sender-unauthenticated legacy path.
            return false
        case .senderNotTrusted:
            // Unknown sender: an attack once every expected sender is resolved, a
            // readiness gap before then.
            return !senderSetComplete
        case .noRecipients, .tooManyRecipients, .invalidRecipientKind,
             .duplicateRecipientIdentityKeyId, .invalidEnvelope, .missingRecipientWrap,
             .invalidContentKey, .recipientPrivateKeyMismatch:
            // Structural / not-addressed-to-this-recipient errors are not a sender
            // downgrade; preserve the existing legacy-compatible behavior so a
            // genuinely old or non-matching payload is still read by the caller's
            // legacy path.
            return true
        }
    }
}
