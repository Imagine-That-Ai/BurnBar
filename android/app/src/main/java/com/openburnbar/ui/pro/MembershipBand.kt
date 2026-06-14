// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — horizontal foil strip. Embedded inside free-user surfaces
 * (forecast cards, quota detail, provider wizard) for a tasteful Pro reveal.
 */
@Composable
fun MembershipBand(
    title: String,
    detail: String,
    modifier: Modifier = Modifier,
    variant: MembershipBandVariant = MembershipBandVariant.Upsell,
    icon: ImageVector = Icons.Filled.AutoAwesome,
    ctaLabel: String = "OPEN CLOUD",
    onClick: (() -> Unit)? = null,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val shimmerPhase =
        if (!reduceMotion) {
            rememberInfiniteTransition(label = "bandShimmer").animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec =
                infiniteRepeatable(
                    animation = tween(ProMotion.MERCURY_SHIMMER_DURATION_MS.toInt(), easing = LinearEasing),
                    repeatMode = RepeatMode.Restart,
                ),
                label = "bandShimmerPhase",
            ).value
        } else {
            0f
        }

    val tappable = variant == MembershipBandVariant.Upsell && onClick != null
    val accessibilityText =
        if (variant == MembershipBandVariant.Upsell) {
            "$title. $detail. $ctaLabel."
        } else {
            "$title. $detail."
        }

    MembershipBandSurface(
        config =
        MembershipBandSurfaceConfig(
            variant = variant,
            tappable = tappable,
            onClick = onClick,
            accessibilityText = accessibilityText,
            shimmerPhase = shimmerPhase,
            reduceMotion = reduceMotion,
            modifier = modifier,
        ),
    ) {
        MembershipBandRow(
            title = title,
            detail = detail,
            variant = variant,
            icon = icon,
            ctaLabel = ctaLabel,
        )
    }
}

enum class MembershipBandVariant {
    Upsell,
    Active,
}
