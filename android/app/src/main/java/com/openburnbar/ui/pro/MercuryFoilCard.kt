@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — obsidian card with foil edge + continuous mercury shimmer
 * + one-shot specular sweep on first composition. Mirrors the iOS variant.
 */
@Composable
fun MercuryFoilCard(
    modifier: Modifier = Modifier,
    cornerRadiusDp: Dp = ProLayout.cardRadiusDp.dp,
    tone: MercuryFoilTone = MercuryFoilTone.Obsidian,
    enableSpecular: Boolean = true,
    enableShimmer: Boolean = true,
    content: @Composable () -> Unit,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val shape = RoundedCornerShape(cornerRadiusDp)

    val shimmer =
        if (enableShimmer && !reduceMotion) {
            rememberInfiniteTransition(label = "mercuryFoilShimmer").animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec =
                infiniteRepeatable(
                    animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                    repeatMode = RepeatMode.Restart,
                ),
                label = "mercuryFoilShimmerPhase",
            ).value
        } else {
            0f
        }

    val specularAnimated by animateFloatAsState(
        targetValue = if (enableSpecular && !reduceMotion) 1.4f else -1.4f,
        animationSpec = tween(ProMotion.specularDurationMs, delayMillis = 150, easing = LinearEasing),
        label = "specularSweep",
    )

    val backgroundColor =
        when (tone) {
            MercuryFoilTone.Obsidian -> ProPalette.obsidian
            MercuryFoilTone.ObsidianElevated -> ProPalette.obsidianElevated
        }

    Box(
        modifier =
        modifier
            .clip(shape)
            .background(backgroundColor, shape)
            .drawWithCache {
                onDrawWithContent {
                    drawContent()
                    drawMercuryFoilHalo()
                    if (enableShimmer && !reduceMotion) {
                        drawMercuryFoilShimmer(shimmer)
                    }
                    if (enableSpecular && !reduceMotion) {
                        drawMercuryFoilSpecular(specularAnimated)
                    }
                }
            }
            .border(
                width = ProLayout.foilStrokeDp.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = shape,
            ),
    ) {
        content()
    }
}

enum class MercuryFoilTone {
    Obsidian,
    ObsidianElevated,
}
