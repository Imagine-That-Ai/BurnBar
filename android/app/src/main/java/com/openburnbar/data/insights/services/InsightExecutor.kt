package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightWidgetData

/**
 * Turns an InsightDataBinding into concrete InsightWidgetData using
 * the digest as the data source. Mirrors Swift InsightExecutor.
 *
 * On Android, macOS-only bindings (useCaseClusters, focusMatrices) return
 * InsightWidgetData.Empty with a reason explaining the limitation.
 */
object InsightExecutor {
    fun execute(binding: InsightDataBinding, digest: InsightDigest, canvasFilter: InsightFilter): InsightWidgetData {
        val effectiveFilter =
            canvasFilter.overlaidBy(
                when (binding) {
                    is InsightDataBinding.Kpi -> null
                    is InsightDataBinding.TimeSeries -> null
                    else -> null
                },
            )
        return when (binding) {
            is InsightDataBinding.Kpi -> InsightExecutorBindings.executeKpi(binding, digest)
            is InsightDataBinding.TimeSeries -> InsightExecutorBindings.executeTimeSeries(binding, digest)
            is InsightDataBinding.Ranking -> InsightExecutorBindings.executeRanking(binding, digest)
            is InsightDataBinding.Distribution -> InsightExecutorBindings.executeDistribution(binding, digest)
            is InsightDataBinding.Heatmap -> InsightExecutorBindings.executeHeatmap(binding, digest)
            is InsightDataBinding.Quota -> InsightExecutorBindings.executeQuota(binding, digest)
            is InsightDataBinding.Forecast -> InsightExecutorExtendedBindings.executeForecast(binding, digest)
            is InsightDataBinding.Anomaly -> InsightExecutorExtendedBindings.executeAnomaly(digest)
            is InsightDataBinding.UseCaseClusters ->
                InsightWidgetData.Empty(
                    reason = "Use-case clustering requires macOS session data not available on Android",
                )
            is InsightDataBinding.AgentFocusMatrix ->
                InsightWidgetData.Empty(
                    reason = "Agent focus matrix requires macOS session data not available on Android",
                )
            is InsightDataBinding.ModelFocusMatrix ->
                InsightWidgetData.Empty(
                    reason = "Model focus matrix requires macOS session data not available on Android",
                )
            is InsightDataBinding.Drilldown -> InsightExecutorExtendedBindings.executeDrilldown(binding, digest)
            is InsightDataBinding.Narrative -> binding.data
            is InsightDataBinding.Recommendation -> binding.data
            is InsightDataBinding.MermaidSource -> InsightWidgetData.MermaidDiagram(binding.source)
            is InsightDataBinding.Ascii -> binding.data
            is InsightDataBinding.Composed ->
                InsightWidgetData.Composed(
                    binding.bindings.map { execute(it, digest, canvasFilter) },
                )
            is InsightDataBinding.Scatter -> InsightExecutorExtendedBindings.executeScatter(binding, digest)
            is InsightDataBinding.Sankey -> InsightExecutorExtendedBindings.executeSankey(digest)
            is InsightDataBinding.Radar -> InsightExecutorExtendedBindings.executeRadar(digest)
            is InsightDataBinding.Cohort ->
                InsightWidgetData.Cohort(
                    cohortLabels = emptyList(),
                    periodLabels = emptyList(),
                    cells = emptyList(),
                )
            is InsightDataBinding.Funnel -> InsightWidgetData.Funnel(steps = emptyList())
        }
    }
}
