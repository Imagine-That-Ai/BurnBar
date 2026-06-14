// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors

@Composable
internal fun StreamGraphCanvas(series: List<TrendDataDigest.DailySeries>, sweepProgress: Float, selectedIndex: Int?, onSelect: (Int?) -> Unit) {
    val providers =
        remember(series) {
            series.flatMap { it.perProvider.entries }
                .groupBy { it.key }
                .map { (k, v) -> k to v.sumOf { it.value } }
                .sortedByDescending { it.second }
                .map { it.first }
        }
    val maxStack =
        remember(series) {
            series.maxOfOrNull { it.perProvider.values.sum() }?.coerceAtLeast(0.0001) ?: 0.0001
        }

    Canvas(
        modifier =
        Modifier
            .fillMaxSize()
            .pointerInput(series) {
                detectTapGestures { offset ->
                    if (series.size < 2) return@detectTapGestures
                    val stepX = size.width / (series.size - 1).coerceAtLeast(1)
                    val idx = (offset.x / stepX).toInt().coerceIn(0, series.size - 1)
                    onSelect(if (selectedIndex == idx) null else idx)
                }
            },
    ) {
        val stepX = size.width / (series.size - 1).coerceAtLeast(1)
        drawStreamGraphStacks(series, providers, maxStack, stepX, size.height, sweepProgress)
        drawStreamGraphGuides(series.size, stepX, size.height, selectedIndex)
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawStreamGraphStacks(
    series: List<TrendDataDigest.DailySeries>,
    providers: List<String>,
    maxStack: Double,
    stepX: Float,
    height: Float,
    sweepProgress: Float,
) {
    val cumulativeBelow = DoubleArray(series.size)
    for (provider in providers) {
        val topPoints = ArrayList<Offset>(series.size)
        val bottomPoints = ArrayList<Offset>(series.size)
        for ((i, day) in series.withIndex()) {
            val value = day.perProvider[provider] ?: 0.0
            val below = cumulativeBelow[i]
            val above = below + value
            val x = i * stepX
            topPoints += Offset(x, height - (above / maxStack).toFloat() * height * sweepProgress)
            bottomPoints += Offset(x, height - (below / maxStack).toFloat() * height * sweepProgress)
            cumulativeBelow[i] = above
        }
        drawPath(path = catmullRomFillPath(topPoints, bottomPoints), brush = providerBrush(provider), alpha = 0.92f)
        drawPath(
            path = catmullRomStrokePath(topPoints),
            color = providerAccent(provider).copy(alpha = 0.55f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.2f, cap = StrokeCap.Round),
        )
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawStreamGraphGuides(seriesSize: Int, stepX: Float, height: Float, selectedIndex: Int?) {
    if (seriesSize > 0) {
        val todayX = (seriesSize - 1) * stepX
        drawLine(
            color = AuroraColors.amber.copy(alpha = 0.55f),
            start = Offset(todayX, 0f),
            end = Offset(todayX, height),
            strokeWidth = 1.5f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f)),
        )
    }
    if (selectedIndex != null && selectedIndex in 0 until seriesSize) {
        val selX = selectedIndex * stepX
        drawLine(
            color = AuroraColors.ember.copy(alpha = 0.85f),
            start = Offset(selX, 0f),
            end = Offset(selX, height),
            strokeWidth = 1.8f,
        )
    }
}

internal fun catmullRomFillPath(top: List<Offset>, bottom: List<Offset>): Path {
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

internal fun catmullRomStrokePath(points: List<Offset>): Path {
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

internal fun providerAccent(providerKey: String): Color {
    val agent = AgentProvider.fromKey(providerKey)
    return if (agent != null) Color(agent.brandColor) else AuroraColors.ember
}

internal fun providerBrush(providerKey: String): Brush {
    val accent = providerAccent(providerKey)
    return Brush.verticalGradient(colors = listOf(accent.copy(alpha = 0.55f), accent.copy(alpha = 0.18f)))
}
