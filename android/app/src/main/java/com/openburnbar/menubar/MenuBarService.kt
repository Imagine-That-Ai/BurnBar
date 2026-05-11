package com.openburnbar.menubar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import com.openburnbar.MainActivity
import com.openburnbar.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Foreground service that owns the persistent BurnBar notification — the
 * Android-side stand-in for the iOS menu-bar label. The service collects
 * [MenuBarController.snapshot] and re-renders the notification each time a
 * new snapshot arrives.
 *
 * Users can suppress this notification via `Settings → BurnBar → Quick glance
 * notification`; the controlling setting persists in [SuppressionStore] and
 * the service stops itself when suppression is enabled.
 */
class MenuBarService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var collectorJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
        startForegroundWithSnapshot(MenuBarController.snapshot.value)
        collectorJob = scope.launch {
            MenuBarController.snapshot.collectLatest { snap ->
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, buildNotification(this@MenuBarService, snap))
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onDestroy() {
        collectorJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private fun startForegroundWithSnapshot(snap: MenuBarSnapshot) {
        val notification = buildNotification(this, snap)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForegroundDataSync(notification)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun startForegroundDataSync(notification: Notification) {
        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
    }

    companion object {
        const val CHANNEL_ID = "burnbar.menubar"
        const val NOTIFICATION_ID = 0xBBA12

        fun start(context: Context) {
            if (!SuppressionStore.allowed(context)) return
            val intent = Intent(context, MenuBarService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MenuBarService::class.java))
        }

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Quick glance",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "BurnBar cost glance bar"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(channel)
        }

        fun buildNotification(context: Context, snap: MenuBarSnapshot): Notification {
            val openDashboard = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    data = android.net.Uri.parse("burnbar://dashboard")
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val title = "BurnBar — ${MenuBarController.formatCost(snap.costToday)} today"
            val sub = if (snap.streaming) "Hermes is thinking…"
                else "Δ ${MenuBarController.formatCost(snap.costToday - snap.costYesterday)} vs. yesterday"

            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(sub)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setContentIntent(openDashboard)
                .setShowWhen(false)
                .build()
        }
    }
}
