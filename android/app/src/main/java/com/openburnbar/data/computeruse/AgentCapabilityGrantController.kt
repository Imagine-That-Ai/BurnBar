package com.openburnbar.data.computeruse

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

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
        val authenticated = authenticateIfNeeded(activity, preset)
        val sourceDeviceId = trustedSourceDeviceId(uid)
        val request = AgentCapabilityGrantRequest(
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
            } catch (error: Throwable) {
                if (deliveryMode == AgentGrantDeliveryMode.LIVE) throw error
            }
        }

        queue(uid = uid, request = request)
        return remember(request.pendingReceipt("Mac was unreachable, so this was queued for 5 minutes."))
    }

    private suspend fun trustedSourceDeviceId(uid: String): String {
        val device = AndroidEscrowDeviceRegistry().registerSelf(uid = uid)
        if (device.trustState != AndroidEscrowDeviceRegistry.TRUSTED) {
            throw GrantError.DeviceNotTrusted
        }
        return device.deviceId
    }

    private suspend fun authenticateIfNeeded(
        activity: FragmentActivity,
        preset: AgentPermissionPreset,
    ): Boolean {
        if (!preset.requiresDeviceAuth) return false
        return withContext(Dispatchers.Main) {
            val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            val manager = BiometricManager.from(activity)
            if (manager.canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
                throw GrantError.LocalAuthenticationFailed
            }
            suspendCancellableCoroutine { continuation ->
                val prompt = BiometricPrompt(
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

                        override fun onAuthenticationFailed() {
                            if (continuation.isActive) {
                                continuation.resumeWithException(GrantError.LocalAuthenticationFailed)
                            }
                        }
                    },
                )
                val info = BiometricPrompt.PromptInfo.Builder()
                    .setTitle("Allow ${preset.title} desktop permissions")
                    .setSubtitle("This grant applies only to this agent thread.")
                    .setAllowedAuthenticators(authenticators)
                    .build()
                continuation.invokeOnCancellation { prompt.cancelAuthentication() }
                prompt.authenticate(info)
            }
        }
    }

    private suspend fun ensurePhoneControlSender(
        uid: String,
        sourceDeviceId: String,
    ): PhoneControlSender = senderMutex.withLock {
        val coordinator = BurnBarApplication.mediaControlCoordinator
            ?: throw GrantError.NoPairedMac
        val pair = coordinator.activePair.value ?: throw GrantError.NoPairedMac
        val publicKey = keyStore.publicKey()
        val peerNodeId = keyStore.peerNodeId()

        phoneControlSender
            ?.takeIf { phoneControlConnectionID == pair.connectionID }
            ?.let { sender ->
                sendPhoneControlClassify(coordinator, pair, peerNodeId)
                return@withLock sender
            }

        val authority = PhoneControlAuthorityDocumentFactory.document(
            connectionId = pair.connectionID,
            deviceId = sourceDeviceId,
            publicKey = publicKey,
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
            privateKeySeedProvider = { keyStore.privateKeySeed() },
            counterStore = counterStore,
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
                control = HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                    authorityPeerNodeId = peerNodeId,
                ),
            )
        )
    }

    private suspend fun queue(uid: String, request: AgentCapabilityGrantRequest) {
        val signedWire = signedWireRequest(request)
        val authority = PhoneControlAuthorityDocumentFactory.document(
            connectionId = phoneControlConnectionID ?: "agent-grant-queued",
            deviceId = request.sourceDeviceId,
            publicKey = keyStore.publicKey(),
            publishedAtMillis = System.currentTimeMillis(),
        )
        PhoneControlAuthorityPublisher(firestore)
            .publishAgentGrantAuthority(uid = uid, sourceDeviceId = request.sourceDeviceId, authority = authority)
        firestore.collection("users").document(uid)
            .collection("agent_capability_grant_requests").document(request.requestId)
            .set(wireRequestMap(signedWire) + mapOf(
                "status" to AgentGrantDecisionStatus.QUEUED.wireValue,
                "createdAt" to FieldValue.serverTimestamp(),
                "updatedAt" to FieldValue.serverTimestamp(),
            ))
            .await()
    }

    private fun signedWireRequest(
        request: AgentCapabilityGrantRequest,
    ): com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest {
        val peerNodeId = keyStore.peerNodeId()
        val placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = "",
            counter = 0,
            timestamp = request.requestedAtSwiftReferenceSeconds,
            intentHashBlake3 = "",
            signatureEd25519 = "",
        )
        val unsignedWire = request.toWire(placeholder)
        val authority = PhoneControlSigner.signAgentGrantRequest(
            request = unsignedWire,
            peerNodeId = peerNodeId,
            counter = counterStore.nextCounter(peerNodeId),
            timestampMillis = System.currentTimeMillis(),
            privateKeySeed = keyStore.privateKeySeed(),
        )
        return request.toWire(
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = authority.peerNodeId,
                counter = authority.counter,
                timestamp = authority.swiftDateReferenceSeconds,
                intentHashBlake3 = authority.intentHashBlake3,
                signatureEd25519 = authority.signatureEd25519,
            )
        )
    }

    private fun wireRequestMap(
        wire: com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest,
    ): Map<String, Any> = mapOf(
        "requestId" to wire.requestId,
        "runtime" to wire.runtime,
        "threadId" to wire.threadId,
        "preset" to wire.preset,
        "capabilities" to wire.capabilities,
        "trustMode" to wire.trustMode,
        "deliveryMode" to wire.deliveryMode,
        "requestedAt" to wire.requestedAt,
        "expiresAt" to wire.expiresAt,
        "grantDurationSeconds" to wire.grantDurationSeconds,
        "sourceDeviceId" to wire.sourceDeviceId,
        "clientIntentId" to wire.clientIntentId,
        "localAuthenticationSatisfied" to wire.localAuthenticationSatisfied,
        "authority" to mapOf(
            "peerNodeId" to wire.authority.peerNodeId,
            "counter" to wire.authority.counter,
            "timestamp" to wire.authority.timestamp,
            "intentHashBlake3" to wire.authority.intentHashBlake3,
            "signatureEd25519" to wire.authority.signatureEd25519,
        ),
    )

    private fun remember(receipt: AgentCapabilityGrantReceipt): AgentCapabilityGrantReceipt {
        AgentCapabilityGrantState.apply(receipt)
        return receipt
    }
}
