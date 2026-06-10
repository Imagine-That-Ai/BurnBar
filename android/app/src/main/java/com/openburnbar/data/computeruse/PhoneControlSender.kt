package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentContextTarget
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntent
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionRequest

class PhoneControlSender(
    private val uid: String,
    private val connectionId: String,
    private val peerNodeId: String,
    /**
     * F2 — the key-kind-aware signing identity (StrongBox/TEE P-256 when the
     * gate is on and the hardware exists, legacy software Ed25519 otherwise).
     * Mirrors the iOS `PhoneControlSender.signingIdentityProvider`; for
     * `Ed25519` every emitted byte is identical to the pre-F2 seed provider.
     */
    private val signingIdentityProvider: () -> PhoneControlSigningIdentity?,
    private val counterStore: PhoneControlCounterStore,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
    private val frameSink: suspend (HermesRealtimeRelayFrame) -> Unit,
) {
    sealed class SendError(message: String) : RuntimeException(message) {
        object SigningKeyMissing : SendError("phone-control signing key missing")
    }

    suspend fun send(intent: PhoneControlIntent): PhoneControlAuthorityEnvelope {
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val outboundIntent =
            if (intent.clientIntentId.isNullOrBlank()) {
                intent.copy(clientIntentId = java.util.UUID.randomUUID().toString())
            } else {
                intent
            }
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority =
            PhoneControlSignerSign.sign(
                intent = outboundIntent,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val relayAuthority = authority.toRelayAuthority()
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
                uid = uid,
                connectionId = connectionId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                    inputIntent = outboundIntent.toRelayIntent(relayAuthority),
                ),
            )
        frameSink(frame)
        return authority
    }

    suspend fun send(agentGrant: AgentCapabilityGrantRequest): HermesRealtimeRelayAgentGrantRequest {
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val placeholder =
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = "",
                counter = 0,
                timestamp = agentGrant.requestedAtSwiftReferenceSeconds,
                intentHashBlake3 = "",
                signatureEd25519 = "",
            )
        val unsignedWire = agentGrant.toWire(placeholder)
        val authority =
            PhoneControlSignerSign.signAgentGrantRequest(
                request = unsignedWire,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val signedGrant =
            if (agentGrant.localAuthenticationSatisfied) {
                agentGrant.copy(
                    localAuthProof =
                    PhoneControlSignerSign.signLocalAuthProof(
                        deviceId = agentGrant.sourceDeviceId,
                        signedIntentHash = authority.intentHashBlake3,
                        authenticatedAtMillis = timestampMillis,
                        expiresAtSwiftReferenceSeconds = agentGrant.expiresAtSwiftReferenceSeconds,
                        identity = identity,
                    ),
                )
            } else {
                agentGrant
            }
        val signedWire = signedGrant.toWire(authority.toRelayAuthority())
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_AGENT_GRANT_REQUEST,
                uid = uid,
                connectionId = connectionId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = "control.agent.grant",
                    agentGrantRequest = signedWire,
                ),
            )
        frameSink(frame)
        return signedWire
    }

    suspend fun send(clipboardRequest: PhoneControlClipboardRequest): HermesRealtimeRelayClipboardRequest {
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val request =
            if (clipboardRequest.clientIntentId.isNullOrBlank()) {
                clipboardRequest.copy(clientIntentId = java.util.UUID.randomUUID().toString())
            } else {
                clipboardRequest
            }
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority =
            PhoneControlSignerSign.signClipboardRequest(
                request = request,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val signedWire =
            HermesRealtimeRelayClipboardRequest(
                requestId = request.requestId,
                action = request.toRelayAction(),
                contentType = request.contentType,
                text = request.text,
                maxBytes = request.maxBytes,
                clientIntentId = request.clientIntentId.orEmpty(),
                authority = authority.toRelayAuthority(),
            )
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_CLIPBOARD_REQUEST,
                uid = uid,
                connectionId = connectionId,
                requestId = request.requestId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = "control.clipboard",
                    clipboardRequest = signedWire,
                ),
            )
        frameSink(frame)
        return signedWire
    }

    suspend fun send(remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope): HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val placeholder =
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = "",
                counter = 0,
                timestamp = 0.0,
                intentHashBlake3 = "",
                signatureEd25519 = "",
            )
        val unsignedCredential = remoteUnlockCredential.copy(authority = placeholder)
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority =
            PhoneControlSignerSign.signRemoteUnlockCredential(
                credential = unsignedCredential,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val signedWire = unsignedCredential.copy(authority = authority.toRelayAuthority())
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.REMOTE_UNLOCK_CREDENTIAL,
                uid = uid,
                connectionId = connectionId,
                requestId = signedWire.requestId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = "remote_unlock",
                    sessionId = signedWire.sessionId,
                    remoteUnlockCredential = signedWire,
                ),
            )
        frameSink(frame)
        return signedWire
    }

    suspend fun send(agentContextTarget: PhoneControlAgentContextTarget): HermesRealtimeRelayAgentContextTarget {
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val target =
            if (agentContextTarget.clientIntentId.isNullOrBlank()) {
                agentContextTarget.copy(clientIntentId = java.util.UUID.randomUUID().toString())
            } else {
                agentContextTarget
            }
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority =
            PhoneControlSignerSign.signAgentContextTarget(
                target = target,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val signedWire =
            HermesRealtimeRelayAgentContextTarget(
                requestId = target.requestId,
                sessionId = target.sessionId,
                runtime = target.runtime,
                threadId = target.threadId,
                displayId = target.displayId,
                normalizedX = target.normalizedX,
                normalizedY = target.normalizedY,
                normalizedRect = target.normalizedRect,
                instruction = target.instruction,
                focusContext = target.focusContext,
                clientIntentId = target.clientIntentId,
                requestedAt = target.requestedAt,
                authority = authority.toRelayAuthority(),
            )
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_AGENT_CONTEXT_TARGET,
                uid = uid,
                connectionId = connectionId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                    agentContextTarget = signedWire,
                ),
            )
        frameSink(frame)
        return signedWire
    }

    suspend fun send(systemPermissionRequest: PhoneControlSystemPermissionRequest): HermesRealtimeRelaySystemPermissionRequest {
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val request =
            if (systemPermissionRequest.clientIntentId.isNullOrBlank()) {
                systemPermissionRequest.copy(clientIntentId = java.util.UUID.randomUUID().toString())
            } else {
                systemPermissionRequest
            }
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority =
            PhoneControlSignerSign.signSystemPermissionRequest(
                request = request,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val signedWire =
            HermesRealtimeRelaySystemPermissionRequest(
                requestId = request.requestId,
                clientIntentId = request.clientIntentId.orEmpty(),
                kind = request.kind.toRelayKind(),
                bundleId = request.bundleId,
                originatingToolCallId = request.originatingToolCallId,
                originatingToolName = request.originatingToolName,
                action = request.action.toRelayAction(),
                requestedAt = request.requestedAtSwiftReferenceSeconds,
                authority = authority.toRelayAuthority(),
            )
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_SYSTEM_PERMISSION_REQUEST,
                uid = uid,
                connectionId = connectionId,
                requestId = request.requestId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = "control.system.permission",
                    systemPermissionRequest = signedWire,
                ),
            )
        frameSink(frame)
        return signedWire
    }

    private fun PhoneControlAuthorityEnvelope.toRelayAuthority(): HermesRealtimeRelayAuthorityEnvelope = HermesRealtimeRelayAuthorityEnvelope(
        peerNodeId = peerNodeId,
        counter = counter,
        timestamp = swiftDateReferenceSeconds,
        intentHashBlake3 = intentHashBlake3,
        signatureEd25519 = signatureEd25519,
        attestationHashBlake3 = attestationHashBlake3,
        keyKind = keyKind,
    )

    private fun PhoneControlIntent.toRelayIntent(authority: HermesRealtimeRelayAuthorityEnvelope): HermesRealtimeRelayInputIntent =
        HermesRealtimeRelayInputIntent(
            kind =
            when (kind) {
                PhoneControlIntentKind.TAP -> HermesRealtimeRelayInputIntentKind.TAP
                PhoneControlIntentKind.DRAG_START -> HermesRealtimeRelayInputIntentKind.DRAG_START
                PhoneControlIntentKind.DRAG_MOVE -> HermesRealtimeRelayInputIntentKind.DRAG_MOVE
                PhoneControlIntentKind.DRAG_END -> HermesRealtimeRelayInputIntentKind.DRAG_END
                PhoneControlIntentKind.TYPE -> HermesRealtimeRelayInputIntentKind.TYPE
                PhoneControlIntentKind.SHORTCUT -> HermesRealtimeRelayInputIntentKind.SHORTCUT
                PhoneControlIntentKind.SCROLL -> HermesRealtimeRelayInputIntentKind.SCROLL
                PhoneControlIntentKind.POINTER_MOVE -> HermesRealtimeRelayInputIntentKind.POINTER_MOVE
                PhoneControlIntentKind.POINTER_CLICK -> HermesRealtimeRelayInputIntentKind.POINTER_CLICK
                PhoneControlIntentKind.PANIC -> HermesRealtimeRelayInputIntentKind.PANIC
            },
            displayId = displayId,
            normalizedX = normalizedX,
            normalizedY = normalizedY,
            normalizedX2 = normalizedX2,
            normalizedY2 = normalizedY2,
            text = text,
            key = key,
            modifiers = modifiers,
            mouseButton = mouseButton,
            clientIntentId = clientIntentId,
            authority = authority,
        )
}

interface PhoneControlCounterStore {
    fun nextCounter(peerNodeId: String): Long
}

class InMemoryPhoneControlCounterStore(
    initialCounters: Map<String, Long> = emptyMap(),
) : PhoneControlCounterStore {
    private val counters = initialCounters.toMutableMap()

    override fun nextCounter(peerNodeId: String): Long {
        val next = (counters[peerNodeId] ?: 0L) + 1L
        counters[peerNodeId] = next
        return next
    }
}

class SharedPreferencesPhoneControlCounterStore(
    context: android.content.Context,
) : PhoneControlCounterStore {
    private val prefs =
        context.applicationContext
            .getSharedPreferences("computer_use_phone_control_counters", android.content.Context.MODE_PRIVATE)

    @Synchronized
    override fun nextCounter(peerNodeId: String): Long {
        val key = "counter_$peerNodeId"
        val next = (prefs.getLong(key, 0L) + 1L).coerceAtLeast(1L)
        prefs.edit().putLong(key, next).apply()
        return next
    }
}
