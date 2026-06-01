@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

internal fun buildAuroraSparklinePoints(
    data: List<Float>,
    width: Float,
    height: Float,
    progress: Float,
): List<Offset> {
    val minVal = data.minOrNull() ?: 0f
    val maxVal = data.maxOrNull() ?: 1f
    val range = (maxVal - minVal).coerceAtLeast(0.001f)
    val stepX = width / (data.size - 1).coerceAtLeast(1)
    return data.mapIndexed { index, value ->
        val nx = index * stepX
        val ny = height - (value - minVal) / range * height * progress
        Offset(nx, ny)
    }
}

internal fun buildCatmullRomPath(points: List<Offset>): Path =
    Path().apply {
        moveTo(points.first().x, points.first().y)
        for (index in 0 until points.size - 1) {
            val p0 = points.getOrNull(index - 1) ?: points[index]
            val p1 = points[index]
            val p2 = points[index + 1]
            val p3 = points.getOrNull(index + 2) ?: points[index + 1]
            val cp1 = Offset(p1.x + (p2.x - p0.x) / 6f, p1.y + (p2.y - p0.y) / 6f)
            val cp2 = Offset(p2.x - (p3.x - p1.x) / 6f, p2.y - (p3.y - p1.y) / 6f)
            cubicTo(cp1.x, cp1.y, cp2.x, cp2.y, p2.x, p2.y)
        }
    }

internal fun DrawScope.drawAuroraSparklineFill(
    path: Path,
    fillColor: Color,
    width: Float,
    height: Float,
) {
    val fillPath =
        Path().apply {
            addPath(path)
            lineTo(width, height)
            lineTo(0f, height)
            close()
        }
    drawPath(path = fillPath, color = fillColor)
}

internal fun DrawScope.drawAuroraSparklineStroke(path: Path, strokeColor: Color, strokeWidth: Float) {
    drawPath(
        path = path,
        color = strokeColor,
        style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round),
    )
}

internal fun DrawScope.drawAuroraSparklineTip(tip: Offset, strokeColor: Color, pointColor: Color?, strokeWidth: Float) {
    drawCircle(color = pointColor ?: strokeColor, radius = strokeWidth * 1.6f, center = tip)
    drawCircle(color = Color.White, radius = strokeWidth * 0.6f, center = tip)
}
