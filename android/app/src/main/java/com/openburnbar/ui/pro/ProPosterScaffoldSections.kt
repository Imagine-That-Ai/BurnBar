// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope

internal fun DrawScope.drawProPosterRibbon(ribbonHeight: Float) {
    drawRect(
        brush =
        Brush.verticalGradient(
            colors = ProPalette.darkAuroraRibbonStops,
            startY = 0f,
            endY = ribbonHeight,
        ),
        topLeft = Offset.Zero,
        size = Size(size.width, ribbonHeight),
        blendMode = BlendMode.Plus,
    )
}

internal fun DrawScope.drawProPosterHalo(haloRadius: Float) {
    drawRect(
        brush =
        Brush.radialGradient(
            colors =
            listOf(
                ProPalette.aureate.copy(alpha = 0.14f),
                Color.Transparent,
            ),
            center = Offset(size.width * 0.5f, size.height * 0.18f),
            radius = haloRadius,
        ),
        blendMode = BlendMode.Plus,
    )
}

internal fun DrawScope.drawProPosterGrain() {
    val density = 0.16f
    val count = (size.width * size.height * density / 600f).toInt()
    var seed = 0xC0FFEEBEEFL
    repeat(count) {
        seed = seed * 6364136223846793005L + 1442695040888963407L
        val x = (seed ushr 16 and 0xFFFF).toFloat() / 0xFFFF * size.width
        seed = seed * 6364136223846793005L + 1442695040888963407L
        val y = (seed ushr 16 and 0xFFFF).toFloat() / 0xFFFF * size.height
        seed = seed * 6364136223846793005L + 1442695040888963407L
        val a = 0.06f + (seed ushr 16 and 0xFFF).toFloat() / 0xFFF * 0.18f
        drawRect(
            color = Color.White.copy(alpha = a * 0.4f),
            topLeft = Offset(x, y),
            size = Size(1f, 1f),
            blendMode = BlendMode.Overlay,
        )
    }
}
