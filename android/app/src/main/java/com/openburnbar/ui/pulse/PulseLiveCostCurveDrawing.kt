@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.theme.AuroraColors
import kotlin.math.max

internal fun DrawScope.drawPulseLiveEmptyRail(accent: Color, plotH: Float, width: Float, sweep: Float) {
    val railY = plotH * 0.78f
    drawLine(
        brush =
        androidx.compose.ui.graphics.Brush.linearGradient(
            colors =
            listOf(
                accent.copy(alpha = 0.25f),
                AuroraColors.amber.copy(alpha = 0.55f),
                accent.copy(alpha = 0.25f),
            ),
            start = Offset(0f, railY),
            end = Offset(width, railY),
        ),
        start = Offset(0f, railY),
        end = Offset(width, railY),
        strokeWidth = 1.5.dp.toPx(),
        cap = StrokeCap.Round,
        pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 12f)),
    )
    val blobWidth = width * 0.30f
    val sweepOffset = (width + blobWidth) * sweep - blobWidth * 0.5f
    drawRect(
        brush =
        androidx.compose.ui.graphics.Brush.horizontalGradient(
            colors = listOf(Color.Transparent, accent.copy(alpha = 0.42f), Color.Transparent),
            startX = sweepOffset,
            endX = sweepOffset + blobWidth,
        ),
        topLeft = Offset(sweepOffset, railY - 14.dp.toPx()),
        size = androidx.compose.ui.geometry.Size(blobWidth, 28.dp.toPx()),
    )
}

internal data class PulseFilledCurveDrawParams(
    val samples: List<CostSample>,
    val domain: Pair<Long, Long>,
    val plotH: Float,
    val width: Float,
    val yMax: Double,
    val accent: Color,
    val isDark: Boolean,
    val pulse: Float,
)

internal data class PulseLiveFilledCurveGeometry(
    val plotH: Float,
    val width: Float,
    val yMax: Double,
)

internal fun DrawScope.drawPulseLiveFilledCurve(params: PulseFilledCurveDrawParams) {
    val xFor: (Long) -> Float = { t ->
        val span = (params.domain.second - params.domain.first).coerceAtLeast(1L)
        ((t - params.domain.first).toDouble() / span * params.width).toFloat()
    }
    val yFor: (Double) -> Float = { v ->
        val frac = (v / params.yMax).coerceIn(0.0, 1.0)
        (params.plotH - frac * params.plotH).toFloat()
    }
    val points = params.samples.map { Offset(xFor(it.timeMillis), yFor(it.cumulative)) }
    val linePath = monotonePath(points)
    val areaPath =
        Path().apply {
            addPath(linePath)
            lineTo(points.last().x, params.plotH)
            lineTo(points.first().x, params.plotH)
            close()
        }
    drawPath(
        path = areaPath,
        brush =
        androidx.compose.ui.graphics.Brush.verticalGradient(
            colors =
            listOf(
                params.accent.copy(alpha = if (params.isDark) 0.55f else 0.42f),
                AuroraColors.amber.copy(alpha = if (params.isDark) 0.30f else 0.20f),
                AuroraColors.blaze.copy(alpha = 0f),
            ),
            startY = 0f,
            endY = params.plotH,
        ),
    )
    drawPath(
        path = linePath,
        color = params.accent.copy(alpha = 0.35f),
        style = Stroke(width = 6.dp.toPx(), cap = StrokeCap.Round),
    )
    drawPath(
        path = linePath,
        brush =
        androidx.compose.ui.graphics.Brush.horizontalGradient(
            colors = listOf(AuroraColors.amber, params.accent, AuroraColors.ember),
        ),
        style = Stroke(width = 2.4.dp.toPx(), cap = StrokeCap.Round),
    )
    val last = points.last()
    val haloR = (14f + 6f * params.pulse).dp.toPx()
    drawCircle(color = params.accent.copy(alpha = 0.18f * (1f - 0.5f * params.pulse)), radius = haloR, center = last)
    drawCircle(color = params.accent.copy(alpha = 0.30f), radius = 7.dp.toPx(), center = last)
    drawCircle(color = params.accent, radius = 4.dp.toPx(), center = last)
}

internal fun monotonePath(points: List<Offset>): Path {
    val path = Path()
    if (points.isEmpty()) return path
    path.moveTo(points[0].x, points[0].y)
    if (points.size == 1) return path
    if (points.size == 2) {
        path.lineTo(points[1].x, points[1].y)
        return path
    }
    val n = points.size
    val tangents = FloatArray(n)
    for (i in 0 until n - 1) {
        val dx = points[i + 1].x - points[i].x
        val dy = points[i + 1].y - points[i].y
        tangents[i] = if (dx != 0f) dy / dx else 0f
    }
    tangents[n - 1] = tangents[n - 2]
    for (i in 0 until n - 1) {
        val p0 = points[i]
        val p1 = points[i + 1]
        val dx = (p1.x - p0.x) / 3f
        val c1 = Offset(p0.x + dx, p0.y + dx * tangents[i])
        val c2 = Offset(p1.x - dx, p1.y - dx * tangents[i + 1])
        path.cubicTo(c1.x, c1.y, c2.x, c2.y, p1.x, p1.y)
    }
    return path
}

internal fun TokenUsage.pulseEventTimeMillis(): Long {
    val eventTimes = listOf(timestamp, startTime, endTime).filter { it > 0L }
    eventTimes.maxOrNull()?.let { return it }
    return 0L
}

internal fun domainFor(scope: PulseTimelineScope, nowMillis: Long): Pair<Long, Long> =
    when (scope) {
        PulseTimelineScope.MINUTE -> nowMillis - 60_000L to nowMillis
        PulseTimelineScope.HOUR -> nowMillis - 3_600_000L to nowMillis
        PulseTimelineScope.DAY -> nowMillis - 86_400_000L to nowMillis
        PulseTimelineScope.WEEK -> {
            val start = startOfLocalPulseDayMillis(nowMillis) - 6L * 86_400_000L
            start to nowMillis
        }
        PulseTimelineScope.MONTH -> {
            val start = startOfLocalPulseDayMillis(nowMillis) - 29L * 86_400_000L
            start to nowMillis
        }
    }

internal fun buildLiveSamples(
    usages: List<com.openburnbar.data.models.TokenUsage>,
    scope: PulseTimelineScope,
    domain: Pair<Long, Long>,
    displayMode: com.openburnbar.data.models.UsageDisplayMode,
    nowMillis: Long,
): List<CostSample> {
    val (lower, _) = domain
    val upper = nowMillis
    if (upper <= lower) return emptyList()
    val bucketCount =
        when (scope) {
            PulseTimelineScope.MINUTE -> 24
            PulseTimelineScope.HOUR -> 30
            PulseTimelineScope.DAY -> 24
            else -> 24
        }
    val span = upper - lower
    val stride = span / bucketCount.toLong()
    if (stride <= 0L) return emptyList()
    val relevant =
        usages
            .asSequence()
            .filter { it.pulseEventTimeMillis() in lower..upper }
            .sortedBy { it.pulseEventTimeMillis() }
            .toList()
    val out = ArrayList<CostSample>(bucketCount + 1)
    out += CostSample(timeMillis = lower, cumulative = 0.0)
    var cumulative = 0.0
    var cursor = 0
    for (i in 1..bucketCount) {
        val edge = lower + i * stride
        while (cursor < relevant.size && relevant[cursor].pulseEventTimeMillis() <= edge) {
            val event = relevant[cursor]
            cumulative +=
                when (displayMode) {
                    com.openburnbar.data.models.UsageDisplayMode.CURRENCY -> max(0.0, event.effectiveCost)
                    com.openburnbar.data.models.UsageDisplayMode.TOKENS -> max(0, event.totalTokens).toDouble()
                }
            cursor++
        }
        out += CostSample(timeMillis = edge, cumulative = cumulative)
    }
    return out
}

internal fun buildAggregateSamples(dailyPoints: Map<String, Double>, domain: Pair<Long, Long>): List<CostSample> {
    val parser = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
    val sorted =
        dailyPoints.entries
            .mapNotNull { entry ->
                runCatching { parser.parse(entry.key)?.time }.getOrNull()?.let { it to entry.value }
            }
            .filter { it.first in domain.first..domain.second }
            .sortedBy { it.first }
    val out = ArrayList<CostSample>(sorted.size + 1)
    out += CostSample(timeMillis = domain.first, cumulative = 0.0)
    var cumulative = 0.0
    for ((time, value) in sorted) {
        cumulative += max(0.0, value)
        out += CostSample(timeMillis = time, cumulative = cumulative)
    }
    return out
}

internal fun emptyMessage(scope: PulseTimelineScope): String =
    when (scope) {
        PulseTimelineScope.MINUTE -> "AWAITING THIS MINUTE'S BURN"
        PulseTimelineScope.HOUR -> "AWAITING THIS HOUR'S BURN"
        PulseTimelineScope.DAY -> "NO BURN IN LAST 24H"
        PulseTimelineScope.WEEK -> "NO DATA THIS WEEK YET"
        PulseTimelineScope.MONTH -> "NO DATA THIS MONTH YET"
    }
