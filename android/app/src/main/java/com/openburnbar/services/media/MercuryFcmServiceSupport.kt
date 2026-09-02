package com.openburnbar.services.media

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.MainActivity
import com.openburnbar.MobileOsIntentNavigation
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.policy.MobileOsDestination
import com.openburnbar.data.policy.MobileOsIntegrationPolicy
import kotlinx.coroutines.tasks.await

private const val INCOMING_CALL_CONTEXT_COLLECTION = "incoming_call_contexts"
private const val MAX_CORRELATION_ID_LENGTH = 128
private const val MAX_ROUTING_ID_LENGTH = 160

internal data class IncomingCallRouting(
    val connectionId: String,
    val callerName: String,
    val callerInitial: String,
)

internal object IncomingCallPayloadPolicy {
    fun correlationId(data: Map<String, String>): String? = data["correlation_id"]?.trim()?.takeIf { it.isNotBlank() }

    fun connectionIdFromPush(data: Map<String, String>): String? {
        // Connection ids stay in owner-scoped Firestore context, never FCM.
        if (data["connection_id"] != null || data["connectionId"] != null) return null
        return null
    }

    suspend fun resolveConnectionId(data: Map<String, String>, lookup: suspend (correlationId: String) -> String?): String? {
        connectionIdFromPush(data)?.let { return it }
        val correlation = correlationId(data) ?: return null
        return lookup(correlation)
    }
}

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
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            this.data = Uri.parse(deepLink)
            MobileOsIntentNavigation.putEnvelopeExtras(this, data)
            putExtra(MainActivity.EXTRA_EVENT_ID, eventId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
    openIntent.setPackage(packageName)
    val replyIntent =
        Intent(this, AgentReplyNotificationReceiver::class.java).apply {
            action = AgentReplyNotificationReceiver.ACTION_REPLY
            putExtra(AgentReplyNotificationReceiver.EXTRA_EVENT_ID, eventId)
            putExtra(AgentReplyNotificationReceiver.EXTRA_THREAD_ID, threadId)
            putExtra(AgentReplyNotificationReceiver.EXTRA_RUNTIME, runtime)
        }
    replyIntent.setPackage(packageName)
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
        .addAction(buildAgentReplyAction(replyPending))
        .build()
}

private fun buildAgentReplyAction(replyPending: PendingIntent): NotificationCompat.Action {
    val remoteInput =
        RemoteInput.Builder(AgentReplyNotificationReceiver.KEY_TEXT_REPLY)
            .setLabel("Reply to agent")
            .build()
    return NotificationCompat.Action.Builder(
        com.openburnbar.R.drawable.ic_mercury_call,
        "Reply",
        replyPending,
    ).addRemoteInput(remoteInput).setAllowGeneratedReplies(true).build()
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

internal fun MercuryFcmService.postRoutedOsNotification(data: Map<String, String>) {
    ensureAgentReplyChannel()
    val routed = MobileOsIntegrationPolicy.route(data)
    val deepLink = routed.deepLink ?: return
    val eventId = data["event_id"] ?: deepLink
    val title = when (routed.destination) {
        MobileOsDestination.BURN -> "Quota update"
        MobileOsDestination.MISSION -> "Mission update"
        else -> "OpenBurnBar"
    }
    val openIntent =
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            this.data = Uri.parse(deepLink)
            MobileOsIntentNavigation.putEnvelopeExtras(this, data)
            putExtra(MainActivity.EXTRA_EVENT_ID, eventId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
    openIntent.setPackage(packageName)
    val openPending =
        PendingIntent.getActivity(
            this,
            eventId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    val notification =
        NotificationCompat.Builder(this, MercuryFcmService.AGENT_REPLY_CHANNEL_ID)
            .setSmallIcon(com.openburnbar.R.drawable.ic_mercury_call)
            .setContentTitle(title)
            .setContentText("Open OpenBurnBar to continue.")
            .setContentIntent(openPending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
    try {
        NotificationManagerCompat.from(this).notify(eventId.hashCode(), notification)
    } catch (error: SecurityException) {
        android.util.Log.w(
            "BurnBar",
            "routed_notification_post_denied event=$eventId reason=${error.message}",
        )
        AgentReplyNotificationState.recordPermissionResult(applicationContext, granted = false)
    }
}

internal fun MercuryFcmService.postDeviceApprovalNotification(data: Map<String, String>) {
    ensureAgentReplyChannel()
    val deviceName = data["device_name"] ?: "New device"
    val platform = data["platform"] ?: "Web"
    val deviceId = data["device_id"] ?: ""
    val deepLink = data["deep_link"] ?: "openburnbar://approve-device?deviceId=${Uri.encode(deviceId)}"
    val envelope = MobileOsIntegrationPolicy.envelope(data)
    val eventId = envelope.eventId.ifBlank { "device-approval-$deviceId" }

    val openIntent =
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            this.data = Uri.parse(deepLink)
            MobileOsIntentNavigation.putEnvelopeExtras(this, data)
            putExtra(MainActivity.EXTRA_EVENT_ID, eventId)
            putExtra(MainActivity.EXTRA_PUSH_TYPE, "device_approval_request")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
    openIntent.setPackage(packageName)
    val openPending =
        PendingIntent.getActivity(
            this,
            eventId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    val notification =
        NotificationCompat.Builder(this, MercuryFcmService.AGENT_REPLY_CHANNEL_ID)
            .setSmallIcon(com.openburnbar.R.drawable.ic_mercury_call)
            .setContentTitle("New Device Approval Request")
            .setContentText("$deviceName ($platform) is requesting access to your vault.")
            .setContentIntent(openPending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
    try {
        NotificationManagerCompat.from(this).notify(eventId.hashCode(), notification)
    } catch (error: SecurityException) {
        android.util.Log.w(
            "BurnBar",
            "device_approval_notification_post_denied event=$eventId reason=${error.message}",
        )
    }
}

private suspend fun resolveThreadId(eventId: String): String? {
    val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return null
    return try {
        val snapshot = FirestoreRepository.database()
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

internal suspend fun MercuryFcmService.resolveIncomingCallRouting(data: Map<String, String>): IncomingCallRouting? {
    val callerName = data["caller_name"]?.trim()?.takeIf { it.isNotBlank() } ?: "Incoming call"
    val callerInitial = data["caller_initial"]?.trim()?.takeIf { it.isNotBlank() }
        ?: callerName.firstOrNull()?.toString()
        ?: "I"
    val connectionId = IncomingCallPayloadPolicy.resolveConnectionId(data) { correlationId ->
        resolveIncomingCallContextConnectionId(correlationId)
    } ?: return null
    return IncomingCallRouting(
        connectionId = connectionId,
        callerName = callerName,
        callerInitial = callerInitial,
    )
}

private suspend fun resolveIncomingCallContextConnectionId(rawCorrelationId: String?): String? {
    val correlationId = normalizedCorrelationId(rawCorrelationId) ?: return null
    val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return null
    return try {
        val snapshot = FirestoreRepository.database()
            .collection("users").document(uid)
            .collection(INCOMING_CALL_CONTEXT_COLLECTION).document(correlationId)
            .get()
            .await()
        if (!snapshot.exists()) return null
        val expireAtMillis = snapshot.getTimestamp("expireAt")?.toDate()?.time
        if (expireAtMillis != null && expireAtMillis <= System.currentTimeMillis()) return null
        normalizedRoutingId(snapshot.getString("connectionId"))
    } catch (_: Exception) {
        null
    }
}

private fun normalizedCorrelationId(value: String?): String? {
    val normalized = value?.trim()?.takeIf { it.isNotBlank() } ?: return null
    if (normalized.length > MAX_CORRELATION_ID_LENGTH) return null
    if (normalized.contains("/")) return null
    if (CONTROL_OR_BIDI_REGEX.containsMatchIn(normalized)) return null
    return normalized
}

private fun normalizedRoutingId(value: String?): String? {
    val normalized = value?.trim()?.takeIf { it.isNotBlank() } ?: return null
    if (normalized.length > MAX_ROUTING_ID_LENGTH) return null
    if (CONTROL_OR_BIDI_REGEX.containsMatchIn(normalized)) return null
    return normalized
}

private val CONTROL_OR_BIDI_REGEX = Regex("[\\u0000-\\u001f\\u202a-\\u202e]")
