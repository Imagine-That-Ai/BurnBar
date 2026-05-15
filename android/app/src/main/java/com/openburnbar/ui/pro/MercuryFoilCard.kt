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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — obsidian card with foil edge + continuous mercury shimmer
 * + one-shot specular sweep on first composition. Mirrors the iOS variant.
 *
 * Wrap content with this composable when you want a Pro surface: plan tiles,
 * capability cards, inline poster moments.
 */
@Composable
fun MercuryFoilCard(
    modifier: Modifier = Modifier,
    cornerRadiusDp: Dp = ProLayout.cardRadiusDp.dp,
    tone: MercuryFoilTone = MercuryFoilTone.Obsidian,
    enableSpecular: Boolean = true,
    enableShimmer: Boolean = true,
    content: @Composable () -> Unit
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val shape = RoundedCornerShape(cornerRadiusDp)

    // Continuous mercury shimmer phase
    val shimmer = if (enableShimmer && !reduceMotion) {
        val transition = rememberInfiniteTransition(label = "mercuryFoilShimmer")
        transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                repeatMode = RepeatMode.Restart
            ),
            label = "mercuryFoilShimmerPhase"
        ).value
    } else 0f

    // One-shot specular sweep on first composition
    var specularPhase by remember { mutableFloatStateOf(-1.4f) }
    LaunchedEffect(enableSpecular, reduceMotion) {
        if (enableSpecular && !reduceMotion) {
            kotlinx.coroutines.delay(150)
            // animateTo would suffice but we use Animatable for control
            val anim = androidx.compose.animation.core.Animatable(-1.4f)
            anim.animateTo(
                targetValue = 1.4f,
                animationSpec = tween(ProMotion.specularDurationMs, easing = LinearEasing)
            )
        }
    }
    val specularAnimated by animateFloatAsState(
        targetValue = if (enableSpecular && !reduceMotion) 1.4f else -1.4f,
        animationSpec = tween(ProMotion.specularDurationMs, delayMillis = 150, easing = LinearEasing),
        label = "specularSweep"
    )

    val backgroundColor = when (tone) {
        MercuryFoilTone.Obsidian -> ProPalette.obsidian
        MercuryFoilTone.ObsidianElevated -> ProPalette.obsidianElevated
    }

    Box(
        modifier = modifier
            .clip(shape)
            .background(backgroundColor, shape)
            .drawWithCache {
                val cornerPx = cornerRadiusDp.toPx()
                onDrawWithContent {
                    drawContent()

                    // Top-left aureate halo for depth
                    drawRect(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                ProPalette.aureate.copy(alpha = 0.12f),
                                Color.Transparent
                            ),
                            center = Offset(0f, 0f),
                            radius = size.minDimension * 1.2f
                        ),
                        blendMode = BlendMode.Plus
                    )

                    // Continuous mercury shimmer band
                    if (enableShimmer && !reduceMotion) {
                        val bandWidth = size.width * 0.55f
                        val offsetX = shimmer * (size.width + bandWidth) - bandWidth
                        translate(left = offsetX) {
                            drawRect(
                                brush = Brush.linearGradient(
                                    colors = listOf(
                                        Color.Transparent,
                                        ProPalette.mercury.copy(alpha = 0.20f),
                                        Color.White.copy(alpha = 0.20f),
                                        ProPalette.mercury.copy(alpha = 0.20f),
                                        Color.Transparent
                                    )
                                ),
                                topLeft = Offset.Zero,
                                size = Size(bandWidth, size.height),
                                blendMode = BlendMode.Plus,
                                alpha = 0.55f
                            )
                        }
                    }

                    // One-shot specular sweep
                    if (enableSpecular && !reduceMotion) {
                        val bandWidth = size.width * 0.5f
                        val offsetX = specularAnimated * size.width
                        translate(left = offsetX) {
                            drawRect(
                                brush = Brush.linearGradient(
                                    colors = listOf(
                                        Color.Transparent,
                                        ProPalette.aureate.copy(alpha = 0.22f),
                                        Color.White.copy(alpha = 0.24f),
                                        ProPalette.aureate.copy(alpha = 0.22f),
                                        Color.Transparent
                                    )
                                ),
                                topLeft = Offset.Zero,
                                size = Size(bandWidth, size.height),
                                blendMode = BlendMode.Plus
                            )
                        }
                    }
                }
            }
            .border(
                width = ProLayout.foilStrokeDp.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = shape
            )
    ) {
        content()
    }
}

enum class MercuryFoilTone {
    Obsidian,
    ObsidianElevated
}
