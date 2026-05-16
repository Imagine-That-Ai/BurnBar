package com.openburnbar.services.media

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/**
 * High-priority FCM listener for Mercury incoming calls. iOS uses APNs +
 * PushKit; Android equivalent is a high-priority FCM data message routed
 * through `FirebaseMessagingService` with a `Notification.CallStyle`
 * full-screen-intent pinned to `IncomingCallActivity`.
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
        // Persist the FCM token under the same `users/{uid}/devices/{deviceId}/fcm_token`
        // path the iOS APNs branch writes to. The Cloud Function reads
        // whichever variant is present per device.
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
        val deviceId = android.provider.Settings.Secure.getString(
            applicationContext.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        ) ?: "android"
        GlobalScope.launch {
            runCatching {
                FirebaseFirestore.getInstance()
                    .collection("users").document(uid)
                    .collection("devices").document(deviceId)
                    .set(
                        mapOf(
                            "fcm_token" to token,
                            "platform" to "android",
                            "updated_at_millis" to System.currentTimeMillis(),
                        ),
                        com.google.firebase.firestore.SetOptions.merge(),
                    )
                    .await()
            }
        }
    }

    private fun postIncomingCall(connectionId: String, callerName: String, callerInitial: String) {
        MediaSessionForegroundService.ensureNotificationChannel(this)

        val acceptIntent = Intent(this, IncomingCallActivity::class.java).apply {
            action = IncomingCallActivity.ACTION_ACCEPT
            putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, connectionId)
            putExtra(IncomingCallActivity.EXTRA_CALLER_NAME, callerName)
            putExtra(IncomingCallActivity.EXTRA_CALLER_INITIAL, callerInitial)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val declineIntent = Intent(this, IncomingCallActivity::class.java).apply {
            action = IncomingCallActivity.ACTION_DECLINE
            putExtra(IncomingCallActivity.EXTRA_CONNECTION_ID, connectionId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val acceptPending = PendingIntent.getActivity(this, 1, acceptIntent, pendingFlags)
        val declinePending = PendingIntent.getActivity(this, 2, declineIntent, pendingFlags)
        val fullScreenPending = PendingIntent.getActivity(this, 3, acceptIntent, pendingFlags)

        val builder = NotificationCompat.Builder(this, MediaSessionForegroundService.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(fullScreenPending, true)
            .setContentTitle("Incoming call")
            .setContentText("$callerName is calling")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(callerName)
                .setImportant(true)
                .build()
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(person, declinePending, acceptPending)
            )
        } else {
            builder.addAction(android.R.drawable.ic_menu_call, "Accept", acceptPending)
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", declinePending)
        }

        val notification: Notification = builder.build()
        try {
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Missing POST_NOTIFICATIONS permission — fall through silently.
        }
    }

    companion object {
        const val NOTIFICATION_ID = 0x4D435A02
    }
}
