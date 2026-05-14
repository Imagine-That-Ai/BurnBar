package com.openburnbar.ui.insights

import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightMissionCandidate
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.models.AgentProvider

/**
 * Cross-platform-parallel scope for the per-agent Insights surface on Android.
 *
 * Mirrors `AgentInsightsScope` from `OpenBurnBarCore` (Swift). `provider == null`
 * means the aggregate view across every agent.
 */
data class AgentInsightsScope(
    val provider: AgentProvider? = null,
    val window: InsightTimeWindow = InsightTimeWindow.Last7d
) {
    val isAggregate: Boolean get() = provider == null

    /** Stable token for deep-link routes (`burnbar://insights/{slug}`). */
    val routeSlug: String get() = provider?.key ?: "all"

    companion object {
        val Aggregate = AgentInsightsScope()
        fun agent(provider: AgentProvider, window: InsightTimeWindow = InsightTimeWindow.Last7d) =
            AgentInsightsScope(provider, window)

        fun fromRouteSlug(slug: String, window: InsightTimeWindow = InsightTimeWindow.Last7d): AgentInsightsScope? {
            val normalized = slug.lowercase()
            if (normalized.isEmpty() || normalized == "all") {
                return AgentInsightsScope(window = window)
            }
            val provider = AgentProvider.fromKey(normalized) ?: return null
            return AgentInsightsScope(provider, window)
        }
    }
}

/**
 * Fully-resolved Insights payload for a scope. The same shape as
 * `AgentInsightsBundle` on iOS so future cross-platform tests can share
 * fixtures.
 */
data class AgentInsightsBundle(
    val scope: AgentInsightsScope,
    val header: AgentInsightsHeader,
    val kpis: AgentInsightsKPIStrip,
    val brief: InsightAnalysisResult? = null,
    val canvases: List<InsightCanvas> = emptyList(),
    val missions: List<InsightMissionCandidate> = emptyList()
) {
    val isEmpty: Boolean get() = kpis.sessions.raw == 0.0 && canvases.isEmpty() && brief == null
}

data class AgentInsightsHeader(
    val provider: AgentProvider?,
    val title: String,
    val subtitle: String?,
    val status: Status,
    val modelLineup: List<String> = emptyList()
) {
    enum class Status(val displayLabel: String) {
        ACTIVE("Active"),
        IDLE("Idle"),
        DORMANT("Dormant"),
        UNCONFIGURED("Not connected")
    }
}

data class AgentInsightsKPIStrip(
    val spend: KPI,
    val tokens: KPI,
    val sessions: KPI,
    val anomaly: KPI
) {
    val ordered: List<KPI> get() = listOf(spend, tokens, sessions, anomaly)

    data class KPI(
        val id: String,
        val label: String,
        val valueText: String,
        val raw: Double,
        val symbol: String
    )
}

/**
 * Pure assembler. Given a digest + analysis + canvases, produces a
 * bundle for the requested scope. No I/O, no platform calls — mirrors
 * `AgentInsightsBundleAssembler.assemble` in Swift.
 */
object AgentInsightsBundleAssembler {

    fun assemble(
        scope: AgentInsightsScope,
        digest: InsightDigest?,
        analysis: InsightAnalysisResult?,
        canvases: List<InsightCanvas>
    ): AgentInsightsBundle {
        val providerSnapshot = providerSnapshot(scope, digest)
        val header = makeHeader(scope, providerSnapshot)
        val kpis = makeKPIs(scope, digest, providerSnapshot, analysis)
        val scopedCanvases = filterCanvases(canvases, scope)
        val rankedMissions = (analysis?.missionCandidates ?: emptyList())
            .sortedByDescending { priorityRank(it.priority) }

        return AgentInsightsBundle(
            scope = scope,
            header = header,
            kpis = kpis,
            brief = analysis,
            canvases = scopedCanvases,
            missions = rankedMissions
        )
    }

    private fun providerSnapshot(
        scope: AgentInsightsScope,
        digest: InsightDigest?
    ): InsightDigest.ProviderSnapshot? {
        val provider = scope.provider ?: return null
        return digest?.providers?.firstOrNull { it.id.equals(provider.key, ignoreCase = true) || it.displayName.equals(provider.displayName, ignoreCase = true) }
    }

    private fun makeHeader(
        scope: AgentInsightsScope,
        snapshot: InsightDigest.ProviderSnapshot?
    ): AgentInsightsHeader {
        if (scope.provider == null) {
            return AgentInsightsHeader(
                provider = null,
                title = "All agents",
                subtitle = "Combined view across every provider",
                status = AgentInsightsHeader.Status.ACTIVE,
                modelLineup = emptyList()
            )
        }
        val provider = scope.provider
        val status = if (snapshot == null || (snapshot.sessionCount == 0 && snapshot.totalTokens == 0L)) {
            AgentInsightsHeader.Status.UNCONFIGURED
        } else {
            AgentInsightsHeader.Status.ACTIVE
        }
        val lineup = snapshot?.topModels?.take(3) ?: emptyList()
        val subtitle = lineup.firstOrNull()?.let { "Top model: $it" } ?: status.displayLabel
        return AgentInsightsHeader(
            provider = provider,
            title = provider.displayName,
            subtitle = subtitle,
            status = status,
            modelLineup = lineup
        )
    }

    private fun makeKPIs(
        scope: AgentInsightsScope,
        digest: InsightDigest?,
        snapshot: InsightDigest.ProviderSnapshot?,
        analysis: InsightAnalysisResult?
    ): AgentInsightsKPIStrip {
        val spend = if (scope.isAggregate) digest?.totals?.costUSD ?: 0.0 else snapshot?.costUSD ?: 0.0
        val tokens = if (scope.isAggregate) digest?.totals?.totalTokens ?: 0L else snapshot?.totalTokens ?: 0L
        val sessions = if (scope.isAggregate) digest?.totals?.sessionCount ?: 0 else snapshot?.sessionCount ?: 0
        val anomalyScore = (analysis?.anomalies?.maxByOrNull { it.score }?.score) ?: 0.0

        return AgentInsightsKPIStrip(
            spend = AgentInsightsKPIStrip.KPI("spend", "Spend", formatUSD(spend), spend, "attach_money"),
            tokens = AgentInsightsKPIStrip.KPI("tokens", "Tokens", formatCompact(tokens.toDouble()), tokens.toDouble(), "sum"),
            sessions = AgentInsightsKPIStrip.KPI("sessions", "Sessions", formatCompact(sessions.toDouble()), sessions.toDouble(), "groups"),
            anomaly = AgentInsightsKPIStrip.KPI(
                "anomaly",
                "Anomaly",
                if (anomalyScore <= 0.0) "None" else "${(anomalyScore.coerceIn(0.0, 1.0) * 100).toInt()} / 100",
                anomalyScore,
                "warning"
            )
        )
    }

    private fun filterCanvases(canvases: List<InsightCanvas>, scope: AgentInsightsScope): List<InsightCanvas> {
        val provider = scope.provider ?: return canvases.sortedWith(canvasOrdering)
        val token = provider.displayName
        val scoped = canvases.filter { it.filter.providers.any { p -> p.equals(token, ignoreCase = true) } }
        return if (scoped.isNotEmpty()) {
            scoped.sortedWith(canvasOrdering)
        } else {
            canvases.filter { it.filter.providers.isEmpty() }.sortedWith(canvasOrdering)
        }
    }

    private val canvasOrdering: Comparator<InsightCanvas> = Comparator { a, b ->
        when {
            a.sortIndex != b.sortIndex -> a.sortIndex.compareTo(b.sortIndex)
            else -> b.updatedAt.compareTo(a.updatedAt)
        }
    }

    private fun priorityRank(priority: InsightMissionCandidate.Priority): Int = when (priority) {
        InsightMissionCandidate.Priority.CRITICAL -> 4
        InsightMissionCandidate.Priority.HIGH -> 3
        InsightMissionCandidate.Priority.MEDIUM -> 2
        InsightMissionCandidate.Priority.LOW -> 1
    }

    private fun formatUSD(value: Double): String {
        return if (value < 10.0) "$%.2f".format(value) else "$%.0f".format(value)
    }

    private fun formatCompact(value: Double): String = when {
        value >= 1_000_000_000 -> "%.1fB".format(value / 1_000_000_000)
        value >= 1_000_000 -> "%.1fM".format(value / 1_000_000)
        value >= 1_000 -> "%.1fK".format(value / 1_000)
        else -> "%.0f".format(value)
    }
}
