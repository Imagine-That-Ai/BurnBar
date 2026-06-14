package com.openburnbar.data.cloud

import android.app.Activity
import android.app.Application
import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import kotlinx.coroutines.launch

/**
 * RR-5 / T-PTR-02: run survivor-side Cloud Vault rotation pickup when the app
 * returns to the foreground, not only when the Devices screen first loads.
 * Mirrors Mac `AppDelegate` launch/foreground pickup triggers.
 */
object CloudVaultRotationPickupLifecycle {
    private const val DEBOUNCE_MS = 30_000L
    private const val TAG = "BurnBar"

    @Volatile
    private var installed = false

    @Volatile
    private var lastPickupAtMs = 0L

    fun install(application: Application) {
        if (installed) return
        installed = true
        var visibleActivities = 0
        application.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) = Unit

                override fun onActivityStarted(activity: Activity) {
                    visibleActivities++
                    if (visibleActivities == 1) {
                        schedulePickup()
                    }
                }

                override fun onActivityResumed(activity: Activity) = Unit

                override fun onActivityPaused(activity: Activity) = Unit

                override fun onActivityStopped(activity: Activity) {
                    visibleActivities = (visibleActivities - 1).coerceAtLeast(0)
                }

                override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) = Unit

                override fun onActivityDestroyed(activity: Activity) = Unit
            },
        )
    }

    private fun schedulePickup() {
        val now = System.currentTimeMillis()
        if (now - lastPickupAtMs < DEBOUNCE_MS) return
        lastPickupAtMs = now

        val user = FirebaseAuth.getInstance().currentUser
        if (user == null || user.isAnonymous) return

        BurnBarApplication.applicationScope.launch {
            runCatching {
                val rotatingDeviceId = AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
                ComputerUseSecurityCallableClient().pickUpPendingCloudVaultRotations(rotatingDeviceId)
            }.onFailure { error ->
                Log.w(TAG, "Cloud Vault rotation pickup on foreground failed: ${error.message}")
            }
        }
    }
}
