package com.openburnbar.util

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs

/**
 * Formats a provider quota bucket's reset moment into the same
 * "relative · absolute" pair every other platform uses (Mac micro-badge,
 * iOS [UnifiedQuotaSignalView] reset row, Smart Hub cast page).
 *
 * Example output: `"in 2h 14m · May 8, 3:35 AM"`.
 *
 * Returns `null` when the input is `null` so callers can suppress the
 * reset row entirely rather than rendering an empty hint.
 */
object QuotaResetFormatter {

    /** Convenience: combined "relative · absolute" line. */
    fun combinedLabel(
        resetsAt: Instant?,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String? {
        val parts = resetsAt?.let { format(it, now, zone, locale) } ?: return null
        return "${parts.relative} · ${parts.absolute}"
    }

    /** Split form for callers that want to style each half independently. */
    fun format(
        resetsAt: Instant,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): Parts {
        return Parts(
            relative = relativeLabel(resetsAt, now),
            absolute = absoluteLabel(resetsAt, zone, locale),
        )
    }

    data class Parts(val relative: String, val absolute: String)

    private fun relativeLabel(resetsAt: Instant, now: Instant): String {
        val delta = Duration.between(now, resetsAt)
        val seconds = delta.seconds
        val past = seconds < 0
        val abs = abs(seconds)

        // Same bucketing the Swift `RelativeDateTimeFormatter` produces at
        // the `.abbreviated` style so the two platforms read interchangeably.
        val core = when {
            abs < 60 -> "${abs}s"
            abs < 3600 -> "${abs / 60}m"
            abs < 24 * 3600 -> {
                val h = abs / 3600
                val m = (abs % 3600) / 60
                if (m > 0) "${h}h ${m}m" else "${h}h"
            }
            abs < 7 * 24 * 3600 -> {
                val d = abs / (24 * 3600)
                val h = (abs % (24 * 3600)) / 3600
                if (h > 0) "${d}d ${h}h" else "${d}d"
            }
            else -> "${abs / (24 * 3600)}d"
        }
        return if (past) "$core ago" else "in $core"
    }

    private fun absoluteLabel(
        resetsAt: Instant,
        zone: ZoneId,
        locale: Locale,
    ): String {
        val formatter = DateTimeFormatter
            .ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(locale)
            .withZone(zone)
        return formatter.format(resetsAt)
    }
}
