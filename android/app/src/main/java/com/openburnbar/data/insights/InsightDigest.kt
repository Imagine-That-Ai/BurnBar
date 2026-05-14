package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * The sanitized, privacy-bounded data snapshot shipped to the selected model
 * when authoring/refreshing a canvas.
 * Hard guarantees:
 *   - No raw file contents, source code, or secrets.
 *   - No conversation message bodies.
 *   - No API keys or credential labels.
 *   - Device names replaced with hashed IDs.
 *   - Project paths replaced with project_xxx IDs.
 *   - Total encoded byte size <= 24 KB.
 */
@Serializable
data class InsightDigest(
    val contentHash: String = "",
    val generatedAt: String = "",
    val windowStart: String = "",
    val windowEnd: String = "",
    val rowCount: Int = 0,
    val totals: Totals = Totals(),
    val providers: List<ProviderSnapshot> = emptyList(),
    val models: List<ModelSnapshot> = emptyList(),
    val projects: List<ProjectSnapshot> = emptyList(),
    val devices: List<DeviceSnapshot> = emptyList(),
    val daily: List<DailyPoint> = emptyList(),
    val hourly: List<Int> = emptyList(),
    val useCaseHistogram: List<UseCaseBin> = emptyList(),
    val agentFocusSignals: List<AgentFocusSignal> = emptyList(),
    val modelFocusSignals: List<ModelFocusSignal> = emptyList(),
    val quotaSnapshots: List<QuotaSnapshotSummary> = emptyList(),
    val operatingActions: List<ActionDigest> = emptyList(),
    val summaryRunsLog: List<SummaryRunDigest> = emptyList(),
    val modelBenchmarks: List<ModelBenchmarkSummary> = emptyList(),
    val anomalies: List<PrecomputedAnomaly> = emptyList(),
    val glossary: InsightTaxonomy = InsightTaxonomy.DEFAULT
) {
    companion object {
        const val MAX_ENCODED_BYTES: Int = 24 * 1024
    }

    @Serializable
    data class Totals(
        val costUSD: Double = 0.0, val totalTokens: Long = 0,
        val inputTokens: Long = 0, val outputTokens: Long = 0,
        val reasoningTokens: Long = 0, val cacheReadTokens: Long = 0,
        val cacheCreationTokens: Long = 0, val sessionCount: Int = 0
    )

    @Serializable
    data class ProviderSnapshot(
        val id: String, val displayName: String, val costUSD: Double = 0.0,
        val totalTokens: Long = 0, val sessionCount: Int = 0,
        val topModels: List<String> = emptyList(),
        val topInferredTaskTitles: List<String> = emptyList(),
        val topKeyTools: List<String> = emptyList()
    )

    @Serializable
    data class ModelSnapshot(
        val id: String, val providerID: String, val costUSD: Double = 0.0,
        val totalTokens: Long = 0, val sessionCount: Int = 0,
        val avgCostPerSession: Double = 0.0, val cacheHitRate: Double = 0.0,
        val topInferredTaskTitles: List<String> = emptyList(),
        val topProjects: List<String> = emptyList()
    )

    @Serializable
    data class ProjectSnapshot(
        val id: String, val displayName: String, val costUSD: Double = 0.0,
        val totalTokens: Long = 0, val sessionCount: Int = 0
    )

    @Serializable
    data class DeviceSnapshot(
        val id: String, val displayName: String, val costUSD: Double = 0.0,
        val sessionCount: Int = 0
    )

    @Serializable
    data class DailyPoint(
        val day: String, val costUSD: Double = 0.0, val totalTokens: Long = 0,
        val sessionCount: Int = 0, val perProvider: Map<String, Double> = emptyMap()
    )

    @Serializable
    data class UseCaseBin(val id: String, val count: Int, val costUSD: Double = 0.0)

    @Serializable
    data class AgentFocusSignal(val agentID: String, val focus: String, val weight: Double)

    @Serializable
    data class ModelFocusSignal(val modelID: String, val focus: String, val weight: Double)

    @Serializable
    data class QuotaSnapshotSummary(
        val id: String, val providerID: String, val bucketName: String,
        val used: Double, val limit: Double? = null, val resetsAt: String? = null
    )

    @Serializable
    data class ActionDigest(
        val id: String, val kind: String, val projectID: String? = null,
        val occurredAt: String, val summary: String
    )

    @Serializable
    data class SummaryRunDigest(
        val id: String, val providerID: String, val modelID: String,
        val costUSD: Double = 0.0, val ranAt: String
    )

    @Serializable
    data class ModelBenchmarkSummary(
        val id: String,
        val source: String,
        val sourceURL: String? = null,
        val attribution: String? = null,
        val fetchedAt: String,
        val modelID: String,
        val providerID: String? = null,
        val taskCategory: String,
        val score: Double? = null,
        val rank: Int? = null,
        val costSignal: Double? = null,
        val latencySignal: Double? = null,
        val contextWindowTokens: Int? = null,
        val reliabilitySignal: Double? = null,
        val confidence: Double? = null,
        val freshness: String,
        val inputCostPerMtoken: Double? = null,
        val outputCostPerMtoken: Double? = null,
        val blendedCostPerMtoken: Double? = null
    )

    @Serializable
    data class PrecomputedAnomaly(
        val id: String, val occurredAt: String, val label: String,
        val score: Double, val detail: String? = null
    )
}
