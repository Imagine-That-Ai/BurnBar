package com.openburnbar

import android.util.Log
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.cloud.MercuryDeviceRegistrationState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock

/**
 * Backoff schedule for re-running the Mercury registration preflight after a
 * transient failure (offline sign-in, callable outage). Exponential from 5s,
 * capped at 160s, bounded attempts so a permanently broken backend cannot
 * retry forever within one auth epoch.
 */
internal object MercuryRegistrationRetryPolicy {
    const val MAX_ATTEMPTS = 6
    private const val BASE_DELAY_MILLIS = 5_000L
    private const val MAX_SHIFT = 5

    fun delayMillis(attempt: Int): Long = BASE_DELAY_MILLIS shl (attempt - 1).coerceIn(0, MAX_SHIFT)
}

/** Pure trust-state mapping shared by the snapshot listener and its tests. */
internal fun escrowTrustRegistrationState(trustState: String, deviceId: String): MercuryDeviceRegistrationState =
    if (trustState == AndroidEscrowDeviceRegistry.TRUSTED) {
        MercuryDeviceRegistrationState.Ready(deviceId)
    } else {
        MercuryDeviceRegistrationState.PendingApproval(deviceId)
    }

/**
 * Retry the registration preflight after a failure so a transient error at
 * sign-in does not leave this auth epoch stuck in `Failed` (and pairing
 * stopped) until the next auth transition. Every attempt re-checks the auth
 * epoch before and inside the transition lock, so a sign-out or account switch
 * cancels the retry chain.
 */
internal fun BurnBarApplication.scheduleMercuryRegistrationRetry(uid: String, epoch: Long, attempt: Int) {
    if (attempt > MercuryRegistrationRetryPolicy.MAX_ATTEMPTS) {
        Log.w("BurnBar", "Mercury registration retries exhausted after ${attempt - 1} attempts; pairing remains stopped.")
        return
    }
    BurnBarApplication.applicationScope.launch {
        delay(MercuryRegistrationRetryPolicy.delayMillis(attempt))
        if (!controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) return@launch
        controllerAuthTransitionLock.withLock {
            if (!controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) return@withLock
            val registration = registerMercuryDeviceBeforePairing(uid = uid, epoch = epoch)
            if (registration == null) {
                scheduleMercuryRegistrationRetry(uid = uid, epoch = epoch, attempt = attempt + 1)
                return@withLock
            }
            if (controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) {
                restartPairingListener(uid = uid, epoch = epoch)
                observeEscrowDeviceTrust(uid = uid, epoch = epoch, deviceId = registration.deviceId)
            }
        }
    }
}

/**
 * Watch `users/{uid}/escrow_devices/{deviceId}` so a Mac-side approval (or
 * revocation) flips the published registration state live. Without this, a
 * device registered as `PendingApproval` shows the pending banner until the
 * next app launch even after the Mac approves it.
 */
internal fun BurnBarApplication.observeEscrowDeviceTrust(uid: String, epoch: Long, deviceId: String) {
    escrowTrustListener?.remove()
    escrowTrustListener = FirebaseFirestore.getInstance()
        .collection("users").document(uid)
        .collection("escrow_devices").document(deviceId)
        .addSnapshotListener { snapshot, error ->
            if (!controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) {
                return@addSnapshotListener
            }
            if (error != null) {
                Log.w("BurnBar", "Escrow trust listener error: ${error.message}")
                return@addSnapshotListener
            }
            val trustState = snapshot?.getString("trustState") ?: return@addSnapshotListener
            BurnBarApplication.publishMercuryDeviceRegistrationState(
                escrowTrustRegistrationState(trustState = trustState, deviceId = deviceId),
            )
        }
}
