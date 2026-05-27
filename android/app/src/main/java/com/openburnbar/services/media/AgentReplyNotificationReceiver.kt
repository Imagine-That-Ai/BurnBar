package com.openburnbar.services.media

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.google.firebase.functions.FirebaseFunctions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/**
 * Handles Android notification direct replies for agent messages.
 *
 * The receiver writes the reply into the shared Cloud Functions outbox. The
 * foreground app/runtime drains that command through the same path as an
 * in-app send, which keeps provider routing, auth, and relay semantics aligned
 * across Android/iOS/macOS.
 */
class AgentReplyNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REPLY) return
        val eventId = intent.getStringExtra(EXTRA_EVENT_ID)?.trim().orEmpty()
        val reply = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(KEY_TEXT_REPLY)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (eventId.isEmpty() || reply.isEmpty()) return

        val pending = goAsync()
        CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
            runCatching {
                val stableDeviceId = AgentReplyNotificationState.stableDeviceId(context)
                FirebaseFunctions.getInstance("us-central1")
                    .getHttpsCallable("submitAgentNotificationReply")
                    .call(
                        mapOf(
                            "eventId" to eventId,
                            "replyText" to reply,
                            "deviceId" to stableDeviceId,
                            "clientReplyId" to "${eventId}_${stableDeviceId}_${System.currentTimeMillis()}",
                        )
                    )
                    .await()
                NotificationManagerCompat.from(context).cancel(eventId.hashCode())
            }
            pending.finish()
        }
    }

    companion object {
        const val ACTION_REPLY = "com.openburnbar.agentnotifications.REPLY"
        const val KEY_TEXT_REPLY = "agent_reply_text"
        const val EXTRA_EVENT_ID = "event_id"
        const val EXTRA_THREAD_ID = "thread_id"
        const val EXTRA_RUNTIME = "runtime"
    }
}
