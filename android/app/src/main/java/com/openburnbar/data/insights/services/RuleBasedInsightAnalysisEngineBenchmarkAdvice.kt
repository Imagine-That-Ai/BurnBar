@file:Suppress("MatchingDeclarationName")

package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.ValueFormat

internal data class RuleBasedBenchmarkAdvice(
    val findings: List<InsightFinding>,
    val recommendations: List<InsightRecommendation>,
    val widgets: List<InsightGeneratedWidget>,
)

internal fun ruleBasedModelBenchmarkAdvice(
    digest: InsightDigest,
    topModel: InsightDigest.ModelSnapshot?,
    selectedModel: InsightModelTag,
    window: InsightTimeWindow,
): RuleBasedBenchmarkAdvice {
    val benchmarks = digest.modelBenchmarks
    if (benchmarks.isEmpty()) return RuleBasedBenchmarkAdvice(emptyList(), emptyList(), emptyList())
    val candidates = resolveRuleBasedBenchmarkCandidates(topModel, benchmarks)
    val findings = buildRuleBasedDesignFinding(topModel, candidates.bestDesign)
    val recommendations = buildRuleBasedBenchmarkRecommendations(topModel, candidates, benchmarks)
    val widgets = buildRuleBasedBenchmarkWidget(benchmarks, digest, selectedModel, window)
    return RuleBasedBenchmarkAdvice(findings.take(2), recommendations.take(INSIGHT_MAX_BENCHMARK_RECOMMENDATIONS), widgets.take(2))
}

private data class RuleBasedBenchmarkCandidates(
    val topBenchmark: InsightDigest.ModelBenchmarkSummary?,
    val bestDesign: InsightDigest.ModelBenchmarkSummary?,
    val cheapestSimilar: InsightDigest.ModelBenchmarkSummary?,
)

private fun resolveRuleBasedBenchmarkCandidates(
    topModel: InsightDigest.ModelSnapshot?,
    benchmarks: List<InsightDigest.ModelBenchmarkSummary>,
): RuleBasedBenchmarkCandidates {
    val topBenchmark =
        topModel?.let { model ->
            benchmarks.filter { ruleBasedNormalizedModelID(it.modelID) == ruleBasedNormalizedModelID(model.id) }
                .maxByOrNull { it.score ?: -1.0 }
        }
    val bestDesign =
        benchmarks
            .filter { it.taskCategory == "design" }
            .maxByOrNull { it.score ?: -1.0 }
            ?: benchmarks
                .filter { it.taskCategory == "coding" }
                .maxByOrNull { it.score ?: -1.0 }
    val cheapestSimilar =
        topModel?.let { current ->
            val baselineCost = (topBenchmark?.costSignal ?: 0.0) + INSIGHT_BENCHMARK_COST_MARGIN
            val baselineScore = topBenchmark?.score ?: 0.0
            benchmarks
                .filter { ruleBasedNormalizedModelID(it.modelID) != ruleBasedNormalizedModelID(current.id) }
                .filter { it.costSignal != null && it.costSignal > baselineCost }
                .filter { topBenchmark?.score == null || it.score == null || it.score >= baselineScore -
                    INSIGHT_BENCHMARK_SCORE_TOLERANCE }
                .maxWithOrNull(compareBy<InsightDigest.ModelBenchmarkSummary> { it.costSignal ?: 0.0 }.thenBy {
                    it.score ?: 0.0 })
        }
    return RuleBasedBenchmarkCandidates(topBenchmark, bestDesign, cheapestSimilar)
}

private fun buildRuleBasedDesignFinding(
    topModel: InsightDigest.ModelSnapshot?,
    bestDesign: InsightDigest.ModelBenchmarkSummary?,
): List<InsightFinding> {
    if (topModel == null || bestDesign == null || ruleBasedNormalizedModelID(bestDesign.modelID) ==
        ruleBasedNormalizedModelID(topModel.id)) {
        return emptyList()
    }
    return listOf(
        InsightFinding(
            title = "UI/design work should be checked against ${bestDesign.modelID}",
            whyItMatters = "${topModel.id} leads spend, but ${bestDesign.modelID} is the strongest cited ${bestDesign.taskCategory} benchmark candidate${ruleBasedScorePhrase(bestDesign)}.",
            evidence =
            listOf(
                InsightCitation("model:${topModel.id}", InsightCitation.Kind.Model(topModel.id), topModel.id),
                ruleBasedBenchmarkCitation(bestDesign),
            ),
            confidence = ruleBasedBenchmarkConfidence(bestDesign),
            severity = InsightSeverity.MEDIUM,
            recommendedAction =
                "Use ${bestDesign.modelID} for the next UI-heavy task only if quota and routing are healthy.",
        ),
    )
}

private fun buildRuleBasedBenchmarkRecommendations(
    topModel: InsightDigest.ModelSnapshot?,
    candidates: RuleBasedBenchmarkCandidates,
    benchmarks: List<InsightDigest.ModelBenchmarkSummary>,
): List<InsightRecommendation> {
    val recommendations = mutableListOf<InsightRecommendation>()
    if (topModel != null && candidates.cheapestSimilar != null) {
        val cheapestSimilar = candidates.cheapestSimilar
        val impact =
            cheapestSimilar.blendedCostPerMtoken?.let {
                "$${"%.2f".format(it)}/MTok blended; validate quality before moving routine work."
            }
                ?: cheapestSimilar.costSignal?.let {
                    "Cost signal ${(it * 100).toInt()}/100; exact savings need provider price confirmation."
                }
        recommendations.add(
            InsightRecommendation(
                title = "${cheapestSimilar.modelID} looks cheaper at similar benchmark strength",
                rationale =
                "${topModel.id} is your largest model cost contributor. ${cheapestSimilar.modelID} is close " +
                    "on benchmark evidence${ruleBasedScorePhrase(cheapestSimilar)} and has a stronger cost signal.",
                recommendedAction = "Route one routine ${cheapestSimilar.taskCategory} session to ${cheapestSimilar.modelID}, then compare output quality before changing defaults.",
                estimatedImpact = impact,
                evidence =
                listOf(
                    InsightCitation("model:${topModel.id}", InsightCitation.Kind.Model(topModel.id), topModel.id),
                    ruleBasedBenchmarkCitation(cheapestSimilar),
                ),
                confidence = ruleBasedBenchmarkConfidence(cheapestSimilar),
                severity = InsightSeverity.HIGH,
            ),
        )
    }
    benchmarks.maxByOrNull { it.score ?: -1.0 }?.let { best ->
        recommendations.add(
            InsightRecommendation(
                title = "Do not blindly switch to ${best.modelID}",
                rationale = "Benchmarks are advisory. A higher public score loses when quota, account health, privacy mode, or task fit is worse.",
                recommendedAction = "Treat ${best.modelID} as a candidate for ${best.taskCategory}, not as a global default.",
                estimatedImpact = "Avoids over-routing premium or unavailable models.",
                evidence = listOf(ruleBasedBenchmarkCitation(best)),
                confidence = ruleBasedBenchmarkConfidence(best),
                severity = InsightSeverity.MEDIUM,
            ),
        )
    }
    return recommendations
}

private fun buildRuleBasedBenchmarkWidget(
    benchmarks: List<InsightDigest.ModelBenchmarkSummary>,
    digest: InsightDigest,
    selectedModel: InsightModelTag,
    window: InsightTimeWindow,
): List<InsightGeneratedWidget> {
    val used = digest.models.associateBy { ruleBasedNormalizedModelID(it.id) }
    val rows =
        benchmarks
            .filter { it.score != null || it.rank != null }
            .sortedWith(
                compareByDescending<InsightDigest.ModelBenchmarkSummary> {
                    used.containsKey(ruleBasedNormalizedModelID(it.modelID)) }
                    .thenByDescending { it.score ?: -1.0 }
                    .thenBy { it.rank ?: Int.MAX_VALUE },
            )
            .take(INSIGHT_BENCHMARK_RANKING_ROW_LIMIT)
            .map {
                InsightWidgetData.Ranking.Row(
                    id = it.id,
                    label = it.modelID,
                    value = it.score ?: it.rank?.let { rank -> 1.0 / rank.coerceAtLeast(1) } ?: 0.0,
                    secondaryLabel = listOf(it.taskCategory, it.attribution ?: it.source).joinToString(" · "),
                )
            }
    if (rows.isEmpty()) return emptyList()
    val widget =
        InsightWidget(
            kind = InsightWidgetKind.BAR_RANKING,
            title = "Benchmark-aware model board",
            spec = InsightWidgetSpec.Ranking(InsightWidgetSpec.RankingSpec()),
            dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.MODEL, INSIGHT_BENCHMARK_RANKING_ROW_LIMIT, window),
            data = InsightWidgetData.Ranking(rows, ValueFormat.PERCENT, "Benchmark"),
            freshness = com.openburnbar.data.insights.InsightFreshness.FRESH,
            modelTag = selectedModel,
            rationale = "Ranks cited benchmark candidates beside models used in this window.",
        )
    return listOf(
        InsightGeneratedWidget(
            widget = widget,
            reason = "Shows used models against public benchmark evidence.",
            citations = benchmarks.take(INSIGHT_BENCHMARK_RANKING_ROW_LIMIT).map { ruleBasedBenchmarkCitation(it) },
        ),
    )
}

internal fun ruleBasedBenchmarkCitation(benchmark: InsightDigest.ModelBenchmarkSummary): InsightCitation =
    InsightCitation(
    "benchmark:${benchmark.id}",
    InsightCitation.Kind.Benchmark(benchmark.source, benchmark.modelID, benchmark.taskCategory),
    "${benchmark.attribution ?: benchmark.source} ${benchmark.taskCategory}",
)

internal fun ruleBasedBenchmarkConfidence(benchmark: InsightDigest.ModelBenchmarkSummary): InsightConfidence {
    val conf = benchmark.confidence ?: INSIGHT_DEFAULT_BENCHMARK_CONFIDENCE
    return when {
        conf >= INSIGHT_HIGH_CONFIDENCE_FLOOR -> InsightConfidence.HIGH
        conf <= INSIGHT_LOW_CONFIDENCE_CEILING -> InsightConfidence.LOW
        else -> InsightConfidence.MEDIUM
    }
}

internal fun ruleBasedScorePhrase(benchmark: InsightDigest.ModelBenchmarkSummary): String = benchmark.score?.let {
    " (${(it * 100).toInt()}/100)"
} ?: benchmark.rank?.let { " (#$it)" } ?: ""

internal fun ruleBasedNormalizedModelID(
    value: String): String = value.lowercase().replace("_", "-").replace(".", "-").replace("/", "-")
