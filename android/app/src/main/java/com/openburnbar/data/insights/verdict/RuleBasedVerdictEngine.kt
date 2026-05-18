package com.openburnbar.data.insights.verdict

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Deterministic, no-LLM verdict producer.
 *
 * Kotlin port of `OpenBurnBarCore.RuleBasedVerdictEngine`. Same shapes,
 * same gating thresholds, same hashing behavior. Verdicts produced on
 * Android with the same input digest will hash equal to verdicts
 * produced on macOS/iOS — that's the parity contract.
 */
class RuleBasedVerdictEngine(
    val thresholds: Thresholds = Thresholds.DEFAULT,
    val calendar: Calendar = Calendar.getInstance()
) {

    data class Thresholds(
        val cacheTargetRate: Double,
        val sessionTargetMinimum: Int,
        val spendBudgetFloor: Double,
        val spendBudgetGrowthRate: Double,
        val anomalyZThreshold: Double,
        val recommendationMinDailyHistory: Int,
        val trendsMinDailyHistory: Int,
        val forecastMinDailyHistory: Int
    ) {
        companion object {
            val DEFAULT = Thresholds(
                cacheTargetRate = 0.85,
                sessionTargetMinimum = 1,
                spendBudgetFloor = 5.0,
                spendBudgetGrowthRate = 1.2,
                anomalyZThreshold = 2.0,
                recommendationMinDailyHistory = 60,
                trendsMinDailyHistory = 14,
                forecastMinDailyHistory = 30
            )
        }
    }

    // MARK: - Entry point

    fun produce(
        digest: InsightDigest,
        window: VerdictWindow,
        priorDigest: InsightDigest? = null,
        now: Date = Date()
    ): InsightVerdict {
        val rings = buildRings(digest, priorDigest)
        val keyNumbers = buildKeyNumbers(digest, priorDigest)
        val bullets = buildBullets(digest, priorDigest, window)
        val anomaly = buildAnomaly(digest)
        val recommendation = buildRecommendation(digest)
        val dominantProvider = digest.providers.maxByOrNull { it.costUSD }?.id
        val mood = ProviderTint.forProviderKey(dominantProvider)
        val provenance = InsightModelTag(
            providerKey = "local-rules",
            modelID = "rule-based-v2",
            displayName = "Local rules",
            egressTier = InsightEgressTier.LOCAL_ONLY,
            stampedAt = isoFormatter.format(now)
        )

        val verdict = InsightVerdict(
            id = UUID.randomUUID().toString(),
            generatedAt = isoFormatter.format(now),
            window = window,
            headline = buildHeadline(digest, priorDigest, window).take(InsightVerdict.HEADLINE_MAX_LENGTH),
            subhead = buildSubhead(digest)?.take(InsightVerdict.SUBHEAD_MAX_LENGTH),
            rings = rings,
            keyNumbers = keyNumbers.take(InsightVerdict.MAX_KEY_NUMBERS),
            sessionTrace = null,
            bullets = bullets.take(InsightVerdict.MAX_BULLETS),
            anomaly = anomaly,
            recommendation = recommendation,
            moodSwatch = mood,
            provenance = provenance,
            confidence = computeConfidence(digest),
            followUps = buildFollowUps(digest, window).take(InsightVerdict.MAX_FOLLOW_UPS),
            isRuleBased = true,
            contentHash = ""
        )
        return verdict.copy(contentHash = hash(verdict))
    }

    // MARK: - Rings

    private fun buildRings(
        digest: InsightDigest,
        prior: InsightDigest?
    ): List<VerdictRing> {
        val totals = digest.totals
        val priorTotals = prior?.totals

        val spendTarget = maxOf(
            (priorTotals?.costUSD ?: thresholds.spendBudgetFloor) * thresholds.spendBudgetGrowthRate,
            thresholds.spendBudgetFloor
        )
        val spendRing = VerdictRing(
            identity = VerdictRing.Identity.spend,
            label = "Spend",
            current = totals.costUSD,
            target = spendTarget,
            unit = VerdictDelta.Unit.usd,
            valueLabel = "$${twoDecimals(totals.costUSD)} / $${noDecimals(spendTarget)}",
            delta = priorTotals?.let {
                deltaPercent(
                    current = totals.costUSD,
                    prior = it.costUSD,
                    baseline = "vs prior period",
                    direction = VerdictDelta.Direction.lowerIsBetter
                )
            },
            tint = ProviderTint.forProviderKey(
                digest.providers.maxByOrNull { it.costUSD }?.id
            )
        )

        val cacheRate = cacheHitRate(totals)
        val priorCacheRate = priorTotals?.let { cacheHitRate(it) }
        val cacheRing = VerdictRing(
            identity = VerdictRing.Identity.cache,
            label = "Cache",
            current = cacheRate * 100,
            target = thresholds.cacheTargetRate * 100,
            unit = VerdictDelta.Unit.pct,
            valueLabel = "${(cacheRate * 100).roundToInt()}% / ${(thresholds.cacheTargetRate * 100).roundToInt()}%",
            delta = priorCacheRate?.let {
                deltaPercent(
                    current = cacheRate * 100,
                    prior = it * 100,
                    baseline = "vs prior period",
                    direction = VerdictDelta.Direction.higherIsBetter
                )
            },
            tint = ProviderTint.silver
        )

        val sessionTarget = maxOf(
            ((priorTotals?.sessionCount ?: 0) + 1),
            thresholds.sessionTargetMinimum
        )
        val sessionsRing = VerdictRing(
            identity = VerdictRing.Identity.sessions,
            label = "Sessions",
            current = totals.sessionCount.toDouble(),
            target = sessionTarget.toDouble(),
            unit = VerdictDelta.Unit.sessions,
            valueLabel = "${totals.sessionCount} / $sessionTarget",
            delta = priorTotals?.let {
                deltaPercent(
                    current = totals.sessionCount.toDouble(),
                    prior = it.sessionCount.toDouble(),
                    baseline = "vs prior period",
                    direction = VerdictDelta.Direction.higherIsBetter
                )
            },
            tint = ProviderTint.mercury
        )

        return listOf(spendRing, cacheRing, sessionsRing)
    }

    // MARK: - Key Numbers

    private fun buildKeyNumbers(
        digest: InsightDigest,
        prior: InsightDigest?
    ): List<VerdictNumber> {
        val totals = digest.totals
        val priorTotals = prior?.totals
        val out = mutableListOf<VerdictNumber>()

        out.add(VerdictNumber(
            id = "spend",
            label = "Spend",
            value = "$${twoDecimals(totals.costUSD)}",
            rawValue = totals.costUSD,
            unit = VerdictDelta.Unit.usd,
            delta = priorTotals?.let {
                deltaPercent(totals.costUSD, it.costUSD, "vs prior period", VerdictDelta.Direction.lowerIsBetter)
            }
        ))
        val cacheRate = cacheHitRate(totals) * 100
        out.add(VerdictNumber(
            id = "cache",
            label = "Cache hit",
            value = "${cacheRate.roundToInt()}%",
            rawValue = cacheRate,
            unit = VerdictDelta.Unit.pct,
            delta = priorTotals?.let {
                deltaPercent(cacheRate, cacheHitRate(it) * 100, "vs prior period", VerdictDelta.Direction.higherIsBetter)
            }
        ))
        out.add(VerdictNumber(
            id = "sessions",
            label = "Sessions",
            value = "${totals.sessionCount}",
            rawValue = totals.sessionCount.toDouble(),
            unit = VerdictDelta.Unit.sessions,
            delta = priorTotals?.let {
                deltaPercent(
                    totals.sessionCount.toDouble(),
                    it.sessionCount.toDouble(),
                    "vs prior period",
                    VerdictDelta.Direction.higherIsBetter
                )
            }
        ))
        digest.models.maxByOrNull { it.sessionCount }?.let { top ->
            out.add(VerdictNumber(
                id = "top_model_calls_${top.id}",
                label = top.id,
                value = "${top.sessionCount}",
                rawValue = top.sessionCount.toDouble(),
                unit = VerdictDelta.Unit.sessions
            ))
        }
        return out
    }

    // MARK: - Bullets

    private fun buildBullets(
        digest: InsightDigest,
        prior: InsightDigest?,
        window: VerdictWindow
    ): List<VerdictBullet> {
        val bullets = mutableListOf<VerdictBullet>()
        val priorTotals = prior?.totals

        if (priorTotals != null && priorTotals.costUSD > 0) {
            val delta = (digest.totals.costUSD - priorTotals.costUSD) / priorTotals.costUSD * 100
            val direction = if (delta < 0) "under" else "over"
            val absPct = abs(delta).roundToInt()
            bullets.add(VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.comparison,
                claim = "You spent $${twoDecimals(digest.totals.costUSD)} — $absPct% $direction the prior period.",
                citations = dayCitations(digest, limit = 3),
                delta = VerdictDelta(
                    value = delta,
                    unit = VerdictDelta.Unit.pct,
                    baseline = "vs prior period",
                    direction = VerdictDelta.Direction.lowerIsBetter
                ),
                confidence = InsightConfidence.HIGH
            ))
        } else if (digest.totals.sessionCount > 0) {
            bullets.add(VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.reflective_fact,
                claim = "You logged ${digest.totals.sessionCount} sessions, spending $${twoDecimals(digest.totals.costUSD)}.",
                citations = dayCitations(digest, limit = 3),
                confidence = InsightConfidence.HIGH
            ))
        }

        digest.useCaseHistogram.filter { it.count >= 2 }.maxByOrNull { it.count }?.let { top ->
            val pct = if (digest.totals.sessionCount > 0) {
                top.count.toDouble() / digest.totals.sessionCount * 100
            } else 0.0
            bullets.add(VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.pattern,
                claim = "${pct.roundToInt()}% of your sessions were ${top.id} (${top.count} total).",
                citations = listOf(
                    InsightCitation(
                        id = UUID.randomUUID().toString(),
                        kind = InsightCitation.Kind.Query(top.id),
                        label = top.id
                    )
                ),
                confidence = if (pct >= 30) InsightConfidence.HIGH else InsightConfidence.MEDIUM
            ))
        }

        val cacheRate = cacheHitRate(digest.totals)
        if (cacheRate > 0 && cacheRate < thresholds.cacheTargetRate - 0.10) {
            bullets.add(VerdictBullet(
                id = UUID.randomUUID().toString(),
                type = VerdictBulletType.pattern,
                claim = "Cache hit rate is ${(cacheRate * 100).roundToInt()}% — " +
                    "${((thresholds.cacheTargetRate - cacheRate) * 100).roundToInt()} " +
                    "points below the ${(thresholds.cacheTargetRate * 100).toInt()}% target.",
                citations = providerCitations(digest, limit = 2),
                confidence = InsightConfidence.MEDIUM
            ))
        } else if (cacheRate >= thresholds.cacheTargetRate) {
            digest.providers
                .filter { it.costUSD > 0 }
                .maxByOrNull { it.totalTokens }
                ?.let { top ->
                    bullets.add(VerdictBullet(
                        id = UUID.randomUUID().toString(),
                        type = VerdictBulletType.reflective_fact,
                        claim = "Cache hit rate held at ${(cacheRate * 100).roundToInt()}% across ${digest.providers.size} providers (led by ${top.displayName}).",
                        citations = providerCitations(digest, limit = 2),
                        confidence = InsightConfidence.HIGH
                    ))
                }
        }

        digest.anomalies
            .filter { it.score >= thresholds.anomalyZThreshold }
            .maxByOrNull { it.score }
            ?.let { top ->
                if (bullets.size < InsightVerdict.MAX_BULLETS) {
                    bullets.add(VerdictBullet(
                        id = UUID.randomUUID().toString(),
                        type = VerdictBulletType.anomaly,
                        claim = "${top.label} (z=${oneDecimal(top.score)}).",
                        citations = listOf(
                            InsightCitation(
                                id = UUID.randomUUID().toString(),
                                kind = InsightCitation.Kind.Anomaly(top.id),
                                label = top.label
                            )
                        ),
                        confidence = InsightConfidence.HIGH
                    ))
                }
            }

        return bullets
    }

    // MARK: - Anomaly + recommendation + headline/subhead

    private fun buildAnomaly(digest: InsightDigest): VerdictAnomaly? {
        val top = digest.anomalies
            .filter { it.score >= thresholds.anomalyZThreshold }
            .maxByOrNull { it.score } ?: return null
        return VerdictAnomaly(
            id = UUID.randomUUID().toString(),
            label = top.label,
            detail = top.detail ?: "",
            occurredAt = top.occurredAt,
            zScore = top.score,
            citations = listOf(
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Anomaly(top.id),
                    label = top.label
                )
            ),
            acceptAction = VerdictAcceptAction(
                label = "Investigate",
                intent = VerdictAcceptAction.Intent.investigate,
                payload = mapOf("anomalyID" to top.id)
            )
        )
    }

    private fun buildRecommendation(digest: InsightDigest): VerdictRecommendation? {
        if (digest.daily.size < thresholds.recommendationMinDailyHistory) return null
        val candidate = digest.models
            .filter { it.sessionCount >= 5 && it.costUSD >= 1.0 }
            .maxByOrNull { it.costUSD } ?: return null
        val cheaper = digest.models
            .filter {
                it.providerID == candidate.providerID
                    && it.id != candidate.id
                    && it.avgCostPerSession < candidate.avgCostPerSession * 0.5
            }
            .minByOrNull { it.avgCostPerSession } ?: return null
        val perSessionDelta = candidate.avgCostPerSession - cheaper.avgCostPerSession
        val weeklyImpact = perSessionDelta * candidate.sessionCount
        if (weeklyImpact < 1.0) return null
        return VerdictRecommendation(
            id = UUID.randomUUID().toString(),
            headline = "Try ${cheaper.id} for routine work",
            rationale = "${candidate.id} cost $${threeDecimals(candidate.avgCostPerSession)} per session; " +
                "${cheaper.id} averages $${threeDecimals(cheaper.avgCostPerSession)}.",
            expectedImpact = "Saves ~$${twoDecimals(weeklyImpact)}/period",
            acceptAction = VerdictAcceptAction(
                label = "Switch default",
                intent = VerdictAcceptAction.Intent.switchRouterRule,
                payload = mapOf(
                    "providerID" to candidate.providerID,
                    "fromModel" to candidate.id,
                    "toModel" to cheaper.id
                )
            ),
            citations = listOf(
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Model(candidate.id),
                    label = candidate.id
                ),
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Model(cheaper.id),
                    label = cheaper.id
                )
            ),
            confidence = if (weeklyImpact >= 5.0) InsightConfidence.HIGH else InsightConfidence.MEDIUM
        )
    }

    private fun buildHeadline(
        digest: InsightDigest,
        prior: InsightDigest?,
        window: VerdictWindow
    ): String {
        if (digest.totals.sessionCount == 0) {
            return "No sessions logged ${window.displayLabel.lowercase()}."
        }
        val costStr = "$${twoDecimals(digest.totals.costUSD)}"
        val priorTotals = prior?.totals
        if (priorTotals == null || priorTotals.costUSD <= 0) {
            return "You spent $costStr across ${digest.totals.sessionCount} sessions ${window.displayLabel.lowercase()}."
        }
        val pct = abs((digest.totals.costUSD - priorTotals.costUSD) / priorTotals.costUSD * 100)
        val direction = if (digest.totals.costUSD < priorTotals.costUSD) "under" else "over"
        return "You spent $costStr ${window.displayLabel.lowercase()} — ${pct.roundToInt()}% $direction the prior period."
    }

    private fun buildSubhead(digest: InsightDigest): String? {
        val cacheRate = cacheHitRate(digest.totals)
        if (cacheRate <= 0) return null
        val topProvider = digest.providers.maxByOrNull { it.costUSD } ?: return null
        return "Cache hit ${(cacheRate * 100).roundToInt()}% led by ${topProvider.displayName}."
    }

    private fun computeConfidence(digest: InsightDigest): InsightConfidence {
        val history = digest.daily.size
        return when {
            history >= thresholds.recommendationMinDailyHistory -> InsightConfidence.HIGH
            history >= thresholds.trendsMinDailyHistory -> InsightConfidence.MEDIUM
            else -> InsightConfidence.LOW
        }
    }

    private fun buildFollowUps(digest: InsightDigest, window: VerdictWindow): List<String> {
        val qs = mutableListOf<String>()
        digest.models.maxByOrNull { it.costUSD }?.let {
            qs.add("Why did ${it.id} cost so much ${window.displayLabel.lowercase()}?")
        }
        digest.providers.maxByOrNull { it.costUSD }?.let {
            qs.add("Show me ${it.displayName} by hour.")
        }
        if (digest.useCaseHistogram.isNotEmpty()) {
            qs.add("What was my most expensive use case?")
        }
        return qs
    }

    // MARK: - Helpers

    private fun dayCitations(digest: InsightDigest, limit: Int): List<InsightCitation> {
        if (digest.daily.isEmpty()) {
            return listOf(InsightCitation(
                id = UUID.randomUUID().toString(),
                kind = InsightCitation.Kind.Day(digest.generatedAt.take(10)),
                label = digest.generatedAt.take(10)
            ))
        }
        return digest.daily
            .sortedByDescending { it.day }
            .take(limit)
            .map { point ->
                val dateStr = point.day.take(10)
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Day(dateStr),
                    label = dateStr
                )
            }
    }

    private fun providerCitations(digest: InsightDigest, limit: Int): List<InsightCitation> {
        val cites = digest.providers
            .sortedByDescending { it.costUSD }
            .take(limit)
            .map { p ->
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Agent(p.id),
                    label = p.displayName
                )
            }
        if (cites.isEmpty()) {
            return listOf(InsightCitation(
                id = UUID.randomUUID().toString(),
                kind = InsightCitation.Kind.Agent("all"),
                label = "All providers"
            ))
        }
        return cites
    }

    private fun cacheHitRate(totals: InsightDigest.Totals): Double {
        val denom = totals.cacheReadTokens + totals.inputTokens
        if (denom <= 0) return 0.0
        return totals.cacheReadTokens.toDouble() / denom
    }

    private fun deltaPercent(
        current: Double,
        prior: Double,
        baseline: String,
        direction: VerdictDelta.Direction
    ): VerdictDelta? {
        if (prior == 0.0) return null
        val pct = (current - prior) / abs(prior) * 100
        return VerdictDelta(
            value = pct,
            unit = VerdictDelta.Unit.pct,
            baseline = baseline,
            direction = direction
        )
    }

    private fun twoDecimals(v: Double): String = String.format(Locale.US, "%.2f", v)
    private fun noDecimals(v: Double): String = String.format(Locale.US, "%.0f", v)
    private fun threeDecimals(v: Double): String = String.format(Locale.US, "%.3f", v)
    private fun oneDecimal(v: Double): String = String.format(Locale.US, "%.1f", v)

    private fun hash(verdict: InsightVerdict): String {
        val canonical = verdict.copy(
            id = "00000000-0000-0000-0000-000000000000",
            generatedAt = "1970-01-01T00:00:00Z",
            contentHash = ""
        )
        // Note: full kotlinx.serialization-based canonicalization
        // matching Swift's `RuleBasedVerdictEngine.hash(of:)` lives in
        // Phase B with the schema-gen tool. For Android Phase A we
        // hash a stable stringification of the canonical verdict.
        val payload = canonical.toString()
        val sha = MessageDigest.getInstance("SHA-256").digest(payload.toByteArray(Charsets.UTF_8))
        return sha.joinToString("") { "%02x".format(it) }
    }

    companion object {
        private val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
    }
}
