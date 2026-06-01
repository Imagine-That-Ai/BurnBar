package com.openburnbar.data.computeruse

object PhoneControlSignerVerify {
    fun verify(
        intent: PhoneControlIntent,
        authority: PhoneControlAuthorityEnvelope,
        publicKey: ByteArray,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long = 5_000L,
    ) {
        verifySignedAuthority(
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = lastSeenCounter,
            nowMillis = nowMillis,
            freshnessMillis = freshnessMillis,
            observedHash = PhoneControlSignerCanonical.intentHashHex(intent),
        )
    }

    fun verifyClipboardRequest(
        request: PhoneControlClipboardRequest,
        authority: PhoneControlAuthorityEnvelope,
        publicKey: ByteArray,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long = 5_000L,
    ) {
        verifySignedAuthority(
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = lastSeenCounter,
            nowMillis = nowMillis,
            freshnessMillis = freshnessMillis,
            observedHash = PhoneControlSignerCanonical.clipboardRequestHashHex(request),
        )
    }

    fun verifyAgentContextTarget(
        target: PhoneControlAgentContextTarget,
        authority: PhoneControlAuthorityEnvelope,
        publicKey: ByteArray,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long = 5_000L,
    ) {
        verifySignedAuthority(
            authority = authority,
            publicKey = publicKey,
            lastSeenCounter = lastSeenCounter,
            nowMillis = nowMillis,
            freshnessMillis = freshnessMillis,
            observedHash = PhoneControlSignerCanonical.agentContextTargetHashHex(target),
        )
    }

    fun verifySignedAuthority(
        authority: PhoneControlAuthorityEnvelope,
        publicKey: ByteArray,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long,
        observedHash: String,
    ) {
        validateSignedAuthority(authority, publicKey, lastSeenCounter, nowMillis, freshnessMillis, observedHash)
            ?.let { throw it }
    }

    private fun validateSignedAuthority(
        authority: PhoneControlAuthorityEnvelope,
        publicKey: ByteArray,
        lastSeenCounter: Long,
        nowMillis: Long,
        freshnessMillis: Long,
        observedHash: String,
    ): PhoneControlVerifyError? =
        when {
            publicKey.size != VAL_32 -> PhoneControlVerifyError.InvalidPublicKey
            kotlin.math.abs(nowMillis - authority.timestampMillis) > freshnessMillis ->
                PhoneControlVerifyError.StaleTimestamp(kotlin.math.abs(nowMillis - authority.timestampMillis))
            authority.counter <= lastSeenCounter ->
                PhoneControlVerifyError.CounterReplay(lastSeenCounter, authority.counter)
            observedHash != authority.intentHashBlake3 -> PhoneControlVerifyError.IntentHashMismatch
            else -> validateAuthoritySignatureOrError(publicKey, authority)
        }

    private fun validateAuthoritySignatureOrError(
        publicKey: ByteArray,
        authority: PhoneControlAuthorityEnvelope,
    ): PhoneControlVerifyError? {
        val signature = decodeAuthoritySignature(authority.signatureEd25519) ?: return PhoneControlVerifyError.InvalidSignature
        val payload =
            PhoneControlSignerPayload.signablePayload(
                intentHashHex = authority.intentHashBlake3,
                counter = authority.counter,
                timestampMillis = authority.timestampMillis,
            )
        return if (verifyAuthoritySignature(publicKey, signature, payload)) {
            null
        } else {
            PhoneControlVerifyError.InvalidSignature
        }
    }

    private fun decodeAuthoritySignature(encoded: String): ByteArray? =
        runCatching { java.util.Base64.getDecoder().decode(encoded) }.getOrNull()

    private fun verifyAuthoritySignature(publicKey: ByteArray, signature: ByteArray, payload: ByteArray): Boolean =
        runCatching {
            com.google.crypto.tink.subtle.Ed25519Verify(publicKey).verify(signature, payload)
            true
        }.getOrDefault(false)
}

private const val VAL_32 = 32
