package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Mirrors iOS `CacheConstellationScene` — scatter plot of `(durationSec,
 * cacheHitRate)` per recent session, point radius scaled by cost, with two
 * guide rules (75% ideal + user average) and a 3-stat capsule footer
 * (hit rate, cache reads, session count).
 */
@Composable
fun CacheConstellationScene(
    digest: TrendDataDigest,
    modifier: Modifier = Modifier
) {
    val sessions = digest.recentSessions.filter { it.durationSec > 0 }
    val userAvg = digest.cache.cacheHitRate

    Column(modifier = modifier) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(200.dp)
                .clip(RoundedCornerShape(12.dp))
        ) {
            ConstellationCanvas(sessions = sessions, userAvg = userAvg)
            AxisLabels(modifier = Modifier.fillMaxSize())
        }

        Spacer(Modifier.height(10.dp))

        StatsFooter(digest = digest)
    }
}

@Composable
private fun ConstellationCanvas(
    sessions: List<TrendDataDigest.SessionSlice>,
    userAvg: Double
) {
    if (sessions.isEmpty()) {
        EmptyConstellation()
        return
    }

    val maxDuration = remember(sessions) {
        sessions.maxOf { it.durationSec }.coerceAtLeast(1)
    }
    val minCost = remember(sessions) {
        sessions.minOf { it.costUsd }.coerceAtLeast(0.0001)
    }
    val maxCost = remember(sessions) {
        sessions.maxOf { it.costUsd }.coerceAtLeast(0.001)
    }

    Canvas(modifier = Modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val left = 16f
        val right = w - 16f
        val top = 16f
        val bottom = h - 16f

        // Grid lines at 0.25 / 0.50 / 0.75 / 1.00
        val gridColor = AuroraColors.lightBorder.copy(alpha = 0.12f)
        for (frac in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
            val y = bottom - (bottom - top) * frac
            drawLine(
                color = gridColor,
                start = Offset(left, y),
                end = Offset(right, y),
                strokeWidth = 0.75f
            )
        }

        // 75% ideal guide (dashed success)
        val ideal = bottom - (bottom - top) * 0.75f
        drawLine(
            color = AuroraColors.success.copy(alpha = 0.5f),
            start = Offset(left, ideal),
            end = Offset(right, ideal),
            strokeWidth = 1.6f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f))
        )

        // User-average guide (dashed amber)
        val avgY = bottom - (bottom - top) * userAvg.toFloat().coerceIn(0f, 1f)
        drawLine(
            color = AuroraColors.amber.copy(alpha = 0.6f),
            start = Offset(left, avgY),
            end = Offset(right, avgY),
            strokeWidth = 1.4f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 4f))
        )

        // Scatter points — log-scaled radius by cost so cheap sessions stay
        // visible alongside expensive ones.
        val costSpan = ln(maxCost + 1e-6) - ln(minCost + 1e-6)
        for (s in sessions) {
            val xFrac = (s.durationSec.toFloat() / maxDuration).coerceIn(0f, 1f)
            val yFrac = s.cacheHitRate.toFloat().coerceIn(0f, 1f)
            val cx = left + (right - left) * xFrac
            val cy = bottom - (bottom - top) * yFrac
            val relCost = if (costSpan > 0) {
                ((ln(s.costUsd + 1e-6) - ln(minCost + 1e-6)) / costSpan).toFloat()
            } else 0.5f
            val radius = 4f + relCost * 10f
            val accent = providerColor(s.providerKey)

            drawCircle(
                color = accent.copy(alpha = 0.65f),
                radius = radius,
                center = Offset(cx, cy)
            )
            drawCircle(
                color = Color.White.copy(alpha = 0.7f),
                radius = radius,
                center = Offset(cx, cy),
                style = Stroke(width = 0.75f)
            )
        }
    }
}

@Composable
private fun AxisLabels(modifier: Modifier = Modifier) {
    Box(modifier = modifier) {
        Text(
            text = "100% cache hit",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = 2.dp, end = 4.dp)
        )
        Text(
            text = "0%",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(bottom = 2.dp, end = 4.dp)
        )
        Text(
            text = "longer →",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 2.dp)
        )
    }
}

@Composable
private fun EmptyConstellation() {
    Canvas(modifier = Modifier.fillMaxSize()) {
        // Empty state — still draw the guides so users see the chart frame.
        val w = size.width
        val h = size.height
        val left = 16f
        val right = w - 16f
        val top = 16f
        val bottom = h - 16f
        val ideal = bottom - (bottom - top) * 0.75f
        drawLine(
            color = AuroraColors.success.copy(alpha = 0.45f),
            start = Offset(left, ideal),
            end = Offset(right, ideal),
            strokeWidth = 1.5f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f))
        )
    }
}

@Composable
private fun StatsFooter(digest: TrendDataDigest) {
    val cacheRate = digest.cache.cacheHitRate
    val rateColor = if (cacheRate >= 0.5) AuroraColors.success else AuroraColors.warning

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        StatCapsule(
            modifier = Modifier.weight(1f),
            dotColor = rateColor,
            label = "Hit rate",
            value = "${(cacheRate * 100).toInt()}%"
        )
        StatCapsule(
            modifier = Modifier.weight(1f),
            dotColor = AuroraColors.whimsy,
            label = "Cache reads",
            value = formatTokensShort(digest.cache.totalCacheReadTokens)
        )
        StatCapsule(
            modifier = Modifier.weight(1f),
            dotColor = AuroraColors.ember,
            label = "Sessions",
            value = digest.recentSessions.size.toString()
        )
    }
}

@Composable
private fun StatCapsule(
    modifier: Modifier = Modifier,
    dotColor: Color,
    label: String,
    value: String
) {
    Surface(
        modifier = modifier,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Spacer(Modifier.width(6.dp))
            Column {
                Text(
                    text = value,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = label,
                    fontSize = 9.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private fun providerColor(providerKey: String): Color {
    val agent = AgentProvider.fromKey(providerKey)
    return if (agent != null) Color(agent.brandColor) else AuroraColors.ember
}

private fun formatTokensShort(n: Long): String = when {
    n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
    n >= 1_000     -> "%.1fK".format(n / 1_000.0)
    else           -> n.toString()
}
