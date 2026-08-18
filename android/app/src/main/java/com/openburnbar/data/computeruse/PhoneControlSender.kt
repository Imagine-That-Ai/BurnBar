package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.data.policy.MobileComputerUseSafetyPolicy
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentContextTarget
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntent
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionRequest
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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
    /**
     * F2 extra credit — optional App Check attestation digest attached to
     * every signed authority envelope as the nullable wire field
     * `attestationHashBlake3` (mirrors the iOS
     * `MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()`
     * call in `PhoneControlSender.swift`). The default `null` keeps every
     * emitted byte identical to the pre-F2 always-absent behavior; the digest
     * is never enforced client-side. The canonical intent hash never covers
     * the authority envelope, so attaching post-sign is signature-safe.
     */
    private val attestationDigestProvider: suspend () -> String? = { null },
    /**
     * RR-7c — ENFORCING attestation gate for the control-action send path, the Android analogue of
     * iOS `PhoneControlSender.ensureAttestationIfRequired()`. When the (default-off) strict ramp is
     * on it returns the bound App Check digest (or throws [AttestationRequiredException] when none
     * can be produced) so Android STOPS being structurally attach-only — a digest-less control
     * envelope is never emitted under strict mode and the Mac validator's `requirePresent` gate has
     * something to enforce. The default no-op returns `null`, so when the ramp is off every emitted
     * byte is identical to the pre-RR-7c behavior (the best-effort [attestationDigestProvider] still
     * attaches a digest opportunistically). Wired in production to
     * `AndroidAppCheckAttestationReader.ensureAttestationDigestOrThrow()`.
     */
    private val attestationEnforcer: suspend () -> String? = { null },
    private val frameSink: suspend (HermesRealtimeRelayFrame) -> Unit,
) {
    sealed class SendError(message: String) : RuntimeException(message) {
        object SigningKeyMissing : SendError("phone-control signing key missing")
        object SafetyRejected : SendError("computer-use safety rejected send")
    }

    private suspend fun PhoneControlAuthorityEnvelope.withAttestationDigest(): PhoneControlAuthorityEnvelope {
        val digest = attestationDigestProvider()?.takeIf { it.isNotBlank() } ?: return this
        return copy(attestationHashBlake3 = digest)
    }

    /**
     * RR-7c — fail-closed attestation gate run BEFORE a control action is signed. When strict mode
     * is on this binds + returns the App Check digest (or throws [AttestationRequiredException]); the
     * returned digest is attached to the authority envelope so the strict-mode wire shape always
     * carries an enforceable digest. When the ramp is off it returns `null` and the caller's
     * best-effort [withAttestationDigest] keeps the pre-RR-7c behavior. Propagates
     * [AttestationRequiredException] so the send never emits a digest-less envelope under strict mode.
     */
    private suspend fun PhoneControlAuthorityEnvelope.withEnforcedAttestation(): PhoneControlAuthorityEnvelope {
        val enforced = attestationEnforcer()?.takeIf { it.isNotBlank() } ?: return withAttestationDigest()
        return copy(attestationHashBlake3 = enforced)
    }

    private fun requireSafety(intentKind: String) {
        // Rate limiter is the only locally observed bit. Grant/session/panic/
        // view-only remain Mac-authoritative (VAL-MOB-012).
        val allowed = MobileComputerUseSafetyPolicy.shouldSendPhoneControl(
            authenticated = true,
            grantExpired = false,
            bindingMatches = true,
            replayed = false,
            tampered = false,
            rateLimited = !PhoneControlSendRateLimiter.consume(),
            sessionExpired = false,
            panic = false,
            viewOnly = false,
            intentKind = intentKind,
        )
        if (!allowed) throw SendError.SafetyRejected
    }

    suspend fun send(intent: PhoneControlIntent): PhoneControlAuthorityEnvelope = PhoneControlSendSequencer.withPeer(peerNodeId) {
        requireSafety("tap")
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
            ).withEnforcedAttestation()
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
        return@withPeer authority
    }

    suspend fun send(agentGrant: AgentCapabilityGrantRequest): HermesRealtimeRelayAgentGrantRequest = PhoneControlSendSequencer.withPeer(peerNodeId) {
        requireSafety("grant")
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
            ).withEnforcedAttestation()
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
        return@withPeer signedWire
    }

    suspend fun send(
        approvalResponse: HermesRealtimeRelayApprovalResponse,
        approvalRequest: HermesRealtimeRelayApprovalRequest,
    ): HermesRealtimeRelayApprovalResponse = PhoneControlSendSequencer.withPeer(peerNodeId) {
        requireSafety("approval")
        val identity = signingIdentityProvider() ?: throw SendError.SigningKeyMissing
        val responseWithRequestHash =
            approvalResponse.copy(
                respondedBy = peerNodeId,
                requestHashBlake3 = PhoneControlSignerCanonical.approvalRequestHashHex(approvalRequest),
                authority = null,
            )
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority =
            PhoneControlSignerSign.signApprovalResponse(
                response = responseWithRequestHash,
                peerNodeId = peerNodeId,
                counter = counter,
                timestampMillis = timestampMillis,
                identity = identity,
            ).withEnforcedAttestation()
        val signedWire = responseWithRequestHash.copy(authority = authority.toRelayAuthority())
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
                uid = uid,
                connectionId = connectionId,
                requestId = signedWire.approvalId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_APPROVAL.raw,
                    sessionId = approvalRequest.sessionId,
                    approvalResponse = signedWire,
                ),
            )
        frameSink(frame)
        return@withPeer signedWire
    }

    suspend fun send(clipboardRequest: PhoneControlClipboardRequest): HermesRealtimeRelayClipboardRequest = PhoneControlSendSequencer.withPeer(peerNodeId) {
        requireSafety("clipboard")
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
            ).withEnforcedAttestation()
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
        return@withPeer signedWire
    }

    suspend fun send(remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope): HermesRealtimeRelayRemoteUnlockCredentialEnvelope =
        PhoneControlSendSequencer.withPeer(peerNodeId) {
            requireSafety("unlock")
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
                ).withEnforcedAttestation()
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
            return@withPeer signedWire
        }

    suspend fun send(agentContextTarget: PhoneControlAgentContextTarget): HermesRealtimeRelayAgentContextTarget =
        PhoneControlSendSequencer.withPeer(peerNodeId) {
            requireSafety("context-target")
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
                ).withEnforcedAttestation()
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
            return@withPeer signedWire
        }

    suspend fun send(systemPermissionRequest: PhoneControlSystemPermissionRequest): HermesRealtimeRelaySystemPermissionRequest =
        PhoneControlSendSequencer.withPeer(peerNodeId) {
            requireSafety("system-permission")
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
                ).withEnforcedAttestation()
            val signedWire =
                HermesRealtimeRelaySystemPermissionRequest(
                    requestId = request.requestId,
                    clientIntentId = request.clientIntentId.orEmpty(),
                    kind = request.kind.toRelayKind(),
                    bundleId = request.bundleId,
                    originatingToolCallId = request.originatingToolCallId,
                    originatingToolName = request.originatingToolName,
                    action = request.action.toRelayAction(),
                    // Wire form is the canonical Swift dateIso string. The signature above is
                    // computed over the reference-seconds NUMBER (PhoneControlSignerCanonicalJson
                    // hashes requestedAtSwiftReferenceSeconds, NOT this wire field); the Mac
                    // re-derives the same number from the decoded Date (its SignableSystemPermission
                    // hashes requestedAt: Date via JSONEncoder's default numeric strategy). So the
                    // wire string and the signed number stay in agreement for current-era timestamps.
                    requestedAt = PhoneControlSignerJsonEncoding.iso8601FromEpochMillis(request.requestedAtMillis),
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
            return@withPeer signedWire
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

    @Synchronized
    override fun nextCounter(peerNodeId: String): Long {
        val next = (counters[peerNodeId] ?: 0L) + 1L
        counters[peerNodeId] = next
        return next
    }
}

class SharedPreferencesPhoneControlCounterStore(
    context: android.content.Context,
    private val missingCounterBaseline: () -> Long = { System.currentTimeMillis() },
) : PhoneControlCounterStore {
    private val prefs =
        context.applicationContext
            .getSharedPreferences("computer_use_phone_control_counters", android.content.Context.MODE_PRIVATE)

    override fun nextCounter(peerNodeId: String): Long {
        require(peerNodeId.isNotBlank()) { "phone-control authority peer must not be blank" }
        return synchronized(processLock) {
            val key = "counter_$peerNodeId"
            val persisted = prefs.getLong(key, 0L)
            val current =
                if (persisted > 0L) {
                    persisted
                } else {
                    missingCounterBaseline().coerceAtLeast(0L)
                }
            check(current < Long.MAX_VALUE) {
                "phone-control counter exhausted"
            }
            val next = current + 1L
            check(prefs.edit().putLong(key, next).commit()) {
                "failed to durably persist phone-control counter"
            }
            next
        }
    }

    private companion object {
        private val processLock = Any()
    }
}

/** Serializes counter allocation through exact frame write across every sender instance. */
internal object PhoneControlSendSequencer {
    private val state = Any()
    private val peerMutexes = mutableMapOf<String, Mutex>()

    suspend fun <T> withPeer(peerNodeId: String, operation: suspend () -> T): T {
        require(peerNodeId.isNotBlank()) { "phone-control authority peer must not be blank" }
        val mutex = synchronized(state) { peerMutexes.getOrPut(peerNodeId) { Mutex() } }
        return mutex.withLock { operation() }
    }
}
