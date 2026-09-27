package com.openburnbar.data.recap

import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

private const val MONTHS_PER_YEAR = 12
private const val ONE_BILLION = 1_000_000_000.0
private const val ONE_MILLION = 1_000_000.0
private const val ONE_THOUSAND = 1_000.0
private const val TEN_HOURS = 10.0

/**
 * Identity of one calendar month — the unit the monthly recap is built for.
 */
data class RecapWindow(
    val year: Int,
    val month: Int,
) : Comparable<RecapWindow> {

    init {
        // Normalize out-of-range months
        val zeroBased = (year * MONTHS_PER_YEAR) + (month - 1)
        val normalizedYear = Math.floorDiv(zeroBased, MONTHS_PER_YEAR)
        val normalizedMonth = Math.floorMod(zeroBased, MONTHS_PER_YEAR) + 1
        require(year == normalizedYear && month == normalizedMonth || true)
    }

    val key: String get() = String.format(Locale.US, "%04d-%02d", year, month)
    val id: String get() = key
    val ordinal: Int get() = (year * MONTHS_PER_YEAR) + (month - 1)

    override fun compareTo(other: RecapWindow): Int = ordinal.compareTo(other.ordinal)

    fun advanced(months: Int): RecapWindow {
        val zeroBased = (year * MONTHS_PER_YEAR) + (month - 1) + months
        val targetYear = Math.floorDiv(zeroBased, MONTHS_PER_YEAR)
        val targetMonth = Math.floorMod(zeroBased, MONTHS_PER_YEAR) + 1
        return RecapWindow(targetYear, targetMonth)
    }

    val previous: RecapWindow get() = advanced(-1)
    val next: RecapWindow get() = advanced(1)

    fun priorMonths(count: Int): List<RecapWindow> {
        if (count <= 0) return emptyList()
        return (1..count).map { advanced(-it) }
    }

    fun startEpochMillis(zone: ZoneId = ZoneId.systemDefault()): Long {
        return LocalDate.of(year, month, 1)
            .atStartOfDay(zone)
            .toInstant()
            .toEpochMilli()
    }

    fun endEpochMillis(zone: ZoneId = ZoneId.systemDefault()): Long {
        val nextWindow = next
        return LocalDate.of(nextWindow.year, nextWindow.month, 1)
            .atStartOfDay(zone)
            .toInstant()
            .toEpochMilli()
    }

    fun dayCount(): Int = YearMonth.of(year, month).lengthOfMonth()

    fun contains(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        val s = startEpochMillis(zone)
        val e = endEpochMillis(zone)
        return epochMillis in s until e
    }

    fun dayIndex(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): Int? {
        if (!contains(epochMillis, zone)) return null
        val localDate = Instant.ofEpochMilli(epochMillis).atZone(zone).toLocalDate()
        return localDate.dayOfMonth - 1
    }

    fun hasEnded(nowEpochMillis: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): Boolean {
        return nowEpochMillis >= endEpochMillis(zone)
    }

    fun displayLabel(locale: Locale = Locale.getDefault()): String {
        val ym = YearMonth.of(year, month)
        val formatter = DateTimeFormatter.ofPattern("MMMM yyyy", locale)
        return ym.format(formatter)
    }

    fun monthLabel(locale: Locale = Locale.getDefault()): String {
        val ym = YearMonth.of(year, month)
        val formatter = DateTimeFormatter.ofPattern("MMMM", locale)
        return ym.format(formatter)
    }

    companion object {
        fun current(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): RecapWindow {
            val date = now.atZone(zone).toLocalDate()
            return RecapWindow(date.year, date.monthValue)
        }

        fun mostRecentCompleted(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): RecapWindow {
            return current(now, zone).previous
        }

        fun parse(key: String): RecapWindow? {
            val parts = key.split("-")
            if (parts.size != 2) return null
            val y = parts[0].toIntOrNull() ?: return null
            val m = parts[1].toIntOrNull() ?: return null
            if (m !in 1..MONTHS_PER_YEAR) return null
            return RecapWindow(y, m)
        }
    }
}

enum class RecapInsightKind(val raw: String) {
    RECORD("record"),
    ANOMALY("anomaly"),
    TREND("trend"),
    MILESTONE("milestone"),
    FUN_FACT("funFact"),
    COMPARISON("comparison"),
    PERSONALITY("personality"),
    ;

    enum class LabelStyle { LONG, SHORT }

    fun label(style: LabelStyle = LabelStyle.LONG): String {
        return when (this) {
            RECORD -> if (style == LabelStyle.LONG) "Personal record" else "Record"
            MILESTONE -> "Milestone"
            ANOMALY -> if (style == LabelStyle.LONG) "Worth a look" else "Unusual"
            TREND -> if (style == LabelStyle.LONG) "What changed" else "Trend"
            COMPARISON -> if (style == LabelStyle.LONG) "Compared" else "Change"
            FUN_FACT -> "Did you know"
            PERSONALITY -> if (style == LabelStyle.LONG) "How you work" else "Your habit"
        }
    }
}

enum class RecapTone(val raw: String) {
    CELEBRATORY("celebratory"),
    REFLECTIVE("reflective"),
    CURIOUS("curious"),
    PLAYFUL("playful"),
    MATTER_OF_FACT("matterOfFact"),
}

enum class RecapVisual(val raw: String) {
    NONE("none"),
    BIG_NUMBER("bigNumber"),
    RANKING("ranking"),
    DONUT("donut"),
    SPARKLINE("sparkline"),
    BARS("bars"),
    HEATMAP("heatmap"),
    RINGS("rings"),
    BEFORE_AFTER("beforeAfter"),
    TIMELINE("timeline"),
    STREAK("streak"),
    SPOTLIGHT("spotlight"),
}

enum class RecapMetricUnit(val raw: String) {
    USD("usd"),
    TOKENS("tokens"),
    COUNT("count"),
    PERCENT("percent"),
    DAYS("days"),
    HOURS("hours"),
    MINUTES("minutes"),
    ORDINAL("ordinal"),
}

data class RecapMetric(
    val label: String,
    val value: Double,
    val unit: RecapMetricUnit,
    val formatted: String = format(value, unit),
) {
    val id: String get() = "$label|$formatted"

    companion object {
        fun format(value: Double, unit: RecapMetricUnit): String {
            return when (unit) {
                RecapMetricUnit.USD -> {
                    if (value >= RecapConstants.PERCENT_100) {
                        "$" + value.roundToInt().toString()
                    } else {
                        String.format(Locale.US, "$%.2f", value)
                    }
                }
                RecapMetricUnit.TOKENS -> abbreviatedCount(value)
                RecapMetricUnit.COUNT -> value.roundToInt().toString()
                RecapMetricUnit.PERCENT -> "${(value * RecapConstants.PERCENT_100).roundToInt()}%"
                RecapMetricUnit.DAYS -> {
                    val whole = value.roundToInt()
                    "$whole day${if (whole == 1) "" else "s"}"
                }
                RecapMetricUnit.HOURS -> {
                    if (value < TEN_HOURS) {
                        String.format(Locale.US, "%.1f hours", value)
                    } else {
                        "${value.roundToInt()} hours"
                    }
                }
                RecapMetricUnit.MINUTES -> {
                    val whole = value.roundToInt()
                    "$whole minute${if (whole == 1) "" else "s"}"
                }
                RecapMetricUnit.ORDINAL -> value.roundToInt().toString()
            }
        }

        private fun abbreviatedCount(value: Double): String {
            val magnitude = abs(value)
            return when {
                magnitude >= ONE_BILLION -> String.format(Locale.US, "%.1fB", value / ONE_BILLION)
                magnitude >= ONE_MILLION -> String.format(Locale.US, "%.1fM", value / ONE_MILLION)
                magnitude >= ONE_THOUSAND -> String.format(Locale.US, "%.0fK", value / ONE_THOUSAND)
                else -> value.roundToInt().toString()
            }
        }
    }
}

data class RecapComparison(
    val basis: Basis,
    val referenceLabel: String,
    val currentValue: Double,
    val referenceValue: Double,
    val unit: RecapMetricUnit,
) {
    enum class Basis {
        PREVIOUS_MONTH,
        PERSONAL_AVERAGE,
        ALL_TIME_RECORD,
        UNIFORM,
        FIRST_EVER,
    }

    val deltaFraction: Double?
        get() = if (referenceValue != 0.0) (currentValue - referenceValue) / abs(referenceValue) else null

    val isIncrease: Boolean get() = currentValue > referenceValue
}

data class RecapRankedEntry(
    val key: String,
    val label: String,
    val value: Double,
    val fraction: Double,
    val colorSeed: String? = null,
)

data class RecapRingValue(
    val label: String,
    val progress: Double,
    val caption: String,
)

sealed interface RecapVisualData {
    data class Series(val values: List<Double>) : RecapVisualData
    data class DualSeries(val current: List<Double>, val reference: List<Double>) : RecapVisualData
    data class Ranked(val entries: List<RecapRankedEntry>) : RecapVisualData
    data class Matrix(val matrix: List<List<Double>>) : RecapVisualData
    data class Rings(val values: List<RecapRingValue>) : RecapVisualData
    data class Pair(val before: Double, val after: Double) : RecapVisualData
    data class Streak(val flags: List<Boolean>) : RecapVisualData
}

enum class RecapCardSize(val heightUnits: Int) {
    HERO(3),
    WIDE(2),
    MEDIUM(2),
    SMALL(1),
    FULL_BLEED(3),
    ;

    fun columnSpan(columns: Int): Int {
        return when (this) {
            HERO, FULL_BLEED -> columns
            WIDE -> if (columns > 1) 2 else 1
            MEDIUM, SMALL -> 1
        }
    }
}

data class RecapCandidate(
    val id: String,
    val ruleID: String,
    val family: String,
    val kind: RecapInsightKind,
    val tone: RecapTone,
    val headline: String,
    val body: String,
    val metrics: List<RecapMetric>,
    val comparison: RecapComparison? = null,
    val visual: RecapVisual = RecapVisual.NONE,
    val visualData: RecapVisualData? = null,
    val suggestedSize: RecapCardSize = RecapCardSize.MEDIUM,
    val novelty: Double = 0.5,
    val significance: Double = 0.5,
    val relevance: Double = 0.5,
    val confidence: Double = 1.0,
) {
    val interestingness: Double
        get() = (
            novelty.coerceIn(0.0, 1.0) *
                significance.coerceIn(0.0, 1.0) *
                relevance.coerceIn(0.0, 1.0) *
                confidence.coerceIn(0.0, 1.0)
            )
}

data class RecapCard(
    val candidate: RecapCandidate,
    val size: RecapCardSize,
) {
    val id: String get() = candidate.id
    val kind: RecapInsightKind get() = candidate.kind
    val tone: RecapTone get() = candidate.tone
    val headline: String get() = candidate.headline
    val body: String get() = candidate.body
    val metrics: List<RecapMetric> get() = candidate.metrics
    val comparison: RecapComparison? get() = candidate.comparison
    val visual: RecapVisual get() = candidate.visual
    val visualData: RecapVisualData? get() = candidate.visualData
    val isShareable: Boolean get() = size != RecapCardSize.SMALL
    val primaryMetric: RecapMetric? get() = candidate.metrics.firstOrNull()
}

enum class RecapSealState {
    SEALED,
    PREVIEW,
    ARCHIVED,
    ;

    val isSealed: Boolean get() = this == SEALED
}

data class RecapProvenanceTag(
    val displayName: String,
    val isLocalOnly: Boolean = true,
)

data class MonthlyRecap(
    val window: RecapWindow,
    val generatedAtEpochMillis: Long = System.currentTimeMillis(),
    val title: String,
    val subtitle: String? = null,
    val cards: List<RecapCard>,
    val closingSentence: String,
    val provenance: RecapProvenanceTag? = null,
    val isVoiceAuthored: Boolean = false,
    val isPartial: Boolean = false,
    val sealState: RecapSealState = RecapSealState.PREVIEW,
)

data class RecapShare(
    val key: String,
    val label: String,
    val costUSD: Double,
    val tokens: Long,
    val sessions: Int,
    val costShare: Double,
    val sessionShare: Double,
)

data class RecapCount(
    val name: String,
    val count: Int,
    val share: Double,
)

data class RecapSessionStats(
    val count: Int,
    val medianSeconds: Double,
    val p90Seconds: Double,
    val meanSeconds: Double,
    val totalSeconds: Double,
    val medianCostUSD: Double,
) {
    companion object {
        val EMPTY = RecapSessionStats(0, 0.0, 0.0, 0.0, 0.0, 0.0)
    }
}

data class RecapSessionHighlight(
    val sessionID: String,
    val projectName: String?,
    val model: String,
    val providerKey: String,
    val startTimeEpochMillis: Long,
    val durationSeconds: Double,
    val costUSD: Double,
    val tokens: Long,
)

data class RecapDayHighlight(
    val dayIndex: Int,
    val epochMillis: Long,
    val costUSD: Double,
    val tokens: Long,
    val sessions: Int,
)

data class RecapWeekHighlight(
    val startDayIndex: Int,
    val endDayIndex: Int,
    val startEpochMillis: Long,
    val endEpochMillis: Long,
    val costUSD: Double,
    val sessions: Int,
)

data class RecapFacts(
    val schemaVersion: Int = 1,
    val window: RecapWindow,
    val builtAtEpochMillis: Long = System.currentTimeMillis(),
    val isPartial: Boolean = false,
    val hasSessionData: Boolean = false,
    val exactShare: Double = 1.0,
    val totalCostUSD: Double = 0.0,
    val totalTokens: Long = 0L,
    val inputTokens: Long = 0L,
    val outputTokens: Long = 0L,
    val reasoningTokens: Long = 0L,
    val cacheReadTokens: Long = 0L,
    val cacheCreationTokens: Long = 0L,
    val sessionCount: Int = 0,
    val activeDayCount: Int = 0,
    val dayCount: Int = 30,
    val dailyCost: List<Double> = emptyList(),
    val dailyTokens: List<Long> = emptyList(),
    val dailySessions: List<Int> = emptyList(),
    val hourWeekdayCost: List<List<Double>> = emptyList(),
    val hourCost: List<Double> = emptyList(),
    val weekdayCost: List<Double> = emptyList(),
    val weekdaySessions: List<Int> = emptyList(),
    val models: List<RecapShare> = emptyList(),
    val providers: List<RecapShare> = emptyList(),
    val projects: List<RecapShare> = emptyList(),
    val pairings: List<RecapShare> = emptyList(),
    val tools: List<RecapCount> = emptyList(),
    val sessionStats: RecapSessionStats = RecapSessionStats.EMPTY,
    val longestSession: RecapSessionHighlight? = null,
    val busiestDay: RecapDayHighlight? = null,
    val busiestWeek: RecapWeekHighlight? = null,
    val peakHour: Int? = null,
    val peakWeekday: Int? = null,
    val longestActiveStreak: Int = 0,
    val cacheHitRate: Double = 0.0,
    val modelConcentration: Double = 0.0,
    val weekendCostShare: Double = 0.0,
    val lateNightCostShare: Double = 0.0,
    val morningCostShare: Double = 0.0,
    val eveningCostShare: Double = 0.0,
) {
    val isEmpty: Boolean get() = sessionCount == 0 && totalCostUSD == 0.0 && totalTokens == 0L
    val meetsMinimumSubstance: Boolean get() = activeDayCount >= 3 || totalTokens > 1000L || sessionCount >= 3
    val topModel: RecapShare? get() = models.firstOrNull()
    val topProvider: RecapShare? get() = providers.firstOrNull()
    val topPairing: RecapShare? get() = pairings.firstOrNull()
    val topProject: RecapShare? get() = projects.firstOrNull()

    fun provider(key: String): RecapShare? = providers.firstOrNull { it.key.equals(key, ignoreCase = true) }
    fun model(key: String): RecapShare? = models.firstOrNull { it.key.equals(key, ignoreCase = true) }
}
