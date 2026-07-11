package com.openburnbar.data.computeruse

import android.content.Context
import androidx.fragment.app.FragmentActivity
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayComputerUseSessionGrantChallenge
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionRequest
import com.openburnbar.security.BiometricCryptoAuth
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class AgentCapabilityGrantController(
    context: Context,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val counterStore: PhoneControlCounterStore = SharedPreferencesPhoneControlCounterStore(context),
    private val trustRegistrar: AgentCapabilityGrantTrustRegistrar = FirebaseAgentCapabilityGrantTrustRegistrar(),
    signingKeysOverride: AgentCapabilityGrantSigningKeys? = null,
    private val authorityPublisher: AgentCapabilityGrantAuthorityPublishing =
        FirebaseAgentCapabilityGrantAuthorityPublishing(firestore),
    private val grantQueue: AgentCapabilityGrantQueueing = FirebaseAgentCapabilityGrantQueueing(),
) {
    private val appContext = context.applicationContext
    private val keyStore = PhoneControlSigningKeyStore(appContext)
    private val signingKeys = signingKeysOverride ?: PhoneControlSigningKeyStoreAdapter(keyStore)
    private val senderMutex = Mutex()
    private var phoneControlSender: PhoneControlSender? = null
    private var phoneControlConnectionID: String? = null
    private var phoneControlSenderSealed: Boolean = false

    sealed class GrantError(message: String) : RuntimeException(message) {
        object NotSignedIn : GrantError("Sign in before granting desktop permissions.")

        object LocalAuthenticationFailed : GrantError("Device authentication did not complete.")

        object NoPairedMac : GrantError("No paired Mac is reachable. The request was queued instead.")

        object DeviceNotTrusted : GrantError("Approve this Android in Devices & Sync before granting Mac control.")
    }

    suspend fun grant(
        activity: FragmentActivity,
        runtime: String,
        threadId: String,
        preset: AgentPermissionPreset,
        deliveryMode: AgentGrantDeliveryMode = AgentGrantDeliveryMode.LIVE_THEN_QUEUED,
    ): AgentCapabilityGrantReceipt {
        val uid = auth.currentUser?.uid ?: throw GrantError.NotSignedIn
        val sourceDeviceId = trustedSourceDeviceId(uid)
        val authenticated = authenticateIfNeeded(activity, preset)
        val request =
            AgentCapabilityGrantRequest(
                runtime = runtime,
                threadId = threadId,
                preset = preset,
                deliveryMode = deliveryMode,
                sourceDeviceId = sourceDeviceId,
                localAuthenticationSatisfied = authenticated,
            )

        return deliver(uid = uid, sourceDeviceId = sourceDeviceId, request = request)
    }

    /** Issues a grant bound to one exact, validated Linux session challenge. */
    suspend fun grant(
        activity: FragmentActivity,
        sessionChallenge: HermesRealtimeRelayComputerUseSessionGrantChallenge,
    ): AgentCapabilityGrantReceipt {
        val uid = auth.currentUser?.uid ?: throw GrantError.NotSignedIn
        ComputerUseSessionGrantChallengeValidator.validate(sessionChallenge)
        val sourceDeviceId = trustedSourceDeviceId(uid)
        var request =
            AgentCapabilityGrantRequest.fromValidatedSessionChallenge(
                challenge = sessionChallenge,
                sourceDeviceId = sourceDeviceId,
            )
        request = request.copy(localAuthenticationSatisfied = authenticateIfNeeded(activity, request.preset))
        return deliver(uid = uid, sourceDeviceId = sourceDeviceId, request = request)
    }

    private suspend fun deliver(
        uid: String,
        sourceDeviceId: String,
        request: AgentCapabilityGrantRequest,
    ): AgentCapabilityGrantReceipt {
        if (request.deliveryMode != AgentGrantDeliveryMode.QUEUED) {
            sendLive(uid = uid, sourceDeviceId = sourceDeviceId, request = request, deliveryMode = request.deliveryMode)
                ?.let { return it }
        }

        queue(uid = uid, request = request)
        return remember(request.pendingReceipt("Mac was unreachable, so this was queued for 5 minutes."))
    }

    /**
     * Attempt the live phone-control send. Returns the receipt on success,
     * null when the failure should fall back to the queue, and rethrows when
     * the caller demanded live-only delivery.
     */
    private suspend fun sendLive(
        uid: String,
        sourceDeviceId: String,
        request: AgentCapabilityGrantRequest,
        deliveryMode: AgentGrantDeliveryMode,
    ): AgentCapabilityGrantReceipt? {
        return try {
            val sender = ensurePhoneControlSender(uid = uid, sourceDeviceId = sourceDeviceId)
            sender.send(agentGrant = request)
            remember(request.pendingReceipt("Sent to your Mac."))
        } catch (error: FirebaseException) {
            if (deliveryMode == AgentGrantDeliveryMode.LIVE) throw error
            null
        } catch (error: GrantError.NoPairedMac) {
            if (deliveryMode == AgentGrantDeliveryMode.LIVE) throw error
            null
        }
    }

    suspend fun sendSystemPermissionRequest(request: PhoneControlSystemPermissionRequest): HermesRealtimeRelaySystemPermissionRequest {
        val uid = auth.currentUser?.uid ?: throw GrantError.NotSignedIn
        val sourceDeviceId = trustedSourceDeviceId(uid)
        val sender = ensurePhoneControlSender(uid = uid, sourceDeviceId = sourceDeviceId)
        return sender.send(systemPermissionRequest = request)
    }

    private suspend fun trustedSourceDeviceId(uid: String): String {
        return trustRegistrar.trustedSourceDeviceId(uid)
    }

    private suspend fun authenticateIfNeeded(activity: FragmentActivity, preset: AgentPermissionPreset): Boolean {
        if (!preset.requiresDeviceAuth) return false
        runCatching {
            BiometricCryptoAuth.requireStrongBiometric(
                activity = activity,
                title = "Allow ${preset.title} desktop permissions",
                subtitle = "This grant applies only to this agent thread.",
                failureMessage = GrantError.LocalAuthenticationFailed.message.orEmpty(),
            )
        }.getOrElse {
            throw GrantError.LocalAuthenticationFailed
        }
        return true
    }

    private suspend fun ensurePhoneControlSender(uid: String, sourceDeviceId: String): PhoneControlSender = senderMutex.withLock {
        val coordinator =
            BurnBarApplication.mediaControlCoordinator
                ?: throw GrantError.NoPairedMac
        val pair = coordinator.activePair.value ?: throw GrantError.NoPairedMac
        // F2: resolve the signing identity once so the published authority key
        // and every envelope this sender signs stay the same key.
        val identity = signingKeys.signingIdentity()
        val peerNodeId = signingKeys.peerNodeId(identity)

        phoneControlSender
            ?.takeIf { phoneControlConnectionID == pair.connectionID }
            ?.let { sender ->
                val sealSession = establishControlSealAndClassify(coordinator, pair, peerNodeId)
                if (phoneControlSenderSealed == (sealSession != null)) {
                    return@withLock sender
                }
            }

        val authority =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = pair.connectionID,
                deviceId = sourceDeviceId,
                identity = identity,
                publishedAtMillis = System.currentTimeMillis(),
            )
        authorityPublisher.publish(uid = pair.uid, authority = authority)
        authorityPublisher.publishAgentGrantAuthority(
            uid = uid,
            sourceDeviceId = sourceDeviceId,
            authority = authority,
        )
        val sealSession = establishControlSealAndClassify(coordinator, pair, peerNodeId)
        val baseSink: suspend (HermesRealtimeRelayFrame) -> Unit = { frame -> coordinator.send(frame) }

        PhoneControlSender(
            uid = pair.uid,
            connectionId = pair.connectionID,
            peerNodeId = peerNodeId,
            signingIdentityProvider = { identity },
            counterStore = counterStore,
            attestationDigestProvider = { AndroidAppCheckAttestationReader.currentAttestationDigestForEnvelope() },
            // RR-7c: fail-closed attestation gate under the strict ramp (the agent-grant path enforces, mirror iOS).
            attestationEnforcer = { AndroidAppCheckAttestationReader.ensureAttestationDigestOrThrow() },
            frameSink = sealSession
                ?.let { ControlSealSessionEstablisher.sealingFrameSink(baseSink, it) }
                ?: baseSink,
        ).also {
            phoneControlSender = it
            phoneControlConnectionID = pair.connectionID
            phoneControlSenderSealed = sealSession != null
        }
    }

    private suspend fun establishControlSealAndClassify(
        coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
        pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
        peerNodeId: String,
    ): ControlSealSessionEstablisher.Session? {
        AndroidAppCheckAttestationReader.ensureAttestationBoundIfRequired()
        val sealSession =
            ControlSealSessionEstablisher.establishIfNegotiated(
                uid = pair.uid,
                connectionId = pair.connectionID,
                controllerPeerNodeId = peerNodeId,
                macCapabilities = coordinator.lastPeerCapabilities.value,
            )
        sendPhoneControlClassify(coordinator, pair, peerNodeId, sealSession?.envelope)
        if (sealSession != null) {
            ControlSealSessionEstablisher.register(sealSession, pair.connectionID)
        } else {
            ControlSealSessionEstablisher.unregister(pair.connectionID)
        }
        return sealSession
    }

    private suspend fun sendPhoneControlClassify(
        coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
        pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
        peerNodeId: String,
        controlSealKey: HermesRealtimeRelayControlSealKeyEnvelope? = null,
    ) {
        coordinator.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
                uid = pair.uid,
                connectionId = pair.connectionID,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                    authorityPeerNodeId = peerNodeId,
                    controlSealKey = controlSealKey,
                ),
            ),
        )
    }

    private suspend fun queue(uid: String, request: AgentCapabilityGrantRequest) {
        // F2: one identity resolution covers the published authority key and
        // the queued request's signature.
        val identity = signingKeys.signingIdentity()
        val signedWire = signedWireRequest(request, identity)
        val authority =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = phoneControlConnectionID ?: "agent-grant-queued",
                deviceId = request.sourceDeviceId,
                identity = identity,
                publishedAtMillis = System.currentTimeMillis(),
            )
        authorityPublisher.publishAgentGrantAuthority(
            uid = uid,
            sourceDeviceId = request.sourceDeviceId,
            authority = authority,
        )
        grantQueue.queueAgentCapabilityGrantRequest(wireRequestMap(signedWire))
    }

    private fun signedWireRequest(
        request: AgentCapabilityGrantRequest,
        identity: PhoneControlSigningIdentity,
    ): com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest {
        val peerNodeId = signingKeys.peerNodeId(identity)
        val placeholder =
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = "",
                counter = 0,
                timestamp = request.requestedAtSwiftReferenceSeconds,
                intentHashBlake3 = "",
                signatureEd25519 = "",
            )
        val unsignedWire = request.toWire(placeholder)
        val timestampMillis = System.currentTimeMillis()
        val authority =
            PhoneControlSignerSign.signAgentGrantRequest(
                request = unsignedWire,
                peerNodeId = peerNodeId,
                counter = counterStore.nextCounter(peerNodeId),
                timestampMillis = timestampMillis,
                identity = identity,
            )
        val signedRequest =
            if (request.localAuthenticationSatisfied) {
                request.copy(
                    localAuthProof =
                    PhoneControlSignerSign.signLocalAuthProof(
                        deviceId = request.sourceDeviceId,
                        signedIntentHash = authority.intentHashBlake3,
                        authenticatedAtMillis = timestampMillis,
                        expiresAtSwiftReferenceSeconds = request.expiresAtSwiftReferenceSeconds,
                        identity = identity,
                    ),
                )
            } else {
                request
            }
        return signedRequest.toWire(
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = authority.peerNodeId,
                counter = authority.counter,
                timestamp = authority.swiftDateReferenceSeconds,
                intentHashBlake3 = authority.intentHashBlake3,
                signatureEd25519 = authority.signatureEd25519,
                keyKind = authority.keyKind,
            ),
        )
    }

    private fun wireRequestMap(wire: com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest): Map<String, Any> = buildMap {
        put("requestId", wire.requestId)
        put("runtime", wire.runtime)
        put("threadId", wire.threadId)
        put("preset", wire.preset)
        put("capabilities", wire.capabilities)
        put("trustMode", wire.trustMode)
        put("deliveryMode", wire.deliveryMode)
        put("requestedAt", wire.requestedAt)
        put("expiresAt", wire.expiresAt)
        put("grantDurationSeconds", wire.grantDurationSeconds)
        put("sourceDeviceId", wire.sourceDeviceId)
        put("clientIntentId", wire.clientIntentId)
        put("localAuthenticationSatisfied", wire.localAuthenticationSatisfied)
        wire.localAuthProof?.let { proof ->
            put(
                "localAuthProof",
                mapOf(
                    "proofId" to proof.proofId,
                    "deviceId" to proof.deviceId,
                    "signedIntentHash" to proof.signedIntentHash,
                    "authenticatedAt" to proof.authenticatedAt,
                    "expiresAt" to proof.expiresAt,
                    "signatureEd25519" to proof.signatureEd25519,
                ),
            )
        }
        put(
            "authority",
            buildMap {
                put("peerNodeId", wire.authority.peerNodeId)
                put("counter", wire.authority.counter)
                put("timestamp", wire.authority.timestamp)
                put("intentHashBlake3", wire.authority.intentHashBlake3)
                put("signatureEd25519", wire.authority.signatureEd25519)
                // F2: omitted for legacy Ed25519 — pre-F2 payloads stay byte-identical.
                wire.authority.keyKind?.let { put("keyKind", it) }
            },
        )
    }

    private fun remember(receipt: AgentCapabilityGrantReceipt): AgentCapabilityGrantReceipt {
        AgentCapabilityGrantState.apply(receipt)
        return receipt
    }
}

interface AgentCapabilityGrantTrustRegistrar {
    suspend fun trustedSourceDeviceId(uid: String): String
}

private class FirebaseAgentCapabilityGrantTrustRegistrar : AgentCapabilityGrantTrustRegistrar {
    override suspend fun trustedSourceDeviceId(uid: String): String {
        val device = AndroidEscrowDeviceRegistry().registerSelf(uid = uid)
        if (device.trustState != AndroidEscrowDeviceRegistry.TRUSTED) {
            throw AgentCapabilityGrantController.GrantError.DeviceNotTrusted
        }
        return device.deviceId
    }
}

interface AgentCapabilityGrantSigningKeys {
    fun signingIdentity(): PhoneControlSigningIdentity
    fun peerNodeId(identity: PhoneControlSigningIdentity): String
}

private class PhoneControlSigningKeyStoreAdapter(
    private val keyStore: PhoneControlSigningKeyStore,
) : AgentCapabilityGrantSigningKeys {
    override fun signingIdentity(): PhoneControlSigningIdentity = keyStore.signingIdentity()

    override fun peerNodeId(identity: PhoneControlSigningIdentity): String = keyStore.peerNodeId(identity)
}

interface AgentCapabilityGrantAuthorityPublishing {
    suspend fun publish(uid: String, authority: PhoneControlAuthorityDoc)
    suspend fun publishAgentGrantAuthority(uid: String, sourceDeviceId: String, authority: PhoneControlAuthorityDoc)
}

private class FirebaseAgentCapabilityGrantAuthorityPublishing(
    private val firestore: FirebaseFirestore,
) : AgentCapabilityGrantAuthorityPublishing {
    private val publisher: PhoneControlAuthorityPublisher by lazy {
        PhoneControlAuthorityPublisher(firestore)
    }

    override suspend fun publish(uid: String, authority: PhoneControlAuthorityDoc) {
        publisher.publish(uid = uid, authority = authority)
    }

    override suspend fun publishAgentGrantAuthority(uid: String, sourceDeviceId: String, authority: PhoneControlAuthorityDoc) {
        publisher.publishAgentGrantAuthority(uid = uid, sourceDeviceId = sourceDeviceId, authority = authority)
    }
}

interface AgentCapabilityGrantQueueing {
    suspend fun queueAgentCapabilityGrantRequest(payload: Map<String, Any>)
}

private class FirebaseAgentCapabilityGrantQueueing : AgentCapabilityGrantQueueing {
    override suspend fun queueAgentCapabilityGrantRequest(payload: Map<String, Any>) {
        ComputerUseSecurityCallableClient().queueAgentCapabilityGrantRequest(payload)
    }
}
