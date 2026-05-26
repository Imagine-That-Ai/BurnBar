package com.openburnbar.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.R
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.ui.theme.LocalUIMode
import com.openburnbar.ui.theme.UIMode
import kotlin.math.abs
import kotlin.math.sin

enum class CookingLoaderStyle {
    /** Inline spinner (~24dp). Use for buttons, header refreshes, status rows. */
    INLINE,
    /** Page-level loader (~60dp). Use for full-screen loading or panel states. */
    PANEL,
    /** Hero loader (~100dp). Use for prominent first-run or onboarding moments. */
    HERO
}

/**
 * A playful, dancing eggs-and-bacon skillet loading indicator that replaces the standard
 * circular spinner in Cooking mode. The skillet bounces and sways reactively to a gentle rhythm.
 */
@Composable
fun CookingLoader(
    style: CookingLoaderStyle = CookingLoaderStyle.PANEL,
    label: String? = null,
    tint: Color? = null,
    modifier: Modifier = Modifier
) {
    val reduceMotion = LocalAuroraReduceMotion.current

    val size: Dp = when (style) {
        CookingLoaderStyle.INLINE -> 24.dp
        CookingLoaderStyle.PANEL -> 60.dp
        CookingLoaderStyle.HERO -> 100.dp
    }

    val labelTextSize = when (style) {
        CookingLoaderStyle.INLINE -> 11.sp
        CookingLoaderStyle.PANEL -> 13.sp
        CookingLoaderStyle.HERO -> 16.sp
    }

    val labelFontWeight = when (style) {
        CookingLoaderStyle.INLINE, CookingLoaderStyle.PANEL -> FontWeight.Medium
        CookingLoaderStyle.HERO -> FontWeight.SemiBold
    }

    val spacing: Dp = when (style) {
        CookingLoaderStyle.INLINE -> 4.dp
        CookingLoaderStyle.PANEL -> 10.dp
        CookingLoaderStyle.HERO -> 14.dp
    }

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(spacing)
    ) {
        if (reduceMotion) {
            // Static skillet frame
            Image(
                painter = painterResource(id = R.drawable.ic_cooking_skillet),
                contentDescription = label ?: "Loading",
                modifier = Modifier
                    .size(size)
                    .graphicsLayer { alpha = 0.92f }
            )
        } else {
            // Dancing skillet with physics-based overlaps matching the 1.6s iOS loop
            val infiniteTransition = rememberInfiniteTransition(label = "skillet-dance")
            val animationProgress by infiniteTransition.animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = tween(1600, easing = LinearEasing),
                    repeatMode = RepeatMode.Restart
                ),
                label = "dance-progress"
            )

            val phase = animationProgress
            val s = sin(phase * Math.PI * 2).toFloat()

            // Vertical bounce: egg-like hop, up then soft landing settle
            val bounceValue = if (s > 0) {
                Math.pow(s.toDouble(), 0.7).toFloat()
            } else {
                -Math.pow(abs(s).toDouble(), 1.4).toFloat() * 0.3f
            }
            val bounceOffset = -bounceValue * size.value * 0.12f

            // Rocking sway: lags the bounce slightly to simulate momentum
            val lagged = (phase + 0.15f) % 1.0f
            val swayRotation = sin(lagged * Math.PI * 2).toFloat() * 5.0f

            // Squash-stretch: taller at apex, squatter at bottom
            val squashScale = 1.0f + s * 0.04f

            Image(
                painter = painterResource(id = R.drawable.ic_cooking_skillet),
                contentDescription = label ?: "Loading",
                modifier = Modifier
                    .size(size)
                    .graphicsLayer {
                        translationY = bounceOffset.dp.toPx()
                        rotationZ = swayRotation
                        scaleX = squashScale
                        scaleY = squashScale
                    }
            )
        }

        if (!label.isNullOrEmpty()) {
            Text(
                text = label,
                fontSize = labelTextSize,
                fontWeight = labelFontWeight,
                color = tint ?: MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 8.dp)
            )
        }
    }
}

/**
 * A mode-aware loading wrapper that inspects the ambient UIMode. Displays the playful
 * dancing CookingLoader when in Cooking mode, falling back to a CircularProgressIndicator.
 */
@Composable
fun ModeAwareLoader(
    modifier: Modifier = Modifier,
    style: CookingLoaderStyle = CookingLoaderStyle.PANEL,
    label: String? = null,
    tint: Color? = null,
    strokeWidth: Dp = 3.dp
) {
    val uiMode = LocalUIMode.current

    if (uiMode == UIMode.COOKING) {
        CookingLoader(
            style = style,
            label = label,
            tint = tint,
            modifier = modifier
        )
    } else {
        Column(
            modifier = modifier,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            CircularProgressIndicator(
                color = tint ?: MaterialTheme.colorScheme.primary,
                strokeWidth = strokeWidth,
                modifier = Modifier.size(
                    when (style) {
                        CookingLoaderStyle.INLINE -> 20.dp
                        CookingLoaderStyle.PANEL -> 36.dp
                        CookingLoaderStyle.HERO -> 56.dp
                    }
                )
            )
            if (!label.isNullOrEmpty() && style != CookingLoaderStyle.INLINE) {
                Text(
                    text = label,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = tint ?: MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
