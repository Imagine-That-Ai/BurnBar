package com.openburnbar.data.cloud

import com.openburnbar.data.policy.MobileEscrowEnvelopePolicy
import com.openburnbar.data.policy.MobileEscrowImportFailure

/** Production gate for escrow envelope import. Missing grant expiry is expired. */
object AndroidEscrowEnvelopeImport {
    const val MIN_ENVELOPE_VERSION = 2

    fun wellFormed(ciphertextBase64: String?, grantId: String?, envelopeVersion: Int?): Boolean {
        val ciphertext = ciphertextBase64?.trim().orEmpty()
        if (ciphertext.isEmpty()) return false
        if (grantId?.trim().isNullOrEmpty()) return false
        return (envelopeVersion ?: 0) >= MIN_ENVELOPE_VERSION
    }

    fun rejectIfUnimportable(
        targetDeviceId: String?,
        currentDeviceId: String?,
        grantStatus: String?,
        grantExpiresAtMs: Long?,
        nowMs: Long,
        hasPrivateKey: Boolean,
        ciphertextBase64: String?,
        grantId: String?,
        envelopeVersion: Int?,
    ): MobileEscrowImportFailure? = MobileEscrowEnvelopePolicy.classify(
        targetDeviceId = targetDeviceId,
        currentDeviceId = currentDeviceId,
        grantStatus = grantStatus,
        grantExpiresAtMs = grantExpiresAtMs,
        nowMs = nowMs,
        hasPrivateKey = hasPrivateKey,
        envelopeWellFormed = wellFormed(ciphertextBase64, grantId, envelopeVersion),
    )
}
