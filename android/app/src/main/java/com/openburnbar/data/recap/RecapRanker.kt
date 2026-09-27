package com.openburnbar.data.recap

object RecapRanker {

    data class Limits(
        val minimumInterestingness: Double = 0.05,
        val maximumCards: Int = 12,
        val maxPerKind: Int = 3,
        val maxPerFamily: Int = 1,
        val maxAdditionalHeroes: Int = 2,
    ) {
        companion object {
            val STANDARD = Limits()
        }
    }

    fun rank(candidates: List<RecapCandidate>, limits: Limits = Limits.STANDARD): List<RecapCard> {
        val scored = candidates
            .filter { it.interestingness >= limits.minimumInterestingness }
            .sortedWith { a, b ->
                if (a.interestingness == b.interestingness) a.id.compareTo(b.id) else b.interestingness.compareTo(a.interestingness)
            }

        if (scored.isEmpty()) return emptyList()

        val diverse = applyDiversity(scored, limits)
        val ordered = applyNarrative(diverse)
        return assignSizes(ordered, limits)
    }

    private fun applyDiversity(candidates: List<RecapCandidate>, limits: Limits): List<RecapCandidate> {
        val kindCounts = mutableMapOf<RecapInsightKind, Int>()
        val familyCounts = mutableMapOf<String, Int>()
        val kept = mutableListOf<RecapCandidate>()
        val rejected = mutableListOf<RecapCandidate>()

        for (candidate in candidates) {
            val kCount = kindCounts[candidate.kind] ?: 0
            val fCount = familyCounts[candidate.family] ?: 0
            val canFit = kept.size < limits.maximumCards
            val withinLimits = kCount < limits.maxPerKind && fCount < limits.maxPerFamily

            if (canFit && withinLimits) {
                kindCounts[candidate.kind] = kCount + 1
                familyCounts[candidate.family] = fCount + 1
                kept.add(candidate)
            } else {
                rejected.add(candidate)
            }
        }

        for (wanted in listOf(RecapInsightKind.FUN_FACT, RecapInsightKind.COMPARISON)) {
            val alreadyHasKind = kept.any { it.kind == wanted }
            val spaceAvailable = kept.size < limits.maximumCards
            if (!alreadyHasKind && spaceAvailable) {
                val rescue = rejected.firstOrNull {
                    it.kind == wanted && (familyCounts[it.family] ?: 0) < limits.maxPerFamily
                }
                if (rescue != null) {
                    familyCounts[rescue.family] = (familyCounts[rescue.family] ?: 0) + 1
                    kept.add(rescue)
                    rejected.remove(rescue)
                }
            }
        }

        return kept
    }

    private fun applyNarrative(candidates: List<RecapCandidate>): List<RecapCandidate> {
        val slots = listOf<(RecapCandidate) -> Boolean>(
            // 1. Record or milestone
            { it.kind == RecapInsightKind.RECORD || it.kind == RecapInsightKind.MILESTONE },
            // 2. Personality
            { it.kind == RecapInsightKind.PERSONALITY },
            // 3. Fleet
            { it.ruleID == "favourite-model" },
            { it.ruleID == "favourite-pairing" },
            // 4. Project
            { it.family.startsWith("project") },
            // 5. Rhythm
            { it.family.startsWith("rhythm") },
            // 6. Trend / comparison
            { it.kind == RecapInsightKind.TREND || it.kind == RecapInsightKind.COMPARISON },
            // 7. Fun fact
            { it.kind == RecapInsightKind.FUN_FACT },
            // 8. Economy
            { it.family.startsWith("economy") },
        )

        val remaining = candidates.toMutableList()
        val ordered = mutableListOf<RecapCandidate>()

        for (slot in slots) {
            val idx = remaining.indexOfFirst(slot)
            if (idx >= 0) {
                ordered.add(remaining.removeAt(idx))
            }
        }

        ordered.addAll(remaining)
        return ordered
    }

    private fun assignSizes(candidates: List<RecapCandidate>, limits: Limits): List<RecapCard> {
        var heroesUsed = 0
        val cards = mutableListOf<RecapCard>()

        for ((index, candidate) in candidates.withIndex()) {
            val size = if (index == 0) {
                if (candidate.visual == RecapVisual.NONE) RecapCardSize.FULL_BLEED else RecapCardSize.HERO
            } else if (candidate.suggestedSize == RecapCardSize.HERO || candidate.suggestedSize == RecapCardSize.FULL_BLEED) {
                if (heroesUsed < limits.maxAdditionalHeroes) {
                    heroesUsed++
                    candidate.suggestedSize
                } else {
                    RecapCardSize.WIDE
                }
            } else {
                candidate.suggestedSize
            }
            cards.add(RecapCard(candidate = candidate, size = size))
        }

        return cards
    }
}
