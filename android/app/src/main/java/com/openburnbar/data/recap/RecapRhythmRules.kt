package com.openburnbar.data.recap

import java.util.Locale
import kotlin.math.abs
import kotlin.math.max

object RecapRhythmRules {

    fun weekdayPersonality(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val peakIdx = facts.peakWeekday ?: return null
        val totalCost = facts.totalCostUSD
        if (totalCost <= 0.0) return null
        val peakCost = facts.weekdayCost.getOrElse(peakIdx) { 0.0 }
        val share = peakCost / totalCost
        if (share < RecapConstants.PEAK_WEEKDAY_MIN_SHARE) return null

        val dayName = RecapRuleSupport.weekdayName(peakIdx)
        val plural = RecapRuleSupport.weekdayPlural(peakIdx)

        val rankedWeekdays = facts.weekdayCost.indices.map { idx ->
            RecapRankedEntry(
                key = "weekday-$idx",
                label = RecapRuleSupport.weekdayName(idx),
                value = facts.weekdayCost[idx],
                fraction = if (peakCost > 0.0) (facts.weekdayCost[idx] / peakCost).coerceIn(0.0, 1.0) else 0.0,
            )
        }

        return RecapCandidate(
            id = "weekday-personality:$peakIdx",
            ruleID = "weekday-personality",
            family = "rhythm:weekday",
            kind = RecapInsightKind.PERSONALITY,
            tone = RecapTone.PLAYFUL,
            headline = "Apparently $dayName is build day.",
            body = "${RecapRuleSupport.approximateFraction(share).replaceFirstChar { it.uppercase() }} of your spend this month landed on $plural.",
            metrics = listOf(
                RecapMetric("Share of spend", share, RecapMetricUnit.PERCENT),
                RecapMetric("Spent on $plural", peakCost, RecapMetricUnit.USD),
            ),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.UNIFORM,
                referenceLabel = "an even week",
                currentValue = share,
                referenceValue = 1.0 / RecapConstants.DAYS_PER_WEEK,
                unit = RecapMetricUnit.PERCENT,
            ),
            visual = RecapVisual.BARS,
            visualData = RecapVisualData.Ranked(rankedWeekdays),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.8,
            significance = 0.75,
            relevance = 0.8,
            confidence = 0.85,
        )
    }

    fun lateNightHabit(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val share = facts.lateNightCostShare
        if (share < RecapConstants.LATE_NIGHT_MIN_SHARE) return null

        val body = "${RecapRuleSupport.percent(share)} of your work happened between midnight and 6am."

        return RecapCandidate(
            id = "late-night:${ctx.window.key}",
            ruleID = "late-night",
            family = "rhythm:hours",
            kind = RecapInsightKind.PERSONALITY,
            tone = RecapTone.PLAYFUL,
            headline = "Late-night builder.",
            body = body,
            metrics = listOf(RecapMetric("After midnight", share, RecapMetricUnit.PERCENT)),
            visual = RecapVisual.HEATMAP,
            visualData = RecapVisualData.Matrix(facts.hourWeekdayCost),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.8,
            significance = 0.8,
            relevance = 0.85,
            confidence = 0.9,
        )
    }

    fun peakHour(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val hour = facts.peakHour ?: return null
        val total = facts.hourCost.sum()
        if (total <= 0.0) return null
        val share = facts.hourCost[hour] / total
        if (share < RecapConstants.PEAK_HOUR_MIN_SHARE) return null

        val hourFormatted = String.format(Locale.US, "%02d:00", hour)

        return RecapCandidate(
            id = "peak-hour:$hour",
            ruleID = "peak-hour",
            family = "rhythm:hours",
            kind = RecapInsightKind.FUN_FACT,
            tone = RecapTone.CURIOUS,
            headline = "Your hour is $hourFormatted.",
            body = "More of your month happened around $hourFormatted than any other hour.",
            metrics = listOf(
                RecapMetric("Share of spend", share, RecapMetricUnit.PERCENT),
            ),
            visual = RecapVisual.BARS,
            visualData = RecapVisualData.Series(facts.hourCost),
            suggestedSize = RecapCardSize.SMALL,
            novelty = 0.7,
            significance = 0.65,
            relevance = 0.6,
            confidence = 0.8,
        )
    }

    fun weekendHabit(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val share = facts.weekendCostShare
        val isHigh = share >= RecapConstants.WEEKEND_HIGH_SHARE
        val isLow = share <= RecapConstants.WEEKEND_LOW_SHARE && facts.activeDayCount >= RecapConstants.WEEKEND_MIN_ACTIVE_DAYS
        if (!isHigh && !isLow) return null

        return RecapCandidate(
            id = "weekend-habit:${ctx.window.key}",
            ruleID = "weekend-habit",
            family = "rhythm:weekend",
            kind = RecapInsightKind.PERSONALITY,
            tone = if (isHigh) RecapTone.CURIOUS else RecapTone.CELEBRATORY,
            headline = if (isHigh) "Weekends counted." else "You kept your weekends.",
            body = if (isHigh) {
                "${RecapRuleSupport.percent(share)} of your work happened on Saturdays and Sundays."
            } else {
                "Barely ${RecapRuleSupport.percent(share)} of your work touched a weekend."
            },
            metrics = listOf(RecapMetric("Weekend share", share, RecapMetricUnit.PERCENT)),
            visual = RecapVisual.BIG_NUMBER,
            suggestedSize = RecapCardSize.SMALL,
            novelty = 0.65,
            significance = 0.7,
            relevance = 0.75,
            confidence = 0.85,
        )
    }

    fun longestStreak(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        if (facts.longestActiveStreak < RecapConstants.MIN_STREAK_DAYS) return null

        val flags = (0 until facts.dayCount).map {
            facts.dailyCost.getOrElse(it) { 0.0 } > 0.0 || facts.dailyTokens.getOrElse(it) { 0L } > 0L
        }

        return RecapCandidate(
            id = "streak:${ctx.window.key}",
            ruleID = "streak",
            family = "rhythm:streak",
            kind = RecapInsightKind.RECORD,
            tone = RecapTone.CELEBRATORY,
            headline = "You kept showing up.",
            body = "You worked with AI ${facts.longestActiveStreak} days in a row.",
            metrics = listOf(RecapMetric("Streak", facts.longestActiveStreak.toDouble(), RecapMetricUnit.DAYS)),
            visual = RecapVisual.STREAK,
            visualData = RecapVisualData.Streak(flags),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.75,
            significance = 0.8,
            relevance = 0.85,
            confidence = 0.9,
        )
    }

    fun busiestWeek(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val week = facts.busiestWeek ?: return null
        if (week.costUSD <= 0.0) return null

        val range = RecapRuleSupport.dayRange(week.startEpochMillis, week.endEpochMillis)

        return RecapCandidate(
            id = "busiest-week:${ctx.window.key}",
            ruleID = "busiest-week",
            family = "rhythm:peak",
            kind = RecapInsightKind.MILESTONE,
            tone = RecapTone.CELEBRATORY,
            headline = "You were on a roll.",
            body = "$range was your busiest stretch of the month.",
            metrics = listOf(
                RecapMetric("That week", week.costUSD, RecapMetricUnit.USD),
            ),
            visual = RecapVisual.TIMELINE,
            visualData = RecapVisualData.Series(facts.dailyCost),
            suggestedSize = RecapCardSize.HERO,
            novelty = 0.8,
            significance = 0.85,
            relevance = 0.9,
            confidence = 0.9,
        )
    }

    fun busiestDay(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val day = facts.busiestDay ?: return null
        if (day.costUSD <= 0.0) return null
        val avgDay = facts.totalCostUSD / max(1, facts.activeDayCount)
        if (avgDay <= 0.0 || day.costUSD / avgDay < RecapConstants.BUSIEST_DAY_MULTIPLE) return null

        val multiple = day.costUSD / avgDay
        val dayLabel = RecapRuleSupport.dayLabel(day.epochMillis)

        return RecapCandidate(
            id = "busiest-day:${ctx.window.key}",
            ruleID = "busiest-day",
            family = "rhythm:peak",
            kind = RecapInsightKind.FUN_FACT,
            tone = RecapTone.CURIOUS,
            headline = "One day carried the load.",
            body = "$dayLabel was ${String.format(Locale.US, "%.1f", multiple)}× your average active day.",
            metrics = listOf(
                RecapMetric("That day", day.costUSD, RecapMetricUnit.USD),
            ),
            visual = RecapVisual.SPARKLINE,
            visualData = RecapVisualData.Series(facts.dailyCost),
            suggestedSize = RecapCardSize.SMALL,
            novelty = 0.65,
            significance = 0.7,
            relevance = 0.7,
            confidence = 0.85,
        )
    }

    fun longestSession(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val session = facts.longestSession ?: return null
        if (session.durationSeconds < RecapConstants.LONGEST_SESSION_MIN_SECONDS) return null

        val where = session.projectName?.let { " on $it" } ?: ""

        return RecapCandidate(
            id = "longest-session:${ctx.window.key}",
            ruleID = "longest-session",
            family = "session:length",
            kind = RecapInsightKind.MILESTONE,
            tone = RecapTone.CELEBRATORY,
            headline = "The long haul.",
            body = "One session ran ${RecapRuleSupport.duration(session.durationSeconds)}$where.",
            metrics = listOf(
                RecapMetric("Duration", session.durationSeconds / RecapConstants.SECONDS_PER_HOUR, RecapMetricUnit.HOURS),
                RecapMetric("Cost", session.costUSD, RecapMetricUnit.USD),
            ),
            visual = RecapVisual.BIG_NUMBER,
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.75,
            significance = 0.8,
            relevance = 0.8,
            confidence = 0.85,
        )
    }

    fun sessionLengthTrend(ctx: RecapContext): RecapCandidate? {
        val prev = ctx.previousMonth ?: return null
        val current = ctx.facts.sessionStats.medianSeconds
        val prior = prev.sessionStats.medianSeconds
        if (prior <= 0.0 || current <= 0.0) return null
        val delta = (current - prior) / prior
        if (abs(delta) < RecapConstants.SESSION_LENGTH_DELTA) return null

        val longer = delta > 0
        val prevLabel = prev.window.monthLabel()

        return RecapCandidate(
            id = "session-length-trend:${ctx.window.key}",
            ruleID = "session-length-trend",
            family = "session:length",
            kind = RecapInsightKind.TREND,
            tone = RecapTone.REFLECTIVE,
            headline = if (longer) "Your sessions got longer." else "Shorter, sharper sessions.",
            body = "A typical session ran ${RecapRuleSupport.duration(current)}, ${RecapRuleSupport.deltaPhrase(delta)} on $prevLabel.",
            metrics = listOf(
                RecapMetric("Typical session", current / RecapConstants.SECONDS_PER_MINUTE, RecapMetricUnit.MINUTES),
                RecapMetric(prevLabel, prior / RecapConstants.SECONDS_PER_MINUTE, RecapMetricUnit.MINUTES),
            ),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.PREVIOUS_MONTH,
                referenceLabel = prevLabel,
                currentValue = current / RecapConstants.SECONDS_PER_MINUTE,
                referenceValue = prior / RecapConstants.SECONDS_PER_MINUTE,
                unit = RecapMetricUnit.MINUTES,
            ),
            visual = RecapVisual.BEFORE_AFTER,
            visualData = RecapVisualData.Pair(
                before = prior / RecapConstants.SECONDS_PER_MINUTE,
                after = current / RecapConstants.SECONDS_PER_MINUTE,
            ),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.75,
            significance = 0.75,
            relevance = 0.75,
            confidence = 0.8,
        )
    }

    fun showUpRate(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        if (facts.activeDayCount < RecapConstants.SHOW_UP_MIN_DAYS) return null
        val rate = facts.activeDayCount.toDouble() / max(1, facts.dayCount)
        if (rate < RecapConstants.SHOW_UP_MIN_RATE) return null

        val flags = (0 until facts.dayCount).map {
            facts.dailyCost.getOrElse(it) { 0.0 } > 0.0 || facts.dailyTokens.getOrElse(it) { 0L } > 0L
        }

        return RecapCandidate(
            id = "show-up-rate:${ctx.window.key}",
            ruleID = "show-up-rate",
            family = "rhythm:streak",
            kind = RecapInsightKind.PERSONALITY,
            tone = RecapTone.CELEBRATORY,
            headline = "You showed up.",
            body = "${facts.activeDayCount} of ${facts.dayCount} days had AI work in them.",
            metrics = listOf(
                RecapMetric("Active days", facts.activeDayCount.toDouble(), RecapMetricUnit.DAYS),
                RecapMetric("Of the month", rate, RecapMetricUnit.PERCENT),
            ),
            visual = RecapVisual.STREAK,
            visualData = RecapVisualData.Streak(flags),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.7,
            significance = 0.75,
            relevance = 0.85,
            confidence = 0.9,
        )
    }
}
