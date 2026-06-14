package com.openburnbar.data.computeruse

import java.nio.ByteBuffer
import java.nio.ByteOrder

private const val COUNTER_AND_TIMESTAMP_BYTES = 16

internal object PhoneControlSignerPayload {
    fun signablePayload(intentHashHex: String, counter: Long, timestampMillis: Long): ByteArray {
        require(counter >= 0) { "counter must be non-negative" }
        val hashBytes = intentHashHex.toByteArray(Charsets.UTF_8)
        val suffix =
            ByteBuffer.allocate(COUNTER_AND_TIMESTAMP_BYTES)
                .order(ByteOrder.BIG_ENDIAN)
                .putLong(counter)
                .putLong(timestampMillis)
                .array()
        return hashBytes + suffix
    }

    fun localAuthProofPayload(
        proofId: String,
        deviceId: String,
        signedIntentHash: String,
        authenticatedAtSwiftReferenceSeconds: Double,
        expiresAtSwiftReferenceSeconds: Double,
    ): ByteArray = listOf(
        "OpenBurnBar.AgentGrantLocalAuthProof.v1",
        proofId,
        deviceId,
        signedIntentHash.lowercase(),
        PhoneControlSignerJsonEncoding.number(authenticatedAtSwiftReferenceSeconds),
        PhoneControlSignerJsonEncoding.number(expiresAtSwiftReferenceSeconds),
    ).joinToString(separator = "\n").toByteArray(Charsets.UTF_8)
}
