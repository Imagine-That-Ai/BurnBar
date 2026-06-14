package com.openburnbar.data.computeruse

private const val AUTHORITY_PUBLIC_KEY_BYTES = 32

internal object PhoneControlSignerAuthorityValidation {
    fun validateAuthorityState(
        publicKey: ByteArray,
        authority: PhoneControlAuthorityEnvelope,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long,
        observedHash: String,
    ): PhoneControlVerifyError? = validatePublicKeySize(publicKey)
        ?: validateTimestampFreshness(authority, nowMillis, freshnessMillis)
        ?: validateCounterMonotonic(authority, lastSeenCounter)
        ?: validateIntentHashMatch(observedHash, authority.intentHashBlake3)

    private fun validatePublicKeySize(publicKey: ByteArray): PhoneControlVerifyError? =
        if (publicKey.size != AUTHORITY_PUBLIC_KEY_BYTES) PhoneControlVerifyError.InvalidPublicKey else null

    private fun validateTimestampFreshness(authority: PhoneControlAuthorityEnvelope, nowMillis: Long, freshnessMillis: Long): PhoneControlVerifyError? {
        val skew = kotlin.math.abs(nowMillis - authority.timestampMillis)
        return if (skew > freshnessMillis) PhoneControlVerifyError.StaleTimestamp(skew) else null
    }

    private fun validateCounterMonotonic(authority: PhoneControlAuthorityEnvelope, lastSeenCounter: Long): PhoneControlVerifyError? =
        if (authority.counter <= lastSeenCounter) {
            PhoneControlVerifyError.CounterReplay(lastSeenCounter, authority.counter)
        } else {
            null
        }

    private fun validateIntentHashMatch(observedHash: String, intentHash: String): PhoneControlVerifyError? =
        if (observedHash != intentHash) PhoneControlVerifyError.IntentHashMismatch else null
}
