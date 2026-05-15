package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Pro vocabulary — the cinematic stage. Obsidian base + descending darkened
 * aurora ribbon + soft upper-center halo + film grain. Mirrors iOS poster.
 */
@Composable
fun ProPosterScaffold(
    modifier: Modifier = Modifier,
    includeGrain: Boolean = true,
    includeRibbon: Boolean = true,
    content: @Composable () -> Unit
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(ProPalette.obsidian)
            .drawWithCache {
                val ribbonHeight = 360f
                val haloRadius = 320f
                onDrawWithContent {
                    if (includeRibbon) {
                        drawRect(
                            brush = Brush.verticalGradient(
                                colors = ProPalette.darkAuroraRibbonStops,
                                startY = 0f,
                                endY = ribbonHeight
                            ),
                            topLeft = Offset(0f, 0f),
                            size = Size(size.width, ribbonHeight),
                            blendMode = BlendMode.Plus
                        )
                    }

                    // Soft upper-center halo
                    drawRect(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                ProPalette.aureate.copy(alpha = 0.14f),
                                Color.Transparent
                            ),
                            center = Offset(size.width * 0.5f, size.height * 0.18f),
                            radius = haloRadius
                        ),
                        blendMode = BlendMode.Plus
                    )

                    drawContent()

                    // Film grain
                    if (includeGrain) {
                        val density = 0.16f
                        val count = (size.width * size.height * density / 600f).toInt()
                        var seed = 0xC0FFEEBEEFL
                        repeat(count) {
                            seed = seed * 6364136223846793005L + 1442695040888963407L
                            val x = ((seed ushr 16) and 0xFFFF).toFloat() / 0xFFFF * size.width
                            seed = seed * 6364136223846793005L + 1442695040888963407L
                            val y = ((seed ushr 16) and 0xFFFF).toFloat() / 0xFFFF * size.height
                            seed = seed * 6364136223846793005L + 1442695040888963407L
                            val a = 0.06f + ((seed ushr 16) and 0xFFF).toFloat() / 0xFFF * 0.18f
                            drawRect(
                                color = Color.White.copy(alpha = a * 0.4f),
                                topLeft = Offset(x, y),
                                size = Size(1f, 1f),
                                blendMode = BlendMode.Overlay
                            )
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        content()
    }
}
