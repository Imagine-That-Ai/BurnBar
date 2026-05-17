package com.openburnbar.data.insights.verdict

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightModelTag
import kotlinx.serialization.Serializable

/**
 * Kotlin mirror of the Swift verdict value objects in
 * `OpenBurnBarCore/SharedModels/Insights/Verdict/`.
 *
 * Plan §4.1 — these will eventually be generated from the canonical
 * JSON Schema once `tools/insights-schema-gen` ships. Hand-written here
 * to unblock Android Phase A. Keep this file byte-for-byte aligned with
 * the Swift sources; the round-trip test
 * `GeneratedInsightsModelsRoundTripTest` (Phase B) will enforce parity.
 */

/** The time horizon a verdict summarizes. */
@Serializable
enum class VerdictWindow {
    today,
    yesterday,
    thisWeek,
    lastWeek,
    thisMonth,
    lastMonth,
    quarter,
    year;

    val displayLabel: String get() = when (this) {
        today -> "Today"
        yesterday -> "Yesterday"
        thisWeek -> "This week"
        lastWeek -> "Last week"
        thisMonth -> "This month"
        lastMonth -> "Last month"
        quarter -> "This quarter"
        year -> "This year"
    }

    /** Cache TTL in milliseconds — mirrors the Swift `cacheTTL`. */
    val cacheTTLMillis: Long get() = when (this) {
        today -> 2L * 60 * 60 * 1000
        yesterday -> 12L * 60 * 60 * 1000
        thisWeek, lastWeek -> 24L * 60 * 60 * 1000
        thisMonth, lastMonth -> 7L * 24 * 60 * 60 * 1000
        quarter -> 14L * 24 * 60 * 60 * 1000
        year -> 30L * 24 * 60 * 60 * 1000
    }
}

/** Dominant accent identity of a verdict. */
@Serializable
enum class ProviderTint {
    ember,
    whimsy,
    silver,
    mercury,
    prism,
    ember_alt,
    neutral;

    companion object {
        fun forProviderKey(key: String?): ProviderTint = when (key?.lowercase()) {
            "anthropic", "claude" -> ember
            "openai", "gpt" -> whimsy
            "pi", "ollama", "local" -> silver
            "hermes" -> mercury
            "openrouter" -> prism
            "burnbar", "burnbar-hosted", "hosted" -> ember_alt
            else -> neutral
        }
    }
}

/** A signed change against a baseline. */
@Serializable
data class VerdictDelta(
    val value: Double,
    val unit: Unit,
    val baseline: String,
    val direction: Direction = Direction.neutral
) {
    @Serializable
    enum class Unit { usd, tokens, sessions, pct, days, ms, ratio, count }

    @Serializable
    enum class Direction { higherIsBetter, lowerIsBetter, neutral }

    val isFavorable: Boolean get() = when (direction) {
        Direction.higherIsBetter -> value > 0
        Direction.lowerIsBetter -> value < 0
        Direction.neutral -> false
    }
}

/** The shape of a single verdict bullet. */
@Serializable
enum class VerdictBulletType {
    reflective_fact, comparison, pattern, anomaly,
    recommendation, discovery, forecast, achievement, risk, story
}

/** A one-tap follow-through. */
@Serializable
data class VerdictAcceptAction(
    val label: String,
    val intent: Intent,
    val payload: Map<String, String>? = null
) {
    @Serializable
    enum class Intent {
        switchRouterRule,
        pinCanvas,
        openSession,
        openSettings,
        openExternal,
        createMission,
        investigate,
        snooze
    }
}

/** One of the three Activity-style rings on the verdict hero. */
@Serializable
data class VerdictRing(
    val identity: Identity,
    val label: String,
    val current: Double,
    val target: Double,
    val unit: VerdictDelta.Unit,
    val valueLabel: String,
    val delta: VerdictDelta? = null,
    val tint: ProviderTint = ProviderTint.neutral
) {
    @Serializable
    enum class Identity { spend, cache, sessions }

    /** Clamped progress in [0, 1.5]. */
    val progress: Double get() {
        if (target <= 0.0) return 0.0
        return (current / target).coerceIn(0.0, 1.5)
    }

    val isNearCap: Boolean get() {
        if (target <= 0.0) return false
        val p = current / target
        return p >= 0.9 && p < 1.05
    }
}

/** A single headline KPI tile under the verdict hero. */
@Serializable
data class VerdictNumber(
    val id: String,
    val label: String,
    val value: String,
    val rawValue: Double,
    val unit: VerdictDelta.Unit,
    val delta: VerdictDelta? = null,
    val sparkline: List<Double>? = null,
    val drillIntent: VerdictAcceptAction.Intent? = null,
    val drillPayload: Map<String, String>? = null
)

/** One opinionated claim in the verdict. */
@Serializable
data class VerdictBullet(
    val id: String,
    val type: VerdictBulletType,
    val claim: String,
    val citations: List<InsightCitation>,
    val delta: VerdictDelta? = null,
    val acceptAction: VerdictAcceptAction? = null,
    val confidence: InsightConfidence = InsightConfidence.MEDIUM
)

/** A discrete anomaly surfaced on the verdict hero. */
@Serializable
data class VerdictAnomaly(
    val id: String,
    val label: String,
    val detail: String,
    val occurredAt: String,
    val zScore: Double,
    val affectedSessionIDs: List<String> = emptyList(),
    val citations: List<InsightCitation> = emptyList(),
    val acceptAction: VerdictAcceptAction? = null
)

/** The single surfaced recommendation. */
@Serializable
data class VerdictRecommendation(
    val id: String,
    val headline: String,
    val rationale: String,
    val expectedImpact: String,
    val acceptAction: VerdictAcceptAction,
    val citations: List<InsightCitation>,
    val confidence: InsightConfidence = InsightConfidence.MEDIUM
)

/** Vercel-style horizontal flame strip of one session. */
@Serializable
data class VerdictTraceStrip(
    val id: String,
    val sessionID: String,
    val lanes: List<TraceLane>,
    val ticks: List<TraceTick> = emptyList(),
    val startedAt: String,
    val endedAt: String,
    val summary: String,
    val costUSD: Double,
    val didTimeout: Boolean = false,
    val tint: ProviderTint = ProviderTint.neutral
)

@Serializable
data class TraceLane(
    val id: String,
    val kind: Kind,
    val label: String,
    val startOffsetSeconds: Double,
    val durationSeconds: Double,
    val costUSD: Double? = null,
    val tint: ProviderTint = ProviderTint.neutral
) {
    @Serializable
    enum class Kind { model, tool, cache, prompt, response, retry }
}

@Serializable
data class TraceTick(
    val id: String,
    val offsetSeconds: Double,
    val costUSD: Double,
    val label: String? = null
)

/**
 * The single top-level value the verdict pipeline produces.
 * Mirrors `OpenBurnBarCore.InsightVerdict`.
 */
@Serializable
data class InsightVerdict(
    val id: String,
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val generatedAt: String,
    val window: VerdictWindow,
    val headline: String,
    val subhead: String? = null,
    val rings: List<VerdictRing>,
    val keyNumbers: List<VerdictNumber> = emptyList(),
    val sessionTrace: VerdictTraceStrip? = null,
    val bullets: List<VerdictBullet> = emptyList(),
    val anomaly: VerdictAnomaly? = null,
    val recommendation: VerdictRecommendation? = null,
    val moodSwatch: ProviderTint = ProviderTint.neutral,
    val provenance: InsightModelTag,
    val confidence: InsightConfidence = InsightConfidence.MEDIUM,
    val followUps: List<String> = emptyList(),
    val isRuleBased: Boolean = false,
    val contentHash: String = ""
) {
    val isRenderable: Boolean
        get() = rings.size == REQUIRED_RING_COUNT
            && headline.isNotEmpty()
            && (bullets.isEmpty() || bullets.all { it.citations.isNotEmpty() })

    companion object {
        const val CURRENT_SCHEMA_VERSION: Int = 1
        const val HEADLINE_MAX_LENGTH: Int = 80
        const val SUBHEAD_MAX_LENGTH: Int = 120
        const val MAX_BULLETS: Int = 4
        const val MAX_KEY_NUMBERS: Int = 4
        const val MAX_FOLLOW_UPS: Int = 3
        const val REQUIRED_RING_COUNT: Int = 3
    }
}
