@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors
import kotlin.math.ln

@Composable
internal fun ConstellationCanvas(sessions: List<TrendDataDigest.SessionSlice>, userAvg: Double) {
    if (sessions.isEmpty()) {
        EmptyConstellationCanvas()
        return
    }

    val maxDuration = remember(sessions) { sessions.maxOf { it.durationSec }.coerceAtLeast(1) }
    val minCost = remember(sessions) { sessions.minOf { it.costUsd }.coerceAtLeast(0.0001) }
    val maxCost = remember(sessions) { sessions.maxOf { it.costUsd }.coerceAtLeast(0.001) }

    Canvas(modifier = Modifier.fillMaxSize()) {
        val bounds = ConstellationBounds(left = 16f, right = size.width - 16f, top = 16f, bottom = size.height - 16f)
        drawConstellationGrid(bounds)
        drawConstellationGuides(bounds, userAvg)
        drawConstellationPoints(sessions, bounds, maxDuration, minCost, maxCost)
    }
}

private data class ConstellationBounds(val left: Float, val right: Float, val top: Float, val bottom: Float)

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawConstellationGrid(bounds: ConstellationBounds) {
    val gridColor = AuroraColors.lightBorder.copy(alpha = 0.12f)
    for (frac in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
        val y = bounds.bottom - (bounds.bottom - bounds.top) * frac
        drawLine(color = gridColor, start = Offset(bounds.left, y), end = Offset(bounds.right, y), strokeWidth = 0.75f)
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawConstellationGuides(bounds: ConstellationBounds, userAvg: Double) {
    val ideal = bounds.bottom - (bounds.bottom - bounds.top) * 0.75f
    drawLine(
        color = AuroraColors.success.copy(alpha = 0.5f),
        start = Offset(bounds.left, ideal),
        end = Offset(bounds.right, ideal),
        strokeWidth = 1.6f,
        pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f)),
    )
    val avgY = bounds.bottom - (bounds.bottom - bounds.top) * userAvg.toFloat().coerceIn(0f, 1f)
    drawLine(
        color = AuroraColors.amber.copy(alpha = 0.6f),
        start = Offset(bounds.left, avgY),
        end = Offset(bounds.right, avgY),
        strokeWidth = 1.4f,
        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 4f)),
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawConstellationPoints(
    sessions: List<TrendDataDigest.SessionSlice>,
    bounds: ConstellationBounds,
    maxDuration: Int,
    minCost: Double,
    maxCost: Double,
) {
    val costSpan = ln(maxCost + 1e-6) - ln(minCost + 1e-6)
    for (session in sessions) {
        val xFrac = (session.durationSec.toFloat() / maxDuration).coerceIn(0f, 1f)
        val yFrac = session.cacheHitRate.toFloat().coerceIn(0f, 1f)
        val cx = bounds.left + (bounds.right - bounds.left) * xFrac
        val cy = bounds.bottom - (bounds.bottom - bounds.top) * yFrac
        val relCost =
            if (costSpan > 0) {
                ((ln(session.costUsd + 1e-6) - ln(minCost + 1e-6)) / costSpan).toFloat()
            } else {
                0.5f
            }
        val radius = 4f + relCost * 10f
        val accent = constellationProviderColor(session.providerKey)
        drawCircle(color = accent.copy(alpha = 0.65f), radius = radius, center = Offset(cx, cy))
        drawCircle(color = Color.White.copy(alpha = 0.7f), radius = radius, center = Offset(cx, cy), style = Stroke(width = 0.75f))
    }
}

@Composable
internal fun EmptyConstellationCanvas() {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val bounds = ConstellationBounds(left = 16f, right = size.width - 16f, top = 16f, bottom = size.height - 16f)
        val ideal = bounds.bottom - (bounds.bottom - bounds.top) * 0.75f
        drawLine(
            color = AuroraColors.success.copy(alpha = 0.45f),
            start = Offset(bounds.left, ideal),
            end = Offset(bounds.right, ideal),
            strokeWidth = 1.5f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f)),
        )
    }
}

internal fun constellationProviderColor(providerKey: String): Color {
    val agent = AgentProvider.fromKey(providerKey)
    return if (agent != null) Color(agent.brandColor) else AuroraColors.ember
}
