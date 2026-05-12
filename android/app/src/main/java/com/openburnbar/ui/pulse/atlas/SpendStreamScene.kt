package com.openburnbar.ui.pulse.atlas

import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Mirrors iOS `StreamGraphScene` — stacked area chart per provider with
 * Catmull-Rom interpolation, dotted today rule, tap-to-select day annotation,
 * decorative total ribbon overlay, and a 24-cell hour-of-day heat strip
 * underneath.
 */
@Composable
fun SpendStreamScene(
    digest: TrendDataDigest,
    modifier: Modifier = Modifier
) {
    val daily = digest.daily
    if (daily.isEmpty() || daily.all { it.total <= 0.0 }) {
        EmptySpendScene(modifier)
        return
    }

    var selectedIndex by remember(daily.size) { mutableStateOf<Int?>(null) }
    val sweep by animateFloatAsState(
        targetValue = 1f,
        animationSpec = tween(durationMillis = 900, easing = EaseOutCubic),
        label = "stream-sweep"
    )

    Column(modifier = modifier) {
        Box(modifier = Modifier.fillMaxWidth().height(180.dp)) {
            StreamGraphCanvas(
                series = daily,
                sweepProgress = sweep,
                selectedIndex = selectedIndex,
                onSelect = { selectedIndex = it }
            )
            TotalRibbon(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(16.dp)
                    .padding(horizontal = 4.dp)
                    .padding(top = 4.dp)
            )
            if (selectedIndex != null) {
                SelectedAnnotation(
                    daily[selectedIndex!!],
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 4.dp)
                )
            }
        }

        Spacer(Modifier.height(8.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = formatDayShort(daily.first().date),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = formatDayShort(daily.last().date),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Spacer(Modifier.height(12.dp))

        HourOfDayHeatStrip(digest = digest)

        Spacer(Modifier.height(8.dp))

        ProviderLegend(daily)
    }
}

@Composable
private fun StreamGraphCanvas(
    series: List<TrendDataDigest.DailySeries>,
    sweepProgress: Float,
    selectedIndex: Int?,
    onSelect: (Int?) -> Unit
) {
    val providers = remember(series) {
        // Stable provider draw order: by aggregate cost across the window
        // (largest at the bottom of the stack — most visual weight).
        series.flatMap { it.perProvider.entries }
            .groupBy { it.key }
            .map { (k, v) -> k to v.sumOf { it.value } }
            .sortedByDescending { it.second }
            .map { it.first }
    }

    val maxStack = remember(series) {
        series.maxOfOrNull { it.perProvider.values.sum() }?.coerceAtLeast(0.0001) ?: 0.0001
    }

    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(series) {
                detectTapGestures { offset ->
                    if (series.size < 2) return@detectTapGestures
                    val stepX = size.width / (series.size - 1).coerceAtLeast(1)
                    val idx = (offset.x / stepX).toInt().coerceIn(0, series.size - 1)
                    onSelect(if (selectedIndex == idx) null else idx)
                }
            }
    ) {
        val w = size.width
        val h = size.height
        val stepX = w / (series.size - 1).coerceAtLeast(1)

        // Build per-provider point sequences from cumulative top → bottom.
        // Each provider contributes points that trace its TOP edge in the
        // stack; the BOTTOM edge is the cumulative of providers below it.
        val cumulativeBelow = DoubleArray(series.size)

        for (provider in providers) {
            val topPoints = ArrayList<Offset>(series.size)
            val bottomPoints = ArrayList<Offset>(series.size)
            for ((i, day) in series.withIndex()) {
                val value = day.perProvider[provider] ?: 0.0
                val below = cumulativeBelow[i]
                val above = below + value
                val x = i * stepX
                val yTop = h - (above / maxStack).toFloat() * h * sweepProgress
                val yBottom = h - (below / maxStack).toFloat() * h * sweepProgress
                topPoints += Offset(x, yTop)
                bottomPoints += Offset(x, yBottom)
                cumulativeBelow[i] = above
            }

            val fillPath = catmullRomFillPath(topPoints, bottomPoints)
            val brush = providerBrush(provider)
            drawPath(path = fillPath, brush = brush, alpha = 0.92f)
            // Stroke the top edge with a slightly brighter version for definition.
            val edge = catmullRomStrokePath(topPoints)
            drawPath(
                path = edge,
                color = providerAccent(provider).copy(alpha = 0.55f),
                style = Stroke(width = 1.2f, cap = StrokeCap.Round)
            )
        }

        // Dotted today rule (last day in series).
        if (series.isNotEmpty()) {
            val todayX = (series.size - 1) * stepX
            drawLine(
                color = AuroraColors.amber.copy(alpha = 0.55f),
                start = Offset(todayX, 0f),
                end = Offset(todayX, h),
                strokeWidth = 1.5f,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f))
            )
        }

        // Selected-date rule (solid).
        if (selectedIndex != null && selectedIndex in series.indices) {
            val selX = selectedIndex * stepX
            drawLine(
                color = AuroraColors.ember.copy(alpha = 0.85f),
                start = Offset(selX, 0f),
                end = Offset(selX, h),
                strokeWidth = 1.8f
            )
        }
    }
}

@Composable
private fun TotalRibbon(modifier: Modifier = Modifier) {
    // Decorative top-bleed ribbon — mimics iOS overlay with `.plusLighter`
    // blend. Compose Canvas doesn't expose plusLighter cleanly, so we use
    // BlendMode.Plus which is the standard analogue.
    Canvas(modifier = modifier) {
        drawRect(
            brush = Brush.verticalGradient(
                colors = listOf(
                    AuroraColors.ember.copy(alpha = 0.35f),
                    AuroraColors.amber.copy(alpha = 0.18f),
                    Color.Transparent
                )
            ),
            size = size,
            blendMode = BlendMode.Plus
        )
    }
}

@Composable
private fun SelectedAnnotation(
    series: TrendDataDigest.DailySeries,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = formatDayLong(series.date),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = "$${"%.2f".format(series.total)}",
                style = AuroraType.caption,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

@Composable
private fun ProviderLegend(daily: List<TrendDataDigest.DailySeries>) {
    val providers = remember(daily) {
        daily.flatMap { it.perProvider.entries }
            .groupBy { it.key }
            .map { (k, v) -> k to v.sumOf { it.value } }
            .sortedByDescending { it.second }
            .map { it.first }
            .take(4)
    }
    if (providers.isEmpty()) return
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        providers.forEach { p ->
            val accent = providerAccent(p)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(accent.copy(alpha = 0.85f))
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = AgentProvider.fromKey(p)?.displayName ?: p,
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun HourOfDayHeatStrip(digest: TrendDataDigest) {
    val buckets = digest.hourly
    val max = buckets.maxOfOrNull { it.tokens }?.toFloat()?.coerceAtLeast(1f) ?: 1f
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(28.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        for (b in buckets) {
            val intensity = b.tokens.toFloat() / max
            val alpha = 0.15f + intensity * 0.70f
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(4.dp))
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(
                                AuroraColors.amber.copy(alpha = alpha),
                                AuroraColors.ember.copy(alpha = alpha * 0.85f)
                            )
                        )
                    )
            )
        }
    }
}

@Composable
private fun EmptySpendScene(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .height(180.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "No spend history yet",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = "Run a session and Trend Atlas will fill in.",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// ── Path helpers ──

/** Catmull-Rom interpolated FILL path that closes top-edge ↔ bottom-edge. */
private fun catmullRomFillPath(top: List<Offset>, bottom: List<Offset>): Path {
    val path = Path()
    if (top.isEmpty()) return path
    path.moveTo(top.first().x, top.first().y)
    appendCatmullRom(path, top)
    // Walk the bottom edge in reverse so the closed area covers the stack.
    val rev = bottom.reversed()
    path.lineTo(rev.first().x, rev.first().y)
    appendCatmullRom(path, rev)
    path.close()
    return path
}

/** Stroke-only Catmull-Rom polyline. */
private fun catmullRomStrokePath(points: List<Offset>): Path {
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

// ── Provider color helpers ──

private fun providerAccent(providerKey: String): Color {
    val agent = AgentProvider.fromKey(providerKey)
    return if (agent != null) Color(agent.brandColor) else AuroraColors.ember
}

private fun providerBrush(providerKey: String): Brush {
    val accent = providerAccent(providerKey)
    return Brush.verticalGradient(
        colors = listOf(accent.copy(alpha = 0.55f), accent.copy(alpha = 0.18f))
    )
}

// ── Date formatting ──

private val ISO = SimpleDateFormat("yyyy-MM-dd", Locale.US)
private val SHORT = SimpleDateFormat("MMM d", Locale.getDefault())
private val LONG = SimpleDateFormat("EEE, MMM d", Locale.getDefault())

private fun formatDayShort(iso: String): String =
    runCatching { ISO.parse(iso)?.let { SHORT.format(it) } }.getOrNull() ?: iso

private fun formatDayLong(iso: String): String =
    runCatching { ISO.parse(iso)?.let { LONG.format(it) } }.getOrNull() ?: iso
