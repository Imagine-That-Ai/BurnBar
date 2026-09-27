package com.openburnbar.data.recap

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

private const val FLAT_DELTA_THRESHOLD = 0.02
private const val FRAC_NEARLY_ALL = 0.85
private const val FRAC_THREE_QUARTERS = 0.70
private const val FRAC_TWO_THIRDS = 0.60
private const val FRAC_HALF = 0.45
private const val FRAC_THIRD = 0.30
private const val FRAC_QUARTER = 0.20
private const val FRAC_TENTH = 0.10
private const val MAX_WEEKDAY_INDEX = 6
private const val MIN_UNIFORMITY_COUNT = 10
private const val Z_SCALE = 0.3
private const val CONFIDENCE_FULL_SAMPLE = 30
private const val CONFIDENCE_MIN = 0.2
private const val NOVELTY_0 = 0.95
private const val NOVELTY_1 = 0.70
private const val NOVELTY_2 = 0.50
private const val NOVELTY_DEFAULT = 0.35

object RecapRuleSupport {

    fun percent(fraction: Double): String {
        val pct = (fraction * RecapConstants.PERCENT_100).roundToInt()
        return "$pct%"
    }

    fun deltaPhrase(delta: Double): String {
        val pct = (abs(delta) * RecapConstants.PERCENT_100).roundToInt()
        return when {
            abs(delta) < FLAT_DELTA_THRESHOLD -> "flat"
            delta > 0 -> "up $pct%"
            else -> "down $pct%"
        }
    }

    fun approximateFraction(fraction: Double): String {
        return when {
            fraction >= FRAC_NEARLY_ALL -> "nearly all"
            fraction >= FRAC_THREE_QUARTERS -> "about three quarters"
            fraction >= FRAC_TWO_THIRDS -> "nearly two thirds"
            fraction >= FRAC_HALF -> "about half"
            fraction >= FRAC_THIRD -> "about a third"
            fraction >= FRAC_QUARTER -> "about a quarter"
            fraction >= FRAC_TENTH -> "about one in ten"
            else -> percent(fraction)
        }
    }

    fun money(amount: Double): String {
        return if (amount >= RecapConstants.PERCENT_100) {
            "$" + amount.roundToInt().toString()
        } else {
            String.format(Locale.US, "$%.2f", amount)
        }
    }

    fun duration(seconds: Double): String {
        val totalMins = (seconds / RecapConstants.SECONDS_PER_MINUTE).roundToInt()
        val hours = totalMins / RecapConstants.MINUTES_PER_HOUR
        val mins = totalMins % RecapConstants.MINUTES_PER_HOUR
        return when {
            hours > 0 && mins > 0 -> "$hours hr $mins min"
            hours > 0 -> "$hours hr${if (hours > 1) "s" else ""}"
            else -> "$totalMins min"
        }
    }

    fun weekdayNames(): List<String> = listOf("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
    fun weekdayPlurals(): List<String> = listOf("Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays")

    fun weekdayName(index: Int): String {
        val names = weekdayNames()
        return names.getOrElse(index.coerceIn(0, MAX_WEEKDAY_INDEX)) { "Day" }
    }

    fun weekdayPlural(index: Int): String {
        val plurals = weekdayPlurals()
        return plurals.getOrElse(index.coerceIn(0, MAX_WEEKDAY_INDEX)) { "Days" }
    }

    fun dayLabel(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val date = Instant.ofEpochMilli(epochMillis).atZone(zone).toLocalDate()
        val formatter = DateTimeFormatter.ofPattern("MMMM d", Locale.getDefault())
        return date.format(formatter)
    }

    fun dayRange(startEpochMillis: Long, endEpochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val sDate = Instant.ofEpochMilli(startEpochMillis).atZone(zone).toLocalDate()
        val eDate = Instant.ofEpochMilli(endEpochMillis).atZone(zone).toLocalDate()
        return if (sDate.monthValue == eDate.monthValue) {
            val month = sDate.format(DateTimeFormatter.ofPattern("MMMM", Locale.getDefault()))
            "$month ${sDate.dayOfMonth}–${eDate.dayOfMonth}"
        } else {
            val f = DateTimeFormatter.ofPattern("MMM d", Locale.getDefault())
            "${sDate.format(f)} – ${eDate.format(f)}"
        }
    }

    fun list(items: List<String>): String {
        return when (items.size) {
            0 -> ""
            1 -> items[0]
            2 -> "${items[0]} and ${items[1]}"
            else -> items.dropLast(1).joinToString(", ") + ", and " + items.last()
        }
    }

    fun rankedEntries(shares: List<RecapShare>, limit: Int = 5): List<RecapRankedEntry> {
        val top = shares.take(limit)
        val maxVal = top.maxOfOrNull { it.costUSD }?.takeIf { it > 0.0 } ?: 1.0
        return top.map {
            RecapRankedEntry(
                key = it.key,
                label = it.label,
                value = it.costUSD,
                fraction = (it.costUSD / maxVal).coerceIn(0.0, 1.0),
                colorSeed = it.key,
            )
        }
    }
}

object RecapStatistics {
    fun clamp(value: Double): Double = value.coerceIn(0.0, 1.0)

    fun twoProportionZ(s1: Int, n1: Int, s2: Int, n2: Int): Double? {
        if (n1 <= 0 || n2 <= 0) return null
        val p1 = s1.toDouble() / n1
        val p2 = s2.toDouble() / n2
        val pPool = (s1 + s2).toDouble() / (n1 + n2)
        val se = sqrt(pPool * (1.0 - pPool) * (1.0 / n1 + 1.0 / n2))
        if (se == 0.0) return null
        return (p1 - p2) / se
    }

    fun significanceFromZ(z: Double): Double {
        val absZ = abs(z)
        return (1.0 - 1.0 / (1.0 + Z_SCALE * absZ)).coerceIn(0.0, 1.0)
    }

    fun uniformityEffect(counts: List<Int>): Double? {
        val total = counts.sum()
        if (total < MIN_UNIFORMITY_COUNT || counts.isEmpty()) return null
        val expected = total.toDouble() / counts.size
        var chi2 = 0.0
        for (c in counts) {
            val diff = c - expected
            chi2 += (diff * diff) / expected
        }
        val v = sqrt(chi2 / (total * (counts.size - 1)))
        return v.coerceIn(0.0, 1.0)
    }

    fun recordMargin(current: Double, previousBest: Double): Double? {
        if (previousBest <= 0.0 || current <= previousBest) return null
        return ((current - previousBest) / previousBest).coerceIn(0.0, 1.0)
    }
}

class RecapContext(
    val facts: RecapFacts,
    val previousMonth: RecapFacts? = null,
    val history: List<RecapFacts> = emptyList(),
) {
    val window: RecapWindow get() = facts.window
    val monthsOfHistory: Int get() = history.size
    val allowsAbsoluteClaims: Boolean get() = !facts.isPartial

    fun average(selector: (RecapFacts) -> Double): Double? {
        if (history.isEmpty()) return null
        val values = history.map(selector)
        return if (values.isNotEmpty()) values.sum() / values.size else null
    }

    fun allTimeBest(selector: (RecapFacts) -> Double): Pair<RecapWindow, Double>? {
        if (history.isEmpty()) return null
        val best = history.maxByOrNull(selector) ?: return null
        val v = selector(best)
        return best.window to v
    }

    fun previousShare(key: String, dimSelector: (RecapFacts) -> List<RecapShare>): RecapShare? {
        return previousMonth?.let { dimSelector(it).firstOrNull { s -> s.key == key } }
    }

    fun monthsWhereTop(key: String, dimSelector: (RecapFacts) -> List<RecapShare>): Int {
        return history.count { dimSelector(it).firstOrNull()?.key == key }
    }

    fun confidence(sampleSize: Int, full: Int = CONFIDENCE_FULL_SAMPLE): Double {
        return (sampleSize.toDouble() / full).coerceIn(CONFIDENCE_MIN, 1.0)
    }

    fun novelty(repeatedInPriorMonths: Int): Double {
        return when (repeatedInPriorMonths) {
            0 -> NOVELTY_0
            1 -> NOVELTY_1
            2 -> NOVELTY_2
            else -> NOVELTY_DEFAULT
        }
    }
}

object RecapRuleEngine {

    fun generateCandidates(ctx: RecapContext): List<RecapCandidate> {
        val rules = listOf<(RecapContext) -> RecapCandidate?>(
            // Fleet Rules
            { RecapFleetRules.favouriteModel(it) },
            { RecapFleetRules.biggestModelGain(it) },
            { RecapFleetRules.biggestModelDecline(it) },
            { RecapFleetRules.favouritePairing(it) },
            { RecapFleetRules.fleetConcentration(it) },
            { RecapFleetRules.newModelsTried(it) },
            // Economy Rules
            { RecapEconomyRules.spendShift(it) },
            { RecapEconomyRules.spendRecord(it) },
            { RecapEconomyRules.cacheEfficiency(it) },
            { RecapEconomyRules.costPerSessionShift(it) },
            { RecapEconomyRules.thinkingShare(it) },
            { RecapEconomyRules.volumeMilestone(it) },
            // Rhythm Rules
            { RecapRhythmRules.weekdayPersonality(it) },
            { RecapRhythmRules.lateNightHabit(it) },
            { RecapRhythmRules.peakHour(it) },
            { RecapRhythmRules.weekendHabit(it) },
            { RecapRhythmRules.longestStreak(it) },
            { RecapRhythmRules.busiestWeek(it) },
            { RecapRhythmRules.busiestDay(it) },
            { RecapRhythmRules.longestSession(it) },
            { RecapRhythmRules.sessionLengthTrend(it) },
            { RecapRhythmRules.showUpRate(it) },
        )

        return rules.mapNotNull { rule ->
            try {
                rule(ctx)
            } catch (_: Exception) {
                null
            }
        }
    }
}
