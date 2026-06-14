package com.openburnbar.ui.chartstudio

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Decoded representation of what Hermes can ask Chart Studio to render.
 * The wire format is a single JSON object; the top-level `kind` field
 * dispatches into one of five variants (or a recursive composition).
 *
 * This mirrors the iOS `ChartStudioRendering` enum semantically without
 * adopting Kotlin's sealed-hierarchy serialization defaults — we parse the
 * wire JSON ourselves in [ChartSpecRenderer] so that prose-wrapped responses
 * still decode.
 */
sealed class ChartStudioRendering {
    data class Native(val spec: ChartSpec) : ChartStudioRendering()

    data class Mermaid(val spec: MermaidSpec) : ChartStudioRendering()

    data class Ascii(val spec: AsciiSpec) : ChartStudioRendering()

    data class Insight(val spec: InsightSpec) : ChartStudioRendering()

    data class Composed(val items: List<ChartStudioRendering>) : ChartStudioRendering()

    data class Error(val message: String) : ChartStudioRendering()
}

// ── Native (Apple Charts → Compose Canvas) ─────────────────────────────────

@Serializable
data class ChartSpec(
    val kind: String = "native",
    val chart: ChartKind = ChartKind.LINE,
    val title: String? = null,
    val subtitle: String? = null,
    val xAxis: AxisSpec? = null,
    val yAxis: AxisSpec? = null,
    val series: List<SeriesSpec> = emptyList(),
    val rules: List<RuleSpec> = emptyList(),
    val legend: Boolean = true,
    // override; default is 260dp in full mode, 165dp in gallery
    val height: Int? = null,
)

enum class ChartKind {
    @SerialName("line")
    LINE,

    @SerialName("bar")
    BAR,

    @SerialName("stacked_bar")
    STACKED_BAR,

    @SerialName("area")
    AREA,

    @SerialName("stacked_area")
    STACKED_AREA,

    @SerialName("stream")
    STREAM,

    @SerialName("scatter")
    SCATTER,

    @SerialName("heatmap")
    HEATMAP,

    @SerialName("donut")
    DONUT,

    @SerialName("rule")
    RULE,
}

@Serializable
data class AxisSpec(
    val label: String? = null,
    // "linear" | "time" | "category"
    val type: String = "linear",
    // "date" | "currency" | "percent" | "tokens" | null
    val format: String? = null,
    val showGrid: Boolean = true,
    // hint to renderer
    val ticks: Int? = null,
)

@Serializable
data class SeriesSpec(
    val name: String,
    // hex like "F45B69" — optional override
    val color: String? = null,
    // resolves to AgentProvider brand color
    val providerKey: String? = null,
    val data: List<DataPoint> = emptyList(),
)

@Serializable
data class DataPoint(
    // ISO date, category name, or stringified number
    val x: String,
    val y: Double,
    val label: String? = null,
)

@Serializable
data class RuleSpec(
    // "horizontal" | "vertical"
    val orientation: String = "horizontal",
    // y for horizontal, x-index for vertical
    val value: Double,
    val color: String? = null,
    val label: String? = null,
    val dashed: Boolean = true,
)

// ── Mermaid (DSL diagrams) ─────────────────────────────────────────────────

@Serializable
data class MermaidSpec(
    val kind: String = "mermaid",
    val title: String? = null,
    val subtitle: String? = null,
    // raw Mermaid DSL
    val source: String,
    // "dark" | "default"
    val theme: String? = null,
)

// ── ASCII (terminal-chrome canvas) ─────────────────────────────────────────

@Serializable
data class AsciiSpec(
    val kind: String = "ascii",
    val title: String? = null,
    // "bar" | "sparkline" | "heatmap" | "banner" | "scene"
    val variant: String = "scene",
    // ASCII art / box-drawing
    val body: String,
)

// ── Insight (narrative card) ───────────────────────────────────────────────

@Serializable
data class InsightSpec(
    val kind: String = "insight",
    val title: String,
    val body: String,
    // "positive" | "neutral" | "warning"
    val tone: String = "neutral",
    // optional inline trend
    val sparkline: List<Double>? = null,
    // "Show me the chart →" injects this prompt
    val followUpPrompt: String? = null,
    val followUpLabel: String? = null,
)
