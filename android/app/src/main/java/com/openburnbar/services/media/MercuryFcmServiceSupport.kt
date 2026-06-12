package com.openburnbar.services.media

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.openburnbar.MainActivity

internal fun MercuryFcmService.buildAgentReplyNotification(data: Map<String, String>): Notification? {
    ensureAgentReplyChannel()
    val eventId = data["event_id"] ?: return null
    val threadId = data["thread_id"] ?: return null
    val runtime = data["runtime"] ?: "hermes"
    val title = data["title"] ?: "Agent replied"
    val preview = data["preview"] ?: ""
    val deepLink = data["deep_link"] ?: "burnbar://assistants/$runtime?threadId=$threadId"
    if (AgentReplyNotificationState.shouldSuppressLocal(runtime, threadId)) return null

    val openIntent =
        Intent(Intent.ACTION_VIEW, Uri.parse(deepLink), this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    val replyIntent =
        Intent(this, AgentReplyNotificationReceiver::class.java).apply {
            action = AgentReplyNotificationReceiver.ACTION_REPLY
            putExtra(AgentReplyNotificationReceiver.EXTRA_EVENT_ID, eventId)
            putExtra(AgentReplyNotificationReceiver.EXTRA_THREAD_ID, threadId)
            putExtra(AgentReplyNotificationReceiver.EXTRA_RUNTIME, runtime)
        }
    val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_MUTABLE else 0
    val immutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
    val openPending =
        PendingIntent.getActivity(
            this,
            eventId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag,
        )
    val replyPending =
        PendingIntent.getBroadcast(
            this,
            eventId.hashCode(),
            replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
        )
    val remoteInput =
        RemoteInput.Builder(AgentReplyNotificationReceiver.KEY_TEXT_REPLY)
            .setLabel("Reply to agent")
            .build()
    val replyAction =
        NotificationCompat.Action.Builder(
            com.openburnbar.R.drawable.ic_mercury_call,
            "Reply",
            replyPending,
        ).addRemoteInput(remoteInput).setAllowGeneratedReplies(true).build()

    return NotificationCompat.Builder(this, MercuryFcmService.AGENT_REPLY_CHANNEL_ID)
        .setSmallIcon(com.openburnbar.R.drawable.ic_mercury_call)
        .setContentTitle(title)
        .setContentText(preview)
        .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
        .setContentIntent(openPending)
        .setAutoCancel(true)
        .setCategory(NotificationCompat.CATEGORY_MESSAGE)
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .addAction(replyAction)
        .build()
}

internal fun MercuryFcmService.postAgentReplyNotification(data: Map<String, String>) {
    val notification = buildAgentReplyNotification(data) ?: return
    val eventId = data["event_id"] ?: return
    try {
        NotificationManagerCompat.from(this).notify(eventId.hashCode(), notification)
    } catch (error: SecurityException) {
        // Missing POST_NOTIFICATIONS permission — log it and persist the real
        // (revoked) permission state so the cloud fan-out stops targeting this
        // device instead of marking dropped pushes "sent".
        android.util.Log.w(
            "BurnBar",
            "agent_reply_notification_post_denied event=$eventId reason=${error.message}",
        )
        AgentReplyNotificationState.recordPermissionResult(applicationContext, granted = false)
    }
}
