package com.openburnbar.services.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.openburnbar.MainActivity

/**
 * Service that owns the persistent Mercury return-to-call notification.
 *
 * The service is intentionally thin — call setup / teardown lives in
 * `CallSessionCoordinator`. It does not capture camera, microphone, or
 * screen content itself, so it deliberately avoids Android foreground
 * service permissions and their Play Console declaration path.
 */
class MediaSessionForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureNotificationChannel(this)
        val notification = buildCallStyleNotification()
        showCallNotification(notification)
        return START_STICKY
    }

    override fun onDestroy() {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    private fun showCallNotification(notification: Notification) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun buildCallStyleNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pendingFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            android.app.PendingIntent.FLAG_IMMUTABLE
        else 0
        val launchPending = android.app.PendingIntent.getActivity(
            this, 0, launchIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or pendingFlag,
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(com.openburnbar.R.drawable.ic_mercury_call)
            .setContentTitle("Mercury call in progress")
            .setContentText("Tap to return to the call")
            .setContentIntent(launchPending)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
        return builder.build()
    }

    companion object {
        const val CHANNEL_ID = "mercury_call_session"
        const val CHANNEL_NAME = "Mercury Calls"
        const val NOTIFICATION_ID = 0x4D435A01

        fun ensureNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Active Mercury call session notification"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        fun start(context: Context) {
            val intent = Intent(context, MediaSessionForegroundService::class.java)
            context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MediaSessionForegroundService::class.java))
        }
    }
}
