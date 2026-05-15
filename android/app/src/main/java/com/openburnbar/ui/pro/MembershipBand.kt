package com.openburnbar.ui.pro

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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

private val BandTitleStyle = TextStyle(
    fontFamily = FontFamily.SansSerif,
    fontWeight = FontWeight.SemiBold,
    fontSize = 13.sp,
    lineHeight = 18.sp
)

private val BandDetailStyle = TextStyle(
    fontFamily = FontFamily.SansSerif,
    fontWeight = FontWeight.Normal,
    fontSize = 11.sp,
    lineHeight = 15.sp
)

private val BandCtaStyle = TextStyle(
    fontFamily = FontFamily.SansSerif,
    fontWeight = FontWeight.Black,
    fontSize = 10.sp,
    letterSpacing = 1.4.sp
)

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
    onClick: (() -> Unit)? = null
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val shape = RoundedCornerShape(ProLayout.bandRadiusDp.dp)

    val shimmerPhase = if (!reduceMotion) {
        rememberInfiniteTransition(label = "bandShimmer").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(ProMotion.mercuryShimmerDurationMs.toInt(), easing = LinearEasing),
                repeatMode = RepeatMode.Restart
            ),
            label = "bandShimmerPhase"
        ).value
    } else 0f

    val tappable = variant == MembershipBandVariant.Upsell && onClick != null
    val accessibilityText = if (variant == MembershipBandVariant.Upsell) {
        "$title. $detail. $ctaLabel."
    } else {
        "$title. $detail."
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (variant == MembershipBandVariant.Upsell) 10.dp else 6.dp,
                shape = shape,
                ambientColor = ProPalette.aureate,
                spotColor = ProPalette.aureate
            )
            .clip(shape)
            .background(ProPalette.obsidian, shape)
            .border(
                width = 0.9.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = shape
            )
            .let { base ->
                if (tappable) {
                    base.clickable { onClick?.invoke() }
                } else base
            }
            .semantics { contentDescription = accessibilityText }
    ) {
        if (!reduceMotion) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        brush = Brush.linearGradient(
                            colors = listOf(
                                Color.Transparent,
                                ProPalette.mercury.copy(alpha = 0.16f),
                                Color.White.copy(alpha = 0.14f),
                                ProPalette.mercury.copy(alpha = 0.16f),
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
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(ProPalette.obsidian, CircleShape)
                    .border(
                        width = 0.9.dp,
                        brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                        shape = CircleShape
                    )
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = ProPalette.aureate,
                    modifier = Modifier.size(13.dp)
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.Center, modifier = Modifier.weight(1f)) {
                Text(title, style = BandTitleStyle, color = ProPalette.mercury)
                Text(
                    detail,
                    style = BandDetailStyle,
                    color = ProPalette.mercury.copy(alpha = 0.70f),
                    maxLines = 2
                )
            }
            Spacer(Modifier.width(10.dp))
            if (variant == MembershipBandVariant.Upsell) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(ctaLabel, style = BandCtaStyle, color = ProPalette.aureate)
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowForward,
                        contentDescription = null,
                        tint = ProPalette.aureate,
                        modifier = Modifier.size(12.dp)
                    )
                }
            } else {
                Icon(
                    Icons.Filled.VerifiedUser,
                    contentDescription = null,
                    tint = ProPalette.aureate,
                    modifier = Modifier.size(14.dp)
                )
            }
        }
    }
}

enum class MembershipBandVariant {
    Upsell,
    Active
}
