@file:Suppress("MatchingDeclarationName")

package com.openburnbar.data.insights.verdict

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightDigest
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

private const val VAL_0_10 = 0.10
private const val VAL_10 = 10

internal fun buildVerdictRings(
    thresholds: RuleBasedVerdictEngine.Thresholds,
    digest: InsightDigest,
    prior: InsightDigest?,
): List<VerdictRing> =
    listOf(
        verdictSpendRing(thresholds, digest, prior?.totals),
        verdictCacheRing(thresholds, digest.totals, prior?.totals),
        verdictSessionsRing(thresholds, digest.totals, prior?.totals),
    )

private fun verdictSpendRing(
    thresholds: RuleBasedVerdictEngine.Thresholds,
    digest: InsightDigest,
    priorTotals: InsightDigest.Totals?,
): VerdictRing {
    val totals = digest.totals
    val spendTarget =
        maxOf(
            (priorTotals?.costUSD ?: thresholds.spendBudgetFloor) * thresholds.spendBudgetGrowthRate,
            thresholds.spendBudgetFloor,
        )
    return VerdictRing(
        identity = VerdictRing.Identity.spend,
        label = "Spend",
        current = totals.costUSD,
        target = spendTarget,
        unit = VerdictDelta.Unit.usd,
        valueLabel = "$${verdictTwoDecimals(totals.costUSD)} / $${verdictNoDecimals(spendTarget)}",
        delta =
        priorTotals?.let {
            verdictDeltaPercent(totals.costUSD, it.costUSD, "vs prior period", VerdictDelta.Direction.lowerIsBetter)
        },
        tint = ProviderTint.forProviderKey(digest.providers.maxByOrNull { it.costUSD }?.id),
    )
}

private fun verdictCacheRing(
    thresholds: RuleBasedVerdictEngine.Thresholds,
    totals: InsightDigest.Totals,
    priorTotals: InsightDigest.Totals?,
): VerdictRing {
    val cacheRate = verdictCacheHitRate(totals)
    val priorCacheRate = priorTotals?.let { verdictCacheHitRate(it) }
    return VerdictRing(
        identity = VerdictRing.Identity.cache,
        label = "Cache",
        current = cacheRate * 100,
        target = thresholds.cacheTargetRate * 100,
        unit = VerdictDelta.Unit.pct,
        valueLabel = "${(cacheRate * 100).roundToInt()}% / ${(thresholds.cacheTargetRate * 100).roundToInt()}%",
        delta =
        priorCacheRate?.let {
            verdictDeltaPercent(cacheRate * 100, it * 100, "vs prior period", VerdictDelta.Direction.higherIsBetter)
        },
        tint = ProviderTint.silver,
    )
}

private fun verdictSessionsRing(
    thresholds: RuleBasedVerdictEngine.Thresholds,
    totals: InsightDigest.Totals,
    priorTotals: InsightDigest.Totals?,
): VerdictRing {
    val sessionTarget = maxOf((priorTotals?.sessionCount ?: 0) + 1, thresholds.sessionTargetMinimum)
    return VerdictRing(
        identity = VerdictRing.Identity.sessions,
        label = "Sessions",
        current = totals.sessionCount.toDouble(),
        target = sessionTarget.toDouble(),
        unit = VerdictDelta.Unit.sessions,
        valueLabel = "${totals.sessionCount} / $sessionTarget",
        delta =
        priorTotals?.let {
            verdictDeltaPercent(
                totals.sessionCount.toDouble(),
                it.sessionCount.toDouble(),
                "vs prior period",
                VerdictDelta.Direction.higherIsBetter,
            )
        },
        tint = ProviderTint.mercury,
    )
}

internal fun buildVerdictKeyNumbers(digest: InsightDigest, prior: InsightDigest?): List<VerdictNumber> {
    val core = verdictCoreKeyNumbers(digest.totals, prior?.totals)
    val topModel = digest.models.maxByOrNull { it.sessionCount }?.let { verdictTopModelKeyNumber(it) }
    return if (topModel == null) core else core + topModel
}

private fun verdictCoreKeyNumbers(totals: InsightDigest.Totals, priorTotals: InsightDigest.Totals?): List<VerdictNumber> {
    val cacheRate = verdictCacheHitRate(totals) * 100
    return listOf(
        VerdictNumber(
            id = "spend",
            label = "Spend",
            value = "$${verdictTwoDecimals(totals.costUSD)}",
            rawValue = totals.costUSD,
            unit = VerdictDelta.Unit.usd,
            delta =
            priorTotals?.let {
                verdictDeltaPercent(totals.costUSD, it.costUSD, "vs prior period", VerdictDelta.Direction.lowerIsBetter)
            },
        ),
        VerdictNumber(
            id = "cache",
            label = "Cache hit",
            value = "${cacheRate.roundToInt()}%",
            rawValue = cacheRate,
            unit = VerdictDelta.Unit.pct,
            delta =
            priorTotals?.let {
                verdictDeltaPercent(cacheRate, verdictCacheHitRate(it) * 100, "vs prior period", VerdictDelta.Direction.higherIsBetter)
            },
        ),
        VerdictNumber(
            id = "sessions",
            label = "Sessions",
            value = "${totals.sessionCount}",
            rawValue = totals.sessionCount.toDouble(),
            unit = VerdictDelta.Unit.sessions,
            delta =
            priorTotals?.let {
                verdictDeltaPercent(
                    totals.sessionCount.toDouble(),
                    it.sessionCount.toDouble(),
                    "vs prior period",
                    VerdictDelta.Direction.higherIsBetter,
                )
            },
        ),
    )
}

private fun verdictTopModelKeyNumber(top: InsightDigest.ModelSnapshot): VerdictNumber =
    VerdictNumber(
        id = "top_model_calls_${top.id}",
        label = top.id,
        value = "${top.sessionCount}",
        rawValue = top.sessionCount.toDouble(),
        unit = VerdictDelta.Unit.sessions,
    )

@Suppress("UnusedParameter")
internal fun buildVerdictBullets(
    thresholds: RuleBasedVerdictEngine.Thresholds,
    digest: InsightDigest,
    prior: InsightDigest?,
    window: VerdictWindow,
): List<VerdictBullet> {
    val bullets = mutableListOf<VerdictBullet>()
    val priorTotals = prior?.totals
    bullets += verdictSpendComparisonBullets(digest, priorTotals)
    bullets += verdictUseCasePatternBullet(digest)
    bullets += verdictCacheBullets(thresholds, digest)
    bullets += verdictAnomalyBullet(thresholds, digest, bullets.size)
    return bullets
}

private fun verdictSpendComparisonBullets(digest: InsightDigest, priorTotals: InsightDigest.Totals?): List<VerdictBullet> {
    if (priorTotals != null && priorTotals.costUSD > 0) {
        val delta = (digest.totals.costUSD - priorTotals.costUSD) / priorTotals.costUSD * 100
        val direction = if (delta < 0) "under" else "over"
        val absPct = abs(delta).roundToInt()
        return listOf(
            VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.comparison,
                claim = "You spent $${verdictTwoDecimals(digest.totals.costUSD)} — $absPct% $direction the prior period.",
                citations = verdictDayCitations(digest, limit = 3),
                delta =
                VerdictDelta(
                    value = delta,
                    unit = VerdictDelta.Unit.pct,
                    baseline = "vs prior period",
                    direction = VerdictDelta.Direction.lowerIsBetter,
                ),
                confidence = InsightConfidence.HIGH,
            ),
        )
    }
    if (digest.totals.sessionCount > 0) {
        return listOf(
            VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.reflective_fact,
                claim = "You logged ${digest.totals.sessionCount} sessions, spending $${verdictTwoDecimals(digest.totals.costUSD)}.",
                citations = verdictDayCitations(digest, limit = 3),
                confidence = InsightConfidence.HIGH,
            ),
        )
    }
    return emptyList()
}

private fun verdictUseCasePatternBullet(digest: InsightDigest): List<VerdictBullet> {
    val top = digest.useCaseHistogram.filter { it.count >= 2 }.maxByOrNull { it.count } ?: return emptyList()
    val pct =
        if (digest.totals.sessionCount > 0) {
            top.count.toDouble() / digest.totals.sessionCount * 100
        } else {
            0.0
        }
    return listOf(
        VerdictBullet(
            id = UUID.randomUUID().toString(),
            type = VerdictBulletType.pattern,
            claim = "${pct.roundToInt()}% of your sessions were ${top.id} (${top.count} total).",
            citations =
            listOf(
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Query(top.id),
                    label = top.id,
                ),
            ),
            confidence = if (pct >= 30) InsightConfidence.HIGH else InsightConfidence.MEDIUM,
        ),
    )
}

private fun verdictCacheBullets(thresholds: RuleBasedVerdictEngine.Thresholds, digest: InsightDigest): List<VerdictBullet> {
    val cacheRate = verdictCacheHitRate(digest.totals)
    if (cacheRate > 0 && cacheRate < thresholds.cacheTargetRate - VAL_0_10) {
        return listOf(
            VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.pattern,
                claim =
                "Cache hit rate is ${(cacheRate * 100).roundToInt()}% — " +
                    "${((thresholds.cacheTargetRate - cacheRate) * 100).roundToInt()} " +
                    "points below the ${(thresholds.cacheTargetRate * 100).toInt()}% target.",
                citations = verdictProviderCitations(digest, limit = 2),
                confidence = InsightConfidence.MEDIUM,
            ),
        )
    }
    if (cacheRate >= thresholds.cacheTargetRate) {
        val top = digest.providers.filter { it.costUSD > 0 }.maxByOrNull { it.totalTokens } ?: return emptyList()
        return listOf(
            VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.reflective_fact,
                claim = "Cache hit rate held at ${(cacheRate * 100).roundToInt()}% across ${digest.providers.size} providers (led by ${top.displayName}).",
                citations = verdictProviderCitations(digest, limit = 2),
                confidence = InsightConfidence.HIGH,
            ),
        )
    }
    return emptyList()
}

private fun verdictAnomalyBullet(
    thresholds: RuleBasedVerdictEngine.Thresholds,
    digest: InsightDigest,
    currentCount: Int,
): List<VerdictBullet> {
    if (currentCount >= InsightVerdict.MAX_BULLETS) return emptyList()
    val top = digest.anomalies.filter { it.score >= thresholds.anomalyZThreshold }.maxByOrNull { it.score } ?: return emptyList()
    return listOf(
        VerdictBullet(
            id = UUID.randomUUID().toString(),
            type = VerdictBulletType.anomaly,
            claim = "${top.label} (z=${verdictOneDecimal(top.score)}).",
            citations =
            listOf(
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Anomaly(top.id),
                    label = top.label,
                ),
            ),
            confidence = InsightConfidence.HIGH,
        ),
    )
}

private fun verdictDayCitations(digest: InsightDigest, limit: Int): List<InsightCitation> {
    if (digest.daily.isEmpty()) {
        return listOf(
            InsightCitation(
                id = UUID.randomUUID().toString(),
                kind = InsightCitation.Kind.Day(digest.generatedAt.take(VAL_10)),
                label = digest.generatedAt.take(VAL_10),
            ),
        )
    }
    return digest.daily
        .sortedByDescending { it.day }
        .take(limit)
        .map { point ->
            val dateStr = point.day.take(VAL_10)
            InsightCitation(
                id = UUID.randomUUID().toString(),
                kind = InsightCitation.Kind.Day(dateStr),
                label = dateStr,
            )
        }
}

private fun verdictProviderCitations(digest: InsightDigest, limit: Int): List<InsightCitation> {
    val cites =
        digest.providers
            .sortedByDescending { it.costUSD }
            .take(limit)
            .map { p ->
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Agent(p.id),
                    label = p.displayName,
                )
            }
    if (cites.isEmpty()) {
        return listOf(
            InsightCitation(
                id = UUID.randomUUID().toString(),
                kind = InsightCitation.Kind.Agent("all"),
                label = "All providers",
            ),
        )
    }
    return cites
}

private fun verdictCacheHitRate(totals: InsightDigest.Totals): Double {
    val denom = totals.cacheReadTokens + totals.inputTokens
    if (denom <= 0) return 0.0
    return totals.cacheReadTokens.toDouble() / denom
}

private fun verdictDeltaPercent(current: Double, prior: Double, baseline: String, direction: VerdictDelta.Direction): VerdictDelta? {
    if (prior == 0.0) return null
    val pct = (current - prior) / abs(prior) * 100
    return VerdictDelta(value = pct, unit = VerdictDelta.Unit.pct, baseline = baseline, direction = direction)
}

private fun verdictTwoDecimals(v: Double): String = String.format(java.util.Locale.US, "%.2f", v)

private fun verdictNoDecimals(v: Double): String = String.format(java.util.Locale.US, "%.0f", v)

private fun verdictOneDecimal(v: Double): String = String.format(java.util.Locale.US, "%.1f", v)
