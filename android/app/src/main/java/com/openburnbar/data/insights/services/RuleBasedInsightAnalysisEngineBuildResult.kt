
package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.ValueFormat

internal data class RuleBasedBuildState(
    val widgets: MutableList<InsightGeneratedWidget>,
    val findings: MutableList<InsightFinding>,
    val recommendations: MutableList<InsightRecommendation>,
    val headline: String,
    val body: String,
    val citations: List<InsightCitation>,
)

internal fun buildRuleBasedInsightResult(
    request: InsightAnalysisRequest,
    platform: InsightAnalysisPlatform,
): InsightAnalysisResult {
    val digest = request.context.digest
    val topProvider = digest.providers.maxByOrNull { it.costUSD }
    val topModel = digest.models.maxByOrNull { it.costUSD }
    val window = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d
    val citations =
        request.context.evidenceIndex.map { it.citation }
            .ifEmpty { listOf(InsightCitation("empty-context", InsightCitation.Kind.Query("empty-insight-context"), "No synced activity")) }
    val state = buildRuleBasedNarrativeSection(request, digest, citations)
    appendRuleBasedProviderRanking(state, digest, topProvider, request, window)
    appendRuleBasedTimeSeries(state, digest, request, window)
    appendRuleBasedDonut(state, digest, request, window)
    appendRuleBasedModelRanking(state, digest, request, window)
    appendRuleBasedTopModelRecommendation(state, topModel)
    val benchmarkAdvice = ruleBasedModelBenchmarkAdvice(digest, topModel, request.selectedModel, window)
    state.findings.addAll(benchmarkAdvice.findings)
    state.recommendations.addAll(benchmarkAdvice.recommendations)
    state.widgets.addAll(benchmarkAdvice.widgets)
    val missionAdvice =
        ruleBasedMissionIntelligence(
            digest = digest,
            topProvider = topProvider,
            topModel = topModel,
            sourceInsightIDs = state.findings.map { it.id },
        )
    state.findings.addAll(missionAdvice.findings)
    state.recommendations.addAll(missionAdvice.recommendations)
    return assembleRuleBasedInsightResult(
        RuleBasedFinalAssembly(
            request = request,
            platform = platform,
            state = state,
            missionAdvice = missionAdvice,
            topProvider = topProvider,
            topModel = topModel,
            digest = digest,
        ),
    )
}

internal data class RuleBasedFinalAssembly(
    val request: InsightAnalysisRequest,
    val platform: InsightAnalysisPlatform,
    val state: RuleBasedBuildState,
    val missionAdvice: RuleBasedMissionAdvice,
    val topProvider: InsightDigest.ProviderSnapshot?,
    val topModel: InsightDigest.ModelSnapshot?,
    val digest: InsightDigest,
)

private fun ruleBasedHeadlineFor(digest: InsightDigest): String =
    if (digest.totals.sessionCount > 0) {
        "${ruleBasedCurrency(digest.totals.costUSD)} analyzed across ${digest.totals.sessionCount} sessions"
    } else {
        "No synced activity in this window"
    }

private fun ruleBasedBodyFor(digest: InsightDigest): String =
    if (digest.totals.sessionCount > 0) {
        val topProvider = digest.providers.maxByOrNull { it.costUSD }
        "The main thing to inspect is whether ${topProvider?.displayName ?: "your top provider"} is doing the right work for its cost profile."
    } else {
        "Insights has no usable rows for this window yet. Refresh sync or choose a broader window."
    }

private fun buildRuleBasedNarrativeSection(
    request: InsightAnalysisRequest,
    digest: InsightDigest,
    citations: List<InsightCitation>,
): RuleBasedBuildState {
    val headline = ruleBasedHeadlineFor(digest)
    val body = ruleBasedBodyFor(digest)
    val narrative =
        InsightWidgetData.Narrative(
            headline = headline,
            body = body,
            bullets =
            listOf(
                "${digest.totals.sessionCount} sessions and ${digest.totals.totalTokens} tokens.",
                "${digest.providers.maxByOrNull { it.costUSD }?.displayName ?: "No provider"} led provider spend.",
            ),
            citations = citations.take(INSIGHT_MAX_CITATIONS),
            sparkline = digest.daily.map { it.costUSD },
        )
    val narrativeWidget =
        ruleBasedGeneratedWidget(
            BoundInsightWidgetParams(
                kind = InsightWidgetKind.NARRATIVE,
                title = "What changed",
                dataBinding = InsightDataBinding.Narrative(narrative),
                data = narrative,
                reason = "Default brief lead finding.",
                modelTag = request.selectedModel,
                citations = citations.take(INSIGHT_MAX_CITATIONS),
            ),
        )
    val findings =
        mutableListOf(
            InsightFinding(
                title = headline,
                whyItMatters = body,
                evidence = citations.take(INSIGHT_MAX_CITATIONS),
                confidence = if (digest.totals.sessionCount > 0) InsightConfidence.HIGH else InsightConfidence.LOW,
                severity = InsightSeverity.MEDIUM,
                recommendedAction =
                if (digest.totals.sessionCount > 0) {
                    "Open the generated provider ranking and compare the top model against cheaper configured routes."
                } else {
                    "Refresh data or switch the window to 30 days."
                },
                generatedWidgetID = narrativeWidget.widget.id,
            ),
        )
    return RuleBasedBuildState(
        widgets = mutableListOf(narrativeWidget),
        findings = findings,
        recommendations = mutableListOf(),
        headline = headline,
        body = body,
        citations = citations,
    )
}

private fun appendRuleBasedProviderRanking(
    state: RuleBasedBuildState,
    digest: InsightDigest,
    topProvider: InsightDigest.ProviderSnapshot?,
    request: InsightAnalysisRequest,
    window: InsightTimeWindow,
) {
    if (topProvider == null || digest.providers.isEmpty()) return
    val providerCitation = InsightCitation("provider:${topProvider.id}", InsightCitation.Kind.Agent(topProvider.id), topProvider.displayName)
    val rankingRows =
        digest.providers
            .sortedByDescending { it.costUSD }
            .take(INSIGHT_RANKING_ROW_LIMIT)
            .map { p ->
                InsightWidgetData.Ranking.Row(
                    id = "p:${p.id}",
                    label = p.displayName,
                    value = p.costUSD,
                    secondaryLabel = "${p.sessionCount} sessions",
                )
            }
    val rankingData =
        InsightWidgetData.Ranking(
            rows = rankingRows,
            valueFormat = ValueFormat.CURRENCY,
            dimensionLabel = "Provider",
        )
    val ranking =
        ruleBasedGeneratedWidget(
            BoundInsightWidgetParams(
                kind = InsightWidgetKind.BAR_RANKING,
                title = "Provider spend ranking",
                dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.PROVIDER, INSIGHT_RANKING_ROW_LIMIT, window),
                data = rankingData,
                reason = "Shows the provider driving the main cost signal.",
                modelTag = request.selectedModel,
                citations = listOf(providerCitation),
            ),
        )
    state.widgets.add(ranking)
    state.findings.add(
        InsightFinding(
            title = "${topProvider.displayName} is the main spend driver",
            whyItMatters = "${topProvider.displayName} accounts for ${ruleBasedCurrency(topProvider.costUSD)} across ${topProvider.sessionCount} sessions.",
            evidence = listOf(providerCitation),
            confidence = InsightConfidence.HIGH,
            severity = InsightSeverity.MEDIUM,
            recommendedAction = "Compare ${topProvider.displayName}'s top models against lower-cost routes before the next heavy session.",
            generatedWidgetID = ranking.widget.id,
        ),
    )
}

private fun appendRuleBasedTimeSeries(
    state: RuleBasedBuildState,
    digest: InsightDigest,
    request: InsightAnalysisRequest,
    window: InsightTimeWindow,
) {
    if (digest.daily.isEmpty()) return
    val tsData =
        InsightWidgetData.TimeSeries(
            series =
            listOf(
                InsightWidgetData.TimeSeries.Series(
                    id = "cost",
                    name = "Daily cost",
                    points =
                    digest.daily.map {
                        InsightWidgetData.TimeSeries.Point(date = it.day, value = it.costUSD)
                    },
                ),
            ),
            xAxisLabel = "Date",
            yAxisLabel = "Cost (USD)",
            yFormat = ValueFormat.CURRENCY,
        )
    state.widgets.add(
        ruleBasedGeneratedWidget(
            BoundInsightWidgetParams(
                kind = InsightWidgetKind.TIME_SERIES_LINE,
                title = "Cost trend",
                dataBinding = InsightDataBinding.TimeSeries("cost", InsightWidgetSpec.Dimension.PROVIDER, window),
                data = tsData,
                reason = "Shows whether the main finding is a spike or a sustained trend.",
                modelTag = request.selectedModel,
                citations = state.citations.take(INSIGHT_MAX_CITATIONS),
            ),
        ),
    )
}

private fun appendRuleBasedDonut(
    state: RuleBasedBuildState,
    digest: InsightDigest,
    request: InsightAnalysisRequest,
    window: InsightTimeWindow,
) {
    if (digest.providers.size < 2) return
    val total = digest.providers.sumOf { it.costUSD }
    val slices =
        digest.providers
            .sortedByDescending { it.costUSD }
            .map {
                InsightWidgetData.Distribution.Slice(
                    id = "slice:${it.id}",
                    label = it.displayName,
                    value = it.costUSD,
                )
            }
    state.widgets.add(
        ruleBasedGeneratedWidget(
            BoundInsightWidgetParams(
                kind = InsightWidgetKind.DONUT,
                title = "Provider cost share",
                dataBinding = InsightDataBinding.Distribution("cost", InsightWidgetSpec.Dimension.PROVIDER, window),
                data =
                InsightWidgetData.Distribution(
                    slices = slices,
                    valueFormat = ValueFormat.CURRENCY,
                    total = total,
                ),
                reason = "How spend splits across the providers in this window.",
                modelTag = request.selectedModel,
                citations = state.citations.take(INSIGHT_MAX_CITATIONS),
            ),
        ),
    )
}

private fun appendRuleBasedModelRanking(
    state: RuleBasedBuildState,
    digest: InsightDigest,
    request: InsightAnalysisRequest,
    window: InsightTimeWindow,
) {
    if (digest.models.isEmpty()) return
    val modelRows =
        digest.models
            .sortedByDescending { it.costUSD }
            .take(INSIGHT_RANKING_ROW_LIMIT)
            .map {
                InsightWidgetData.Ranking.Row(
                    id = "m:${it.id}",
                    label = it.id,
                    value = it.costUSD,
                    secondaryLabel = "${it.sessionCount} sessions",
                )
            }
    state.widgets.add(
        ruleBasedGeneratedWidget(
            BoundInsightWidgetParams(
                kind = InsightWidgetKind.BAR_RANKING,
                title = "Top models by cost",
                dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.MODEL, INSIGHT_RANKING_ROW_LIMIT, window),
                data =
                InsightWidgetData.Ranking(
                    rows = modelRows,
                    valueFormat = ValueFormat.CURRENCY,
                    dimensionLabel = "Model",
                ),
                reason = "Which models cost you the most in this window.",
                modelTag = request.selectedModel,
                citations = state.citations.take(INSIGHT_MAX_CITATIONS),
            ),
        ),
    )
}

private fun appendRuleBasedTopModelRecommendation(
    state: RuleBasedBuildState,
    topModel: InsightDigest.ModelSnapshot?,
) {
    topModel ?: return
    state.recommendations.add(
        InsightRecommendation(
            title = "Check whether ${topModel.id} is the right default",
            rationale = "${topModel.id} is the largest model cost contributor in this window.",
            recommendedAction = "Compare this model against the current Hermes/router default for routine work.",
            estimatedImpact = "Can reduce cost if high-capability models are handling low-risk tasks.",
            evidence = listOf(InsightCitation("model:${topModel.id}", InsightCitation.Kind.Model(topModel.id), topModel.id)),
            confidence = InsightConfidence.MEDIUM,
            severity = InsightSeverity.MEDIUM,
        ),
    )
}

private fun assembleRuleBasedInsightResult(input: RuleBasedFinalAssembly): InsightAnalysisResult {
    val request = input.request
    val platform = input.platform
    val state = input.state
    val missionAdvice = input.missionAdvice
    val topProvider = input.topProvider
    val topModel = input.topModel
    val digest = input.digest
    val briefingAnswer =
        if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) {
            InsightBriefingAnswer(
                question = request.prompt,
                answer = "${state.headline}. ${state.body} ${state.findings.firstOrNull()?.recommendedAction ?: "Review the cited evidence and choose the next action from the brief."}",
                bullets = ruleBasedGroundedPointsForReply(digest, topProvider, topModel),
                citations = state.citations.take(INSIGHT_MAX_CITATIONS),
                source = InsightBriefingAnswer.Source.LOCAL_RULES,
                modelDisplayName = request.selectedModel.displayName,
            )
        } else {
            null
        }
    return InsightAnalysisResult(
        requestID = request.id,
        platform = platform,
        timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d,
        executiveSummary = state.body,
        modelTag = request.selectedModel,
        contextBudget = request.context.budgetReport,
        findings = state.findings.take(INSIGHT_MAX_FINDINGS),
        recommendations = state.recommendations,
        missionCandidates = missionAdvice.missions.take(INSIGHT_MAX_MISSION_CANDIDATES),
        generatedWidgets = state.widgets.take(request.maxGeneratedWidgets),
        followUpQuestions =
        listOf(
            "Why did cost spike this week?",
            "Which project wasted the most money?",
            "Which model should I route routine work to instead?",
            "Which benchmarked model is cheapest at similar performance?",
            "Which model should handle UI and design tasks?",
            "Find quota risks in the next 24 hours.",
        ).map { InsightFollowUpQuestion(question = it) },
        citations = state.citations,
        briefingAnswer = briefingAnswer,
    )
}

internal fun ruleBasedGroundedPointsForReply(
    digest: InsightDigest,
    topProvider: InsightDigest.ProviderSnapshot?,
    topModel: InsightDigest.ModelSnapshot?,
): List<String> {
    val points = mutableListOf<String>()
    topProvider?.let { points.add("${it.displayName}: ${ruleBasedCurrency(it.costUSD)} · ${it.sessionCount} sessions") }
    topModel?.let { points.add("Top model: ${it.id} · ${ruleBasedCurrency(it.costUSD)}") }
    if (digest.daily.isNotEmpty()) {
        digest.daily.maxByOrNull { it.costUSD }?.let { points.add("Peak day ${it.day.take(INSIGHT_ISO_DATE_LENGTH)} at ${ruleBasedCurrency(it.costUSD)}") }
    }
    if (points.isEmpty()) points.add("${digest.totals.sessionCount} sessions · ${ruleBasedCurrency(digest.totals.costUSD)} total")
    return points.take(INSIGHT_MAX_GROUNDED_POINTS)
}
