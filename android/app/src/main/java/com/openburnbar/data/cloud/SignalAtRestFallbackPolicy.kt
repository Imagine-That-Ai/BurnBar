package com.openburnbar.data.cloud

/**
 * # F5 — at-rest sender-authentication downgrade policy (Android mirror)
 *
 * The Android counterpart of Swift `SignalAtRestFallbackPolicy.swift`. When a caller opens a
 * **present** [CloudVaultSignalEnvelope] and [CloudVaultCrypto.openSignalPayload] throws, the
 * historical contract was "treat ANY throw as: fall back to the legacy `sealedPayload`". The legacy
 * path is HPKE-sealed to the recipient but carries **no sender authentication**, so a blanket
 * fallback lets an attacker who can write the Firestore doc strip or forge `senderAuth` and have the
 * recipient silently accept the payload — the downgrade this remediation closes.
 *
 * This policy classifies each failure so callers fall back **only** for cases that are genuinely
 * non-attacks (an unrecognized sender while the trusted-sender set is still being resolved, or a
 * structural error that is not a sender downgrade) and **fail closed** — dropping/surfacing rather
 * than decoding — for a stripped/forged sender block or a relocated (binding-mismatched) envelope.
 *
 * The classification is a pure function of the error and the caller's knowledge of whether its
 * trusted-sender set is complete, so it is fully unit-testable and matches the Swift behavior.
 */
object SignalAtRestFallbackPolicy {
    /**
     * Whether a caller that hit [error] opening a **present** at-rest envelope may safely fall back
     * to the unauthenticated legacy `sealedPayload`.
     *
     * @param senderSetComplete pass `true` once the caller has resolved the full set of trusted
     *   senders (every paired device's pinned key). When the set is complete, an unrecognized sender
     *   ([CloudVaultSignalSenderAuthException.SenderNotTrusted]) is treated as an attack and fails
     *   closed; while the set is still incomplete it is a rollout readiness gap and stays
     *   legacy-eligible so a legitimate cross-device payload is not dropped.
     * @return `true` if a legacy fallback is safe, `false` if the caller must fail closed (drop the
     *   payload / surface an error, never decode legacy).
     */
    fun allowsLegacyAtRestFallback(error: Throwable, senderSetComplete: Boolean): Boolean = when (error) {
        // A forged signature or a stripped sender block — never downgrade to the
        // sender-unauthenticated legacy path.
        is CloudVaultSignalSenderAuthException.SenderSignatureInvalid,
        is CloudVaultSignalSenderAuthException.SenderAuthMissing,
        -> false
        // Unknown sender: an attack once every expected sender is resolved, a readiness gap before then.
        is CloudVaultSignalSenderAuthException.SenderNotTrusted -> !senderSetComplete
        // A relocated/replayed doc (binding mismatch) is surfaced by the binding-guard
        // `require(...)` (IllegalArgumentException) in the opener — never downgrade it either.
        is IllegalArgumentException -> false
        // Structural / not-addressed-to-this-recipient errors are not a sender downgrade; preserve
        // the existing legacy-compatible behavior so a genuinely old or non-matching payload is
        // still read by the caller's legacy path.
        else -> true
    }
}
