package com.openburnbar.data.recap

private const val TOP_FLEET_LIMIT = 3
private const val DONUT_LIMIT = 6

object RecapFleetRules {

    fun favouriteModel(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val top = facts.topModel ?: return null
        if (top.sessions <= 0 && top.tokens <= 0L) return null

        val priorTopMonths = ctx.monthsWhereTop(top.key) { it.models }
        val comparison = ctx.previousShare(top.key) { it.models }?.let { prev ->
            RecapComparison(
                basis = RecapComparison.Basis.PREVIOUS_MONTH,
                referenceLabel = ctx.window.previous.monthLabel(),
                currentValue = top.costShare,
                referenceValue = prev.costShare,
                unit = RecapMetricUnit.PERCENT,
            )
        }

        val headline = when {
            priorTopMonths == 0 && ctx.monthsOfHistory > 0 -> "You found a favorite."
            priorTopMonths == ctx.monthsOfHistory && ctx.monthsOfHistory >= RecapConstants.MIN_MONTHS_FOR_RECORD -> "Still your first choice."
            else -> "Your most-used model."
        }

        val body = "${top.label} handled ${RecapRuleSupport.percent(top.costShare)} of your AI spend."

        return RecapCandidate(
            id = "favourite-model:${top.key}",
            ruleID = "favourite-model",
            family = "model:${top.key}",
            kind = if (priorTopMonths == 0 && ctx.monthsOfHistory > 0) RecapInsightKind.TREND else RecapInsightKind.PERSONALITY,
            tone = RecapTone.CELEBRATORY,
            headline = headline,
            body = body,
            metrics = listOf(
                RecapMetric("Share of spend", top.costShare, RecapMetricUnit.PERCENT),
                RecapMetric("Cost", top.costUSD, RecapMetricUnit.USD),
            ),
            comparison = comparison,
            visual = RecapVisual.SPOTLIGHT,
            visualData = RecapVisualData.Ranked(RecapRuleSupport.rankedEntries(facts.models)),
            suggestedSize = RecapCardSize.MEDIUM,
            novelty = ctx.novelty(priorTopMonths),
            significance = 0.8,
            relevance = 0.9,
            confidence = ctx.confidence(top.sessions.coerceAtLeast(RecapConstants.SESSION_COUNT_THRESHOLD)),
        )
    }

    fun biggestModelGain(ctx: RecapContext): RecapCandidate? = shareMover(ctx, rising = true)
    fun biggestModelDecline(ctx: RecapContext): RecapCandidate? = shareMover(ctx, rising = false)

    private fun shareMover(ctx: RecapContext, rising: Boolean): RecapCandidate? {
        val prev = ctx.previousMonth ?: return null
        if (ctx.facts.totalCostUSD <= 0.0 || prev.totalCostUSD <= 0.0) return null

        var bestModel: RecapShare? = null
        var bestPriorShare = 0.0
        var bestDelta = 0.0

        for (m in ctx.facts.models) {
            val prior = prev.models.firstOrNull { it.key == m.key }
            val priorShare = prior?.costShare ?: 0.0
            val delta = m.costShare - priorShare
            if (rising && delta > RecapConstants.MOVER_SHARE_DELTA && delta > bestDelta) {
                bestDelta = delta
                bestModel = m
                bestPriorShare = priorShare
            } else if (!rising && delta < -RecapConstants.MOVER_SHARE_DELTA && delta < bestDelta && priorShare >= RecapConstants.DECLINE_PRIOR_MIN_SHARE) {
                bestDelta = delta
                bestModel = m
                bestPriorShare = priorShare
            }
        }

        val winner = bestModel ?: return null
        val prevLabel = prev.window.monthLabel()
        val headline = if (rising) "A new go-to." else "Quietly stepped back."
        val body = if (rising) {
            "${winner.label} went from ${RecapRuleSupport.percent(
                bestPriorShare,
            )} of your spend in $prevLabel to ${RecapRuleSupport.percent(winner.costShare)}."
        } else {
            "${winner.label} fell from ${RecapRuleSupport.percent(
                bestPriorShare,
            )} of your spend in $prevLabel to ${RecapRuleSupport.percent(winner.costShare)}."
        }

        return RecapCandidate(
            id = "model-${if (rising) "gain" else "decline"}:${winner.key}",
            ruleID = if (rising) "model-gain" else "model-decline",
            family = "model:${winner.key}",
            kind = RecapInsightKind.TREND,
            tone = if (rising) RecapTone.CELEBRATORY else RecapTone.REFLECTIVE,
            headline = headline,
            body = body,
            metrics = listOf(
                RecapMetric("This month", winner.costShare, RecapMetricUnit.PERCENT),
                RecapMetric(prevLabel, bestPriorShare, RecapMetricUnit.PERCENT),
            ),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.PREVIOUS_MONTH,
                referenceLabel = prevLabel,
                currentValue = winner.costShare,
                referenceValue = bestPriorShare,
                unit = RecapMetricUnit.PERCENT,
            ),
            visual = RecapVisual.BEFORE_AFTER,
            visualData = RecapVisualData.Pair(before = bestPriorShare, after = winner.costShare),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.8,
            significance = 0.75,
            relevance = 0.8,
            confidence = 0.85,
        )
    }

    fun favouritePairing(ctx: RecapContext): RecapCandidate? {
        val facts = ctx.facts
        val top = facts.topPairing ?: return null
        if (top.costShare < RecapConstants.PAIRING_MIN_SHARE || facts.pairings.size < 2) return null

        val body = "${top.label} ran ${RecapRuleSupport.approximateFraction(top.costShare)} of your AI spend."

        return RecapCandidate(
            id = "favourite-pairing:${top.key}",
            ruleID = "favourite-pairing",
            family = "pairing",
            kind = RecapInsightKind.PERSONALITY,
            tone = RecapTone.REFLECTIVE,
            headline = "Your default setup.",
            body = body,
            metrics = listOf(
                RecapMetric("Share of spend", top.costShare, RecapMetricUnit.PERCENT),
                RecapMetric("Total cost", top.costUSD, RecapMetricUnit.USD),
            ),
            visual = RecapVisual.RANKING,
            visualData = RecapVisualData.Ranked(RecapRuleSupport.rankedEntries(facts.pairings)),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.7,
            significance = 0.8,
            relevance = 0.85,
            confidence = 0.9,
        )
    }

    fun fleetConcentration(ctx: RecapContext): RecapCandidate? {
        val pairings = ctx.facts.pairings
        if (pairings.size < RecapConstants.MIN_FLEET_COMBINATIONS) return null
        val topThree = pairings.take(TOP_FLEET_LIMIT)
        val topThreeShare = topThree.sumOf { it.costShare }
        if (topThreeShare < RecapConstants.TOP_THREE_MIN_SHARE) return null

        return RecapCandidate(
            id = "fleet-concentration:${pairings.size}",
            ruleID = "fleet-concentration",
            family = "fleet-shape",
            kind = RecapInsightKind.PERSONALITY,
            tone = RecapTone.CURIOUS,
            headline = "A big bench, a short rotation.",
            body = "You used ${pairings.size} model and provider combinations this month. Three of them did ${RecapRuleSupport.percent(
                topThreeShare,
            )} of the work.",
            metrics = listOf(
                RecapMetric("Combinations used", pairings.size.toDouble(), RecapMetricUnit.COUNT),
                RecapMetric("Top three share", topThreeShare, RecapMetricUnit.PERCENT),
            ),
            visual = RecapVisual.DONUT,
            visualData = RecapVisualData.Ranked(RecapRuleSupport.rankedEntries(pairings, limit = DONUT_LIMIT)),
            suggestedSize = RecapCardSize.WIDE,
            novelty = 0.65,
            significance = 0.75,
            relevance = 0.8,
            confidence = 0.85,
        )
    }

    fun newModelsTried(ctx: RecapContext): RecapCandidate? {
        if (ctx.monthsOfHistory < 1) return null
        val priorKeys = ctx.history.flatMap { it.models.map { m -> m.key } }.toSet()
        val fresh = ctx.facts.models.filter { !priorKeys.contains(it.key) && it.tokens > RecapConstants.NEW_MODEL_MIN_TOKENS }
        if (fresh.isEmpty()) return null

        val names = fresh.take(TOP_FLEET_LIMIT).map { it.label }
        val listed = RecapRuleSupport.list(names)
        val body = if (fresh.size == 1) {
            "You gave $listed its first run this month."
        } else {
            "$listed joined the rotation for the first time."
        }

        return RecapCandidate(
            id = "new-models:${ctx.window.key}",
            ruleID = "new-models",
            family = "firsts",
            kind = RecapInsightKind.MILESTONE,
            tone = RecapTone.CURIOUS,
            headline = if (fresh.size == 1) "Something new." else "New arrivals.",
            body = body,
            metrics = listOf(RecapMetric("New models", fresh.size.toDouble(), RecapMetricUnit.COUNT)),
            comparison = RecapComparison(
                basis = RecapComparison.Basis.FIRST_EVER,
                referenceLabel = "never before",
                currentValue = fresh.size.toDouble(),
                referenceValue = 0.0,
                unit = RecapMetricUnit.COUNT,
            ),
            visual = RecapVisual.RANKING,
            visualData = RecapVisualData.Ranked(RecapRuleSupport.rankedEntries(fresh)),
            suggestedSize = RecapCardSize.MEDIUM,
            novelty = RecapConstants.TOP_SHARE_NOVELTY,
            significance = 0.8,
            relevance = 0.7,
            confidence = 0.9,
        )
    }
}
