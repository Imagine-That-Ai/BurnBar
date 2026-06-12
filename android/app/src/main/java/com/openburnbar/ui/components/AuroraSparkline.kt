// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

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
import androidx.compose.ui.graphics.Color
import com.openburnbar.ui.theme.AuroraColors

/**
 * Catmull-Rom interpolated sparkline matching iOS `MiniSparkline.swift` visual
 * behaviour. Catmull-Rom is converted to cubic Bezier control points so the
 * resulting Path renders smoothly at any density.
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
    showLatestPoint: Boolean = true,
) {
    if (data.size < 2) return

    val progress by animateFloatAsState(
        targetValue = 1f,
        animationSpec = if (animate) tween(800, easing = EaseOutCubic) else snap(),
        label = "aurora-sparkline",
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        val points = buildAuroraSparklinePoints(data, size.width, size.height, progress)
        val path = buildCatmullRomPath(points)
        if (showFill && progress > 0.01f) {
            drawAuroraSparklineFill(path, fillColor, size.width, size.height)
        }
        drawAuroraSparklineStroke(path, strokeColor, strokeWidth)
        if (showLatestPoint && progress > 0.95f) {
            drawAuroraSparklineTip(points.last(), strokeColor, pointColor, strokeWidth)
        }
    }
}
