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

private object TimeThresholds {
    const val SECONDS_PER_MINUTE = 60L
    const val SECONDS_PER_HOUR = 60L * SECONDS_PER_MINUTE
    const val SECONDS_PER_DAY = 24L * SECONDS_PER_HOUR
    const val SECONDS_PER_WEEK = 7L * SECONDS_PER_DAY
    const val HOURS_FIVE = 5L
    const val DAYS_SEVEN = 7L
    const val DAYS_ONE = 1L
    const val MONTH_ADVANCE_MAX_STEPS = 60
}

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
    private const val SECONDS_PER_MINUTE = 60L
    private const val SECONDS_PER_HOUR = 3600L
    private const val SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR
    private const val SECONDS_PER_WEEK = 7 * SECONDS_PER_DAY
    private const val HOURS_FIVE = 5L
    private const val DAYS_SEVEN = 7L
    private const val DAYS_ONE = 1L
    private const val MONTH_ADVANCE_MAX_STEPS = 60

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

    private fun displayResetInstant(resetsAt: Instant, windowLabel: String?, now: Instant, zone: ZoneId): Instant? {
        if (resetsAt.isAfter(now)) return resetsAt

        val marker = windowLabel.orEmpty().lowercase(Locale.US)
        return when {
            marker.contains("5") || marker.contains("five") ->
                advance(resetsAt, Duration.ofHours(TimeThresholds.HOURS_FIVE), now)
            marker.contains("7") || marker.contains("seven") || marker.contains("week") ->
                advance(resetsAt, Duration.ofDays(TimeThresholds.DAYS_SEVEN), now)
            marker.contains("day") ->
                advance(resetsAt, Duration.ofDays(TimeThresholds.DAYS_ONE), now)
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
        repeat(TimeThresholds.MONTH_ADVANCE_MAX_STEPS) {
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
        val core =
            when {
                abs < TimeThresholds.SECONDS_PER_MINUTE -> "${abs}s"
                abs < TimeThresholds.SECONDS_PER_HOUR -> "${abs / TimeThresholds.SECONDS_PER_MINUTE}m"
                abs < TimeThresholds.SECONDS_PER_DAY -> {
                    val h = abs / TimeThresholds.SECONDS_PER_HOUR
                    val m = abs % TimeThresholds.SECONDS_PER_HOUR / TimeThresholds.SECONDS_PER_MINUTE
                    if (m > 0) "${h}h ${m}m" else "${h}h"
                }
                abs < TimeThresholds.SECONDS_PER_WEEK -> {
                    val d = abs / TimeThresholds.SECONDS_PER_DAY
                    val h = abs % TimeThresholds.SECONDS_PER_DAY / TimeThresholds.SECONDS_PER_HOUR
                    if (h > 0) "${d}d ${h}h" else "${d}d"
                }
                else -> "${abs / TimeThresholds.SECONDS_PER_DAY}d"
            }
        return "in $core"
    }

    private fun absoluteLabel(resetsAt: Instant, zone: ZoneId, locale: Locale): String {
        val formatter =
            DateTimeFormatter
                .ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
                .withLocale(locale)
                .withZone(zone)
        return formatter.format(resetsAt)
    }
}
