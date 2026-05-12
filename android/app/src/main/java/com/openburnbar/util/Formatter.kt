package com.openburnbar.util

import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.*

object Formatting {
    private val currencyFormatter = NumberFormat.getCurrencyInstance(Locale.US).apply {
        minimumFractionDigits = 2
        maximumFractionDigits = 2
    }

    private val shortCurrencyFormatter = NumberFormat.getCurrencyInstance(Locale.US).apply {
        minimumFractionDigits = 0
        maximumFractionDigits = 0
    }

    fun formatCurrency(amount: Double): String = currencyFormatter.format(amount)

    fun formatShortCurrency(amount: Double): String = shortCurrencyFormatter.format(amount)

    fun formatTokens(count: Int): String = formatTokens(count.toLong())

    fun formatTokens(count: Long): String {
        return when {
            count >= 1_000_000_000L -> "${"%.2f".format(count / 1_000_000_000.0)}B"
            count >= 1_000_000L -> "${"%.1f".format(count / 1_000_000.0)}M"
            count >= 1_000L -> "${"%.1f".format(count / 1_000.0)}K"
            else -> count.toString()
        }
    }

    fun formatRelativeTime(timestamp: Long): String {
        val now = System.currentTimeMillis()
        val diff = now - timestamp
        return when {
            diff < 60_000 -> "Just now"
            diff < 3_600_000 -> "${diff / 60_000}m ago"
            diff < 86_400_000 -> "${diff / 3_600_000}h ago"
            diff < 604_800_000 -> "${diff / 86_400_000}d ago"
            else -> {
                val sdf = SimpleDateFormat("MMM d", Locale.US)
                sdf.format(Date(timestamp))
            }
        }
    }

    fun formatDate(dateString: String): String {
        return try {
            val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            val date = sdf.parse(dateString) ?: return dateString
            val out = SimpleDateFormat("MMM d", Locale.US)
            out.format(date)
        } catch (_: Exception) {
            dateString
        }
    }

    fun formatDelta(current: Double, previous: Double): String {
        if (previous == 0.0) return "+100%"
        val delta = ((current - previous) / previous) * 100
        val sign = if (delta >= 0) "+" else ""
        return "${sign}${"%.1f".format(delta)}%"
    }
}
