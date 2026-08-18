package com.openburnbar.data.policy

enum class MobileEscrowImportFailure(val wire: String, val userVisibleLabel: String) {
    WRONG_DEVICE("wrong-device", "This envelope is for a different device"),
    EXPIRED_GRANT("expired-grant", "The transfer grant has expired"),
    REVOKED_GRANT("revoked-grant", "The transfer grant was revoked"),
    MISSING_KEY("missing-key", "This device is missing the escrow key"),
    MALFORMED_ENVELOPE("malformed-envelope", "The envelope is malformed"),
}

object MobileEscrowEnvelopePolicy {
    fun classify(
        targetDeviceId: String?,
        currentDeviceId: String?,
        grantStatus: String?,
        grantExpiresAtMs: Long?,
        nowMs: Long,
        hasPrivateKey: Boolean,
        envelopeWellFormed: Boolean,
    ): MobileEscrowImportFailure? {
        if (!envelopeWellFormed) return MobileEscrowImportFailure.MALFORMED_ENVELOPE
        if (!hasPrivateKey) return MobileEscrowImportFailure.MISSING_KEY
        val target = targetDeviceId?.trim().orEmpty()
        val current = currentDeviceId?.trim().orEmpty()
        if (target.isEmpty() || current.isEmpty() || target != current) {
            return MobileEscrowImportFailure.WRONG_DEVICE
        }
        if ((grantStatus ?: "").lowercase() == "revoked") return MobileEscrowImportFailure.REVOKED_GRANT
        val expiry = grantExpiresAtMs
        if (expiry == null || expiry <= 0L || expiry <= nowMs) {
            return MobileEscrowImportFailure.EXPIRED_GRANT
        }
        return null
    }
}
