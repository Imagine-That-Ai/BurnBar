package com.openburnbar.ui.chartstudio

import androidx.compose.ui.graphics.Color
import kotlinx.serialization.Serializable

enum class ChartKind { LINE, BAR, DONUT, SCATTER, AREA }

@Serializable
data class ChartPoint(val x: String = "", val y: Float = 0f)

@Serializable
data class ChartSeries(
    val name: String = "",
    val points: List<ChartPoint> = emptyList(),
    val colorHex: String? = null
) {
    val color: Color?
        get() = colorHex?.let { parseHexColor(it) }
}

@Serializable
data class ChartRendering(
    val title: String = "",
    val subtitle: String? = null,
    val kind: ChartKind = ChartKind.LINE,
    val series: List<ChartSeries> = emptyList()
)

data class GalleryItem(val title: String, val subtitle: String, val kind: ChartKind) {
    fun toRendering(): ChartRendering {
        val samplePoints = when (kind) {
            ChartKind.LINE, ChartKind.AREA -> listOf(
                ChartPoint("Mon", 12f), ChartPoint("Tue", 19f), ChartPoint("Wed", 15f),
                ChartPoint("Thu", 25f), ChartPoint("Fri", 22f), ChartPoint("Sat", 30f), ChartPoint("Sun", 28f)
            )
            ChartKind.BAR -> listOf(
                ChartPoint("GPT-4", 45f), ChartPoint("Claude", 32f), ChartPoint("Gemini", 28f),
                ChartPoint("Cursor", 55f), ChartPoint("Copilot", 20f)
            )
            ChartKind.DONUT -> listOf(
                ChartPoint("OpenAI", 35f), ChartPoint("Anthropic", 25f), ChartPoint("Google", 20f),
                ChartPoint("Cursor", 15f), ChartPoint("Other", 5f)
            )
            ChartKind.SCATTER -> listOf(
                ChartPoint("A", 12f), ChartPoint("B", 45f), ChartPoint("C", 28f),
                ChartPoint("D", 60f), ChartPoint("E", 35f), ChartPoint("F", 50f)
            )
        }
        return ChartRendering(title = title, subtitle = subtitle, kind = kind, series = listOf(ChartSeries("Series 1", samplePoints)))
    }
}

fun parseHexColor(hex: String): Color? {
    val cleaned = hex.trimStart('#')
    if (cleaned.length != 6) return null
    val intValue = cleaned.toIntOrNull(16) ?: return null
    return Color(intValue or 0xFF000000.toInt())
}

fun generateSampleChart(prompt: String): String {
    return """{"title":"${prompt.take(20)}","subtitle":"Generated chart","kind":"LINE","series":[{"name":"Cost","points":[{"x":"Mon","y":12},{"x":"Tue","y":19},{"x":"Wed","y":15},{"x":"Thu","y":25},{"x":"Fri","y":22},{"x":"Sat","y":30},{"x":"Sun","y":28}]}]}"""
}

fun parseRendering(json: String): ChartRendering? {
    return try {
        val kind = when {
            json.contains(""""kind":"BAR"""") -> ChartKind.BAR
            json.contains(""""kind":"DONUT"""") -> ChartKind.DONUT
            json.contains(""""kind":"SCATTER"""") -> ChartKind.SCATTER
            json.contains(""""kind":"AREA"""") -> ChartKind.AREA
            else -> ChartKind.LINE
        }
        GalleryItem("Generated", "From prompt", kind).toRendering().copy(title = "Chart Result")
    } catch (e: Exception) {
        null
    }
}
