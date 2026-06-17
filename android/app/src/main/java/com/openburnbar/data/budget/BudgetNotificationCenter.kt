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
import java.util.Locale

private const val HOURS_PER_DAY = 24
private const val DAYS_PER_MONTH = 30
private const val DAYS_PER_YEAR = 365
private const val MINUTES_PER_HOUR = 60
private const val SECONDS_PER_MINUTE = 60
private const val DAYS_PER_WEEK = 7

class BudgetNotificationCenter(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "burnbar_budget"
        private const val PREFS_NAME = "budget_notification_prefs"
        private const val BUDGET_WARNING_TITLE = "Budget warning"
        private const val BUDGET_BLOCK_TITLE = "Budget limit reached"
        private const val BUDGET_GENERIC_TEXT = "Open BurnBar to review budget status."
        private const val BUDGET_FALLBACK_LABEL = "Budget"

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.notificationManager() ?: return
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel =
                NotificationChannel(
                    CHANNEL_ID,
                    "Budget Alerts",
                    NotificationManager.IMPORTANCE_HIGH,
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

        val periodDurationMs =
            when (rule.period) {
                "day" -> HOURS_PER_DAY * MINUTES_PER_HOUR * SECONDS_PER_MINUTE * 1000L
                "week" -> DAYS_PER_WEEK * HOURS_PER_DAY * MINUTES_PER_HOUR * SECONDS_PER_MINUTE * 1000L
                "month" -> DAYS_PER_MONTH * HOURS_PER_DAY * MINUTES_PER_HOUR * SECONDS_PER_MINUTE * 1000L
                else -> DAYS_PER_YEAR * HOURS_PER_DAY * MINUTES_PER_HOUR * SECONDS_PER_MINUTE * 1000L
            }

        if (now - lastWarningTime < periodDurationMs) {
            return
        }

        prefs.edit().putLong(rulePeriodKey, now).apply()

        sendNotification(
            notificationId = rule.id.hashCode() + 1,
            isBlock = false,
            text = budgetStatusText(rule, used, limit, isBlock = false),
        )
    }

    fun emitBlock(rule: BudgetRuleEntity, used: Double, limit: Double) {
        sendNotification(
            notificationId = rule.id.hashCode() + 2,
            isBlock = true,
            text = budgetStatusText(rule, used, limit, isBlock = true),
        )
    }

    private fun sendNotification(notificationId: Int, isBlock: Boolean, text: String) {
        ensureChannel(context)

        val intent =
            Intent(Intent.ACTION_VIEW).apply {
                setClass(context, MainActivity::class.java)
                data = Uri.parse("burnbar://settings/budget")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        val title = if (isBlock) BUDGET_BLOCK_TITLE else BUDGET_WARNING_TITLE

        val pendingIntent =
            PendingIntent.getActivity(
                context,
                notificationId,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        val builder =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("Budget alert")
                .setContentText(BUDGET_GENERIC_TEXT)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .build()

        val privateBuilder =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(builder)

        val nm = context.notificationManager() ?: return
        nm.notify(notificationId, privateBuilder.build())
    }

    private fun budgetStatusText(rule: BudgetRuleEntity, used: Double, limit: Double, isBlock: Boolean): String {
        val label = rule.label?.takeIf { it.isNotBlank() } ?: BUDGET_FALLBACK_LABEL
        val usage = "${formatUsd(used)} of ${formatUsd(limit)}"
        return if (isBlock) {
            "$label reached $usage for this ${rule.period}."
        } else {
            "$label is at $usage for this ${rule.period}."
        }
    }

    private fun formatUsd(value: Double): String = String.format(Locale.US, "\$%.2f", value)
}

private fun Context.notificationManager(): NotificationManager? = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
