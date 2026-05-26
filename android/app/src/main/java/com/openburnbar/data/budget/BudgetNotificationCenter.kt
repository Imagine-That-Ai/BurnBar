package com.openburnbar.data.budget

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import com.openburnbar.MainActivity
import com.openburnbar.data.db.BudgetRuleEntity

class BudgetNotificationCenter(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "burnbar_budget"
        private const val PREFS_NAME = "budget_notification_prefs"

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Budget Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Budget limit warnings and hard blocks"
                enableVibration(true)
                setShowBadge(true)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun emitWarning(rule: BudgetRuleEntity, used: Double, limit: Double) {
        val rulePeriodKey = "${rule.id}_${rule.period}"
        val lastWarningTime = prefs.getLong(rulePeriodKey, 0L)
        val now = System.currentTimeMillis()

        val periodDurationMs = when (rule.period) {
            "day" -> 24 * 60 * 60 * 1000L
            "week" -> 7 * 24 * 60 * 60 * 1000L
            "month" -> 30 * 24 * 60 * 60 * 1000L
            else -> 365 * 24 * 60 * 60 * 1000L
        }

        if (now - lastWarningTime < periodDurationMs) {
            return
        }

        prefs.edit().putLong(rulePeriodKey, now).apply()

        sendNotification(
            notificationId = rule.id.hashCode() + 1,
            title = "Budget warning: ${rule.toModel().displayLabel}",
            text = "Approaching limit. Spent $${"%.2f".format(used)} of $${"%.2f".format(limit)}."
        )
    }

    fun emitBlock(rule: BudgetRuleEntity, used: Double, limit: Double) {
        sendNotification(
            notificationId = rule.id.hashCode() + 2,
            title = "Budget BLOCKED: ${rule.toModel().displayLabel}",
            text = "Limit exceeded! Spent $${"%.2f".format(used)} of $${"%.2f".format(limit)}."
        )
    }

    private fun sendNotification(notificationId: Int, title: String, text: String) {
        ensureChannel(context)

        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("burnbar://settings/budget")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            notificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(notificationId, builder.build())
    }
}
