// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp

internal fun DrawScope.drawMercuryCrestRings(ringWidth: Dp) {
    val center = Offset(this.size.width / 2f, this.size.height / 2f)
    val radius = this.size.minDimension / 2f
    val foilStroke = ringWidth.toPx()

    drawCircle(color = ProPalette.obsidian, radius = radius, center = center)
    drawCircle(
        brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
        radius = radius - foilStroke / 2f,
        center = center,
        style = Stroke(width = foilStroke),
    )

    val innerRadius = radius * 0.62f
    drawCircle(
        brush =
        Brush.linearGradient(
            colors = listOf(ProPalette.mercury, ProPalette.aureate),
            start = Offset(0f, 0f),
            end = Offset(this.size.width, this.size.height),
        ),
        radius = innerRadius,
        center = center,
        style = Stroke(width = foilStroke * 0.55f),
    )

    drawCircle(
        color = ProPalette.emberPop,
        radius = radius * 0.18f,
        center = center,
    )
}

internal fun DrawScope.drawMercuryCrestShimmer(shimmerPhase: Float) {
    val bandWidth = this.size.width * 0.45f
    val offsetX = shimmerPhase * (this.size.width + bandWidth) - bandWidth
    drawRect(
        brush =
        Brush.linearGradient(
            colors =
            listOf(
                Color.Transparent,
                Color.White.copy(alpha = 0.22f),
                Color.Transparent,
            ),
        ),
        topLeft = Offset(offsetX, 0f),
        size = Size(bandWidth, this.size.height),
        blendMode = BlendMode.Plus,
        alpha = 0.6f,
    )
}
