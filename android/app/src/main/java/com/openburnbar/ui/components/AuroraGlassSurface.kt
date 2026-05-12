package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadowSpec
import com.openburnbar.ui.theme.AuroraShadows

/**
 * Aurora glass surface — translucent fill + brand-tinted sheen + edge-gradient
 * stroke + soft shadow. iOS-parity look for cards/buttons/sheets without
 * relying on Android `RenderEffect` blur for the surface itself.
 *
 * Note: an earlier revision applied `RenderEffect.createBlurEffect` via
 * `graphicsLayer { renderEffect = ... }`, but in Compose that blurs the
 * layer's own content (the card's text and icons) rather than the backdrop.
 * On a real device that made cards look muddy while leaving everything behind
 * them sharp — the opposite of iOS Liquid Glass. We dropped the blur and lean
 * on the translucent stack, which actually reads as layered glass on hardware.
 *
 * True backdrop blur on Android requires capturing the parent's pixels (or
 * using a window-level blur attribute on Android 12+) — both heavyweight, and
 * not necessary to hit visual parity for the dashboard surfaces.
 */

/**
 * Apply the Aurora glass treatment to a modifier chain. The caller is expected
 * to wrap content inside this modifier — the shadow and stroke draw outside of
 * its bounds while the blur applies to anything drawn inside.
 *
 * @param cornerRadius corner radius for the surface; defaults to AuroraRadius.lg
 * @param blurRadiusDp blur radius applied on API 31+. Ignored on older devices.
 * @param tintAlpha base fill alpha on top of the blurred backdrop.
 * @param interactive when true, scales 0.98 on press; wire via Modifier.scale externally.
 * @param shadow elevation/spot spec for the dropped shadow.
 * @param isDark optional override; defaults to `isSystemInDarkTheme`.
 */
@Composable
fun Modifier.auroraGlass(
    cornerRadius: Dp = AuroraRadius.lg.dp,
    @Suppress("UNUSED_PARAMETER") blurRadiusDp: Float = 12f, // retained for API compatibility
    tintAlpha: Float = 0.48f,
    shadow: AuroraShadowSpec = AuroraShadows.medium,
    isDark: Boolean = isSystemInDarkTheme()
): Modifier {
    val shape = RoundedCornerShape(cornerRadius)

    // Frosted fill that stays glass-like regardless of theme. In dark mode
    // the slate `darkSurface` at high alpha pools into a black slab over the
    // warm gradient — so we keep the slate but cap its alpha well below the
    // requested tint, letting the gradient warmth dominate and the slate
    // act as a faint cool wash that preserves legibility of light text on
    // top. Light mode keeps the cream surface at the full requested alpha.
    val baseFill = if (isDark) {
        AuroraColors.darkSurface.copy(alpha = (tintAlpha * 0.35f).coerceIn(0f, 1f))
    } else {
        AuroraColors.lightSurface.copy(alpha = tintAlpha)
    }

    // Subtle top-down lightening keeps the card feeling refractive without
    // blurring content underneath. Brand tint stays low so text wins.
    val sheen = Brush.verticalGradient(
        colors = listOf(
            Color.White.copy(alpha = if (isDark) 0.05f else 0.18f),
            Color.Transparent,
            AuroraColors.blaze.copy(alpha = if (isDark) 0.03f else 0.05f)
        )
    )
    val stroke = Brush.linearGradient(colors = AuroraGradients.glassStroke)

    val withShadow = if (shadow.elevation > 0.dp) {
        this.shadow(
            elevation = shadow.elevation,
            shape = shape,
            spotColor = Color.Black.copy(alpha = shadow.spotAlpha),
            ambientColor = Color.Black.copy(alpha = shadow.spotAlpha)
        )
    } else this

    return withShadow
        .clip(shape)
        .background(baseFill, shape)
        .background(sheen, shape)
        .border(0.75.dp, stroke, shape)
}

/**
 * Lightweight container that applies the glass treatment and reserves no extra
 * padding. Use when you want the glass look on a free-form composable rather
 * than via [AuroraGlassCard], which forces a Column with default padding.
 */
@Composable
fun AuroraGlassBox(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = AuroraRadius.lg.dp,
    shadow: AuroraShadowSpec = AuroraShadows.medium,
    isDark: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    Box(
        modifier = modifier.auroraGlass(
            cornerRadius = cornerRadius,
            shadow = shadow,
            isDark = isDark
        )
    ) { content() }
}

/**
 * Subtle highlight-only sheen for elements that should not get the full glass
 * surface but still benefit from the brand-tinted gradient. Used by buttons in
 * regular (non-prominent) state.
 */
val auroraSheenBrush: Brush
    get() = Brush.linearGradient(
        colors = AuroraGradients.glassSheen,
        start = Offset(0f, 0f),
        end = Offset(800f, 800f)
    )
