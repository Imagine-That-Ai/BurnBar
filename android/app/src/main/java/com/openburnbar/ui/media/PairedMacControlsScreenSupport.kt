package com.openburnbar.ui.media

import android.content.Context
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlSignerSign
import com.openburnbar.data.computeruse.PhoneControlSigningIdentity
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.computeruse.SharedPreferencesPhoneControlCounterStore
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockBackend
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

internal const val MIRROR_REQUEST_TIMEOUT_MS = 20_000L
internal const val REMOTE_UNLOCK_SESSION_TTL_SECONDS = 600L
internal const val REMOTE_UNLOCK_SESSION_REQUIRED = "remote_unlock_session_required"

internal data class PairedMacControlsUiState(
    val phase: MediaControlStreamCoordinator.Phase,
    val statusMessage: String?,
    val pendingRequestID: String?,
    val pendingCallRequestID: String?,
    val recoveringMercury: Boolean,
    val sendingFile: Boolean,
    val mirrorAutoAccept: Boolean,
    val usePremiumSOTAUX: Boolean,
    val useWebsiteBackground: Boolean,
    val isSettingsOpen: Boolean,
    val coordinator: MediaControlStreamCoordinator?,
)

internal data class PairedMacControlsUiActions(
    val onSettingsClick: () -> Unit,
    val onMirrorClick: () -> Unit,
    val onCheckMercuryClick: () -> Unit,
    val onSendFileClick: () -> Unit,
    val onCallMacClick: () -> Unit,
    val onDismissSettings: () -> Unit,
)

internal data class PairedMacControlsEffectsBinding(
    val connectionID: String?,
    val app: BurnBarApplication?,
    val coordinator: MediaControlStreamCoordinator?,
    val pendingRequestID: String?,
    val ack: HermesRealtimeRelayMirrorAck?,
    val pendingCallRequestID: String?,
    val callAck: HermesRealtimeRelayCallAck?,
    val launchedMirrorRequestID: String?,
    val onCoordinatorChange: (MediaControlStreamCoordinator?) -> Unit,
    val onStatusMessageChange: (String?) -> Unit,
    val onPendingRequestIDChange: (String?) -> Unit,
    val onPendingCallRequestIDChange: (String?) -> Unit,
    val onLaunchedMirrorRequestIDChange: (String?) -> Unit,
)

internal data class PairedMacControlsMirrorRequestInput(
    val app: BurnBarApplication?,
    val coordinator: MediaControlStreamCoordinator?,
    val phase: MediaControlStreamCoordinator.Phase,
    val connectionID: String?,
    val activePair: MediaControlStreamCoordinator.ActivePair?,
    val mirrorAutoAccept: Boolean,
)

internal data class PairedMacControlsMirrorRequestResult(
    val coordinator: MediaControlStreamCoordinator?,
    val pendingRequestID: String?,
    val statusMessage: String?,
)

internal data class PairedMacControlsCheckMercuryInput(
    val coordinator: MediaControlStreamCoordinator?,
    val phase: MediaControlStreamCoordinator.Phase,
    val connectionID: String?,
    val activePair: MediaControlStreamCoordinator.ActivePair?,
    val app: BurnBarApplication?,
)

internal data class PairedMacControlsCheckMercuryResult(
    val immediateStatusMessage: String?,
    val shouldRestartMercury: Boolean,
)

internal data class PairedMacControlsWriteCallbacks(
    val setCoordinator: (MediaControlStreamCoordinator?) -> Unit,
    val setPendingRequestID: (String?) -> Unit,
    val setPendingCallRequestID: (String?) -> Unit,
    val setStatusMessage: (String?) -> Unit,
    val setRecoveringMercury: (Boolean) -> Unit,
)

internal fun mirrorClickAction(
    scope: CoroutineScope,
    snapshot: () -> PairedMacControlsMirrorRequestInput,
    write: PairedMacControlsWriteCallbacks,
): () -> Unit =
    {
        launchMirrorRequest(
            scope = scope,
            input = snapshot(),
            onRecoveringMercuryChange = write.setRecoveringMercury,
        ) { result ->
            write.setCoordinator(result.coordinator)
            write.setPendingRequestID(result.pendingRequestID)
            write.setStatusMessage(result.statusMessage)
        }
    }

internal fun checkMercuryClickAction(
    scope: CoroutineScope,
    snapshot: () -> PairedMacControlsCheckMercuryInput,
    write: PairedMacControlsWriteCallbacks,
): () -> Unit =
    {
        val checkResult = evaluateCheckMercury(snapshot())
        write.setStatusMessage(checkResult.immediateStatusMessage)
        if (checkResult.shouldRestartMercury) {
            val input = snapshot()
            val connection = resolveRequestedConnectionID(input.connectionID, input.activePair)
            val application = input.app
            if (connection != null && application != null) {
                launchCheckMercuryRestart(scope, application, connection) { result ->
                    write.setCoordinator(result.coordinator)
                    write.setStatusMessage(result.statusMessage)
                }
            }
        }
    }

internal fun callMacClickAction(
    scope: CoroutineScope,
    snapshot: () -> Pair<MediaControlStreamCoordinator?, MediaControlStreamCoordinator.Phase>,
    write: PairedMacControlsWriteCallbacks,
): () -> Unit =
    {
        val (coordinator, phase) = snapshot()
        launchCallMacRequest(scope, coordinator, phase) { result ->
            write.setCoordinator(result.coordinator)
            write.setPendingCallRequestID(result.pendingRequestID)
            write.setStatusMessage(result.statusMessage)
        }
    }

internal fun pairedMacRequesterDisplayName(): String =
    FirebaseAuth.getInstance().currentUser?.displayName
        ?.takeIf { it.isNotBlank() }
        ?: "Android"

internal fun resolveRequestedConnectionID(
    connectionID: String?,
    activePair: MediaControlStreamCoordinator.ActivePair?,
): String? =
    connectionID
        ?.trim()
        ?.takeIf { it.isNotBlank() && !it.startsWith("paired-mac:") }
        ?: activePair?.connectionID

internal suspend fun executeMirrorRequest(input: PairedMacControlsMirrorRequestInput): PairedMacControlsMirrorRequestResult {
    val name = pairedMacRequesterDisplayName()
    return runCatching {
        val activeCoordinator = input.coordinator
        val targetCoordinator =
            if (activeCoordinator != null && input.phase is MediaControlStreamCoordinator.Phase.Live) {
                activeCoordinator
            } else {
                val connection =
                    resolveRequestedConnectionID(input.connectionID, input.activePair)
                        ?: error("Open this Mac from Hermes Square so Android can target the paired Mac relay.")
                val application =
                    input.app
                        ?: error("BurnBar is not ready to start Mercury yet.")
                Log.i("BurnBar", "Ask to Mirror recovering Mercury for connectionID=$connection")
                application.ensureMediaControlStream(
                    connectionID = connection,
                    forceRestart = true,
                )
                BurnBarApplication.mediaControlCoordinator
                    ?: error("Mercury did not create a control coordinator.")
            }
        val requestID =
            withTimeout(MIRROR_REQUEST_TIMEOUT_MS) {
                targetCoordinator.requestMirror(requesterDisplayName = name)
            }
        PairedMacControlsMirrorRequestResult(
            coordinator = targetCoordinator,
            pendingRequestID = requestID,
            statusMessage =
            if (input.mirrorAutoAccept) {
                "Opening mirror on your Mac..."
            } else {
                "Request sent. Check your Mac."
            },
        )
    }.getOrElse { error ->
        Log.w("BurnBar", "Ask to Mirror failed: ${error.message}")
        PairedMacControlsMirrorRequestResult(
            coordinator = input.coordinator,
            pendingRequestID = null,
            statusMessage =
            when (error) {
                is TimeoutCancellationException ->
                    "Mercury did not connect within 20 seconds. Open BurnBar on the Mac, then try again."
                else ->
                    "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}"
            },
        )
    }
}

internal fun evaluateCheckMercury(input: PairedMacControlsCheckMercuryInput): PairedMacControlsCheckMercuryResult =
    when {
        input.coordinator == null ->
            PairedMacControlsCheckMercuryResult(
                immediateStatusMessage =
                "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online.",
                shouldRestartMercury = false,
            )
        input.phase !is MediaControlStreamCoordinator.Phase.Live -> {
            val connection = resolveRequestedConnectionID(input.connectionID, input.activePair)
            val canRestart = connection != null && input.app != null
            PairedMacControlsCheckMercuryResult(
                immediateStatusMessage = if (canRestart) "Restarting Mercury..." else input.phase.userMessage(),
                shouldRestartMercury = canRestart,
            )
        }
        else ->
            PairedMacControlsCheckMercuryResult(
                immediateStatusMessage = "Mercury is live. Ask to Mirror is ready.",
                shouldRestartMercury = false,
            )
    }

internal suspend fun restartMercuryForCheck(
    app: BurnBarApplication,
    connectionID: String,
): PairedMacControlsMirrorRequestResult {
    return runCatching {
        app.ensureMediaControlStream(connectionID = connectionID, forceRestart = true)
        PairedMacControlsMirrorRequestResult(
            coordinator = BurnBarApplication.mediaControlCoordinator,
            pendingRequestID = null,
            statusMessage = "Mercury retry started.",
        )
    }.getOrElse { error ->
        PairedMacControlsMirrorRequestResult(
            coordinator = BurnBarApplication.mediaControlCoordinator,
            pendingRequestID = null,
            statusMessage = "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}",
        )
    }
}

internal suspend fun executeCallMacRequest(
    coordinator: MediaControlStreamCoordinator?,
    phase: MediaControlStreamCoordinator.Phase,
): PairedMacControlsMirrorRequestResult {
    val currentCoordinator =
        coordinator ?: run {
            Log.i("BurnBar", "Call Mac blocked: media coordinator is null")
            return PairedMacControlsMirrorRequestResult(
                coordinator = null,
                pendingRequestID = null,
                statusMessage = "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online.",
            )
        }
    if (phase !is MediaControlStreamCoordinator.Phase.Live) {
        Log.i("BurnBar", "Call Mac blocked: phase=${phase.javaClass.simpleName}")
        return PairedMacControlsMirrorRequestResult(
            coordinator = currentCoordinator,
            pendingRequestID = null,
            statusMessage = phase.userMessage(),
        )
    }
    return runCatching {
        val requestID = currentCoordinator.requestCall(pairedMacRequesterDisplayName())
        PairedMacControlsMirrorRequestResult(
            coordinator = currentCoordinator,
            pendingRequestID = requestID,
            statusMessage = "Call invite sent. Check your Mac.",
        )
    }.getOrElse { error ->
        PairedMacControlsMirrorRequestResult(
            coordinator = currentCoordinator,
            pendingRequestID = null,
            statusMessage = "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}",
        )
    }
}

internal fun launchCheckMercuryRestart(
    scope: CoroutineScope,
    app: BurnBarApplication,
    connectionID: String,
    onResult: (PairedMacControlsMirrorRequestResult) -> Unit,
) {
    scope.launch {
        onResult(restartMercuryForCheck(app, connectionID))
    }
}

internal fun launchMirrorRequest(
    scope: CoroutineScope,
    input: PairedMacControlsMirrorRequestInput,
    onRecoveringMercuryChange: (Boolean) -> Unit,
    onResult: (PairedMacControlsMirrorRequestResult) -> Unit,
) {
    scope.launch {
        onRecoveringMercuryChange(true)
        onResult(executeMirrorRequest(input))
        onRecoveringMercuryChange(false)
    }
}

internal fun launchCallMacRequest(
    scope: CoroutineScope,
    coordinator: MediaControlStreamCoordinator?,
    phase: MediaControlStreamCoordinator.Phase,
    onResult: (PairedMacControlsMirrorRequestResult) -> Unit,
) {
    scope.launch {
        onResult(executeCallMacRequest(coordinator, phase))
    }
}

internal suspend fun authenticateForRemoteUnlock(activity: FragmentActivity) {
    withContext(Dispatchers.Main) {
        val authenticators =
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        val manager = BiometricManager.from(activity)
        if (manager.canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
            error("Device credential is required for Remote Unlock.")
        }
        suspendCancellableCoroutine { continuation ->
            val prompt =
                BiometricPrompt(
                    activity,
                    ContextCompat.getMainExecutor(activity),
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                            if (continuation.isActive) continuation.resume(Unit)
                        }

                        override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                            if (continuation.isActive) {
                                continuation.resumeWithException(
                                    IllegalStateException("Remote Unlock needs device authentication."),
                                )
                            }
                        }

                        override fun onAuthenticationFailed() = Unit
                    },
                )
            val info =
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle("Trust Remote Unlock")
                    .setSubtitle("This Android will stay trusted for future locked Mac mirrors.")
                    .setAllowedAuthenticators(authenticators)
                    .build()
            continuation.invokeOnCancellation { prompt.cancelAuthentication() }
            prompt.authenticate(info)
        }
    }
}

internal suspend fun ensureRemoteUnlockTrustedDevice(
    uid: String,
    activity: FragmentActivity,
    registry: AndroidEscrowDeviceRegistry = AndroidEscrowDeviceRegistry(),
): com.openburnbar.data.cloud.AndroidEscrowDeviceRegistration {
    var device = registry.registerSelf(uid = uid)
    if (device.trustState == AndroidEscrowDeviceRegistry.TRUSTED) {
        return device
    }
    authenticateForRemoteUnlock(activity)
    device = registry.trustSelf(uid = uid)
    return device
}

internal suspend fun buildRemoteUnlockSession(
    context: Context,
    targetCoordinator: MediaControlStreamCoordinator,
    requesterDisplayName: String,
): HermesRealtimeRelayRemoteUnlockSession {
    val activity =
        context as? FragmentActivity
            ?: error("Remote Unlock requires an activity-backed Android session.")
    val pair =
        targetCoordinator.activePair.value
            ?: error("Mercury control stream is not paired yet.")
    val keyStore = PhoneControlSigningKeyStore(context.applicationContext)
    // F2: resolve the key-kind-aware identity once so the published authority
    // key and the signed session envelope stay the same key.
    val identity = keyStore.signingIdentity()
    val peerNodeId = keyStore.peerNodeId(identity)
    val device = ensureRemoteUnlockTrustedDevice(uid = pair.uid, activity = activity)
    val authority =
        PhoneControlAuthorityDocumentFactory.document(
            connectionId = pair.connectionID,
            deviceId = device.deviceId,
            identity = identity,
            publishedAtMillis = System.currentTimeMillis(),
        )
    PhoneControlAuthorityPublisher().publish(uid = pair.uid, authority = authority)
    return signRemoteUnlockSession(
        context = context,
        requesterDisplayName = requesterDisplayName,
        peerNodeId = peerNodeId,
        identity = identity,
    )
}

private suspend fun signRemoteUnlockSession(
    context: Context,
    requesterDisplayName: String,
    peerNodeId: String,
    identity: PhoneControlSigningIdentity,
): HermesRealtimeRelayRemoteUnlockSession {
    val requestedAt = Instant.now()
    val expiresAt = requestedAt.plusSeconds(REMOTE_UNLOCK_SESSION_TTL_SECONDS)
    val placeholderAuthority =
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = "",
            counter = 0,
            timestamp = 0.0,
            intentHashBlake3 = "",
            signatureEd25519 = "",
        )
    val unsigned =
        HermesRealtimeRelayRemoteUnlockSession(
            requestId = "remote-unlock-${UUID.randomUUID()}",
            sessionId = UUID.randomUUID().toString(),
            intent = HermesRealtimeRelayRemoteUnlockSession.Intent.REQUEST,
            requesterDisplayName = requesterDisplayName,
            viewerDeviceId = android.os.Build.MODEL.orEmpty().ifBlank { "android" },
            requestedAt = requestedAt.toString(),
            expiresAt = expiresAt.toString(),
            localAuthenticationSatisfied = true,
            requestedBackend = HermesRealtimeRelayRemoteUnlockBackend.APPLE_SCREEN_SHARING_LOOPBACK,
            authority = placeholderAuthority,
        )
    val timestampMillis = System.currentTimeMillis()
    val signed =
        PhoneControlSignerSign.signRemoteUnlockSession(
            session = unsigned,
            peerNodeId = peerNodeId,
            counter = SharedPreferencesPhoneControlCounterStore(context).nextCounter(peerNodeId),
            timestampMillis = timestampMillis,
            identity = identity,
        )
    return unsigned.copy(
        authority =
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = signed.peerNodeId,
            counter = signed.counter,
            timestamp = signed.swiftDateReferenceSeconds,
            intentHashBlake3 = signed.intentHashBlake3,
            signatureEd25519 = signed.signatureEd25519,
            // F2 extra credit: best-effort App Check attestation digest —
            // nullable and dropped from the wire when absent, mirroring the
            // iOS sign(remoteUnlockSession:) attachment. Never enforced.
            attestationHashBlake3 =
            com.openburnbar.data.computeruse.AndroidAppCheckAttestationReader
                .currentAttestationDigestForEnvelope(),
            keyKind = signed.keyKind,
        ),
    )
}

internal fun MediaControlStreamCoordinator.Phase.userMessage(): String = when (this) {
    MediaControlStreamCoordinator.Phase.Idle -> "Mercury is idle. Waiting for a paired Mac."
    MediaControlStreamCoordinator.Phase.Dialing -> "Mercury is connecting to your Mac..."
    MediaControlStreamCoordinator.Phase.Live -> "Mercury is live. You can ask the Mac to mirror."
    is MediaControlStreamCoordinator.Phase.Reconnecting -> "Mercury is reconnecting to your Mac..."
    MediaControlStreamCoordinator.Phase.Stopped -> "Mercury is stopped. Open BurnBar on the Mac."
    is MediaControlStreamCoordinator.Phase.Failed -> "Mercury unavailable: $reason"
}

internal fun HermesRealtimeRelayMirrorAck.userMessage(): String = when (decision) {
    HermesRealtimeRelayMirrorAck.Decision.ACCEPTED -> detail ?: "Mac accepted. Waiting for screen frames."
    HermesRealtimeRelayMirrorAck.Decision.DENIED -> detail ?: "Mac declined the request."
    HermesRealtimeRelayMirrorAck.Decision.COOLING_DOWN -> detail ?: "Mac is cooling down."
    HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED -> detail ?: "Mac cannot mirror right now."
    HermesRealtimeRelayMirrorAck.Decision.BUSY -> detail ?: "Mac is busy."
}

internal fun HermesRealtimeRelayCallAck.userMessage(): String = when (decision) {
    HermesRealtimeRelayCallAck.Decision.ACCEPTED -> detail ?: "Mac accepted the call invite."
    HermesRealtimeRelayCallAck.Decision.DENIED -> detail ?: "Mac declined the call."
    HermesRealtimeRelayCallAck.Decision.UNSUPPORTED -> detail ?: "Mac cannot receive calls right now."
    HermesRealtimeRelayCallAck.Decision.BUSY -> detail ?: "Mac is busy."
}
