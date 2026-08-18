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
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.openburnbar.data.policy.MobileNavigationDecision
import com.openburnbar.data.policy.MobileOsDestination
import com.openburnbar.data.policy.MobileOsIntegrationPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

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
 *   "correlation_id": "<fresh per-push id>",
 *   "caller_name": "Incoming call",
 *   "caller_initial": "I",
 *   "feature": "videoCall",
 * }
 * ```
 *
 * The stable paired-Mac connection id is resolved from an owner-scoped,
 * TTL-bound Firestore context keyed by `correlation_id`; it is never required
 * in the third-party FCM payload.
 */
class MercuryFcmService : FirebaseMessagingService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"]
        val envelope = MobileOsIntegrationPolicy.envelope(data)
        val routed = MobileOsIntegrationPolicy.route(envelope)
        val granted = AgentReplyNotificationState.notificationsEnabled(this)
        val isIncomingCall = type == "media_incoming_call"
        if (!MobileOsIntegrationPolicy.mayDeliver(granted)) {
            AgentReplyNotificationState.recordPermissionResult(this, granted = false)
            return
        }
        val decision = MobileOsIntegrationPolicy.navigation(
            envelope = envelope,
            activeUid = FirebaseAuth.getInstance().currentUser?.uid,
            nowMs = System.currentTimeMillis(),
            lastConsumedEventId = AgentReplyNotificationState.lastConsumedEventId,
            permissionGranted = granted,
        )
        if (decision != MobileNavigationDecision.NAVIGATE) {
            return
        }
        if (type == "agent_reply") {
            serviceScope.launch { postAgentReplyNotification(data) }
            return
        }
        if (type == "ai_inbox_item") {
            postAIInboxNotification(data)
            return
        }
        // Quota and mission pushes have no bespoke surface — the policy's
        // destination is the whole routing decision.
        if (routed.destination == MobileOsDestination.BURN || routed.destination == MobileOsDestination.MISSION) {
            postRoutedOsNotification(data)
            return
        }
        if (!isIncomingCall) return
        serviceScope.launch {
            val routing = resolveIncomingCallRouting(data) ?: return@launch
            postIncomingCall(
                connectionId = routing.connectionId,
                callerName = routing.callerName,
                callerInitial = routing.callerInitial,
            )
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // Persist the FCM token under the same stable device document that
        // the foreground app heartbeat updates.
        AgentReplyNotificationState.persistToken(applicationContext, token)
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
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
        acceptIntent.setPackage(packageName)
        val declineIntent =
            Intent(this, IncomingCallActivity::class.java).apply {
                action = IncomingCallActivity.ACTION_DECLINE
                putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, connectionId)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
        declineIntent.setPackage(packageName)
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
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
                "incoming_call_notification_post_denied reason=${error.message}",
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

    /**
     * Its own channel, not the agent-reply one: inbox alerts and chat replies
     * are different enough that a user who mutes one should keep the other.
     */
    internal fun ensureInboxChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(INBOX_CHANNEL_ID) != null) return
        val channel =
            NotificationChannel(
                INBOX_CHANNEL_ID,
                "Inbox alerts",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Urgent findings from the OpenBurnBar AI Inbox"
            }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val NOTIFICATION_ID = 0x4D435A02
        const val AGENT_REPLY_CHANNEL_ID = "agent_replies"
        const val INBOX_CHANNEL_ID = "burnbar_inbox"
    }
}
