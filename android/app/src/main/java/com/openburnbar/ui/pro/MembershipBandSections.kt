// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

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
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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

internal val BandTitleStyle =
    TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 13.sp,
        lineHeight = 18.sp,
    )

internal val BandDetailStyle =
    TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 11.sp,
        lineHeight = 15.sp,
    )

internal val BandCtaStyle =
    TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Black,
        fontSize = 10.sp,
        letterSpacing = 1.4.sp,
    )

internal data class MembershipBandSurfaceConfig(
    val variant: MembershipBandVariant,
    val tappable: Boolean,
    val onClick: (() -> Unit)?,
    val accessibilityText: String,
    val shimmerPhase: Float,
    val reduceMotion: Boolean,
    val modifier: Modifier = Modifier,
)

@Composable
internal fun MembershipBandSurface(config: MembershipBandSurfaceConfig, content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(ProLayout.bandRadiusDp.dp)
    Box(
        modifier =
        config.modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (config.variant == MembershipBandVariant.Upsell) 10.dp else 6.dp,
                shape = shape,
                ambientColor = ProPalette.aureate,
                spotColor = ProPalette.aureate,
            )
            .clip(shape)
            .background(ProPalette.obsidian, shape)
            .border(
                width = 0.9.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = shape,
            )
            .let { base ->
                if (config.tappable) {
                    base.clickable { config.onClick?.invoke() }
                } else {
                    base
                }
            }
            .semantics { contentDescription = config.accessibilityText },
    ) {
        if (!config.reduceMotion) {
            Box(
                modifier =
                Modifier
                    .fillMaxSize()
                    .background(
                        brush =
                        Brush.linearGradient(
                            colors =
                            listOf(
                                Color.Transparent,
                                ProPalette.mercury.copy(alpha = 0.16f),
                                Color.White.copy(alpha = 0.14f),
                                ProPalette.mercury.copy(alpha = 0.16f),
                                Color.Transparent,
                            ),
                            start = Offset(config.shimmerPhase * 400f, 0f),
                            end = Offset(config.shimmerPhase * 400f + 320f, 320f),
                        ),
                    ),
            )
        }
        content()
    }
}

@Composable
internal fun MembershipBandRow(
    title: String,
    detail: String,
    variant: MembershipBandVariant,
    icon: ImageVector,
    ctaLabel: String,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier =
            Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(ProPalette.obsidian, CircleShape)
                .border(
                    width = 0.9.dp,
                    brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                    shape = CircleShape,
                ),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = ProPalette.aureate,
                modifier = Modifier.size(13.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.Center, modifier = Modifier.weight(1f)) {
            Text(title, style = BandTitleStyle, color = ProPalette.mercury)
            Text(
                detail,
                style = BandDetailStyle,
                color = ProPalette.mercury.copy(alpha = 0.70f),
                maxLines = 2,
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
                    modifier = Modifier.size(12.dp),
                )
            }
        } else {
            Icon(
                Icons.Filled.VerifiedUser,
                contentDescription = null,
                tint = ProPalette.aureate,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}
