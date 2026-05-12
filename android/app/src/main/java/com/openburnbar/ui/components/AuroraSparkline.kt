package com.openburnbar.ui.components

import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import com.openburnbar.ui.theme.AuroraColors

/**
 * Catmull-Rom interpolated sparkline matching iOS `MiniSparkline.swift` visual
 * behaviour. Catmull-Rom is converted to cubic Bezier control points so the
 * resulting Path renders smoothly at any density.
 *
 * Pass animate=false for static cards (compose previews, snapshots) where the
 * sweep would otherwise re-fire on every recomposition.
 */
@Composable
fun AuroraSparkline(
    data: List<Float>,
    modifier: Modifier = Modifier,
    strokeColor: Color = AuroraColors.ember,
    fillColor: Color = AuroraColors.ember.copy(alpha = 0.15f),
    pointColor: Color? = null,
    strokeWidth: Float = 2.5f,
    showFill: Boolean = true,
    animate: Boolean = true,
    showLatestPoint: Boolean = true
) {
    if (data.size < 2) return

    val progress by animateFloatAsState(
        targetValue = 1f,
        animationSpec = if (animate) tween(800, easing = EaseOutCubic) else snap(),
        label = "aurora-sparkline"
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val minVal = data.minOrNull() ?: 0f
        val maxVal = data.maxOrNull() ?: 1f
        val range = (maxVal - minVal).coerceAtLeast(0.001f)
        val count = data.size
        val stepX = w / (count - 1).coerceAtLeast(1)

        val pts = data.mapIndexed { i, value ->
            val nx = i * stepX
            val ny = h - ((value - minVal) / range) * h * progress
            Offset(nx, ny)
        }

        val path = Path().apply {
            moveTo(pts.first().x, pts.first().y)
            for (i in 0 until pts.size - 1) {
                val p0 = pts.getOrNull(i - 1) ?: pts[i]
                val p1 = pts[i]
                val p2 = pts[i + 1]
                val p3 = pts.getOrNull(i + 2) ?: pts[i + 1]
                // Catmull-Rom → cubic Bezier control point conversion.
                val cp1 = Offset(p1.x + (p2.x - p0.x) / 6f, p1.y + (p2.y - p0.y) / 6f)
                val cp2 = Offset(p2.x - (p3.x - p1.x) / 6f, p2.y - (p3.y - p1.y) / 6f)
                cubicTo(cp1.x, cp1.y, cp2.x, cp2.y, p2.x, p2.y)
            }
        }

        if (showFill && progress > 0.01f) {
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

        if (showLatestPoint && progress > 0.95f) {
            val tip = pts.last()
            drawCircle(
                color = pointColor ?: strokeColor,
                radius = strokeWidth * 1.6f,
                center = tip
            )
            drawCircle(
                color = Color.White,
                radius = strokeWidth * 0.6f,
                center = tip
            )
        }
    }
}
