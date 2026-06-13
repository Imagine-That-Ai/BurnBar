package com.openburnbar.data.computeruse

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionRequest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class AgentCapabilityGrantController(
    context: Context,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    private val appContext = context.applicationContext
    private val keyStore = PhoneControlSigningKeyStore(appContext)
    private val counterStore = SharedPreferencesPhoneControlCounterStore(appContext)
    private val senderMutex = Mutex()
    private var phoneControlSender: PhoneControlSender? = null
    private var phoneControlConnectionID: String? = null

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

        if (deliveryMode != AgentGrantDeliveryMode.QUEUED) {
            try {
                val sender = ensurePhoneControlSender(uid = uid, sourceDeviceId = sourceDeviceId)
                sender.send(agentGrant = request)
                return remember(request.pendingReceipt("Sent to your Mac."))
            } catch (error: FirebaseException) {
                if (deliveryMode == AgentGrantDeliveryMode.LIVE) throw error
            }
        }

        queue(uid = uid, request = request)
        return remember(request.pendingReceipt("Mac was unreachable, so this was queued for 5 minutes."))
    }

    suspend fun sendSystemPermissionRequest(request: PhoneControlSystemPermissionRequest): HermesRealtimeRelaySystemPermissionRequest {
        val uid = auth.currentUser?.uid ?: throw GrantError.NotSignedIn
        val sourceDeviceId = trustedSourceDeviceId(uid)
        val sender = ensurePhoneControlSender(uid = uid, sourceDeviceId = sourceDeviceId)
        return sender.send(systemPermissionRequest = request)
    }

    private suspend fun trustedSourceDeviceId(uid: String): String {
        val device = AndroidEscrowDeviceRegistry().registerSelf(uid = uid)
        if (device.trustState != AndroidEscrowDeviceRegistry.TRUSTED) {
            throw GrantError.DeviceNotTrusted
        }
        return device.deviceId
    }

    private suspend fun authenticateIfNeeded(activity: FragmentActivity, preset: AgentPermissionPreset): Boolean {
        if (!preset.requiresDeviceAuth) return false
        return withContext(Dispatchers.Main) {
            val authenticators =
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
            val manager = BiometricManager.from(activity)
            if (manager.canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
                throw GrantError.LocalAuthenticationFailed
            }
            suspendCancellableCoroutine { continuation ->
                val prompt =
                    BiometricPrompt(
                        activity,
                        ContextCompat.getMainExecutor(activity),
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                                if (continuation.isActive) continuation.resume(true)
                            }

                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                if (continuation.isActive) {
                                    continuation.resumeWithException(GrantError.LocalAuthenticationFailed)
                                }
                            }

                            override fun onAuthenticationFailed() = Unit
                        },
                    )
                val info =
                    BiometricPrompt.PromptInfo.Builder()
                        .setTitle("Allow ${preset.title} desktop permissions")
                        .setSubtitle("This grant applies only to this agent thread.")
                        .setAllowedAuthenticators(authenticators)
                        .build()
                continuation.invokeOnCancellation { prompt.cancelAuthentication() }
                prompt.authenticate(info)
            }
        }
    }

    private suspend fun ensurePhoneControlSender(uid: String, sourceDeviceId: String): PhoneControlSender = senderMutex.withLock {
        val coordinator =
            BurnBarApplication.mediaControlCoordinator
                ?: throw GrantError.NoPairedMac
        val pair = coordinator.activePair.value ?: throw GrantError.NoPairedMac
        // F2: resolve the signing identity once so the published authority key
        // and every envelope this sender signs stay the same key.
        val identity = keyStore.signingIdentity()
        val peerNodeId = keyStore.peerNodeId(identity)

        phoneControlSender
            ?.takeIf { phoneControlConnectionID == pair.connectionID }
            ?.let { sender ->
                sendPhoneControlClassify(coordinator, pair, peerNodeId)
                return@withLock sender
            }

        val authority =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = pair.connectionID,
                deviceId = sourceDeviceId,
                identity = identity,
                publishedAtMillis = System.currentTimeMillis(),
            )
        val publisher = PhoneControlAuthorityPublisher(firestore)
        publisher.publish(uid = pair.uid, authority = authority)
        publisher.publishAgentGrantAuthority(uid = uid, sourceDeviceId = sourceDeviceId, authority = authority)
        sendPhoneControlClassify(coordinator, pair, peerNodeId)

        PhoneControlSender(
            uid = pair.uid,
            connectionId = pair.connectionID,
            peerNodeId = peerNodeId,
            signingIdentityProvider = { identity },
            counterStore = counterStore,
            attestationDigestProvider = { AndroidAppCheckAttestationReader.currentAttestationDigestForEnvelope() },
            // RR-7c: fail-closed attestation gate under the strict ramp (the agent-grant path enforces, mirror iOS).
            attestationEnforcer = { AndroidAppCheckAttestationReader.ensureAttestationDigestOrThrow() },
            frameSink = { frame -> coordinator.send(frame) },
        ).also {
            phoneControlSender = it
            phoneControlConnectionID = pair.connectionID
        }
    }

    private suspend fun sendPhoneControlClassify(
        coordinator: com.openburnbar.data.media.MediaControlStreamCoordinator,
        pair: com.openburnbar.data.media.MediaControlStreamCoordinator.ActivePair,
        peerNodeId: String,
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
                ),
            ),
        )
    }

    private suspend fun queue(uid: String, request: AgentCapabilityGrantRequest) {
        // F2: one identity resolution covers the published authority key and
        // the queued request's signature.
        val identity = keyStore.signingIdentity()
        val signedWire = signedWireRequest(request, identity)
        val authority =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = phoneControlConnectionID ?: "agent-grant-queued",
                deviceId = request.sourceDeviceId,
                identity = identity,
                publishedAtMillis = System.currentTimeMillis(),
            )
        PhoneControlAuthorityPublisher(firestore)
            .publishAgentGrantAuthority(uid = uid, sourceDeviceId = request.sourceDeviceId, authority = authority)
        ComputerUseSecurityCallableClient().queueAgentCapabilityGrantRequest(wireRequestMap(signedWire))
    }

    private fun signedWireRequest(
        request: AgentCapabilityGrantRequest,
        identity: PhoneControlSigningIdentity,
    ): com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest {
        val peerNodeId = keyStore.peerNodeId(identity)
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
