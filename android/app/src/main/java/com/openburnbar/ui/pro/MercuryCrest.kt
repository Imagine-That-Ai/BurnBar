package com.openburnbar.ui.pro

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.invisibleToUser
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — concentric mercury foil medallion. Replaces ProBadgeDot
 * once a user is a Cloud member. Mirrors the iOS MercuryCrest.
 */
@Composable
fun MercuryCrest(
    size: MercuryCrestSize = MercuryCrestSize.Small,
    shimmer: Boolean = true,
    modifier: Modifier = Modifier
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val diameter: Dp = when (size) {
        MercuryCrestSize.Small -> ProLayout.crestSmallDp.dp
        MercuryCrestSize.Medium -> ProLayout.crestMediumDp.dp
        MercuryCrestSize.Large -> ProLayout.crestLargeDp.dp
    }
    val ringWidth: Dp = when (size) {
        MercuryCrestSize.Small -> 1.0.dp
        MercuryCrestSize.Medium -> 1.4.dp
        MercuryCrestSize.Large -> 1.8.dp
    }

    val shimmerPhase = if (shimmer && !reduceMotion) {
        rememberInfiniteTransition(label = "crestShimmer").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                repeatMode = RepeatMode.Restart
            ),
            label = "crestShimmerPhase"
        ).value
    } else 0f

    Canvas(
        modifier = modifier
            .size(diameter)
            .semantics(mergeDescendants = true) { invisibleToUser() }
    ) {
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        val radius = this.size.minDimension / 2f
        val foilStroke = ringWidth.toPx()

        drawCircle(color = ProPalette.obsidian, radius = radius, center = center)
        drawCircle(
            brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
            radius = radius - foilStroke / 2f,
            center = center,
            style = Stroke(width = foilStroke)
        )

        val innerRadius = radius * 0.62f
        drawCircle(
            brush = Brush.linearGradient(
                colors = listOf(ProPalette.mercury, ProPalette.aureate),
                start = Offset(0f, 0f),
                end = Offset(this.size.width, this.size.height)
            ),
            radius = innerRadius,
            center = center,
            style = Stroke(width = foilStroke * 0.55f)
        )

        // Ember dot center
        drawCircle(
            color = ProPalette.emberPop,
            radius = radius * 0.18f,
            center = center
        )

        // Shimmer overlay sweep
        if (shimmer && !reduceMotion) {
            val bandWidth = this.size.width * 0.45f
            val offsetX = shimmerPhase * (this.size.width + bandWidth) - bandWidth
            drawRect(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.Transparent,
                        Color.White.copy(alpha = 0.22f),
                        Color.Transparent
                    )
                ),
                topLeft = Offset(offsetX, 0f),
                size = Size(bandWidth, this.size.height),
                blendMode = BlendMode.Plus,
                alpha = 0.6f
            )
        }
    }
}

enum class MercuryCrestSize {
    Small,
    Medium,
    Large
}
