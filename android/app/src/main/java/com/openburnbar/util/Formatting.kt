package com.openburnbar.util

import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.*

object Formatting {
    private const val MILLIS_PER_SECOND = 1_000L
    private const val MILLIS_PER_MINUTE = 60 * MILLIS_PER_SECOND
    private const val MILLIS_PER_HOUR = 60 * MILLIS_PER_MINUTE
    private const val MILLIS_PER_DAY = 24 * MILLIS_PER_HOUR
    private const val MILLIS_PER_WEEK = 7 * MILLIS_PER_DAY
    private const val BILLION = 1_000_000_000.0
    private const val MILLION = 1_000_000.0
    private const val THOUSAND = 1_000.0
    private const val DELTA_PERCENT_BASE = 100.0
    private const val TOKENS_BILLION_THRESHOLD = 1_000_000_000L
    private const val TOKENS_MILLION_THRESHOLD = 1_000_000L
    private const val TOKEN_FORMAT_BILLIONS = "%.2f"
    private const val TOKEN_FORMAT_FRACTIONAL = "%.1f"
    private val currencyFormatter =
        NumberFormat.getCurrencyInstance(Locale.US).apply {
            minimumFractionDigits = 2
            maximumFractionDigits = 2
        }

    private val shortCurrencyFormatter =
        NumberFormat.getCurrencyInstance(Locale.US).apply {
            minimumFractionDigits = 0
            maximumFractionDigits = 0
        }

    fun formatCurrency(amount: Double): String = currencyFormatter.format(amount)

    fun formatShortCurrency(amount: Double): String = shortCurrencyFormatter.format(amount)

    fun formatTokens(count: Int): String = formatTokens(count.toLong())

    fun formatTokens(count: Long): String {
        return when {
            count >= TOKENS_BILLION_THRESHOLD -> "${TOKEN_FORMAT_BILLIONS.format(count / BILLION)}B"
            count >= TOKENS_MILLION_THRESHOLD -> "${TOKEN_FORMAT_FRACTIONAL.format(count / MILLION)}M"
            count >= 1_000L -> "${TOKEN_FORMAT_FRACTIONAL.format(count / THOUSAND)}K"
            else -> count.toString()
        }
    }

    fun formatRelativeTime(timestamp: Long): String {
        val now = System.currentTimeMillis()
        val diff = now - timestamp
        return when {
            diff < MILLIS_PER_MINUTE -> "Just now"
            diff < MILLIS_PER_HOUR -> "${diff / MILLIS_PER_MINUTE}m ago"
            diff < MILLIS_PER_DAY -> "${diff / MILLIS_PER_HOUR}h ago"
            diff < MILLIS_PER_WEEK -> "${diff / MILLIS_PER_DAY}d ago"
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
        if (previous == 0.0) return "+${DELTA_PERCENT_BASE.toInt()}%"
        val delta = (current - previous) / previous * DELTA_PERCENT_BASE
        val sign = if (delta >= 0) "+" else ""
        return "${sign}${"%.1f".format(delta)}%"
    }
}
