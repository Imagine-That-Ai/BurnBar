package com.openburnbar.data.recap

import kotlin.math.abs

private val VOLUME_THRESHOLDS = listOf(
    10_000L,
    50_000L,
    100_000L,
    500_000L,
    1_000_000L,
    5_000_000L,
    10_000_000L,
    50_000_000L,
)

object RecapEconomyRules {

    fun spendShift(ctx: RecapContext): RecapCandidate? {
        val prev = ctx.previousMonth ?: return null
        if (ctx.facts.totalCostUSD <= RecapConstants.MIN_SPEND_THRESHOLD || prev.totalCostUSD <= RecapConstants.MIN_SPEND_THRESHOLD) return null
        val current = ctx.facts.totalCostUSD
        val prior = prev.totalCostUSD
        val delta = (current - prior) / prior
        if (abs(delta) < RecapConstants.SPEND_SHIFT_MIN_DELTA) return null

        val prevLabel = prev.window.monthLabel()
        val up = delta > 0

        return RecapCandidate(
            id = "spend-shift:${ctx.window.key}",
            ruleID = "spend-shift",
            family = "economy:spend",
            kind = RecapInsightKind.COMPARISON,
            tone = if (up) RecapTone.MATTER_OF_FACT else RecapTone.CELEBRATORY,
            headline = if (up) "You leaned in harder." else "You got more efficient.",
            body = "${RecapRuleSupport.money(current)} this month, ${RecapRuleSupport.deltaPhrase(delta)} on $prevLabel.",
            metrics = listOf(
                RecapMetric("This month", current, RecapMetricUnit.USD),
                RecapMetric(prevLabel, prior, RecapMetricUnit.USD),
            ),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.PREVIOUS_MONTH,
                referenceLabel = prevLabel,
                currentValue = current,
                referenceValue = prior,
                unit = RecapMetricUnit.USD,
            ),
            visual = RecapVisual.SPARKLINE,
            visualData = RecapVisualData.DualSeries(current = ctx.facts.dailyCost, reference = prev.dailyCost),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.65,
            significance = 0.8,
            relevance = 0.9,
            confidence = 0.9,
        )
    }

    fun spendRecord(ctx: RecapContext): RecapCandidate? {
        if (!ctx.allowsAbsoluteClaims || ctx.monthsOfHistory < RecapConstants.MIN_MONTHS_FOR_RECORD) return null
        val best = ctx.allTimeBest { it.totalCostUSD } ?: return null
        if (ctx.facts.totalCostUSD <= best.second || best.second <= 1.0) return null

        val margin = RecapStatistics.recordMargin(ctx.facts.totalCostUSD, best.second) ?: return null
        if (margin < RecapConstants.RECORD_MARGIN_MIN) return null

        return RecapCandidate(
            id = "spend-record:${ctx.window.key}",
            ruleID = "spend-record",
            family = "economy:spend",
            kind = RecapInsightKind.RECORD,
            tone = RecapTone.MATTER_OF_FACT,
            headline = "Your biggest month yet.",
            body = "${RecapRuleSupport.money(ctx.facts.totalCostUSD)} of AI work — past ${best.first.monthLabel()}, your previous high.",
            metrics = listOf(
                RecapMetric("This month", ctx.facts.totalCostUSD, RecapMetricUnit.USD),
                RecapMetric("Previous high", best.second, RecapMetricUnit.USD),
            ),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.ALL_TIME_RECORD,
                referenceLabel = best.first.monthLabel(),
                currentValue = ctx.facts.totalCostUSD,
                referenceValue = best.second,
                unit = RecapMetricUnit.USD,
            ),
            visual = RecapVisual.BIG_NUMBER,
            visualData = RecapVisualData.Series(ctx.facts.dailyCost),
            suggestedSize = RecapCardSize.HERO,
            novelty = RecapConstants.TOP_SHARE_NOVELTY,
            significance = margin,
            relevance = 0.95,
            confidence = 0.95,
        )
    }

    fun cacheEfficiency(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        if (facts.cacheReadTokens <= 0L) return null
        val rate = facts.cacheHitRate
        if (rate < RecapConstants.CACHE_HIT_MIN_RATE) return null

        val average = ctx.average { it.cacheHitRate }
        val delta = average?.let { rate - it }
        val improved = (delta ?: 0.0) > RecapConstants.CACHE_DELTA_THRESHOLD

        val body = if (delta != null && abs(delta) >= RecapConstants.CACHE_DELTA_THRESHOLD && average != null) {
            if (improved) {
                "${RecapRuleSupport.percent(rate)} of your prompt tokens came from cache — up from ${RecapRuleSupport.percent(average)} on your usual month."
            } else {
                "${RecapRuleSupport.percent(rate)} of your prompt tokens came from cache, down from ${RecapRuleSupport.percent(average)}."
            }
        } else {
            "${RecapRuleSupport.percent(rate)} of your prompt tokens were served from cache instead of being re-read."
        }

        return RecapCandidate(
            id = "cache-efficiency:${ctx.window.key}",
            ruleID = "cache-efficiency",
            family = "economy:cache",
            kind = if (improved) RecapInsightKind.TREND else RecapInsightKind.PERSONALITY,
            tone = if (improved) RecapTone.CELEBRATORY else RecapTone.MATTER_OF_FACT,
            headline = if (improved) "Your context started paying rent." else "Cache did the heavy lifting.",
            body = body,
            metrics = listOf(
                RecapMetric("Cache hit rate", rate, RecapMetricUnit.PERCENT),
                RecapMetric("Cached tokens", facts.cacheReadTokens.toDouble(), RecapMetricUnit.TOKENS),
            ),
            comparison = average?.let {
                RecapComparison(
                    basis = RecapComparison.Basis.PERSONAL_AVERAGE,
                    referenceLabel = "your usual month",
                    currentValue = rate,
                    referenceValue = it,
                    unit = RecapMetricUnit.PERCENT,
                )
            },
            visual = RecapVisual.RINGS,
            visualData = RecapVisualData.Rings(listOf(RecapRingValue("Cache", rate, RecapRuleSupport.percent(rate)))),
            suggestedSize = RecapCardSize.SMALL,
            novelty = if (improved) 0.8 else 0.5,
            significance = 0.7,
            relevance = 0.75,
            confidence = 0.85,
        )
    }

    fun costPerSessionShift(ctx: RecapContext): RecapCandidate? {
        val prev = ctx.previousMonth ?: return null
        if (ctx.facts.sessionCount < RecapConstants.SESSION_COUNT_THRESHOLD || prev.sessionCount < RecapConstants.SESSION_COUNT_THRESHOLD) return null
        val current = ctx.facts.totalCostUSD / ctx.facts.sessionCount
        val prior = prev.totalCostUSD / prev.sessionCount
        if (prior <= RecapConstants.MIN_SPEND_THRESHOLD || current <= RecapConstants.MIN_SPEND_THRESHOLD) return null
        val delta = (current - prior) / prior
        if (abs(delta) < RecapConstants.COST_PER_SESSION_DELTA) return null

        val up = delta > 0
        val prevLabel = prev.window.monthLabel()

        return RecapCandidate(
            id = "cost-per-session:${ctx.window.key}",
            ruleID = "cost-per-session",
            family = "economy:unit",
            kind = RecapInsightKind.TREND,
            tone = RecapTone.REFLECTIVE,
            headline = if (up) "Bigger asks." else "Cheaper per ask.",
            body = if (up) {
                "A typical session cost ${RecapRuleSupport.money(
                    current,
                )}, ${RecapRuleSupport.deltaPhrase(delta)} on $prevLabel — you were handing over larger problems."
            } else {
                "A typical session cost ${RecapRuleSupport.money(current)}, ${RecapRuleSupport.deltaPhrase(delta)} on $prevLabel."
            },
            metrics = listOf(
                RecapMetric("Per session", current, RecapMetricUnit.USD),
                RecapMetric(prevLabel, prior, RecapMetricUnit.USD),
            ),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.PREVIOUS_MONTH,
                referenceLabel = prevLabel,
                currentValue = current,
                referenceValue = prior,
                unit = RecapMetricUnit.USD,
            ),
            visual = RecapVisual.BEFORE_AFTER,
            visualData = RecapVisualData.Pair(before = prior, after = current),
            suggestedSize = RecapCardSize.SMALL,
            novelty = 0.7,
            significance = 0.75,
            relevance = 0.75,
            confidence = 0.8,
        )
    }

    fun thinkingShare(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        if (facts.totalTokens <= 0L || facts.reasoningTokens <= 0L) return null
        val share = facts.reasoningTokens.toDouble() / facts.totalTokens
        if (share < RecapConstants.THINKING_SHARE_MIN) return null

        return RecapCandidate(
            id = "thinking-share:${ctx.window.key}",
            ruleID = "thinking-share",
            family = "economy:tokens",
            kind = RecapInsightKind.FUN_FACT,
            tone = RecapTone.CURIOUS,
            headline = "A lot of it was thinking.",
            body = "${RecapRuleSupport.percent(share)} of your tokens went to reasoning rather than raw output.",
            metrics = listOf(
                RecapMetric("Reasoning share", share, RecapMetricUnit.PERCENT),
                RecapMetric("Reasoning tokens", facts.reasoningTokens.toDouble(), RecapMetricUnit.TOKENS),
            ),
            visual = RecapVisual.RINGS,
            visualData = RecapVisualData.Rings(listOf(RecapRingValue("Thinking", share, RecapRuleSupport.percent(share)))),
            suggestedSize = RecapCardSize.SMALL,
            novelty = 0.65,
            significance = 0.7,
            relevance = 0.65,
            confidence = 0.85,
        )
    }

    fun volumeMilestone(ctx: RecapContext): RecapCandidate? {
        val total = ctx.facts.totalTokens
        val crossed = VOLUME_THRESHOLDS.lastOrNull { total >= it } ?: return null

        return RecapCandidate(
            id = "volume-milestone:$crossed",
            ruleID = "volume-milestone",
            family = "milestone",
            kind = RecapInsightKind.MILESTONE,
            tone = RecapTone.CELEBRATORY,
            headline = "Passed ${RecapMetric.format(crossed.toDouble(), RecapMetricUnit.TOKENS)} tokens.",
            body = "Your workflow processed over ${RecapMetric.format(crossed.toDouble(), RecapMetricUnit.TOKENS)} tokens this month.",
            metrics = listOf(
                RecapMetric("This month", total.toDouble(), RecapMetricUnit.TOKENS),
            ),
            visual = RecapVisual.BIG_NUMBER,
            suggestedSize = RecapCardSize.MEDIUM,
            novelty = 0.9,
            significance = 0.85,
            relevance = 0.8,
            confidence = 0.95,
        )
    }
}
