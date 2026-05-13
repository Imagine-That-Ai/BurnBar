package com.openburnbar.ui.insights.renderers

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProgressIndicatorDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightFreshness
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.ValueFormat
import com.openburnbar.ui.insights.InsightsColors
import com.openburnbar.ui.insights.InsightsSpacing
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

// ─── Formatting helpers ─────────────────────────────────────────────────────

private fun formatValue(value: Double, format: ValueFormat?): String = when (format) {
    ValueFormat.CURRENCY -> String.format("$%,.2f", value)
    ValueFormat.PERCENT -> String.format("%.1f%%", value * 100)
    ValueFormat.DURATION -> {
        val hours = (value / 3600).toInt()
        val mins = ((value % 3600) / 60).toInt()
        val secs = (value % 60).toInt()
        when { hours > 0 -> "${hours}h ${mins}m"; mins > 0 -> "${mins}m ${secs}s"; else -> "${secs}s" }
    }
    ValueFormat.TOKENS -> when {
        value >= 1_000_000 -> String.format("%.1fM", value / 1_000_000)
        value >= 1_000 -> String.format("%.1fk", value / 1_000)
        else -> String.format("%.0f", value)
    }
    ValueFormat.COUNT -> when {
        value >= 1_000_000 -> String.format("%.1fM", value / 1_000_000)
        value >= 1_000 -> String.format("%.1fk", value / 1_000)
        else -> String.format("%.0f", value)
    }
    ValueFormat.RAW -> String.format("%.2f", value)
    null -> String.format("%.1f", value)
}

private fun parseColor(hex: String): Color = try {
    Color(hex.lowercase().removePrefix("#").toLong(16) or 0xFF000000)
} catch (_: Exception) {
    Color.Gray
}

private fun Modifier.coloredRect(color: Color): Modifier = this.drawBehind { drawRect(color) }
private fun Modifier.coloredCircle(color: Color): Modifier = this.drawBehind { drawCircle(color) }

// ─── Main renderer (exhaustive when) ─────────────────────────────────────────

@Composable
fun InsightWidgetRenderer(
    widget: InsightWidget,
    onCitationTap: (InsightCitation) -> Unit,
    theme: InsightTheme = InsightTheme.AURORA,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        WidgetHeader(widget, theme)
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        when (widget.kind) {
            InsightWidgetKind.KPI_TILE            -> KpiTileRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.TIME_SERIES_LINE    -> TimeSeriesRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.TIME_SERIES_AREA    -> TimeSeriesRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.STREAM_GRAPH        -> TimeSeriesRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.BAR_RANKING         -> RankingRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.DONUT               -> DonutRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.TREEMAP             -> TreemapRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.HEATMAP             -> HeatmapRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.SCATTER             -> PlaceholderWidget(widget)
            InsightWidgetKind.SANKEY              -> SankeyRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.RADAR               -> RadarRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.COHORT              -> CohortRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.FUNNEL              -> FunnelRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.QUOTA_PULSE         -> QuotaPulseRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.FORECAST            -> ForecastRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.ANOMALY_TABLE       -> AnomalyTableRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.NARRATIVE            -> NarrativeRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.RECOMMENDATION       -> RecommendationRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.USE_CASE_CLUSTER     -> UseCaseClusterRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.AGENT_FOCUS_MATRIX   -> FocusMatrixRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.MODEL_FOCUS_MATRIX   -> FocusMatrixRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.DRILLDOWN_LIST       -> DrilldownListRenderer(widget, theme, onCitationTap)
            InsightWidgetKind.MERMAID             -> MermaidRenderer(widget, onCitationTap)
            InsightWidgetKind.ASCII               -> AsciiRenderer(widget, onCitationTap)
            InsightWidgetKind.COMPOSED             -> ComposedRenderer(widget, onCitationTap)
            InsightWidgetKind.ERROR               -> ErrorRenderer(widget, onCitationTap)
        }
    }
}

// ─── Widget header ────────────────────────────────────────────────────────────

@Composable
private fun WidgetHeader(widget: InsightWidget, theme: InsightTheme) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(
            text = widget.kind.displayName,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = InsightsColors.accentsFor(theme).first()
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = widget.title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        val (freshColor, freshLabel) = when (widget.freshness) {
            InsightFreshness.FRESH     -> InsightsColors.freshnessFresh to "fresh"
            InsightFreshness.STALE     -> MaterialTheme.colorScheme.onSurfaceVariant to "stale"
            InsightFreshness.COMPUTING -> InsightsColors.freshnessComputing to "computing"
            InsightFreshness.ERROR     -> InsightsColors.freshnessError to "error"
            InsightFreshness.LOCKED    -> InsightsColors.freshnessLocked to "locked"
        }
        Text(text = freshLabel, style = MaterialTheme.typography.labelSmall, color = freshColor)
    }
}

// ─── KPI Tile ─────────────────────────────────────────────────────────────────

@Composable
private fun KpiTileRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.KPI) ?: return EmptyWidget()
    val accent = InsightsColors.accentsFor(theme).first()
    Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = data.metricLabel, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                text = formatValue(data.value, data.valueFormat),
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = if (data.value >= 0) accent else InsightsColors.kpiNegative
            )
            if (data.delta != null) {
                val sign = if (data.delta >= 0) "+" else ""
                val deltaText = if (data.deltaIsPercent) "$sign${String.format("%.1f", data.delta * 100)}%"
                    else "$sign${formatValue(data.delta, data.valueFormat)}"
                Text(text = deltaText, style = MaterialTheme.typography.bodySmall,
                    color = if (data.delta >= 0) InsightsColors.kpiPositive else InsightsColors.kpiNegative)
            }
            if (data.contextLabel != null) {
                Text(text = data.contextLabel, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (data.sparkline.isNotEmpty()) {
            MiniSparkline(data.sparkline, color = accent, modifier = Modifier.size(64.dp, 28.dp))
        }
    }
}

// ─── Time Series (Line / Area / Stream) ───────────────────────────────────────

@Composable
private fun TimeSeriesRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.TimeSeries) ?: return EmptyWidget()
    Column {
        Text(text = data.yAxisLabel, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (data.series.isNotEmpty() && data.series.first().points.isNotEmpty()) {
            SparklineChart(series = data.series, yFormat = data.yFormat,
                modifier = Modifier.fillMaxWidth().height(InsightsSpacing.chartHeight.dp))
        } else {
            Text("No data", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// ─── Ranking (horizontal bars) ────────────────────────────────────────────────

@Composable
private fun RankingRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Ranking) ?: return EmptyWidget()
    val maxVal = data.rows.maxOfOrNull { it.value } ?: 1.0
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        data.rows.take(5).forEach { row ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = row.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(text = formatValue(row.value, data.valueFormat), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
            }
            LinearProgressIndicator(
                progress = { (row.value / maxVal).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(4.dp),
                color = InsightsColors.accentsFor(theme).first(),
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
                strokeCap = ProgressIndicatorDefaults.CircularDeterminateStrokeCap
            )
        }
    }
}

// ─── Donut ────────────────────────────────────────────────────────────────────

@Composable
private fun DonutRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Distribution) ?: return EmptyWidget()
    val colors = InsightsColors.accentsFor(theme)
    Column {
        DonutChart(slices = data.slices, total = data.total, colors = colors, modifier = Modifier.size(120.dp))
        Spacer(modifier = Modifier.height(8.dp))
        data.slices.forEachIndexed { idx, slice ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.size(8.dp).clip(CircleShape).coloredCircle(
                    slice.colorHex?.let { parseColor(it) } ?: colors.getOrElse(idx % colors.size) { Color.Gray }
                ))
                Spacer(modifier = Modifier.width(6.dp))
                Text(text = slice.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(text = formatValue(slice.value, data.valueFormat), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

// ─── Quota Pulse ──────────────────────────────────────────────────────────────

@Composable
private fun QuotaPulseRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.QuotaState) ?: return EmptyWidget()
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        data.buckets.forEach { bucket ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = bucket.providerLabel, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(text = "${String.format("%.1f", bucket.used)} / ${bucket.limit?.let { String.format("%.1f", it) } ?: "∞"}", style = MaterialTheme.typography.bodySmall)
            }
            LinearProgressIndicator(
                progress = { bucket.fraction.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(6.dp),
                color = if (bucket.fraction > 0.8) InsightsColors.kpiNegative else InsightsColors.kpiPositive,
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
                strokeCap = ProgressIndicatorDefaults.CircularDeterminateStrokeCap
            )
        }
    }
}

// ─── Narrative ────────────────────────────────────────────────────────────────

@Composable
private fun NarrativeRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Narrative) ?: return EmptyWidget()
    val toneColor = when (data.tone) {
        InsightWidgetData.Narrative.Tone.POSITIVE -> InsightsColors.kpiPositive
        InsightWidgetData.Narrative.Tone.NEUTRAL -> MaterialTheme.colorScheme.onSurface
        InsightWidgetData.Narrative.Tone.WARNING -> InsightsColors.freshnessComputing
        InsightWidgetData.Narrative.Tone.NEGATIVE -> InsightsColors.kpiNegative
    }
    Column {
        Text(text = data.headline, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = toneColor)
        Spacer(modifier = Modifier.height(4.dp))
        Text(text = data.body, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (data.bullets.isNotEmpty()) {
            Spacer(modifier = Modifier.height(4.dp))
            data.bullets.forEach { Text(text = "\u2022 $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

// ─── Recommendation ──────────────────────────────────────────────────────────

@Composable
private fun RecommendationRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Recommendation) ?: return EmptyWidget()
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        shape = RoundedCornerShape(InsightsSpacing.cardRadius.dp)
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
            Text(text = data.headline, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = Modifier.height(2.dp))
            Text(text = data.rationale, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.height(6.dp))
            AssistChip(onClick = { /* TODO */ }, label = { Text(data.action) })
        }
    }
}

// ─── Focus Matrix (Agent / Model) ────────────────────────────────────────────

@Composable
private fun FocusMatrixRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.FocusMatrix) ?: return EmptyWidget()
    val colors = InsightsColors.accentsFor(theme)
    Column {
        Row(modifier = Modifier.fillMaxWidth()) {
            Spacer(modifier = Modifier.width(60.dp))
            data.columnLabels.forEach { Text(text = it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f), textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        data.rowLabels.forEachIndexed { rowIdx, rowLabel ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = rowLabel, style = MaterialTheme.typography.labelSmall, modifier = Modifier.width(60.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                data.cells.getOrElse(rowIdx) { emptyList() }.forEachIndexed { colIdx, value ->
                    val intensity = value.toFloat().coerceIn(0f, 1f)
                    Box(modifier = Modifier.weight(1f).height(24.dp).padding(1.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .coloredRect(colors.getOrElse(colIdx % colors.size) { colors[0] }.copy(alpha = intensity.coerceIn(0.15f, 1f))))
                }
            }
        }
    }
}

// ─── Anomaly Table ────────────────────────────────────────────────────────────

@Composable
private fun AnomalyTableRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.AnomalyTable) ?: return EmptyWidget()
    if (data.rows.isEmpty()) { Text("No anomalies detected", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); return }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        data.rows.take(5).forEach { row ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = String.format("%.1f", row.score), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = InsightsColors.kpiNegative, modifier = Modifier.width(32.dp))
                Text(text = row.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (row.detail != null) Text(text = row.detail, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

// ─── Drilldown List ──────────────────────────────────────────────────────────

@Composable
private fun DrilldownListRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Drilldown) ?: return EmptyWidget()
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        data.rows.forEach { row ->
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
                elevation = CardDefaults.cardElevation(defaultElevation = 0.dp), shape = RoundedCornerShape(8.dp)) {
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(text = row.title, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
                        if (row.subtitle != null) Text(text = row.subtitle, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (row.costUSD != null) Text(text = formatValue(row.costUSD, ValueFormat.CURRENCY), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

// ─── Sankey ──────────────────────────────────────────────────────────────────

@Composable
private fun SankeyRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Sankey) ?: return EmptyWidget()
    val colors = InsightsColors.accentsFor(theme)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        data.nodes.forEachIndexed { idx, node ->
            val totalOutflow = data.links.filter { it.source == node.id }.sumOf { it.value }
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = node.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.width(80.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Box(modifier = Modifier.weight(1f).height(16.dp).clip(RoundedCornerShape(4.dp))
                    .coloredRect(colors.getOrElse(idx % colors.size) { Color.Gray }.copy(alpha = 0.7f)))
                if (totalOutflow > 0) Text(text = formatValue(totalOutflow, ValueFormat.CURRENCY), style = MaterialTheme.typography.labelSmall, modifier = Modifier.width(50.dp), textAlign = TextAlign.End)
            }
        }
    }
}

// ─── Radar ────────────────────────────────────────────────────────────────────

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun RadarRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Radar) ?: return EmptyWidget()
    if (data.axes.isEmpty() || data.series.isEmpty()) return EmptyWidget()
    val colors = InsightsColors.accentsFor(theme)
    val axes = data.axes
    val n = axes.size
    Column {
        Canvas(modifier = Modifier.size(140.dp)) {
            val center = size / 2f
            val radius = minOf(size.width, size.height) / 2f * 0.8f
            for (i in 1..4) { drawCircle(Color.Gray.copy(alpha = 0.2f), radius * i / 4f, center = Offset(center.width, center.height), style = Stroke(width = 1f)) }
            for (i in 0 until n) {
                val angle = Math.toRadians(90.0 - 360.0 * i / n)
                drawLine(Color.Gray.copy(alpha = 0.3f), Offset(center.width, center.height),
                    Offset(center.width + radius * kotlin.math.cos(angle).toFloat(), center.height - radius * kotlin.math.sin(angle).toFloat()), strokeWidth = 1f)
            }
            data.series.forEachIndexed { idx, series ->
                val color = series.colorHex?.let { parseColor(it) } ?: colors.getOrElse(idx % colors.size) { Color.Gray }
                val path = Path()
                for (i in 0 until n) {
                    val angle = Math.toRadians(90.0 - 360.0 * i / n)
                    val r = radius * series.values[i].toFloat()
                    val x = center.width + r * kotlin.math.cos(angle).toFloat()
                    val y = center.height - r * kotlin.math.sin(angle).toFloat()
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                path.close()
                drawPath(path, color = color.copy(alpha = 0.2f))
                drawPath(path, color = color, style = Stroke(width = 2f))
            }
        }
        FlowRow(modifier = Modifier.fillMaxWidth()) {
            data.axes.forEach { Text(text = it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 4.dp)) }
        }
    }
}

// ─── Cohort ────────────────────────────────────────────────────────────────────

@Composable
private fun CohortRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Cohort) ?: return EmptyWidget()
    if (data.cells.isEmpty() || data.cohortLabels.isEmpty()) return EmptyWidget()
    val colors = InsightsColors.accentsFor(theme)
    Column {
        Row(modifier = Modifier.fillMaxWidth()) {
            Spacer(modifier = Modifier.width(60.dp))
            data.periodLabels.forEach { Text(text = it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f), textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        data.cohortLabels.forEachIndexed { rowIdx, rowLabel ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = rowLabel, style = MaterialTheme.typography.labelSmall, modifier = Modifier.width(60.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                data.cells.getOrElse(rowIdx) { emptyList() }.forEachIndexed { colIdx, value ->
                    val intensity = value?.toFloat()?.coerceIn(0f, 1f) ?: 0f
                    Box(modifier = Modifier.weight(1f).height(24.dp).padding(1.dp).clip(RoundedCornerShape(2.dp))
                        .coloredRect(colors.getOrElse(colIdx % colors.size) { colors[0] }.copy(alpha = 0.15f + intensity * 0.85f)))
                }
            }
        }
    }
}

// ─── Funnel ──────────────────────────────────────────────────────────────────

@Composable
private fun FunnelRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Funnel) ?: return EmptyWidget()
    val maxCount = data.steps.maxOfOrNull { it.count } ?: 1.0
    val colors = InsightsColors.accentsFor(theme)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        data.steps.forEachIndexed { idx, step ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = step.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                LinearProgressIndicator(progress = { (step.count / maxCount).toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.width(100.dp).height(12.dp),
                    color = colors.getOrElse(idx % colors.size) { colors[0] }, trackColor = MaterialTheme.colorScheme.surfaceVariant)
                Text(text = String.format("%.0f", step.count), style = MaterialTheme.typography.labelSmall, modifier = Modifier.width(40.dp), textAlign = TextAlign.End)
            }
        }
    }
}

// ─── Forecast ─────────────────────────────────────────────────────────────────

@Composable
private fun ForecastRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Forecast) ?: return EmptyWidget()
    Column {
        if (data.actual.isNotEmpty()) {
            SparklineChart(series = listOf(InsightWidgetData.TimeSeries.Series(id = "actual", name = "Actual", points = data.actual, colorHex = null)),
                yFormat = data.yFormat, modifier = Modifier.fillMaxWidth().height(InsightsSpacing.chartHeight.dp))
        }
        if (data.summary != null) Text(text = data.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ─── Use-Case Cluster ─────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun UseCaseClusterRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.UseCaseCluster) ?: return EmptyWidget()
    FlowRow(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        data.clusters.forEach { cluster ->
            AssistChip(onClick = { /* TODO */ }, label = { Text("${cluster.label} (${cluster.size})") })
        }
    }
}

// ─── Treemap (delegates to heatmap grid) ──────────────────────────────────────

@Composable
private fun TreemapRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Heatmap) ?: return PlaceholderWidget(w)
    HeatmapRenderer(w.copy(data = data), theme, onCite)
}

// ─── Heatmap ──────────────────────────────────────────────────────────────────

@Composable
private fun HeatmapRenderer(w: InsightWidget, theme: InsightTheme, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Heatmap) ?: return EmptyWidget()
    Column {
        Row(modifier = Modifier.fillMaxWidth()) {
            Spacer(modifier = Modifier.width(60.dp))
            data.columnLabels.take(8).forEach { Text(text = it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f), textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        data.rowLabels.forEachIndexed { rowIdx, rowLabel ->
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(text = rowLabel, style = MaterialTheme.typography.labelSmall, modifier = Modifier.width(60.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                data.cells.getOrElse(rowIdx) { emptyList() }.take(8).forEachIndexed { colIdx, value ->
                    val intensity = value.toFloat().coerceIn(0f, 1f)
                    Box(modifier = Modifier.weight(1f).height(20.dp).padding(1.dp).clip(RoundedCornerShape(2.dp))
                        .coloredRect(InsightsColors.heatmapEmber[1].copy(alpha = 0.15f + intensity * 0.85f)))
                }
            }
        }
    }
}

// ─── Mermaid (WebView placeholder) ────────────────────────────────────────────

@Composable
private fun MermaidRenderer(w: InsightWidget, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.MermaidDiagram) ?: return EmptyWidget()
    Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(text = w.kind.displayName, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
        Spacer(modifier = Modifier.height(4.dp))
        Text(text = data.source.take(200) + if (data.source.length > 200) "..." else "",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = FontFamily.Monospace)
    }
}

// ─── ASCII Card ────────────────────────────────────────────────────────────────

@Composable
private fun AsciiRenderer(w: InsightWidget, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.ASCIICard) ?: return EmptyWidget()
    Column {
        Text(text = data.headline, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
        Spacer(modifier = Modifier.height(4.dp))
        Text(text = data.monoBody, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (data.caption != null) Text(text = data.caption, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ─── Composed ──────────────────────────────────────────────────────────────────

@Composable
private fun ComposedRenderer(w: InsightWidget, onCite: (InsightCitation) -> Unit) {
    val data = (w.data as? InsightWidgetData.Composed) ?: return EmptyWidget()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        data.children.forEachIndexed { idx, _ ->
            Text(text = "Widget ${idx + 1}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// ─── Error ────────────────────────────────────────────────────────────────────

@Composable
private fun ErrorRenderer(w: InsightWidget, onCite: (InsightCitation) -> Unit) {
    val data = w.data as? InsightWidgetData.Error
    if (data != null) Text(text = data.message, style = MaterialTheme.typography.bodySmall, color = InsightsColors.kpiNegative) else EmptyWidget()
}

// ── Reusable chart components ────────────────────────────────────────────────

@Composable
private fun MiniSparkline(data: List<Double>, color: Color, modifier: Modifier = Modifier) {
    if (data.size < 2) return
    Canvas(modifier = modifier) {
        val maxVal = data.maxOrNull() ?: 1.0
        val minVal = data.minOrNull() ?: 0.0
        val range = (maxVal - minVal).coerceAtLeast(0.001)
        val stepX = size.width / (data.size - 1)
        val path = Path()
        path.moveTo(0f, size.height - ((data[0] - minVal) / range * size.height).toFloat())
        for (i in 1 until data.size) {
            path.lineTo(stepX * i, size.height - ((data[i] - minVal) / range * size.height).toFloat())
        }
        drawPath(path, color = color, style = Stroke(width = 2f, cap = StrokeCap.Round))
    }
}

@Composable
private fun SparklineChart(
    series: List<InsightWidgetData.TimeSeries.Series>,
    yFormat: ValueFormat?,
    modifier: Modifier = Modifier
) {
    val colors = listOf(InsightsColors.chartLinePrimary, InsightsColors.chartLineSecondary, InsightsColors.chartLineTertiary, InsightsColors.chartLineQuaternary)
    Canvas(modifier = modifier) {
        series.forEachIndexed { seriesIdx, s ->
            if (s.points.size < 2) return@forEachIndexed
            val color = s.colorHex?.let { parseColor(it) } ?: colors.getOrElse(seriesIdx) { colors[0] }
            val values = s.points.map { it.value }
            val maxVal = values.maxOrNull() ?: 1.0
            val minVal = values.minOrNull() ?: 0.0
            val range = (maxVal - minVal).coerceAtLeast(0.001)
            val stepX = size.width / (values.size - 1)
            val path = Path()
            for (i in values.indices) {
                val x = stepX * i
                val y = size.height - (((values[i] - minVal) / range).toFloat() * size.height * 0.85f) - size.height * 0.075f
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, color = color, style = Stroke(width = 2.5f, cap = StrokeCap.Round))
        }
    }
}

@Composable
private fun DonutChart(
    slices: List<InsightWidgetData.Distribution.Slice>,
    total: Double,
    colors: List<Color>,
    modifier: Modifier = Modifier
) {
    Canvas(modifier = modifier) {
        val strokeWidth = 16.dp.toPx()
        val radius = (minOf(size.width, size.height) - strokeWidth) / 2f
        val center = Offset(size.width / 2f, size.height / 2f)
        var startAngle = -90f
        slices.forEachIndexed { idx, slice ->
            val sweepAngle = if (total > 0) (slice.value / total * 360f).toFloat() else 0f
            drawArc(
                color = slice.colorHex?.let { parseColor(it) } ?: colors.getOrElse(idx % colors.size) { Color.Gray },
                startAngle = startAngle, sweepAngle = sweepAngle, useCenter = false,
                topLeft = Offset(center.x - radius, center.y - radius), size = Size(radius * 2f, radius * 2f),
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
            )
            startAngle += sweepAngle
        }
    }
}

// ─── Shared empty/placeholder widgets ─────────────────────────────────────────

@Composable
private fun EmptyWidget() {
    Text(text = "No data", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun PlaceholderWidget(w: InsightWidget) {
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text = w.kind.displayName, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
        Text(text = "Chart coming soon", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
