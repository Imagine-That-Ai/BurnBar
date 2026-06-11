package com.openburnbar.data.computeruse

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import kotlinx.coroutines.tasks.await

/**
 * F2 extra credit — Remote Config gate for the attestation-required ramp.
 * Android mirror of the Swift `PhoneControlAttestationPolicy`. Default-off
 * and fail-closed-to-false: until the ramp lands, Android NEVER blocks a
 * control action on a missing attestation digest (it only attaches one when
 * available).
 */
object PhoneControlAttestationPolicy {
    /** Same key the iOS client reads (`PhoneControlAttestationPolicy.remoteConfigKey`). */
    const val REMOTE_CONFIG_KEY = "computer_use_phone_control_attestation_required"

    fun attestationRequired(): Boolean =
        runCatching { FirebaseRemoteConfig.getInstance().getBoolean(REMOTE_CONFIG_KEY) }
            .getOrDefault(false)
}

/**
 * F2 extra credit — Android mirror of the iOS `MobileAppCheckAttestationReader`
 * (`OpenBurnBarMobile/Services/ComputerUse/MobileAppCheckAttestationReader.swift`).
 *
 * Reads the server-written `obb_app_check` binding claim from the Firebase
 * Auth ID token (the server binds it from the Play Integrity App Check token
 * whenever Android calls the `bindAppCheckAttestation` callable — which the
 * authority-publish flow already does), checks freshness, and derives the
 * same SHA-256 digest iOS and the Mac derive. The digest is attached as the
 * nullable `attestationHashBlake3` wire field; `null` keeps the envelope
 * byte-identical to the pre-F2 always-absent behavior.
 *
 * NON-ENFORCING by design: every failure path returns null — Android never
 * throws or blocks remote control on a missing attestation (the
 * `computer_use_phone_control_attestation_required` ramp stays default-off).
 */
object AndroidAppCheckAttestationReader {
    /**
     * Last digest produced by [currentAttestationDigestForEnvelope]. Kept so
     * synchronous envelope builders can attach the digest; every async read
     * refreshes it.
     */
    @Volatile
    private var cachedDigest: String? = null

    suspend fun currentAttestationDigestForEnvelope(): String? =
        runCatching {
            val user = FirebaseAuth.getInstance().currentUser ?: return null
            if (user.isAnonymous) return null
            val claims = user.getIdToken(false).await()?.claims ?: return null
            val claim = AppCheckAttestationBinding.parseClaim(claims) ?: return null
            if (!AppCheckAttestationBinding.isFresh(claim)) return null
            AppCheckAttestationBinding.digestHex(claim).also { cachedDigest = it }
        }.getOrNull()

    /**
     * Synchronous best-effort digest for envelope builders that cannot
     * suspend. `null` until an async read has run — identical wire shape to
     * the pre-F2 always-absent behavior.
     */
    fun cachedAttestationDigestForEnvelope(): String? = cachedDigest

    /**
     * Best-effort twin of the iOS `ensureAttestationIfRequired`: when the
     * (default-off) requirement ramp is on and no fresh claim exists, ask the
     * server to bind one and refresh the local claims. NEVER throws and NEVER
     * blocks the send path — Android attaches the digest opportunistically
     * until the ramp is enforced server/Mac-side.
     */
    suspend fun ensureAttestationBoundIfRequired(
        securityCallables: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
    ) {
        if (!PhoneControlAttestationPolicy.attestationRequired()) return
        if (currentAttestationDigestForEnvelope() != null) return
        runCatching { securityCallables.bindAppCheckAttestation() }
        runCatching { currentAttestationDigestForEnvelope() }
    }

    internal fun clearForTests() {
        cachedDigest = null
    }
}
