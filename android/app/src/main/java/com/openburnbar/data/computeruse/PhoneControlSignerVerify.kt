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
    ): PhoneControlVerifyError? {
        // F2 — an absent keyKind resolves to legacy Ed25519; an unknown wire
        // value fails closed before any state is consumed.
        val keyKind =
            PhoneControlSigningKeyKind.fromWire(authority.keyKind)
                ?: return PhoneControlVerifyError.InvalidSignature
        return when {
            !isValidPublicKeySize(publicKey, keyKind) -> PhoneControlVerifyError.InvalidPublicKey
            kotlin.math.abs(nowMillis - authority.timestampMillis) > freshnessMillis ->
                PhoneControlVerifyError.StaleTimestamp(kotlin.math.abs(nowMillis - authority.timestampMillis))
            authority.counter <= lastSeenCounter ->
                PhoneControlVerifyError.CounterReplay(lastSeenCounter, authority.counter)
            observedHash != authority.intentHashBlake3 -> PhoneControlVerifyError.IntentHashMismatch
            else -> validateAuthoritySignatureOrError(publicKey, authority, keyKind)
        }
    }

    /**
     * The published controller key bytes: 32-byte raw for Ed25519, 65-byte
     * X9.63 (`0x04‖X‖Y`) or compact 64-byte raw (`X‖Y`) for SE-P256 —
     * mirroring the Swift `PhoneControlVerifyingKey` normalization.
     */
    private fun isValidPublicKeySize(publicKey: ByteArray, keyKind: PhoneControlSigningKeyKind): Boolean = when (keyKind) {
        PhoneControlSigningKeyKind.ED25519 -> publicKey.size == ED25519_PUBLIC_KEY_BYTES
        PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256 -> publicKey.size == P256_X963_PUBLIC_KEY_BYTES || publicKey.size == P256_RAW_XY_PUBLIC_KEY_BYTES
    }

    private fun validateAuthoritySignatureOrError(
        publicKey: ByteArray,
        authority: PhoneControlAuthorityEnvelope,
        keyKind: PhoneControlSigningKeyKind,
    ): PhoneControlVerifyError? {
        val signature = decodeAuthoritySignature(authority.signatureEd25519) ?: return PhoneControlVerifyError.InvalidSignature
        val payload =
            PhoneControlSignerPayload.signablePayload(
                intentHashHex = authority.intentHashBlake3,
                counter = authority.counter,
                timestampMillis = authority.timestampMillis,
            )
        return if (verifyAuthoritySignature(publicKey, signature, payload, keyKind)) {
            null
        } else {
            PhoneControlVerifyError.InvalidSignature
        }
    }

    private fun decodeAuthoritySignature(encoded: String): ByteArray? = runCatching { java.util.Base64.getDecoder().decode(encoded) }.getOrNull()

    private fun verifyAuthoritySignature(publicKey: ByteArray, signature: ByteArray, payload: ByteArray, keyKind: PhoneControlSigningKeyKind): Boolean =
        when (keyKind) {
            PhoneControlSigningKeyKind.ED25519 ->
                runCatching {
                    com.google.crypto.tink.subtle.Ed25519Verify(publicKey).verify(signature, payload)
                    true
                }.getOrDefault(false)
            PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256 -> {
                // F2 — raw `r‖s` 64-byte ECDSA-over-SHA256 (Swift
                // `ECDSASignature.rawRepresentation`, Node `'ieee-p1363'`).
                val key = PhoneControlP256.publicKeyFromRepresentation(publicKey)
                key != null && PhoneControlP256.verifySignature(key, signature, payload)
            }
        }
}

private const val ED25519_PUBLIC_KEY_BYTES = 32
private const val P256_RAW_XY_PUBLIC_KEY_BYTES = 64
private const val P256_X963_PUBLIC_KEY_BYTES = 65
