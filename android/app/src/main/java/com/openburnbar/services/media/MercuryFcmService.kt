package com.openburnbar.services.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * High-priority FCM listener for Mercury incoming calls. iOS uses APNs +
 * PushKit; Android equivalent is a high-priority FCM data message routed
 * through `FirebaseMessagingService` with a `Notification.CallStyle`.
 *
 * We intentionally avoid `USE_FULL_SCREEN_INTENT`: Play treats it as a
 * declared special access, while Mercury can still expose accept/decline
 * actions and a return-to-call path through the high-priority call
 * notification.
 *
 * Cloud Function `triggerVoIPCall` ships a data message with this
 * envelope:
 *
 * ```
 * data = {
 *   "type": "media_incoming_call",
 *   "connection_id": "<paired Mac connection id>",
 *   "caller_name": "<paired Mac display name>",
 *   "caller_initial": "M",
 *   "feature": "videoCall",
 * }
 * ```
 */
class MercuryFcmService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"]
        if (type == "agent_reply") {
            postAgentReplyNotification(data)
            return
        }
        if (type != "media_incoming_call") return
        val connectionId = data["connection_id"] ?: return
        val callerName = data["caller_name"] ?: "OpenBurnBar"
        val callerInitial = data["caller_initial"] ?: callerName.firstOrNull()?.toString() ?: "M"
        postIncomingCall(
            connectionId = connectionId,
            callerName = callerName,
            callerInitial = callerInitial,
        )
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // Persist the FCM token under the same stable device document that
        // the foreground app heartbeat updates.
        AgentReplyNotificationState.persistToken(applicationContext, token)
    }

    private fun postIncomingCall(connectionId: String, callerName: String, callerInitial: String) {
        MediaSessionForegroundService.ensureNotificationChannel(this)

        val acceptIntent =
            Intent(this, IncomingCallActivity::class.java).apply {
                action = IncomingCallActivity.ACTION_ACCEPT
                putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, connectionId)
                putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
                putExtra(IncomingCallActivity.EXTRA_CALLER_INITIAL, callerInitial)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        val declineIntent =
            Intent(this, IncomingCallActivity::class.java).apply {
                action = IncomingCallActivity.ACTION_DECLINE
                putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, connectionId)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        val pendingFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val acceptPending = PendingIntent.getActivity(this, 1, acceptIntent, pendingFlags)
        val declinePending = PendingIntent.getActivity(this, 2, declineIntent, pendingFlags)

        val builder =
            NotificationCompat.Builder(this, MediaSessionForegroundService.CHANNEL_ID)
                .setSmallIcon(com.openburnbar.R.drawable.ic_mercury_call)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setContentIntent(acceptPending)
                .setContentTitle("Incoming call")
                .setContentText("$callerName is calling")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person =
                Person.Builder()
                    .setName(callerName)
                    .setImportant(true)
                    .build()
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(person, declinePending, acceptPending),
            )
        } else {
            // Pre-Android 12 fallback. CallStyle isn't available before
            // API 31 — use the same Mercury vector glyphs so the
            // notification still looks first-party.
            builder.addAction(com.openburnbar.R.drawable.ic_mercury_call, "Accept", acceptPending)
            builder.addAction(com.openburnbar.R.drawable.ic_mercury_call_end, "Decline", declinePending)
        }

        val notification: Notification = builder.build()
        try {
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification)
        } catch (error: SecurityException) {
            // Missing POST_NOTIFICATIONS permission — log it and persist the real
            // (revoked) permission state so the device doc reflects that incoming
            // calls cannot surface, instead of failing silently.
            Log.w(
                "BurnBar",
                "incoming_call_notification_post_denied connection=$connectionId reason=${error.message}",
            )
            AgentReplyNotificationState.recordPermissionResult(applicationContext, granted = false)
        }
    }

    internal fun ensureAgentReplyChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(AGENT_REPLY_CHANNEL_ID) != null) return
        val channel =
            NotificationChannel(
                AGENT_REPLY_CHANNEL_ID,
                "Agent replies",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifications when an OpenBurnBar agent replies"
            }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val NOTIFICATION_ID = 0x4D435A02
        const val AGENT_REPLY_CHANNEL_ID = "agent_replies"
    }
}
