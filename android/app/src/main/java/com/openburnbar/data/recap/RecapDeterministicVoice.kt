package com.openburnbar.data.recap

private const val MAX_CLAUSES = 3
private const val CONCENTRATION_DELTA_THRESHOLD = 0.08

object RecapDeterministicVoice {

    fun title(ctx: RecapContext, cards: List<RecapCard>): String {
        val month = ctx.window.monthLabel()
        val lead = cards.firstOrNull() ?: return "Your $month with AI"

        val record = cards.firstOrNull { it.kind == RecapInsightKind.RECORD }
        if (record != null) {
            return when (record.candidate.ruleID) {
                "spend-record" -> "$month was your biggest month yet"
                "streak", "show-up-rate" -> "$month was your steadiest month"
                "busiest-week" -> "$month had your best week yet"
                "longest-session" -> "$month went deep"
                else -> "$month set a record"
            }
        }

        return when (lead.candidate.ruleID) {
            "focus-shift" -> {
                val curr = ctx.facts.modelConcentration
                val prev = ctx.previousMonth?.modelConcentration ?: 0.0
                if (curr > prev) "$month was your settled month" else "$month was your exploring month"
            }
            "late-night" -> "$month ran late"
            "weekday-personality" -> "$month had a rhythm"
            "model-gain", "favourite-model", "favourite-pairing" -> "$month was when you picked a side"
            "volume-milestone" -> "$month passed a milestone"
            else -> "Your $month with AI"
        }
    }

    fun closing(ctx: RecapContext, cards: List<RecapCard>): String {
        val month = ctx.window.monthLabel()
        val clauses = mutableListOf<String>()

        for (card in cards) {
            if (clauses.size >= MAX_CLAUSES) break
            val clause = clauseForCard(card, ctx)
            if (clause != null) {
                clauses.add(clause)
            }
        }

        if (clauses.isEmpty()) {
            return if (ctx.facts.isEmpty) {
                "$month was quiet — nothing much to report."
            } else {
                "$month was a steady month: ${ctx.facts.sessionCount} sessions across ${ctx.facts.activeDayCount} active days."
            }
        }

        val joined = RecapRuleSupport.list(clauses)
        val opener = "In $month you $joined."

        val tail = tailForContext(ctx)
        return if (tail != null) "$opener $tail" else opener
    }

    private fun clauseForCard(card: RecapCard, ctx: RecapContext): String? {
        val facts = ctx.facts
        return when (card.candidate.ruleID) {
            "show-up-rate" -> "worked with AI on ${facts.activeDayCount} of ${facts.dayCount} days"
            "streak" -> "put together a ${facts.longestActiveStreak}-day streak"
            "favourite-model" -> facts.topModel?.let { "leaned on ${it.label} for ${RecapRuleSupport.percent(it.costShare)} of your spend" }
            "favourite-pairing" -> facts.topPairing?.let { "settled into ${it.label}" }
            "busiest-week" -> facts.busiestWeek?.let { "had your busiest stretch around ${RecapRuleSupport.dayRange(it.startEpochMillis, it.endEpochMillis)}" }
            "late-night" -> "did ${RecapRuleSupport.percent(facts.lateNightCostShare)} of the work after midnight"
            "weekday-personality" -> facts.peakWeekday?.let { "kept returning on ${RecapRuleSupport.weekdayPlural(it)}" }
            "session-length-trend" -> {
                val prev = ctx.previousMonth
                if (prev != null && prev.sessionStats.medianSeconds > 0.0) {
                    val longer = facts.sessionStats.medianSeconds > prev.sessionStats.medianSeconds
                    if (longer) "let sessions run longer" else "kept sessions shorter"
                } else {
                    null
                }
            }
            "spend-shift" -> {
                val prev = ctx.previousMonth
                if (prev != null && prev.totalCostUSD > 0.0) {
                    val delta = (facts.totalCostUSD - prev.totalCostUSD) / prev.totalCostUSD
                    "moved spend ${RecapRuleSupport.deltaPhrase(delta)}"
                } else {
                    null
                }
            }
            "new-models" -> "gave a few new models their first run"
            "cache-efficiency" -> "got ${RecapRuleSupport.percent(facts.cacheHitRate)} of your prompt tokens out of cache"
            else -> null
        }
    }

    private fun tailForContext(ctx: RecapContext): String? {
        val prev = ctx.previousMonth ?: return null
        val concentrationDelta = ctx.facts.modelConcentration - prev.modelConcentration
        if (concentrationDelta >= CONCENTRATION_DELTA_THRESHOLD) {
            val pairing = ctx.facts.topPairing
            if (pairing != null) {
                return "One setup — ${pairing.label} — quietly became your default."
            }
        }
        if (concentrationDelta <= -CONCENTRATION_DELTA_THRESHOLD) {
            return "You spread the work wider than you did the month before."
        }
        return null
    }
}
