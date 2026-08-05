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

private const val HOURS_PER_DAY = 24
private const val DAYS_PER_MONTH = 30
private const val DAYS_PER_YEAR = 365
private const val MINUTES_PER_HOUR = 60
private const val SECONDS_PER_MINUTE = 60
private const val DAYS_PER_WEEK = 7
private const val BUDGET_ALERT_TITLE = "Budget alert"
private const val BUDGET_GENERIC_TEXT = "Open BurnBar to review budget status."

internal data class BudgetNotificationContent(
    val title: String,
    val text: String,
)

class BudgetNotificationCenter(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "burnbar_budget"
        private const val PREFS_NAME = "budget_notification_prefs"

        internal fun budgetNotificationContent(): BudgetNotificationContent = BudgetNotificationContent(
            title = BUDGET_ALERT_TITLE,
            text = BUDGET_GENERIC_TEXT,
        )

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

    fun emitWarning(rule: BudgetRuleEntity) {
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
        )
    }

    fun emitBlock(rule: BudgetRuleEntity) {
        sendNotification(
            notificationId = rule.id.hashCode() + 2,
        )
    }

    private fun sendNotification(notificationId: Int) {
        ensureChannel(context)

        val intent =
            Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                data = Uri.parse("burnbar://settings/budget")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        intent.setPackage(context.packageName)
        val content = budgetNotificationContent()

        val pendingIntent =
            PendingIntent.getActivity(
                context,
                notificationId,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        val publicVersion = buildBudgetNotification(content, pendingIntent).build()

        val notification =
            buildBudgetNotification(content, pendingIntent)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(publicVersion)
                .build()

        val nm = context.notificationManager() ?: return
        nm.notify(notificationId, notification)
    }

    private fun buildBudgetNotification(content: BudgetNotificationContent, pendingIntent: PendingIntent): NotificationCompat.Builder =
        NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(content.title)
            .setContentText(content.text)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setLocalOnly(true)
}

private fun Context.notificationManager(): NotificationManager? = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
