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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

private val FoilCTASubtitleStyle = TextStyle(
    fontFamily = FontFamily.SansSerif,
    fontWeight = FontWeight.Medium,
    fontSize = 11.sp,
    lineHeight = 15.sp
)

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
    fillWidth: Boolean = true
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val shape = RoundedCornerShape(ProLayout.bandRadiusDp.dp)
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(targetValue = if (pressed) 0.98f else 1.0f, label = "ctaScale")

    val shimmerPhase = if (!reduceMotion) {
        rememberInfiniteTransition(label = "ctaShimmer").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                repeatMode = RepeatMode.Restart
            ),
            label = "ctaShimmerPhase"
        ).value
    } else 0f

    val widthModifier = if (fillWidth) Modifier.fillMaxWidth() else Modifier.wrapContentWidth()

    Box(
        modifier = modifier
            .then(widthModifier)
            .scale(scale)
            .shadow(
                elevation = 12.dp,
                shape = shape,
                ambientColor = ProPalette.aureate,
                spotColor = ProPalette.aureate
            )
            .clip(shape)
            .background(ProPalette.obsidianElevated, shape)
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = shape
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = !isLoading,
                onClick = onClick
            )
            .semantics { contentDescription = subtitle?.let { "$title. $it" } ?: title }
    ) {
        if (!reduceMotion) {
            // Shimmer layer fills the button.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        brush = Brush.linearGradient(
                            colors = listOf(
                                Color.Transparent,
                                ProPalette.mercury.copy(alpha = 0.18f),
                                Color.White.copy(alpha = 0.16f),
                                ProPalette.mercury.copy(alpha = 0.18f),
                                Color.Transparent
                            ),
                            start = Offset(shimmerPhase * 400f, 0f),
                            end = Offset(shimmerPhase * 400f + 320f, 320f)
                        )
                    )
            )
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .padding(horizontal = 18.dp, vertical = 12.dp)
                .fillMaxWidth()
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = ProPalette.mercury,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(14.dp)
                )
            } else {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = ProPalette.aureate,
                    modifier = Modifier.size(16.dp)
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.Center) {
                Text(
                    text = title,
                    style = ProTypography.headlineSerif,
                    color = ProPalette.mercury
                )
                if (!subtitle.isNullOrEmpty()) {
                    Text(
                        text = subtitle,
                        style = FoilCTASubtitleStyle,
                        color = ProPalette.mercury.copy(alpha = 0.68f)
                    )
                }
            }
            Spacer(Modifier.weight(1f))
            if (!isLoading) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    tint = ProPalette.aureate,
                    modifier = Modifier.size(14.dp)
                )
            }
        }
    }
}
