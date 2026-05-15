package com.openburnbar.ui.pulse

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.theme.AuroraColors
import java.text.SimpleDateFormat
import java.util.Locale
import kotlin.math.max

/**
 * Live cumulative cost (or token) curve rendered under the Pulse hero metric.
 *
 *  - Buckets recent `TokenUsage` records into N samples across the visible
 *    window and plots a running cumulative.
 *  - Uses a monotone cubic interpolation for the line + a vertical area fill
 *    that fades from `accent → amber → transparent`.
 *  - Trailing "now" dot pulses and casts a soft halo.
 *  - When the window has no activity (the screenshot case — `$0.00`), the
 *    curve collapses into a soft dashed rail with an "awaiting" caption so
 *    the card still feels alive rather than empty.
 */
@Composable
fun PulseLiveCostCurve(
    usages: List<TokenUsage>,
    dailyPoints: Map<String, Double>,
    scope: PulseTimelineScope,
    displayMode: UsageDisplayMode,
    nowMillis: Long,
    accent: Color,
    modifier: Modifier = Modifier
) {
    val isDark = isSystemInDarkTheme()
    val domain = remember(scope, nowMillis) { domainFor(scope, nowMillis) }
    val samples = remember(usages, dailyPoints, scope, displayMode, nowMillis) {
        buildSamples(
            usages = usages,
            dailyPoints = dailyPoints,
            scope = scope,
            displayMode = displayMode,
            domain = domain,
            nowMillis = nowMillis
        )
    }

    val peak = samples.maxOfOrNull { it.cumulative } ?: 0.0
    val isEmpty = peak <= 0.0001

    val pulseTransition = rememberInfiniteTransition(label = "live-cost-pulse")
    val pulse by pulseTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1400, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse"
    )
    val sweep by pulseTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(4200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "sweep"
    )

    Box(modifier = modifier
        .fillMaxWidth()
        .height(120.dp)
        .padding(top = 4.dp)
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height
            val axisH = 14.dp.toPx()
            val plotH = h - axisH
            val yMax = max(peak * 1.08, 0.0001)

            // Soft baseline tint
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(accent.copy(alpha = 0.04f), Color.Transparent),
                    startY = 0f,
                    endY = plotH
                ),
                size = Size(w, plotH)
            )

            // Zero rule
            drawLine(
                color = AuroraColors.lightTextMuted.copy(alpha = 0.10f),
                start = Offset(0f, plotH - 0.5f),
                end = Offset(w, plotH - 0.5f),
                strokeWidth = 0.5.dp.toPx()
            )

            if (isEmpty) {
                // Dashed rail + sweeping highlight blob
                val railY = plotH * 0.78f
                drawLine(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            accent.copy(alpha = 0.25f),
                            AuroraColors.amber.copy(alpha = 0.55f),
                            accent.copy(alpha = 0.25f)
                        ),
                        start = Offset(0f, railY),
                        end = Offset(w, railY)
                    ),
                    start = Offset(0f, railY),
                    end = Offset(w, railY),
                    strokeWidth = 1.5.dp.toPx(),
                    cap = StrokeCap.Round,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 12f))
                )

                // Sweeping shimmer
                val blobWidth = w * 0.30f
                val sweepOffset = (w + blobWidth) * sweep - blobWidth * 0.5f
                drawRect(
                    brush = Brush.horizontalGradient(
                        colors = listOf(
                            Color.Transparent,
                            accent.copy(alpha = 0.42f),
                            Color.Transparent
                        ),
                        startX = sweepOffset,
                        endX = sweepOffset + blobWidth
                    ),
                    topLeft = Offset(sweepOffset, railY - 14.dp.toPx()),
                    size = Size(blobWidth, 28.dp.toPx())
                )
            } else if (samples.size >= 2) {
                val xFor: (Long) -> Float = { t ->
                    val span = (domain.second - domain.first).coerceAtLeast(1L)
                    ((t - domain.first).toDouble() / span * w).toFloat()
                }
                val yFor: (Double) -> Float = { v ->
                    val frac = (v / yMax).coerceIn(0.0, 1.0)
                    (plotH - frac * plotH).toFloat()
                }

                // Build smoothed line path via monotone tangents (Catmull-Rom-ish).
                val points = samples.map { Offset(xFor(it.timeMillis), yFor(it.cumulative)) }
                val linePath = monotonePath(points)
                val areaPath = Path().apply {
                    addPath(linePath)
                    lineTo(points.last().x, plotH)
                    lineTo(points.first().x, plotH)
                    close()
                }

                // Area fill
                drawPath(
                    path = areaPath,
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            accent.copy(alpha = if (isDark) 0.55f else 0.42f),
                            AuroraColors.amber.copy(alpha = if (isDark) 0.30f else 0.20f),
                            AuroraColors.blaze.copy(alpha = 0f)
                        ),
                        startY = 0f,
                        endY = plotH
                    )
                )

                // Glow under the line
                drawPath(
                    path = linePath,
                    color = accent.copy(alpha = 0.35f),
                    style = Stroke(width = 6.dp.toPx(), cap = StrokeCap.Round)
                )

                // Brand-gradient stroke
                drawPath(
                    path = linePath,
                    brush = Brush.horizontalGradient(
                        colors = listOf(
                            AuroraColors.amber,
                            accent,
                            AuroraColors.ember
                        )
                    ),
                    style = Stroke(width = 2.4.dp.toPx(), cap = StrokeCap.Round)
                )

                // Now dot at trailing edge
                val last = points.last()
                val haloR = (14f + 6f * pulse).dp.toPx()
                drawCircle(
                    color = accent.copy(alpha = 0.18f * (1f - 0.5f * pulse)),
                    radius = haloR,
                    center = last
                )
                drawCircle(
                    color = accent.copy(alpha = 0.30f),
                    radius = 7.dp.toPx(),
                    center = last
                )
                drawCircle(
                    color = accent,
                    radius = 4.dp.toPx(),
                    center = last
                )
            }
        }

        // Time-axis tick labels overlay (drawn with normal text composables for
        // crisp rendering across densities).
        TimeAxisLabels(
            domainStartMillis = domain.first,
            domainEndMillis = domain.second,
            scope = scope,
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomStart)
        )

        // Empty caption overlay (centered) when zero peak.
        if (isEmpty) {
            Surface(
                modifier = Modifier.align(Alignment.Center),
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.65f),
                border = androidx.compose.foundation.BorderStroke(
                    0.5.dp,
                    accent.copy(alpha = 0.4f)
                )
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.Timeline,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(11.dp)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = emptyMessage(scope),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = 0.6.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun TimeAxisLabels(
    domainStartMillis: Long,
    domainEndMillis: Long,
    scope: PulseTimelineScope,
    modifier: Modifier
) {
    val formatPattern = when (scope) {
        PulseTimelineScope.MINUTE -> "mm:ss"
        PulseTimelineScope.HOUR -> "h:mm a"
        PulseTimelineScope.DAY -> "ha"
        PulseTimelineScope.WEEK, PulseTimelineScope.MONTH -> "M/d"
    }
    val formatter = remember(formatPattern) { SimpleDateFormat(formatPattern, Locale.getDefault()) }
    val labels = remember(domainStartMillis, domainEndMillis, formatPattern) {
        val ticks = 4
        val span = (domainEndMillis - domainStartMillis).coerceAtLeast(1L)
        (0 until ticks).map { idx ->
            val t = domainStartMillis + (span * idx) / (ticks - 1)
            formatter.format(t).lowercase(Locale.getDefault())
        }
    }
    Row(modifier = modifier) {
        labels.forEach { label ->
            Text(
                text = label,
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                modifier = Modifier.weight(1f)
            )
        }
    }
}

// ── Bucketing & domain helpers ──

private data class CostSample(val timeMillis: Long, val cumulative: Double)

private fun domainFor(scope: PulseTimelineScope, nowMillis: Long): Pair<Long, Long> = when (scope) {
    PulseTimelineScope.MINUTE -> (nowMillis - 60_000L) to nowMillis
    PulseTimelineScope.HOUR   -> (nowMillis - 3_600_000L) to nowMillis
    PulseTimelineScope.DAY -> {
        val start = startOfLocalPulseDayMillis(nowMillis)
        val end = start + 86_400_000L
        start to end
    }
    PulseTimelineScope.WEEK -> {
        val start = startOfLocalPulseDayMillis(nowMillis) - 6L * 86_400_000L
        start to nowMillis
    }
    PulseTimelineScope.MONTH -> {
        val start = startOfLocalPulseDayMillis(nowMillis) - 29L * 86_400_000L
        start to nowMillis
    }
}

private fun buildSamples(
    usages: List<TokenUsage>,
    dailyPoints: Map<String, Double>,
    scope: PulseTimelineScope,
    displayMode: UsageDisplayMode,
    domain: Pair<Long, Long>,
    nowMillis: Long
): List<CostSample> {
    return when (scope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR,
        PulseTimelineScope.DAY -> buildLiveSamples(usages, scope, domain, displayMode, nowMillis)
        PulseTimelineScope.WEEK,
        PulseTimelineScope.MONTH -> buildAggregateSamples(dailyPoints, domain)
    }
}

private fun buildLiveSamples(
    usages: List<TokenUsage>,
    scope: PulseTimelineScope,
    domain: Pair<Long, Long>,
    displayMode: UsageDisplayMode,
    nowMillis: Long
): List<CostSample> {
    val (lower, _) = domain
    val upper = nowMillis  // clamp right edge to "now" so curve stops at present
    if (upper <= lower) return emptyList()

    val bucketCount = when (scope) {
        PulseTimelineScope.MINUTE -> 24    // ~2.5s each
        PulseTimelineScope.HOUR -> 30      // 2 min each
        PulseTimelineScope.DAY -> 24       // hourly
        else -> 24
    }
    val span = upper - lower
    val stride = span / bucketCount.toLong()
    if (stride <= 0L) return emptyList()

    val relevant = usages
        .asSequence()
        .filter { it.startTime in lower..upper }
        .sortedBy { it.startTime }
        .toList()

    val out = ArrayList<CostSample>(bucketCount + 1)
    out += CostSample(timeMillis = lower, cumulative = 0.0)
    var cumulative = 0.0
    var cursor = 0
    for (i in 1..bucketCount) {
        val edge = lower + i * stride
        while (cursor < relevant.size && relevant[cursor].startTime <= edge) {
            val event = relevant[cursor]
            cumulative += when (displayMode) {
                UsageDisplayMode.CURRENCY -> max(0.0, event.effectiveCost)
                UsageDisplayMode.TOKENS -> max(0, event.totalTokens).toDouble()
            }
            cursor++
        }
        out += CostSample(timeMillis = edge, cumulative = cumulative)
    }
    return out
}

private fun buildAggregateSamples(
    dailyPoints: Map<String, Double>,
    domain: Pair<Long, Long>
): List<CostSample> {
    // dailyPoints keys are typically ISO date strings (YYYY-MM-DD). We parse and
    // sort, then accumulate a running sum.
    val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    val sorted = dailyPoints.entries
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

private fun emptyMessage(scope: PulseTimelineScope): String = when (scope) {
    PulseTimelineScope.MINUTE -> "AWAITING THIS MINUTE'S BURN"
    PulseTimelineScope.HOUR   -> "AWAITING THIS HOUR'S BURN"
    PulseTimelineScope.DAY    -> "AWAITING TODAY'S FIRST BURN"
    PulseTimelineScope.WEEK   -> "NO DATA THIS WEEK YET"
    PulseTimelineScope.MONTH  -> "NO DATA THIS MONTH YET"
}

// ── Monotone cubic path ──
//
// Catmull-Rom with monotone-cubic tangents — keeps the cumulative curve from
// "overshooting" between buckets. Falls back to a straight line for <3 points.

private fun monotonePath(points: List<Offset>): Path {
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

// ── Burn-rate helpers ──

object PulseBurnRate {
    fun dollarsPerMinute(usages: List<TokenUsage>, nowMillis: Long): Double? {
        val windowStart = nowMillis - 5L * 60_000L
        val cost = usages
            .filter { it.startTime in windowStart..nowMillis }
            .sumOf { max(0.0, it.effectiveCost) }
        return if (cost > 0.0) cost / 5.0 else null
    }

    fun tokensPerMinute(usages: List<TokenUsage>, nowMillis: Long): Int? {
        val windowStart = nowMillis - 5L * 60_000L
        val tokens = usages
            .filter { it.startTime in windowStart..nowMillis }
            .sumOf { max(0, it.totalTokens) }
        return if (tokens > 0) tokens / 5 else null
    }
}

