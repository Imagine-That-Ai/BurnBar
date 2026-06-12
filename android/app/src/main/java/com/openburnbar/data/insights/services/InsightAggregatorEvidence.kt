package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightEvidence

internal fun buildInsightEvidenceIndex(digest: InsightDigest): List<InsightEvidence> {
    val out = mutableListOf<InsightEvidence>()
    appendProviderEvidence(out, digest)
    appendModelEvidence(out, digest)
    appendBenchmarkEvidence(out, digest)
    appendQuotaEvidence(out, digest)
    return out
}

private fun appendProviderEvidence(out: MutableList<InsightEvidence>, digest: InsightDigest) {
    digest.providers.take(INSIGHT_EVIDENCE_ROWS_PER_SOURCE).forEach { provider ->
        val citation = InsightCitation("provider:${provider.id}", InsightCitation.Kind.Agent(provider.id), provider.displayName)
        out.add(
            InsightEvidence(
                "provider:${provider.id}",
                citation,
                "provider_summaries",
                "${provider.displayName}: ${provider.sessionCount} sessions, ${provider.totalTokens} tokens.",
                provider.costUSD,
            ),
        )
    }
}

private fun appendModelEvidence(out: MutableList<InsightEvidence>, digest: InsightDigest) {
    digest.models.take(INSIGHT_EVIDENCE_ROWS_PER_SOURCE).forEach { model ->
        val citation = InsightCitation("model:${model.id}", InsightCitation.Kind.Model(model.id), model.id)
        out.add(
            InsightEvidence(
                "model:${model.id}",
                citation,
                "model_summaries",
                "${model.id}: ${model.sessionCount} sessions, ${model.totalTokens} tokens.",
                model.costUSD,
            ),
        )
    }
}

private fun appendBenchmarkEvidence(out: MutableList<InsightEvidence>, digest: InsightDigest) {
    digest.modelBenchmarks.take(INSIGHT_BENCHMARK_EVIDENCE_LIMIT).forEach { benchmark ->
        val label = "${benchmark.attribution ?: benchmark.source} ${benchmark.taskCategory} · ${benchmark.modelID}"
        val citation =
            InsightCitation(
                "benchmark:${benchmark.id}",
                InsightCitation.Kind.Benchmark(benchmark.source, benchmark.modelID, benchmark.taskCategory),
                label,
            )
        val parts =
            buildList {
                benchmark.score?.let { add("score ${(it * 100).toInt()}/100") }
                benchmark.rank?.let { add("rank #$it") }
                benchmark.blendedCostPerMtoken?.let { add("$${"%.2f".format(it)}/MTok blended") }
                    ?: benchmark.costSignal?.let { add("cost signal ${(it * 100).toInt()}/100") }
                add("freshness ${benchmark.freshness}")
            }
        out.add(
            InsightEvidence(
                "benchmark:${benchmark.id}",
                citation,
                "model_benchmarks",
                "${benchmark.modelID} ${benchmark.taskCategory}: ${parts.joinToString()}.",
                benchmark.score,
            ),
        )
    }
}

private fun appendQuotaEvidence(out: MutableList<InsightEvidence>, digest: InsightDigest) {
    digest.quotaSnapshots.take(INSIGHT_EVIDENCE_ROWS_PER_SOURCE).forEach { quota ->
        val citation =
            InsightCitation("quota:${quota.id}", InsightCitation.Kind.Quota(quota.providerID, quota.bucketName), "${quota.providerID} ${quota.bucketName}")
        out.add(
            InsightEvidence(
                "quota:${quota.id}",
                citation,
                "quota_snapshots",
                "${quota.providerID} ${quota.bucketName}: ${quota.used} used.",
                quota.limit?.let { if (it > 0) quota.used / it else 0.0 },
            ),
        )
    }
}
