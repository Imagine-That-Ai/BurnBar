package com.openburnbar.ui.chartstudio.charts

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.chartstudio.AxisSpec
import com.openburnbar.ui.chartstudio.ChartKind
import com.openburnbar.ui.chartstudio.ChartSpec
import com.openburnbar.ui.chartstudio.DataPoint
import com.openburnbar.ui.chartstudio.RuleSpec
import com.openburnbar.ui.chartstudio.SeriesSpec
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sin

/** Render mode — Studio canvases default to FULL (260dp); gallery thumbs use GALLERY (165dp). */
enum class NativeChartDisplay { FULL, GALLERY }

/**
 * Single entry point that dispatches a [ChartSpec] to a Compose Canvas
 * implementation for each chart kind. Reuses the Catmull-Rom + scatter math
 * we already validated in `SpendStreamScene` and `CacheConstellationScene`.
 *
 * The renderer is intentionally additive: extending support for a new chart
 * kind only needs a `when` branch + a private `drawXxx(...)` function.
 */
@Composable
fun NativeChart(
    spec: ChartSpec,
    modifier: Modifier = Modifier,
    display: NativeChartDisplay = NativeChartDisplay.FULL
) {
    val chartHeight: Dp = spec.height?.dp ?: when (display) {
        NativeChartDisplay.FULL -> 260.dp
        NativeChartDisplay.GALLERY -> 165.dp
    }

    Column(modifier = modifier) {
        if (!spec.title.isNullOrBlank() || !spec.subtitle.isNullOrBlank()) {
            ChartHeader(spec.title, spec.subtitle)
            Spacer(Modifier.height(AuroraSpacing.sm.dp))
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(chartHeight)
                .clip(RoundedCornerShape(12.dp))
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawChart(spec)
            }
        }

        if (spec.legend && spec.series.size > 1) {
            Spacer(Modifier.height(AuroraSpacing.sm.dp))
            LegendChipRail(spec.series)
        }
    }
}

@Composable
private fun ChartHeader(title: String?, subtitle: String?) {
    Column {
        if (!title.isNullOrBlank()) {
            Text(
                text = title,
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
        if (!subtitle.isNullOrBlank()) {
            Text(
                text = subtitle,
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun LegendChipRail(series: List<SeriesSpec>) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 2.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        items(series.size) { i ->
            val s = series[i]
            val color = resolveSeriesColor(s, i)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(color.copy(alpha = 0.85f))
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = s.name,
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

// LazyRow's `items` extension that takes Int — explicit so we don't pull in the
// foundation version with type inference that bites us in some Compose betas.
private fun androidx.compose.foundation.lazy.LazyListScope.items(
    count: Int,
    itemContent: @Composable (Int) -> Unit
) = items(count = count, key = null, contentType = { 0 }, itemContent = { itemContent(it) })

// ── Drawing dispatcher ─────────────────────────────────────────────────────

private fun DrawScope.drawChart(spec: ChartSpec) {
    when (spec.chart) {
        ChartKind.LINE -> drawLineOrArea(spec, filled = false)
        ChartKind.AREA -> drawLineOrArea(spec, filled = true)
        ChartKind.STACKED_AREA, ChartKind.STREAM -> drawStackedArea(spec)
        ChartKind.BAR -> drawBars(spec, stacked = false)
        ChartKind.STACKED_BAR -> drawBars(spec, stacked = true)
        ChartKind.SCATTER -> drawScatter(spec)
        ChartKind.HEATMAP -> drawHeatmap(spec)
        ChartKind.DONUT -> drawDonut(spec)
        ChartKind.RULE -> drawRulesOnly(spec)
    }
    // Rules apply on top of every kind so callers can annotate any chart.
    if (spec.chart != ChartKind.RULE && spec.chart != ChartKind.DONUT) {
        for (rule in spec.rules) drawRule(rule)
    }
    drawAxisLabels(spec)
}

// ── Line / Area ────────────────────────────────────────────────────────────

private fun DrawScope.drawLineOrArea(spec: ChartSpec, filled: Boolean) {
    val series = spec.series.firstOrNull() ?: return
    if (series.data.size < 2) return
    val color = resolveSeriesColor(series, 0)
    val xs = series.data.size
    val (minY, maxY) = yRange(spec.series)
    val pts = series.data.mapIndexed { i, p ->
        val x = padL() + (size.width - padL() - padR()) * i / (xs - 1f)
        val y = mapY(p.y, minY, maxY)
        Offset(x, y)
    }
    val path = catmullRomPath(pts)
    if (filled) {
        val fillPath = Path().apply {
            addPath(path)
            lineTo(pts.last().x, mapY(minY, minY, maxY))
            lineTo(pts.first().x, mapY(minY, minY, maxY))
            close()
        }
        drawPath(
            path = fillPath,
            brush = Brush.verticalGradient(
                colors = listOf(color.copy(alpha = 0.55f), color.copy(alpha = 0.10f))
            )
        )
    }
    drawPath(
        path = path,
        color = color,
        style = Stroke(width = 2.5f, cap = StrokeCap.Round, join = StrokeJoin.Round)
    )
}

// ── Stacked Area / Stream ──────────────────────────────────────────────────

private fun DrawScope.drawStackedArea(spec: ChartSpec) {
    val nonEmpty = spec.series.filter { it.data.isNotEmpty() }
    if (nonEmpty.isEmpty()) return
    val xs = nonEmpty.maxOf { it.data.size }
    if (xs < 2) return
    val perX = DoubleArray(xs)
    for (s in nonEmpty) for ((i, p) in s.data.withIndex()) if (i < xs) perX[i] += p.y
    val maxStack = perX.maxOrNull()?.coerceAtLeast(0.0001) ?: 0.0001

    val cumulative = DoubleArray(xs)
    for ((seriesIndex, s) in nonEmpty.withIndex()) {
        val color = resolveSeriesColor(s, seriesIndex)
        val top = mutableListOf<Offset>()
        val bot = mutableListOf<Offset>()
        for (i in 0 until xs) {
            val value = s.data.getOrNull(i)?.y ?: 0.0
            val below = cumulative[i]
            val above = below + value
            val x = padL() + (size.width - padL() - padR()) * i / (xs - 1f)
            val yTop = size.height - padB() - ((above / maxStack).toFloat() * (size.height - padT() - padB()))
            val yBot = size.height - padB() - ((below / maxStack).toFloat() * (size.height - padT() - padB()))
            top += Offset(x, yTop)
            bot += Offset(x, yBot)
            cumulative[i] = above
        }
        val fillPath = stackedFillPath(top, bot)
        drawPath(
            path = fillPath,
            brush = Brush.verticalGradient(
                colors = listOf(color.copy(alpha = 0.65f), color.copy(alpha = 0.20f))
            )
        )
        val edge = catmullRomPath(top)
        drawPath(
            path = edge,
            color = color.copy(alpha = 0.85f),
            style = Stroke(width = 1.4f, cap = StrokeCap.Round)
        )
    }
}

// ── Bars / Stacked Bars ────────────────────────────────────────────────────

private fun DrawScope.drawBars(spec: ChartSpec, stacked: Boolean) {
    val nonEmpty = spec.series.filter { it.data.isNotEmpty() }
    if (nonEmpty.isEmpty()) return
    val categories = nonEmpty.first().data.size
    if (categories == 0) return

    val chartWidth = size.width - padL() - padR()
    val chartHeight = size.height - padT() - padB()
    val (minY, maxY) = if (stacked) {
        val perX = DoubleArray(categories)
        for (s in nonEmpty) for ((i, p) in s.data.withIndex()) if (i < categories) perX[i] += p.y
        0.0 to (perX.maxOrNull() ?: 1.0).coerceAtLeast(0.0001)
    } else {
        yRange(nonEmpty)
    }

    val slotW = chartWidth / categories
    val barInset = slotW * 0.18f
    val barW = slotW - barInset * 2

    if (stacked) {
        val cumulative = DoubleArray(categories)
        for ((seriesIndex, s) in nonEmpty.withIndex()) {
            val color = resolveSeriesColor(s, seriesIndex)
            for (i in 0 until categories) {
                val value = s.data.getOrNull(i)?.y ?: 0.0
                val above = cumulative[i] + value
                val below = cumulative[i]
                val xLeft = padL() + slotW * i + barInset
                val yTop = size.height - padB() - ((above / maxY).toFloat() * chartHeight)
                val yBot = size.height - padB() - ((below / maxY).toFloat() * chartHeight)
                drawRect(
                    color = color,
                    topLeft = Offset(xLeft, yTop),
                    size = Size(barW, max(2f, yBot - yTop))
                )
                cumulative[i] = above
            }
        }
    } else {
        val seriesCount = nonEmpty.size
        val groupW = barW / seriesCount
        for ((seriesIndex, s) in nonEmpty.withIndex()) {
            val color = resolveSeriesColor(s, seriesIndex)
            for (i in 0 until categories) {
                val value = s.data.getOrNull(i)?.y ?: 0.0
                val xLeft = padL() + slotW * i + barInset + groupW * seriesIndex
                val yTop = size.height - padB() - (((value - minY) / (maxY - minY)).toFloat() * chartHeight)
                val yBot = size.height - padB()
                drawRect(
                    color = color,
                    topLeft = Offset(xLeft, yTop),
                    size = Size(groupW * 0.85f, max(2f, yBot - yTop))
                )
            }
        }
    }
}

// ── Scatter ────────────────────────────────────────────────────────────────

private fun DrawScope.drawScatter(spec: ChartSpec) {
    val pts = spec.series.flatMapIndexed { si, s ->
        s.data.map { Triple(si, s, it) }
    }
    if (pts.isEmpty()) return

    val xs = pts.mapNotNull { it.third.x.toDoubleOrNull() }
    val (xMin, xMax) = (xs.minOrNull() ?: 0.0) to (xs.maxOrNull() ?: 1.0).coerceAtLeast(0.0001)
    val (yMin, yMax) = pts.minOf { it.third.y } to pts.maxOf { it.third.y }.coerceAtLeast(0.0001)

    for ((si, series, p) in pts) {
        val xVal = p.x.toDoubleOrNull() ?: continue
        val xFrac = ((xVal - xMin) / (xMax - xMin)).toFloat().coerceIn(0f, 1f)
        val yFrac = ((p.y - yMin) / (yMax - yMin)).toFloat().coerceIn(0f, 1f)
        val cx = padL() + xFrac * (size.width - padL() - padR())
        val cy = size.height - padB() - yFrac * (size.height - padT() - padB())
        val color = resolveSeriesColor(series, si)
        drawCircle(color = color.copy(alpha = 0.7f), radius = 6f, center = Offset(cx, cy))
        drawCircle(color = Color.White.copy(alpha = 0.55f), radius = 6f, center = Offset(cx, cy), style = Stroke(width = 0.6f))
    }
}

// ── Heatmap ────────────────────────────────────────────────────────────────

private fun DrawScope.drawHeatmap(spec: ChartSpec) {
    val series = spec.series.firstOrNull() ?: return
    if (series.data.isEmpty()) return
    val cells = series.data
    val maxV = cells.maxOf { it.y }.coerceAtLeast(0.0001)
    val columns = 24
    val rows = (cells.size + columns - 1) / columns
    val w = (size.width - padL() - padR()) / columns
    val h = (size.height - padT() - padB()) / rows.coerceAtLeast(1)
    val color = resolveSeriesColor(series, 0)
    for ((i, p) in cells.withIndex()) {
        val col = i % columns
        val row = i / columns
        val intensity = (p.y / maxV).toFloat().coerceIn(0f, 1f)
        drawRect(
            color = color.copy(alpha = 0.20f + intensity * 0.75f),
            topLeft = Offset(padL() + col * w + 1f, padT() + row * h + 1f),
            size = Size(w - 2f, h - 2f)
        )
    }
}

// ── Donut ──────────────────────────────────────────────────────────────────

private fun DrawScope.drawDonut(spec: ChartSpec) {
    val series = spec.series.firstOrNull() ?: return
    val points = series.data.filter { it.y > 0 }
    if (points.isEmpty()) return
    val total = points.sumOf { it.y }
    val cx = size.width / 2f
    val cy = size.height / 2f
    val outerR = (kotlin.math.min(size.width, size.height) / 2f) * 0.85f
    val innerR = outerR * 0.55f

    var start = -90f
    for ((i, p) in points.withIndex()) {
        val sweep = (p.y / total).toFloat() * 360f
        val color = resolveSeriesColor(series, i).copy(alpha = 0.85f)
        drawArc(
            color = color,
            startAngle = start,
            sweepAngle = sweep,
            useCenter = true,
            topLeft = Offset(cx - outerR, cy - outerR),
            size = Size(outerR * 2, outerR * 2)
        )
        start += sweep
    }
    // Cut the inner hole — drawing background color
    drawCircle(color = Color.Transparent, radius = innerR, center = Offset(cx, cy))
}

// ── Standalone rule ────────────────────────────────────────────────────────

private fun DrawScope.drawRulesOnly(spec: ChartSpec) {
    for (rule in spec.rules) drawRule(rule)
}

private fun DrawScope.drawRule(rule: RuleSpec) {
    val color = rule.color?.let { parseHex(it) } ?: AuroraColors.amber
    val effect = if (rule.dashed) PathEffect.dashPathEffect(floatArrayOf(6f, 6f)) else null
    if (rule.orientation == "vertical") {
        val x = padL() + rule.value.toFloat()
        drawLine(
            color = color.copy(alpha = 0.7f),
            start = Offset(x, padT()),
            end = Offset(x, size.height - padB()),
            strokeWidth = 1.6f,
            pathEffect = effect
        )
    } else {
        val y = size.height - padB() - rule.value.toFloat() * (size.height - padT() - padB())
        drawLine(
            color = color.copy(alpha = 0.7f),
            start = Offset(padL(), y),
            end = Offset(size.width - padR(), y),
            strokeWidth = 1.6f,
            pathEffect = effect
        )
    }
}

// ── Axes + labels ──────────────────────────────────────────────────────────

private fun DrawScope.drawAxisLabels(spec: ChartSpec) {
    val xAxis = spec.xAxis
    val yAxis = spec.yAxis
    val paint = android.graphics.Paint().apply {
        color = android.graphics.Color.argb(170, 200, 196, 188)
        textSize = 10.sp.toPx()
        isAntiAlias = true
    }

    if (yAxis?.showGrid == true) {
        val ticks = 4
        for (i in 0..ticks) {
            val y = padT() + (size.height - padT() - padB()) * i / ticks
            drawLine(
                color = AuroraColors.lightBorder.copy(alpha = 0.10f),
                start = Offset(padL(), y),
                end = Offset(size.width - padR(), y),
                strokeWidth = 0.6f
            )
        }
    }
    val firstSeries = spec.series.firstOrNull { it.data.isNotEmpty() }
    if (firstSeries != null && xAxis != null) {
        val pts = firstSeries.data
        val tickIdx = listOf(0, pts.size / 2, pts.size - 1).distinct()
        for (i in tickIdx) {
            val label = pts[i].x
            val x = padL() + (size.width - padL() - padR()) * i / (pts.size - 1).coerceAtLeast(1)
            drawIntoCanvas { canvas ->
                canvas.nativeCanvas.drawText(
                    label.take(8),
                    x - paint.measureText(label.take(8)) / 2f,
                    size.height - 4f,
                    paint
                )
            }
        }
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

private fun DrawScope.padL() = 12f
private fun DrawScope.padR() = 8f
private fun DrawScope.padT() = 8f
private fun DrawScope.padB() = 20f

private fun DrawScope.mapY(value: Double, min: Double, max: Double): Float {
    val frac = ((value - min) / (max - min).coerceAtLeast(0.0001)).toFloat().coerceIn(0f, 1f)
    return size.height - padB() - frac * (size.height - padT() - padB())
}

private fun yRange(series: List<SeriesSpec>): Pair<Double, Double> {
    val flat = series.flatMap { it.data }.map { it.y }
    if (flat.isEmpty()) return 0.0 to 1.0
    val lo = flat.min()
    val hi = flat.max()
    val pad = (hi - lo).coerceAtLeast(0.001) * 0.1
    return (lo - pad) to (hi + pad)
}

private fun stackedFillPath(top: List<Offset>, bottom: List<Offset>): Path {
    val path = Path()
    if (top.isEmpty()) return path
    path.moveTo(top.first().x, top.first().y)
    appendCatmullRom(path, top)
    val rev = bottom.reversed()
    path.lineTo(rev.first().x, rev.first().y)
    appendCatmullRom(path, rev)
    path.close()
    return path
}

private fun catmullRomPath(points: List<Offset>): Path {
    val path = Path()
    if (points.isEmpty()) return path
    path.moveTo(points.first().x, points.first().y)
    appendCatmullRom(path, points)
    return path
}

private fun appendCatmullRom(path: Path, points: List<Offset>) {
    for (i in 0 until points.size - 1) {
        val p0 = points.getOrNull(i - 1) ?: points[i]
        val p1 = points[i]
        val p2 = points[i + 1]
        val p3 = points.getOrNull(i + 2) ?: points[i + 1]
        val cp1 = Offset(p1.x + (p2.x - p0.x) / 6f, p1.y + (p2.y - p0.y) / 6f)
        val cp2 = Offset(p2.x - (p3.x - p1.x) / 6f, p2.y - (p3.y - p1.y) / 6f)
        path.cubicTo(cp1.x, cp1.y, cp2.x, cp2.y, p2.x, p2.y)
    }
}

private val palette = listOf(
    AuroraColors.ember, AuroraColors.amber, AuroraColors.whimsy,
    AuroraColors.blaze, AuroraColors.hermesAureate, AuroraColors.success,
    AuroraColors.warning, AuroraColors.hermesMercury
)

private fun resolveSeriesColor(s: SeriesSpec, index: Int): Color {
    s.providerKey?.let { key ->
        AgentProvider.fromKey(key)?.let { return Color(it.brandColor) }
    }
    s.color?.let { return parseHex(it) }
    return palette[index % palette.size]
}

private fun parseHex(hex: String): Color {
    val clean = hex.trim().removePrefix("#")
    val v = clean.toLong(16)
    return when (clean.length) {
        6 -> Color(0xFF000000 or v)
        8 -> Color(v)
        else -> AuroraColors.ember
    }
}

private fun Double.toDoubleOrNull(): Double = this

private fun String.toDoubleOrNull(): Double? = runCatching { this.toDouble() }.getOrNull()
