package com.openburnbar.ui.media

import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.computeruse.RemoteUnlockCredentialEnvelopeCrypto
import com.openburnbar.data.computeruse.RemoteUnlockSavedCredentialStore
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

private const val REMOTE_UNLOCK_STATUS_MAX = 90

internal fun ScreenShareViewerActivity.saveRemoteUnlockPassword(
    password: String,
    store: RemoteUnlockSavedCredentialStore,
    state: HermesRealtimeRelayRemoteUnlockState?,
    onAvailabilityChanged: () -> Unit,
) {
    val credential = password.trimEnd('\n', '\r')
    if (credential.isEmpty()) {
        controlStatus.value = "Enter your Mac password before saving."
        return
    }
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control from this Android to save Remote Unlock."
        return
    }
    val storeKey = remoteUnlockCredentialStoreKey(state)
    if (storeKey == null) {
        controlStatus.value = "Remote Unlock recipient is not ready yet."
        return
    }
    if (state?.capabilities?.allowsSavedCredentialUnlock != true) {
        controlStatus.value = "One-tap Remote Unlock is not available on this Mac yet."
        return
    }
    controlScope.launch {
        runCatching {
            authenticateForRemoteUnlock(
                title = "Save Mac password",
                subtitle = "Confirm this Android before saving one-tap Remote Unlock.",
            )
            store.save(storeKey, credential)
            withContext(Dispatchers.Main) {
                onAvailabilityChanged()
                controlStatus.value = "One-tap Remote Unlock is ready on this Android."
            }
        }.onFailure { error ->
            controlStatus.value = error.message?.take(REMOTE_UNLOCK_STATUS_MAX) ?: "Remote Unlock save failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android Remote Unlock saved credential failed error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.sendSavedRemoteUnlockPassword(
    store: RemoteUnlockSavedCredentialStore,
    state: HermesRealtimeRelayRemoteUnlockState?,
) {
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control from this Android to unlock the Mac."
        return
    }
    val storeKey = remoteUnlockCredentialStoreKey(state)
    if (storeKey == null) {
        controlStatus.value = "Remote Unlock recipient is not ready yet."
        return
    }
    if (state?.capabilities?.allowsSavedCredentialUnlock != true) {
        controlStatus.value = "One-tap Remote Unlock is not available on this Mac yet."
        return
    }
    controlScope.launch {
        runCatching {
            authenticateForRemoteUnlock(
                title = "Unlock Mac",
                subtitle = "Confirm this Android before one-tap Remote Unlock submits the saved credential.",
            )
            val credential =
                store.load(storeKey)
                    ?: error("Saved Remote Unlock credential is no longer available.")
            sendRemoteUnlockPassword(
                password = credential,
                credentialKind = HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.SAVED_PASSWORD,
                authenticate = false,
            )
        }.onFailure { error ->
            controlStatus.value = error.message?.take(REMOTE_UNLOCK_STATUS_MAX) ?: "Remote Unlock failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android saved Remote Unlock credential failed error=${error.message}", error)
        }
    }
}

internal fun ScreenShareViewerActivity.sendRemoteUnlockPassword(
    password: String,
    credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind =
        HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind.TYPED_PASSWORD,
    authenticate: Boolean = true,
) {
    val credential = password.trimEnd('\n', '\r')
    if (credential.isEmpty()) {
        controlStatus.value = "Enter your Mac password."
        return
    }
    if (mirrorViewerRole == "watcher") {
        controlStatus.value = "Watching only. Take control from this Android to unlock the Mac."
        return
    }
    controlScope.launch {
        runCatching {
            if (authenticate) {
                authenticateForRemoteUnlock()
            }
            dispatchRemoteUnlockCredential(credential, credentialKind)
        }.onFailure { error ->
            controlStatus.value = error.message?.take(REMOTE_UNLOCK_STATUS_MAX) ?: "Remote Unlock failed"
            Log.w(ScreenShareViewerActivity.TAG, "Android Remote Unlock credential failed error=${error.message}", error)
        }
    }
}

private suspend fun ScreenShareViewerActivity.dispatchRemoteUnlockCredential(
    credential: String,
    credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind,
) {
    val unlockState = resolveRemoteUnlockStateForSend()
    val envelope = buildRemoteUnlockCredentialEnvelope(credential, credentialKind, unlockState)
    val sender = ensurePhoneControlSender()
    sender.send(envelope)
    controlStatus.value = "Password sent to Mac login window"
    Log.i(
        ScreenShareViewerActivity.TAG,
        "Android Remote Unlock credential sent requestId=${envelope.requestId} sessionId=${envelope.sessionId}",
    )
}

private fun ScreenShareViewerActivity.resolveRemoteUnlockStateForSend(): HermesRealtimeRelayRemoteUnlockState =
    BurnBarApplication.mediaControlCoordinator
        ?.lastRemoteUnlockState
        ?.value
        ?: BurnBarApplication.mediaControlCoordinator
            ?.lastMirrorAck
            ?.value
            ?.remoteUnlockState
        ?: error("Remote Unlock state is not available yet.")

private fun ScreenShareViewerActivity.buildRemoteUnlockCredentialEnvelope(
    credential: String,
    credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind,
    unlockState: HermesRealtimeRelayRemoteUnlockState,
): HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
    val capabilities = unlockState.capabilities
    val sessionId =
        unlockState.sessionId
            ?: error("Remote Unlock session is not available yet.")
    val recipientKeyId =
        capabilities.credentialRecipientKeyId
            ?: error("Remote Unlock recipient key is missing.")
    val recipientPublicKey =
        capabilities.credentialRecipientPublicKeyBase64
            ?: error("Remote Unlock recipient key is missing.")
    val algorithm =
        capabilities.credentialEnvelopeAlgorithm
            ?: error("Remote Unlock envelope algorithm is missing.")
    if (!capabilities.enabled || !capabilities.allowsCredentialPaste) {
        error("Remote Unlock is not ready on this Mac.")
    }
    if (algorithm != RemoteUnlockCredentialEnvelopeCrypto.ALGORITHM) {
        error("Remote Unlock needs an app update on this Android.")
    }
    val requestId = UUID.randomUUID().toString()
    val clientIntentId = UUID.randomUUID().toString()
    val requestedAt = Instant.now()
    val expiresAt = requestedAt.plusSeconds(ScreenShareViewerActivity.REMOTE_UNLOCK_CREDENTIAL_TTL_SECONDS)
    val sealed =
        RemoteUnlockCredentialEnvelopeCrypto.seal(
            RemoteUnlockCredentialEnvelopeCrypto.RemoteUnlockSealRequest(
                credential = credential,
                requestId = requestId,
                sessionId = sessionId,
                clientIntentId = clientIntentId,
                credentialKind = credentialKind,
                recipientKeyId = recipientKeyId,
                recipientPublicKeyBase64 = recipientPublicKey,
                algorithm = algorithm,
            ),
        )
    return HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
        requestId = requestId,
        sessionId = sessionId,
        clientIntentId = clientIntentId,
        credentialKind = credentialKind,
        recipientKeyId = recipientKeyId,
        algorithm = algorithm,
        ciphertextBase64 = sealed.ciphertextBase64,
        aadBase64 = sealed.aadBase64,
        redactedByteCount = sealed.redactedByteCount,
        requestedAt = requestedAt.toString(),
        expiresAt = expiresAt.toString(),
        authority =
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = "",
            counter = 0,
            timestamp = 0.0,
            intentHashBlake3 = "",
            signatureEd25519 = "",
        ),
    )
}

internal fun ScreenShareViewerActivity.remoteUnlockCredentialStoreKey(state: HermesRealtimeRelayRemoteUnlockState?): String? {
    val recipientKey = state?.capabilities?.credentialRecipientKeyId
    return when {
        !recipientKey.isNullOrBlank() -> recipientKey
        !phoneControlConnectionID.isNullOrBlank() -> phoneControlConnectionID
        !mirrorRequestID.isNullOrBlank() -> mirrorRequestID
        else -> null
    }
}

internal suspend fun ScreenShareViewerActivity.authenticateForRemoteUnlock(
    title: String = "Send Mac password",
    subtitle: String = "Confirm this Android before Remote Unlock submits the credential.",
) {
    withContext(Dispatchers.Main) {
        val authenticators =
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        val manager = BiometricManager.from(this@authenticateForRemoteUnlock)
        if (manager.canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
            error("Device credential is required for Remote Unlock.")
        }
        suspendCancellableCoroutine { continuation ->
            val prompt =
                BiometricPrompt(
                    this@authenticateForRemoteUnlock,
                    ContextCompat.getMainExecutor(this@authenticateForRemoteUnlock),
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
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setAllowedAuthenticators(authenticators)
                    .build()
            continuation.invokeOnCancellation { prompt.cancelAuthentication() }
            prompt.authenticate(info)
        }
    }
}
