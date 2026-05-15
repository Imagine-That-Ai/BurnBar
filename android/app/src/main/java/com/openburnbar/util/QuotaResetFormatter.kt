package com.openburnbar.util

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor

/**
 * Formats a provider quota bucket's reset moment into the same
 * "relative · absolute" pair every other platform uses (Mac micro-badge,
 * iOS [UnifiedQuotaSignalView] reset row, Smart Hub cast page).
 *
 * Example output: `"in 2h 14m · May 8, 3:35 AM"`.
 *
 * Returns `null` when the input is `null`, or when it is in the past and
 * the quota window cannot be inferred well enough to advance it.
 */
object QuotaResetFormatter {

    /** Convenience: combined "relative · absolute" line. */
    fun combinedLabel(
        resetsAt: Instant?,
        windowLabel: String? = null,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String? {
        val parts = resetsAt?.let { format(it, windowLabel, now, zone, locale) } ?: return null
        return "${parts.relative} · ${parts.absolute}"
    }

    /** Split form for callers that want to style each half independently. */
    fun format(
        resetsAt: Instant,
        windowLabel: String? = null,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): Parts? {
        val displayReset = displayResetInstant(resetsAt, windowLabel, now, zone) ?: return null
        return Parts(
            relative = relativeLabel(displayReset, now),
            absolute = absoluteLabel(displayReset, zone, locale),
        )
    }

    data class Parts(val relative: String, val absolute: String)

    private fun displayResetInstant(
        resetsAt: Instant,
        windowLabel: String?,
        now: Instant,
        zone: ZoneId,
    ): Instant? {
        if (resetsAt.isAfter(now)) return resetsAt

        val marker = windowLabel.orEmpty().lowercase(Locale.US)
        return when {
            marker.contains("5") || marker.contains("five") ->
                advance(resetsAt, Duration.ofHours(5), now)
            marker.contains("7") || marker.contains("seven") || marker.contains("week") ->
                advance(resetsAt, Duration.ofDays(7), now)
            marker.contains("day") ->
                advance(resetsAt, Duration.ofDays(1), now)
            marker.contains("month") ->
                advanceMonthly(resetsAt, now, zone)
            else -> null
        }
    }

    private fun advance(resetsAt: Instant, interval: Duration, now: Instant): Instant {
        val elapsedSeconds = Duration.between(resetsAt, now).seconds.coerceAtLeast(0)
        val steps = floor(elapsedSeconds.toDouble() / interval.seconds.toDouble()).toLong() + 1
        val candidate = resetsAt.plus(interval.multipliedBy(steps))
        return if (candidate.isAfter(now)) candidate else candidate.plus(interval)
    }

    private fun advanceMonthly(resetsAt: Instant, now: Instant, zone: ZoneId): Instant? {
        var candidate = ZonedDateTime.ofInstant(resetsAt, zone)
        repeat(60) {
            candidate = candidate.plusMonths(1)
            if (candidate.toInstant().isAfter(now)) return candidate.toInstant()
        }
        return null
    }

    private fun relativeLabel(resetsAt: Instant, now: Instant): String {
        val delta = Duration.between(now, resetsAt)
        val seconds = delta.seconds
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
        return "in $core"
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
