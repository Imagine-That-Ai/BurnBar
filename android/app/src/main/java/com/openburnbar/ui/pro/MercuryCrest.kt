@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

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
fun MercuryCrest(size: MercuryCrestSize = MercuryCrestSize.Small, shimmer: Boolean = true, modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val diameter: Dp =
        when (size) {
            MercuryCrestSize.Small -> ProLayout.crestSmallDp.dp
            MercuryCrestSize.Medium -> ProLayout.crestMediumDp.dp
            MercuryCrestSize.Large -> ProLayout.crestLargeDp.dp
        }
    val ringWidth: Dp =
        when (size) {
            MercuryCrestSize.Small -> 1.0.dp
            MercuryCrestSize.Medium -> 1.4.dp
            MercuryCrestSize.Large -> 1.8.dp
        }

    val shimmerPhase =
        if (shimmer && !reduceMotion) {
            rememberInfiniteTransition(label = "crestShimmer").animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec =
                infiniteRepeatable(
                    animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                    repeatMode = RepeatMode.Restart,
                ),
                label = "crestShimmerPhase",
            ).value
        } else {
            0f
        }

    Canvas(
        modifier =
        modifier
            .size(diameter)
            .semantics(mergeDescendants = true) { invisibleToUser() },
    ) {
        drawMercuryCrestRings(ringWidth)
        if (shimmer && !reduceMotion) {
            drawMercuryCrestShimmer(shimmerPhase)
        }
    }
}

enum class MercuryCrestSize {
    Small,
    Medium,
    Large,
}
