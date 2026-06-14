package com.openburnbar.data.computeruse

import java.security.MessageDigest

/**
 * Canonical App Check attestation digest shared by Mac, iOS, Cloud Functions,
 * and Android (WS2/WS4). 1:1 Kotlin port of the Swift
 * `AppCheckAttestationBinding`
 * (`OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AppCheckAttestationBinding.swift`).
 *
 * The server's `bindAppCheckAttestation` callable verifies the caller's App
 * Check token (Play Integrity on Android, App Attest on iOS) and writes the
 * platform-agnostic `obb_app_check` custom claim (`appId`, `boundAtMillis`)
 * onto the Firebase Auth user. Clients re-derive the SHA-256 hex digest from
 * that claim and carry it as the wire field `attestationHashBlake3` (the
 * **controller app's** digest — the field name is historical). Mac strict
 * mode checks presence, not equality with the Mac host App Check app id.
 */
object AppCheckAttestationBinding {
    const val CLAIM_KEY = "obb_app_check"
    const val CANONICAL_PREFIX = "openburnbar.appcheck.v1"
    const val MAX_AGE_MILLIS: Long = 30L * 24L * 60L * 60L * 1000L

    data class Claim(
        val appId: String,
        val boundAtMillis: Long,
    )

    fun digestHex(appId: String, boundAtMillis: Long): String {
        val payload = "$CANONICAL_PREFIX|$appId|$boundAtMillis".toByteArray(Charsets.UTF_8)
        return MessageDigest.getInstance("SHA-256").digest(payload)
            .joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }
    }

    fun digestHex(claim: Claim): String = digestHex(appId = claim.appId, boundAtMillis = claim.boundAtMillis)

    /**
     * Parse the binding claim from ID-token claims. Mirrors the Swift parser:
     * absent/blank `appId` or a non-numeric `boundAtMillis` ⇒ null (no claim).
     */
    fun parseClaim(claims: Map<String, Any?>?): Claim? {
        val raw = claims?.get(CLAIM_KEY) as? Map<*, *> ?: return null
        val appId = (raw["appId"] as? String)?.takeIf { it.isNotEmpty() } ?: return null
        val boundAtMillis = (raw["boundAtMillis"] as? Number)?.toLong() ?: return null
        return Claim(appId = appId, boundAtMillis = boundAtMillis)
    }

    fun isFresh(claim: Claim, nowMillis: Long = System.currentTimeMillis()): Boolean = nowMillis - claim.boundAtMillis <= MAX_AGE_MILLIS

    private const val BYTE_MASK = 0xFF
}
