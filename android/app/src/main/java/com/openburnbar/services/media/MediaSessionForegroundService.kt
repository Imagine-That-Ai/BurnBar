package com.openburnbar.services.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.openburnbar.MainActivity

/**
 * Foreground service that keeps a Mercury 1:1 call session alive when
 * the user switches away from BurnBar. Aggregates the granular Android
 * 14+ foreground-service sub-types so a single persistent notification
 * covers microphone + camera + media projection + phone call usage.
 *
 * The service is intentionally thin — call setup / teardown lives in
 * `CallSessionCoordinator`. The service exists to satisfy the
 * `Notification.CallStyle` lifecycle contract: a call must own a
 * persistent CallStyle notification while audio is captured.
 */
class MediaSessionForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureNotificationChannel(this)
        val notification = buildCallStyleNotification()
        startForegroundCompat(notification)
        return START_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MediaSessionForegroundService::class.java))
        }
    }
}
