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

private const val CHEAPER_MODEL_COST_RATIO = 0.5
private const val RECOMMENDATION_MIN_SESSIONS = 5

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
    val calendar: Calendar = Calendar.getInstance(),
) {
    data class Thresholds(
        val cacheTargetRate: Double,
        val sessionTargetMinimum: Int,
        val spendBudgetFloor: Double,
        val spendBudgetGrowthRate: Double,
        val anomalyZThreshold: Double,
        val recommendationMinDailyHistory: Int,
        val trendsMinDailyHistory: Int,
        val forecastMinDailyHistory: Int,
    ) {
        companion object {
            val DEFAULT =
                Thresholds(
                    cacheTargetRate = 0.85,
                    sessionTargetMinimum = 1,
                    spendBudgetFloor = 5.0,
                    spendBudgetGrowthRate = 1.2,
                    anomalyZThreshold = 2.0,
                    recommendationMinDailyHistory = 60,
                    trendsMinDailyHistory = 14,
                    forecastMinDailyHistory = 30,
                )
        }
    }

    // MARK: - Entry point

    fun produce(digest: InsightDigest, window: VerdictWindow, priorDigest: InsightDigest? = null, now: Date = Date()): InsightVerdict {
        val rings = buildVerdictRings(thresholds, digest, priorDigest)
        val keyNumbers = buildVerdictKeyNumbers(digest, priorDigest)
        val bullets = buildVerdictBullets(thresholds, digest, priorDigest)
        val anomaly = buildAnomaly(digest)
        val recommendation = buildRecommendation(digest)
        val dominantProvider = digest.providers.maxByOrNull { it.costUSD }?.id
        val mood = ProviderTint.forProviderKey(dominantProvider)
        val provenance =
            InsightModelTag(
                providerKey = "local-rules",
                modelID = "rule-based-v2",
                displayName = "Local rules",
                egressTier = InsightEgressTier.LOCAL_ONLY,
                stampedAt = isoFormatter.format(now),
            )

        val verdict =
            InsightVerdict(
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
                contentHash = "",
            )
        return verdict.copy(contentHash = hash(verdict))
    }

    // MARK: - Anomaly + recommendation + headline/subhead

    private fun buildAnomaly(digest: InsightDigest): VerdictAnomaly? {
        val top =
            digest.anomalies
                .filter { it.score >= thresholds.anomalyZThreshold }
                .maxByOrNull { it.score } ?: return null
        return VerdictAnomaly(
            id = UUID.randomUUID().toString(),
            label = top.label,
            detail = top.detail ?: "",
            occurredAt = top.occurredAt,
            zScore = top.score,
            citations =
            listOf(
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Anomaly(top.id),
                    label = top.label,
                ),
            ),
            acceptAction =
            VerdictAcceptAction(
                label = "Investigate",
                intent = VerdictAcceptAction.Intent.investigate,
                payload = mapOf("anomalyID" to top.id),
            ),
        )
    }

    private fun buildRecommendation(digest: InsightDigest): VerdictRecommendation? {
        if (digest.daily.size < thresholds.recommendationMinDailyHistory) return null
        val candidate =
            digest.models
                .filter { it.sessionCount >= RECOMMENDATION_MIN_SESSIONS && it.costUSD >= 1.0 }
                .maxByOrNull { it.costUSD }
        val cheaper =
            candidate?.let { top ->
                digest.models
                    .filter {
                        it.providerID == top.providerID &&
                            it.id != top.id &&
                            it.avgCostPerSession < top.avgCostPerSession * CHEAPER_MODEL_COST_RATIO
                    }
                    .minByOrNull { it.avgCostPerSession }
            }
        val weeklyImpact =
            if (candidate != null && cheaper != null) {
                (candidate.avgCostPerSession - cheaper.avgCostPerSession) * candidate.sessionCount
            } else {
                0.0
            }
        if (candidate == null || cheaper == null || weeklyImpact < 1.0) return null
        return VerdictRecommendation(
            id = UUID.randomUUID().toString(),
            headline = "Try ${cheaper.id} for routine work",
            rationale =
            "${candidate.id} cost $${threeDecimals(candidate.avgCostPerSession)} per session; " +
                "${cheaper.id} averages $${threeDecimals(cheaper.avgCostPerSession)}.",
            expectedImpact = "Saves ~$${twoDecimals(weeklyImpact)}/period",
            acceptAction =
            VerdictAcceptAction(
                label = "Switch default",
                intent = VerdictAcceptAction.Intent.switchRouterRule,
                payload =
                mapOf(
                    "providerID" to candidate.providerID,
                    "fromModel" to candidate.id,
                    "toModel" to cheaper.id,
                ),
            ),
            citations =
            listOf(
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Model(candidate.id),
                    label = candidate.id,
                ),
                InsightCitation(
                    id = UUID.randomUUID().toString(),
                    kind = InsightCitation.Kind.Model(cheaper.id),
                    label = cheaper.id,
                ),
            ),
            confidence = if (weeklyImpact >= 5.0) InsightConfidence.HIGH else InsightConfidence.MEDIUM,
        )
    }

    private fun buildHeadline(digest: InsightDigest, prior: InsightDigest?, window: VerdictWindow): String {
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

    private fun cacheHitRate(totals: InsightDigest.Totals): Double {
        val denom = totals.cacheReadTokens + totals.inputTokens
        if (denom <= 0) return 0.0
        return totals.cacheReadTokens.toDouble() / denom
    }

    private fun twoDecimals(v: Double): String = String.format(Locale.US, "%.2f", v)

    private fun threeDecimals(v: Double): String = String.format(Locale.US, "%.3f", v)

    private fun hash(verdict: InsightVerdict): String {
        val canonical =
            verdict.copy(
                id = "00000000-0000-0000-0000-000000000000",
                generatedAt = "1970-01-01T00:00:00Z",
                contentHash = "",
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
        private val isoFormatter =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
    }
}
