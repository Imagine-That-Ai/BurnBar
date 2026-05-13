package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Streaming events emitted by an InsightModelGateway during an investigation.
 * The UI subscribes to a Flow<InsightInvestigateEvent> and renders widgets
 * as they materialize. Mirrors Swift InsightInvestigateEvent.
 */
sealed class InsightInvestigateEvent {
    data class ThinkingDelta(val text: String) : InsightInvestigateEvent()
    data class PartialCanvas(val canvas: InsightCanvas) : InsightInvestigateEvent()
    data class WidgetReady(val widget: InsightWidget) : InsightInvestigateEvent()
    data class ToolCall(val call: InsightToolCall) : InsightInvestigateEvent()
    data class ToolResult(val result: InsightToolResult) : InsightInvestigateEvent()
    data class Usage(val usage: InsightTokenUsage) : InsightInvestigateEvent()
    data class FinalCanvas(val canvas: InsightCanvas) : InsightInvestigateEvent()
}

@Serializable
data class InsightToolCall(
    val id: String,
    val name: String,
    val arguments: InsightToolArguments
)

@Serializable
data class InsightToolResult(
    val id: String,
    val toolName: String,
    val isError: Boolean,
    val summary: String,
    val payload: InsightToolResultPayload
)

@Serializable
sealed class InsightToolArguments {
    @Serializable data class DrilldownSearch(val query: String, val filter: InsightFilter? = null) : InsightToolArguments()
    @Serializable data class DrilldownSession(val sessionID: String) : InsightToolArguments()
    @Serializable data class AgentUsage(val agent: String, val window: InsightTimeWindow) : InsightToolArguments()
    @Serializable data class ModelUsage(val modelID: String, val window: InsightTimeWindow) : InsightToolArguments()
    @Serializable data class OperatingActions(val window: InsightTimeWindow) : InsightToolArguments()
    @Serializable data class QuotaSnapshot(val providerKey: String? = null) : InsightToolArguments()
    @Serializable data class AnomalyDetail(val anomalyID: String) : InsightToolArguments()
    @Serializable data object ListFocuses : InsightToolArguments()
    @Serializable data object ListUseCases : InsightToolArguments()
}

@Serializable
sealed class InsightToolResultPayload {
    @Serializable data class Sessions(val rows: List<InsightWidgetData.Drilldown.Row>) : InsightToolResultPayload()
    @Serializable data class TimeSeriesData(val data: InsightWidgetData.TimeSeries) : InsightToolResultPayload()
    @Serializable data class RankingData(val data: InsightWidgetData.Ranking) : InsightToolResultPayload()
    @Serializable data class Actions(val actions: List<InsightDigest.ActionDigest>) : InsightToolResultPayload()
    @Serializable data class QuotaData(val data: InsightWidgetData.QuotaState) : InsightToolResultPayload()
    @Serializable data class Anomaly(val row: InsightWidgetData.AnomalyTable.Row) : InsightToolResultPayload()
    @Serializable data class Vocabulary(val words: List<String>) : InsightToolResultPayload()
    @Serializable data class Error(val message: String) : InsightToolResultPayload()
}
