package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Sign
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession
import java.util.Base64

private const val VAL_32 = 32

object PhoneControlSignerSign {
    fun sign(
        intent: PhoneControlIntent,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.intentHashHex(intent),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    fun signAgentGrantRequest(
        request: HermesRealtimeRelayAgentGrantRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.agentGrantRequestHashHex(request),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    fun signClipboardRequest(
        request: PhoneControlClipboardRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.clipboardRequestHashHex(request),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    fun signRemoteUnlockSession(
        session: HermesRealtimeRelayRemoteUnlockSession,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.remoteUnlockSessionHashHex(session),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    fun signRemoteUnlockCredential(
        credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.remoteUnlockCredentialHashHex(credential),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    fun signAgentContextTarget(
        target: PhoneControlAgentContextTarget,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.agentContextTargetHashHex(target),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    fun signSystemPermissionRequest(
        request: PhoneControlSystemPermissionRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.systemPermissionRequestHashHex(request),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )

    private fun signPayload(
        payloadHash: String,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        require(privateKeySeed.size == VAL_32) { "Ed25519 private key seed must be 32 bytes" }
        val payload = PhoneControlSignerPayload.signablePayload(payloadHash, counter, timestampMillis)
        val signature = Ed25519Sign(privateKeySeed).sign(payload)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = payloadHash,
            signatureEd25519 = Base64.getEncoder().encodeToString(signature),
        )
    }
}
