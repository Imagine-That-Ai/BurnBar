@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate

internal fun DrawScope.drawMercuryFoilHalo() {
    drawRect(
        brush =
        Brush.radialGradient(
            colors =
            listOf(
                ProPalette.aureate.copy(alpha = 0.12f),
                Color.Transparent,
            ),
            center = Offset(0f, 0f),
            radius = size.minDimension * 1.2f,
        ),
        blendMode = BlendMode.Plus,
    )
}

internal fun DrawScope.drawMercuryFoilShimmer(shimmer: Float) {
    val bandWidth = size.width * 0.55f
    val offsetX = shimmer * (size.width + bandWidth) - bandWidth
    translate(left = offsetX) {
        drawRect(
            brush =
            Brush.linearGradient(
                colors =
                listOf(
                    Color.Transparent,
                    ProPalette.mercury.copy(alpha = 0.20f),
                    Color.White.copy(alpha = 0.20f),
                    ProPalette.mercury.copy(alpha = 0.20f),
                    Color.Transparent,
                ),
            ),
            topLeft = Offset.Zero,
            size = Size(bandWidth, size.height),
            blendMode = BlendMode.Plus,
            alpha = 0.55f,
        )
    }
}

internal fun DrawScope.drawMercuryFoilSpecular(specularAnimated: Float) {
    val bandWidth = size.width * 0.5f
    val offsetX = specularAnimated * size.width
    translate(left = offsetX) {
        drawRect(
            brush =
            Brush.linearGradient(
                colors =
                listOf(
                    Color.Transparent,
                    ProPalette.aureate.copy(alpha = 0.22f),
                    Color.White.copy(alpha = 0.24f),
                    ProPalette.aureate.copy(alpha = 0.22f),
                    Color.Transparent,
                ),
            ),
            topLeft = Offset.Zero,
            size = Size(bandWidth, size.height),
            blendMode = BlendMode.Plus,
        )
    }
}
