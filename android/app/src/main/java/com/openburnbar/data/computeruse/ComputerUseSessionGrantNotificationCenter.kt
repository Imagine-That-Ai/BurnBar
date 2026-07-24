package com.openburnbar.data.computeruse

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.openburnbar.MainActivity

/** Surfaces a background Linux control challenge so the biometric gate can become reachable. */
class ComputerUseSessionGrantNotificationCenter(
    context: Context,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) {
    private val appContext = context.applicationContext
    private val pendingNotifications =
        PendingSessionGrantNotificationSet(
            post = ::postPendingChallenge,
            cancel = ::dismissPendingChallengeTag,
        )

    init {
        dismissOrphanedPendingChallenges()
    }

    fun showPendingChallenge(challengeId: String, expiresAtMillis: Long) {
        pendingNotifications.show(challengeId, sessionGrantNotificationTimeoutMillis(expiresAtMillis, nowMillis()))
    }

    fun dismissPendingChallenge(challengeId: String) {
        pendingNotifications.dismiss(challengeId)
    }

    private fun postPendingChallenge(challengeId: String, timeoutMillis: Long) {
        ensureChannel()
        // Configured statement by statement rather than through `apply {}`: the
        // package is pinned on `intent` itself, which is what makes the target
        // explicit both at runtime and to static analysis. Pinning it on the
        // receiver inside an `apply` lambda hides it from the latter.
        val intent = Intent(appContext, MainActivity::class.java)
        intent.setPackage(appContext.packageName)
        intent.action = Intent.ACTION_VIEW
        intent.data = Uri.parse("burnbar://computer-use/session-grant/${Uri.encode(challengeId)}")
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val pendingIntent =
            PendingIntent.getActivity(
                appContext,
                challengeId.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val notification =
            NotificationCompat.Builder(appContext, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("Linux control request")
                .setContentText("Open OpenBurnBar to review this time-limited request.")
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setLocalOnly(true)
                .setTimeoutAfter(timeoutMillis)
                .build()
        runCatching { notificationManager()?.notify(notificationTag(challengeId), NOTIFICATION_ID, notification) }
            .onFailure { Log.w(TAG, "Unable to post Linux control request notification: ${it.message}") }
    }

    private fun dismissPendingChallengeTag(challengeId: String) {
        notificationManager()?.cancel(notificationTag(challengeId), NOTIFICATION_ID)
    }

    private fun dismissOrphanedPendingChallenges() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val manager = notificationManager() ?: return
        runCatching {
            manager.activeNotifications
                .filter { it.id == NOTIFICATION_ID && it.tag?.startsWith(NOTIFICATION_TAG_PREFIX) == true }
                .forEach { manager.cancel(it.tag, it.id) }
        }.onFailure { Log.w(TAG, "Unable to clear orphaned Linux control notifications: ${it.message}") }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager() ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Computer Use Requests",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Time-limited requests to control an OpenBurnBar desktop session"
                enableVibration(true)
                setShowBadge(true)
            },
        )
    }

    private fun notificationManager(): NotificationManager? = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private companion object {
        private const val TAG = "BurnBar"
        private const val CHANNEL_ID = "burnbar_computer_use_requests"
        private const val NOTIFICATION_ID = 0x4355
        private const val NOTIFICATION_TAG_PREFIX = "computer-use-session-grant:"

        private fun notificationTag(challengeId: String): String = "$NOTIFICATION_TAG_PREFIX$challengeId"
    }
}

internal class PendingSessionGrantNotificationSet(
    private val post: (String, Long) -> Unit,
    private val cancel: (String) -> Unit,
) {
    private val activeChallengeIds = mutableSetOf<String>()

    fun show(challengeId: String, timeoutMillis: Long) {
        require(challengeId.isNotBlank())
        require(timeoutMillis > 0L)
        val shouldPost = synchronized(activeChallengeIds) { activeChallengeIds.add(challengeId) }
        if (shouldPost) post(challengeId, timeoutMillis)
    }

    fun dismiss(challengeId: String) {
        val shouldDismiss = synchronized(activeChallengeIds) { activeChallengeIds.remove(challengeId) }
        if (shouldDismiss) cancel(challengeId)
    }
}

internal fun sessionGrantNotificationTimeoutMillis(expiresAtMillis: Long, nowMillis: Long): Long =
    (expiresAtMillis - nowMillis).coerceIn(1L, ComputerUseSessionGrantChallengeValidator.MAXIMUM_LIFETIME_SECONDS * 1_000L)
