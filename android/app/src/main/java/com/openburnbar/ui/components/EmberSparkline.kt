package com.openburnbar.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors

/**
 * Simple line sparkline composable.
 * Draws a connected line through data points with an optional area fill beneath.
 */

@Composable
fun EmberSparkline(
    data: List<Float>,
    modifier: Modifier = Modifier,
    strokeColor: Color = AuroraColors.ember,
    fillColor: Color = AuroraColors.ember.copy(alpha = 0.15f),
    strokeWidth: Float = 2.5f,
    showFill: Boolean = true,
    animate: Boolean = true
) {
    if (data.size < 2) return

    val animProgress by animateFloatAsState(
        targetValue = 1f,
        animationSpec = if (animate) tween(800, easing = EaseOutCubic) else snap(),
        label = "sparkline"
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val minVal = data.minOrNull() ?: 0f
        val maxVal = data.maxOrNull() ?: 1f
        val range = (maxVal - minVal).coerceAtLeast(0.001f)
        val count = data.size
        val stepX = w / (count - 1).coerceAtLeast(1)

        fun yFor(value: Float): Float {
            val normalized = (value - minVal) / range
            return h - (normalized * h * animProgress)
        }

        val path = Path().apply {
            moveTo(0f, yFor(data.first()))
            for (i in 1 until count) {
                val x = i * stepX
                val y = yFor(data[i])
                lineTo(x, y)
            }
        }

        if (showFill && animProgress > 0.01f) {
            val fillPath = Path().apply {
                addPath(path)
                lineTo(w, h)
                lineTo(0f, h)
                close()
            }
            drawPath(path = fillPath, color = fillColor)
        }

        drawPath(
            path = path,
            color = strokeColor,
            style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
    }
}
