package com.openburnbar.services.media

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/**
 * Android-side device heartbeat for cross-surface agent-reply notifications.
 *
 * The Cloud fan-out suppresses pushes for the active matching chat. The local
 * FCM service also uses this state to avoid posting a system notification when
 * Android receives a foreground data message for the thread already on screen.
 */
private object AgentReplyNotificationConstants {
    const val HEX_PREFIX_THRESHOLD = 0x10
    const val BYTE_MASK = 0xff
    const val HEX_CHARS_PER_BYTE = 2
}

object AgentReplyNotificationState {
    private const val DEVICE_ID_PREF_NAME = "burnbar.device"
    private const val DEVICE_ID_PREF_KEY = "stable_device_id"

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    @Volatile private var appLifecycle: String = "unknown"

    @Volatile private var activeRuntime: String? = null

    @Volatile private var activeThreadId: String? = null

    @Volatile private var activeSurface: String? = null

    @Volatile private var fcmToken: String? = null

    @Volatile private var lifecycleTrackingInstalled = false

    fun installLifecycleTracking(application: Application) {
        if (lifecycleTrackingInstalled) return
        lifecycleTrackingInstalled = true
        var visibleActivities = 0
        application.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityStarted(activity: Activity) {
                    visibleActivities += 1
                    updateLifecycle(activity, "active")
                }

                override fun onActivityStopped(activity: Activity) {
                    visibleActivities = (visibleActivities - 1).coerceAtLeast(0)
                    if (visibleActivities == 0) updateLifecycle(activity, "background")
                }

                override fun onActivityPaused(activity: Activity) {
                    if (visibleActivities > 0) updateLifecycle(activity, "inactive")
                }

                override fun onActivityResumed(activity: Activity) {
                    updateLifecycle(activity, "active")
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

                override fun onActivityDestroyed(activity: Activity) = Unit
            },
        )
    }

    fun persistToken(context: Context, token: String) {
        fcmToken = token
        persist(context.applicationContext)
    }

    fun setActiveChat(context: Context, runtime: String?, threadId: String?, surface: String?) {
        activeRuntime = runtime
        activeThreadId = threadId
        activeSurface = surface
        persist(context.applicationContext)
    }

    fun shouldSuppressLocal(runtime: String, threadId: String): Boolean = appLifecycle == "active" && activeRuntime == runtime && activeThreadId == threadId

    fun stableDeviceId(context: Context): String {
        val prefs = context.getSharedPreferences(DEVICE_ID_PREF_NAME, Context.MODE_PRIVATE)
        prefs.getString(DEVICE_ID_PREF_KEY, null)?.let { return it }
        val androidId =
            runCatching {
                android.provider.Settings.Secure.getString(
                    context.contentResolver,
                    android.provider.Settings.Secure.ANDROID_ID,
                )
            }.getOrNull().orEmpty().ifBlank { "android-${System.currentTimeMillis()}" }
        val digest = MessageDigest.getInstance("SHA-256").digest(androidId.toByteArray(Charsets.UTF_8))
        val hex =
            buildString(digest.size * AgentReplyNotificationConstants.HEX_CHARS_PER_BYTE) {
                for (byte in digest) {
                    val value = byte.toInt() and AgentReplyNotificationConstants.BYTE_MASK
                    if (value < AgentReplyNotificationConstants.HEX_PREFIX_THRESHOLD) append('0')
                    append(Integer.toHexString(value))
                }
            }
        prefs.edit().putString(DEVICE_ID_PREF_KEY, hex).apply()
        return hex
    }

    private fun updateLifecycle(context: Context, lifecycle: String) {
        appLifecycle = lifecycle
        persist(context.applicationContext)
    }

    private fun persist(context: Context) {
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
        val now = System.currentTimeMillis()
        val payload =
            mutableMapOf<String, Any>(
                "deviceId" to stableDeviceId(context),
                "platform" to "android",
                "appLifecycle" to appLifecycle,
                "agentNotificationsEnabled" to true,
                "lastSeenAtMillis" to now,
                "updated_at_millis" to now,
            )
        fcmToken?.let { payload["fcm_token"] = it }
        activeRuntime?.let { payload["activeRuntime"] = it }
        activeThreadId?.let { payload["activeThreadId"] = it }
        activeSurface?.let { payload["activeSurface"] = it }

        scope.launch {
            runCatching {
                FirebaseFirestore.getInstance()
                    .collection("users").document(uid)
                    .collection("devices").document(stableDeviceId(context))
                    .set(payload, SetOptions.merge())
                    .await()
            }
        }
    }
}
