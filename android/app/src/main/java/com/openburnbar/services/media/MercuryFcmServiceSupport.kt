package com.openburnbar.services.media

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.MainActivity
import kotlinx.coroutines.tasks.await

internal suspend fun MercuryFcmService.buildAgentReplyNotification(data: Map<String, String>): Notification? {
    ensureAgentReplyChannel()
    val eventId = data["event_id"] ?: return null
    val runtime = data["runtime"] ?: "hermes"
    val title = data["title"] ?: "Agent replied"
    val preview = data["preview"] ?: ""
    val threadId = data["thread_id"] ?: resolveThreadId(eventId) ?: return null
    val deepLink = data["deep_link"] ?: "burnbar://assistants/$runtime?threadId=$threadId"
    if (AgentReplyNotificationState.shouldSuppressLocal(runtime, threadId)) return null

    val openIntent =
        Intent(Intent.ACTION_VIEW, Uri.parse(deepLink))
            .setClass(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    val replyIntent =
        Intent().apply {
            setClass(this@buildAgentReplyNotification, AgentReplyNotificationReceiver::class.java)
            action = AgentReplyNotificationReceiver.ACTION_REPLY
            putExtra(AgentReplyNotificationReceiver.EXTRA_EVENT_ID, eventId)
            putExtra(AgentReplyNotificationReceiver.EXTRA_THREAD_ID, threadId)
            putExtra(AgentReplyNotificationReceiver.EXTRA_RUNTIME, runtime)
        }
    val openPending =
        PendingIntent.getActivity(
            this,
            eventId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    val replyPending =
        PendingIntent.getBroadcast(
            this,
            eventId.hashCode(),
            replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
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

internal suspend fun MercuryFcmService.postAgentReplyNotification(data: Map<String, String>) {
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

private suspend fun resolveThreadId(eventId: String): String? {
    val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return null
    return try {
        val snapshot = FirebaseFirestore.getInstance()
            .collection("users").document(uid)
            .collection("agent_notification_events").document(eventId)
            .get()
            .await()
        val threadId = snapshot.getString("threadId")?.trim()
        if (threadId.isNullOrEmpty()) null else threadId
    } catch (_: Exception) {
        null
    }
}
