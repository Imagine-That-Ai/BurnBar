// Holographic gradient stops (hex color literals); token-per-line obscures the palette; shared-palette file deliberately named for the feature, not the first enum.

package com.openburnbar.ui.pro

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * The per-tier iridescent holo palette — a tasteful, low-opacity ghost of the
 * marketing site's `--holo-grad`. Mirrors `TierHolo` in the Cloud store sections
 * exactly so the gating crests match the plan cards:
 *   Cloud — warm ember (gold → orange → pink → violet)
 *   Cloud Pro — cool aqua (mint → cyan → blue → green)
 *   Cloud Ultra — full-spectrum premium (gold → sky → purple → teal → pink)
 */
enum class TierHoloPalette(val colors: List<Color>) {
    CLOUD(
        listOf(
            Color(0xFFFFD56B),
            Color(0xFFFF8A3D),
            Color(0xFFFF5C8A),
            Color(0xFFB06BFF),
        ),
    ),
    PRO(
        listOf(
            Color(0xFF5EF0C9),
            Color(0xFF38D6F3),
            Color(0xFF4F8BFF),
            Color(0xFF8EF0A8),
        ),
    ),
    ULTRA(
        listOf(
            Color(0xFFFFD56B),
            Color(0xFF7DD3FC),
            Color(0xFFC084FC),
            Color(0xFF5EEAD4),
            Color(0xFFFF9EC7),
        ),
    ),
}

/**
 * A soft, slowly-sweeping iridescent aura in the tier's palette. Reused from the
 * Cloud store's `TierHoloAura`; gated on reduce-motion (static when reduced).
 * Fills its parent — place inside a clipped, sized box.
 */
@Composable
fun BoxScope.TierHoloAura(palette: TierHoloPalette, shape: RoundedCornerShape, alpha: Float = 0.13f) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val sweep =
        if (reduceMotion) {
            0f
        } else {
            rememberInfiniteTransition(label = "tierHolo").animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec =
                infiniteRepeatable(
                    animation = tween(durationMillis = 9_000, easing = LinearEasing),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "tierHoloSweep",
            ).value
        }
    Box(
        modifier =
        Modifier
            .matchParentSize()
            .clip(shape)
            .background(
                brush =
                Brush.linearGradient(
                    colors = palette.colors.map { it.copy(alpha = alpha) },
                    start = Offset(sweep * 480f, 0f),
                    end = Offset(sweep * 480f + 760f, 360f),
                ),
            ),
    )
}

/**
 * The hero crest for the unlock experience: the required tier's holographic
 * crest drawable floating over a soft glow of its palette. Reuses the existing
 * per-tier crest assets + holo gradients (no parallel design system).
 */
@Composable
fun HolographicCrestHero(tier: CloudTier, modifier: Modifier = Modifier, size: Dp = 96.dp) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val pulse =
        if (reduceMotion) {
            0.5f
        } else {
            rememberInfiniteTransition(label = "crestHeroGlow").animateFloat(
                initialValue = 0.32f,
                targetValue = 0.5f,
                animationSpec =
                infiniteRepeatable(
                    animation = tween(durationMillis = ProMotion.breathingDurationMs, easing = LinearEasing),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "crestHeroGlowPulse",
            ).value
        }
    Box(modifier = modifier.size(size * 1.7f), contentAlignment = Alignment.Center) {
        // Soft glow halo behind the crest.
        Box(
            modifier =
            Modifier
                .size(size * 1.7f)
                .blur(28.dp)
                .clip(CircleShape)
                .background(
                    brush =
                    Brush.radialGradient(
                        colors =
                        tier.holo.colors.map { it.copy(alpha = pulse * 0.55f) } + Color.Transparent,
                    ),
                ),
        )
        Box(
            modifier =
            Modifier
                .size(size)
                .clip(CircleShape)
                .border(0.9.dp, Color.White.copy(alpha = 0.16f), CircleShape)
                .padding(2.dp),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                painter = painterResource(id = tier.crestDrawable),
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}
