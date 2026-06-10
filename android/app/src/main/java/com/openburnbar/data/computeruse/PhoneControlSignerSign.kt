package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantLocalAuthProof
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession
import java.util.UUID

object PhoneControlSignerSign {
    fun sign(
        intent: PhoneControlIntent,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        sign(intent, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun sign(
        intent: PhoneControlIntent,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.intentHashHex(intent),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    fun signAgentGrantRequest(
        request: HermesRealtimeRelayAgentGrantRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signAgentGrantRequest(request, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun signAgentGrantRequest(
        request: HermesRealtimeRelayAgentGrantRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.agentGrantRequestHashHex(request),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    fun signLocalAuthProof(
        deviceId: String,
        signedIntentHash: String,
        authenticatedAtMillis: Long,
        expiresAtSwiftReferenceSeconds: Double,
        privateKeySeed: ByteArray,
        proofId: String = UUID.randomUUID().toString(),
    ): HermesRealtimeRelayAgentGrantLocalAuthProof =
        signLocalAuthProof(
            deviceId = deviceId,
            signedIntentHash = signedIntentHash,
            authenticatedAtMillis = authenticatedAtMillis,
            expiresAtSwiftReferenceSeconds = expiresAtSwiftReferenceSeconds,
            identity = PhoneControlSigningIdentity.Ed25519(privateKeySeed),
            proofId = proofId,
        )

    /**
     * F2 key-kind-aware twin of `signLocalAuthProof(...privateKeySeed:)`. The
     * `signatureEd25519` field is the signature carrier regardless of
     * algorithm (same convention as the authority envelope).
     */
    fun signLocalAuthProof(
        deviceId: String,
        signedIntentHash: String,
        authenticatedAtMillis: Long,
        expiresAtSwiftReferenceSeconds: Double,
        identity: PhoneControlSigningIdentity,
        proofId: String = UUID.randomUUID().toString(),
    ): HermesRealtimeRelayAgentGrantLocalAuthProof {
        val authenticatedAtSwiftReferenceSeconds =
            AgentCapabilityGrantRequest.swiftReferenceSeconds(authenticatedAtMillis)
        val payload =
            PhoneControlSignerPayload.localAuthProofPayload(
                proofId = proofId,
                deviceId = deviceId,
                signedIntentHash = signedIntentHash,
                authenticatedAtSwiftReferenceSeconds = authenticatedAtSwiftReferenceSeconds,
                expiresAtSwiftReferenceSeconds = expiresAtSwiftReferenceSeconds,
            )
        return HermesRealtimeRelayAgentGrantLocalAuthProof(
            proofId = proofId,
            deviceId = deviceId,
            signedIntentHash = signedIntentHash.lowercase(),
            authenticatedAt = authenticatedAtSwiftReferenceSeconds,
            expiresAt = expiresAtSwiftReferenceSeconds,
            signatureEd25519 = identity.signatureBase64(payload),
        )
    }

    fun signClipboardRequest(
        request: PhoneControlClipboardRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signClipboardRequest(request, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun signClipboardRequest(
        request: PhoneControlClipboardRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.clipboardRequestHashHex(request),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    fun signRemoteUnlockSession(
        session: HermesRealtimeRelayRemoteUnlockSession,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signRemoteUnlockSession(session, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun signRemoteUnlockSession(
        session: HermesRealtimeRelayRemoteUnlockSession,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.remoteUnlockSessionHashHex(session),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    fun signRemoteUnlockCredential(
        credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signRemoteUnlockCredential(credential, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun signRemoteUnlockCredential(
        credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.remoteUnlockCredentialHashHex(credential),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    fun signAgentContextTarget(
        target: PhoneControlAgentContextTarget,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signAgentContextTarget(target, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun signAgentContextTarget(
        target: PhoneControlAgentContextTarget,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.agentContextTargetHashHex(target),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    fun signSystemPermissionRequest(
        request: PhoneControlSystemPermissionRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        privateKeySeed: ByteArray,
    ): PhoneControlAuthorityEnvelope =
        signSystemPermissionRequest(request, peerNodeId, counter, timestampMillis, PhoneControlSigningIdentity.Ed25519(privateKeySeed))

    fun signSystemPermissionRequest(
        request: PhoneControlSystemPermissionRequest,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope =
        signPayload(
            payloadHash = PhoneControlSignerCanonical.systemPermissionRequestHashHex(request),
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            identity = identity,
        )

    /**
     * F2 — every envelope-producing path signs through the key-kind-aware
     * identity. For `Ed25519` the result is byte-identical to the pre-F2
     * seed-based path (`keyKind` stays `null` and Ed25519 signing is
     * deterministic, RFC 8032); for `SecureEnclaveP256` the
     * `signatureEd25519` field carries the raw `r‖s` ECDSA signature and
     * `keyKind` carries `"se-p256"`.
     */
    private fun signPayload(
        payloadHash: String,
        peerNodeId: String,
        counter: Long,
        timestampMillis: Long,
        identity: PhoneControlSigningIdentity,
    ): PhoneControlAuthorityEnvelope {
        require(counter >= 0) { "counter must be non-negative" }
        val payload = PhoneControlSignerPayload.signablePayload(payloadHash, counter, timestampMillis)
        return PhoneControlAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            intentHashBlake3 = payloadHash,
            signatureEd25519 = identity.signatureBase64(payload),
            keyKind = identity.wireKeyKind,
        )
    }
}
