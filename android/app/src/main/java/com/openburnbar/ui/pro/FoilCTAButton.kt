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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — primary action button. Obsidian fill, foil border,
 * continuous mercury shimmer behind the surface. Mirrors iOS FoilCTAButton.
 */
@Composable
fun FoilCTAButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    icon: ImageVector = Icons.Filled.AutoAwesome,
    isLoading: Boolean = false,
    fillWidth: Boolean = true,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val shape = RoundedCornerShape(ProLayout.bandRadiusDp.dp)
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(targetValue = if (pressed) 0.98f else 1.0f, label = "ctaScale")

    val shimmerPhase =
        if (!reduceMotion) {
            rememberInfiniteTransition(label = "ctaShimmer").animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec =
                infiniteRepeatable(
                    animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                    repeatMode = RepeatMode.Restart,
                ),
                label = "ctaShimmerPhase",
            ).value
        } else {
            0f
        }

    val widthModifier = if (fillWidth) Modifier.fillMaxWidth() else Modifier.wrapContentWidth()

    Box(
        modifier =
        modifier
            .then(widthModifier)
            .scale(scale)
            .shadow(
                elevation = 12.dp,
                shape = shape,
                ambientColor = ProPalette.aureate,
                spotColor = ProPalette.aureate,
            )
            .clip(shape)
            .background(ProPalette.obsidianElevated, shape)
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = shape,
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = !isLoading,
                onClick = onClick,
            )
            .semantics { contentDescription = subtitle?.let { "$title. $it" } ?: title },
    ) {
        if (!reduceMotion) {
            FoilCTAShimmerLayer(shimmerPhase = shimmerPhase, shape = shape)
        }
        FoilCTAButtonRow(title = title, subtitle = subtitle, icon = icon, isLoading = isLoading)
    }
}
