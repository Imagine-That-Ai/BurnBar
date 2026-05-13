package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisContext
import com.openburnbar.data.insights.InsightAnalysisAuditEntry
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.repos.InsightAnalysisAuditLogRepository
import kotlinx.coroutines.flow.first

/**
 * Android aggregator. Mirrors the Swift `MacInsightAggregator` /
 * `MobileInsightAggregator` shape: pulls a Firestore-backed digest from the
 * underlying [InsightDataSource], wraps it in an [InsightAnalysisContext]
 * (digest + evidence index + budget report), and folds the last ~10 audit
 * rows into `priorRunSummaries` so generated widgets don't loop.
 *
 * `dataSource` defaults to [FirestoreInsightDataSource] in production. Tests
 * inject [InMemoryInsightDataSource] for hermetic coverage.
 */
class AndroidInsightAggregator(
    private val dataSource: InsightDataSource = FirestoreInsightDataSource(),
    private val auditLog: InsightAnalysisAuditLogRepository? = null,
) {

    /** Build the LLM-safe analysis context for a given filter. */
    suspend fun buildContext(filter: InsightFilter): InsightAnalysisContext {
        val digest = dataSource.buildDigest(filter)
        val priors = loadPriorRunSummaries()
        return InsightAggregator.buildContext(
            digest = digest,
            includedDataSources = INCLUDED_SOURCES,
            priorRunSummaries = priors,
        )
    }

    private suspend fun loadPriorRunSummaries(): List<String> {
        val log = auditLog ?: return emptyList()
        return log.readAll(limit = 10).mapNotNull { entry ->
            if (entry.status != InsightAnalysisAuditEntry.Status.SUCCEEDED &&
                entry.status != InsightAnalysisAuditEntry.Status.PARTIAL
            ) return@mapNotNull null
            val model = entry.selectedModel.displayName
            val day = entry.ranAt.take(10)
            "$day: $model ran an analysis (${entry.resultHash.take(8)})."
        }
    }

    companion object {
        /** Stable identifiers surfaced in the audit row's budget report. */
        val INCLUDED_SOURCES: List<String> = listOf(
            "firestore_rollups",
            "firestore_provider_summaries",
            "firestore_model_summaries",
            "firestore_quota_snapshots",
            "android_prior_analyses",
        )
    }
}
