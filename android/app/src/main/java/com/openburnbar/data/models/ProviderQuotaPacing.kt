package com.openburnbar.data.models

import com.openburnbar.data.stores.QuotaWindowKind
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.roundToInt

private val FIVE_HOUR_WINDOW: Duration = Duration.ofHours(5)
private val SEVEN_DAY_WINDOW: Duration = Duration.ofDays(7)
private val FALLBACK_MONTH: Duration = Duration.ofDays(30)

enum class PaceSeverity {
    ON_PACE,
    AHEAD_OF_BUDGET,
    BEHIND_BUDGET
}

data class IdealPace(
    val windowStart: Instant,
    val windowEnd: Instant,
    val elapsedFraction: Double,
    val usedFraction: Double,
    val delta: Double,
    val severity: PaceSeverity,
    val humanLabel: String
)

object PacingMath {
    const val ON_PACE_THRESHOLD = 0.03

    fun windowDuration(
        kind: QuotaWindowKind,
        resetsAt: Instant,
        zoneId: ZoneId = ZoneId.systemDefault()
    ): Duration? {
        return when (kind) {
            QuotaWindowKind.FIVE_HOUR -> FIVE_HOUR_WINDOW
            QuotaWindowKind.DAILY -> Duration.ofDays(1)
            QuotaWindowKind.SEVEN_DAY -> SEVEN_DAY_WINDOW
            QuotaWindowKind.MONTHLY -> {
                try {
                    val zonedDateTime = resetsAt.atZone(zoneId)
                    val start = zonedDateTime.minusMonths(1)
                    val duration = Duration.between(start, zonedDateTime)
                    if (duration.isNegative || duration.isZero) {
                        FALLBACK_MONTH
                    } else {
                        duration
                    }
                } catch (ignored: Exception) {
                    FALLBACK_MONTH
                }
            }
            QuotaWindowKind.REQUEST, QuotaWindowKind.OTHER -> null
        }
    }

    fun pace(
        windowKind: QuotaWindowKind,
        resetsAt: Instant?,
        progressFraction: Double,
        now: Instant = Instant.now(),
        zoneId: ZoneId = ZoneId.systemDefault()
    ): IdealPace? {
        resetsAt ?: return null
        val duration = windowDuration(windowKind, resetsAt, zoneId) ?: return null
        val durationSecs = duration.seconds
        if (durationSecs <= 0) return null

        val windowEnd: Instant
        val windowStart: Instant
        val elapsedFraction: Double

        if (now.isAfter(resetsAt)) {
            // Snapshot is stale, assume next window started at resetsAt
            windowEnd = resetsAt.plus(duration)
            windowStart = resetsAt
            elapsedFraction = 0.0
        } else {
            windowEnd = resetsAt
            windowStart = resetsAt.minus(duration)
            val elapsedSecs = Duration.between(windowStart, now).seconds
            val raw = elapsedSecs.toDouble() / durationSecs.toDouble()
            elapsedFraction = raw.coerceIn(0.0, 1.0)
        }

        val used = progressFraction.coerceIn(0.0, 1.0)
        val delta = used - elapsedFraction
        val severity = when {
            abs(delta) < ON_PACE_THRESHOLD -> PaceSeverity.ON_PACE
            delta > 0 -> PaceSeverity.AHEAD_OF_BUDGET
            else -> PaceSeverity.BEHIND_BUDGET
        }

        return IdealPace(
            windowStart = windowStart,
            windowEnd = windowEnd,
            elapsedFraction = elapsedFraction,
            usedFraction = used,
            delta = delta,
            severity = severity,
            humanLabel = humanLabel(delta, severity)
        )
    }

    fun humanLabel(delta: Double, severity: PaceSeverity): String {
        return when (severity) {
            PaceSeverity.ON_PACE -> "on pace"
            PaceSeverity.AHEAD_OF_BUDGET -> "+${(delta * 100).roundToInt()}% pace"
            PaceSeverity.BEHIND_BUDGET -> "${(delta * 100).roundToInt()}% pace"
        }
    }
}

fun QuotaBucket.idealPace(now: Instant = Instant.now(), zoneId: ZoneId = ZoneId.systemDefault()): IdealPace? {
    val resetsAt = effectiveResetsAt ?: return null
    val kind = QuotaWindowKind.infer(this)
    val remainingFraction = displayRemainingFraction ?: return null
    val progressFraction = 1.0 - remainingFraction
    return PacingMath.pace(kind, resetsAt, progressFraction, now, zoneId)
}
