package com.openburnbar.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Aurora buttons mirroring the iOS GlassButton family:
 *   • AuroraButton (default) — prominent: ember/amber gradient + brand stroke + press scale
 *   • AuroraGradientButton — alias for the gradient-prominent variant
 *   • AuroraSecondaryButton — outlined, glass-tinted hairline border
 *   • AuroraTextButton — text-only
 *
 * All button variants share the same press-scale (cardPress spring) for tactile
 * parity with iOS.
 */

object AuroraButtonDefaults {
    val shape = RoundedCornerShape(AuroraRadius.FULL.dp)
    val contentPadding = PaddingValues(horizontal = AuroraSpacing.LG.dp, vertical = AuroraSpacing.MD.dp)
    const val PRESSED_SCALE = 0.96f
}

@Composable
private fun pressGesture(enabled: Boolean, onClick: () -> Unit, onPressedChange: (Boolean) -> Unit): Modifier {
    return if (!enabled) {
        Modifier
    } else {
        Modifier.pointerInput(onClick) {
            detectTapGestures(
                onPress = {
                    onPressedChange(true)
                    val released = tryAwaitRelease()
                    onPressedChange(false)
                    if (released) onClick()
                },
            )
        }
    }
}

@Composable
fun AuroraButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    AuroraGradientButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        loading = loading,
        content = content,
    )
}

@Composable
fun AuroraGradientButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    var pressed by remember { mutableStateOf(false) }
    val target = if (pressed) AuroraButtonDefaults.PRESSED_SCALE else 1f
    val scale by animateFloatAsState(
        targetValue = target,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "aurora-button-scale",
    )
    val click = if (enabled && !loading) onClick else null
    val clickModifier =
        if (click != null) {
            pressGesture(enabled = true, onClick = click) { pressed = it }
        } else {
            Modifier
        }

    AuroraGradientButtonSurface(
        modifier = modifier,
        scale = scale,
        enabled = enabled,
        loading = loading,
        clickModifier = clickModifier,
        content = content,
    )
}

@Composable
fun AuroraSecondaryButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    var pressed by remember { mutableStateOf(false) }
    val target = if (pressed) AuroraButtonDefaults.PRESSED_SCALE else 1f
    val scale by animateFloatAsState(
        targetValue = target,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "aurora-secondary-scale",
    )

    val click = if (enabled && !loading) onClick else null
    val strokeBrush = Brush.linearGradient(colors = AuroraGradients.glassStroke)

    Box(
        modifier =
        modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(AuroraButtonDefaults.shape)
            .background(
                Brush.linearGradient(colors = AuroraGradients.glassSheen),
                AuroraButtonDefaults.shape,
            )
            .then(
                if (click != null) {
                    pressGesture(enabled = true, onClick = click) { pressed = it }
                } else {
                    Modifier
                },
            )
            .padding(AuroraButtonDefaults.contentPadding),
        contentAlignment = Alignment.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(
                color = AuroraColors.ember,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
        } else {
            val contentColor = if (enabled) AuroraColors.ember else AuroraColors.ember.copy(alpha = 0.5f)
            CompositionLocalProvider(LocalContentColor provides contentColor) {
                ProvideTextStyle(
                    MaterialTheme.typography.labelLarge.copy(
                        fontWeight = FontWeight.SemiBold,
                        color = contentColor,
                    ),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
                        content = content,
                    )
                }
            }
        }
    }
}

@Composable
fun AuroraTextButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable RowScope.() -> Unit) {
    TextButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = ButtonDefaults.textButtonColors(contentColor = AuroraColors.ember),
        content = content,
    )
}
