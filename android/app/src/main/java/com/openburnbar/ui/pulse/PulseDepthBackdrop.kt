package com.openburnbar.ui.pulse

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.openburnbar.ui.theme.AuroraColors
import kotlin.math.PI
import kotlin.math.sin

/**
 * Secondary aurora layer that sits between the Pulse `AuroraBackdrop` and the
 * card stack. Adds **depth** — soft brand-tinted halos that drift slowly and
 * anchor each scroll band to a warm spot of light.
 *
 * Without this layer the Android Pulse page renders as a flat list of pale
 * cards stacked on the same surface. With it, the scroll feels like it sits
 * inside a slowly breathing volume of color.
 */
@Composable
fun PulseDepthBackdrop(modifier: Modifier = Modifier) {
    val isDark = isSystemInDarkTheme()
    val transition = rememberInfiniteTransition(label = "pulse-depth")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 22_000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase"
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height

        fun drift(amount: Float, freq: Float): Float {
            val theta = phase * (PI * 2 * freq).toFloat()
            return sin(theta) * amount
        }

        fun halo(color: Color, centerX: Float, centerY: Float, radius: Float, intensity: Float) {
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        color.copy(alpha = intensity),
                        color.copy(alpha = intensity * 0.35f),
                        Color.Transparent
                    ),
                    center = Offset(centerX, centerY),
                    radius = radius
                ),
                radius = radius,
                center = Offset(centerX, centerY)
            )
        }

        // Hero ember halo — anchors the top hero card.
        halo(
            color = AuroraColors.ember(isDark),
            centerX = w * 0.18f + drift(28f, 1.0f),
            centerY = h * 0.10f + drift(16f, 0.7f),
            radius = maxOf(w * 0.55f, 460f),
            intensity = if (isDark) 0.32f else 0.20f
        )

        // Amber forecast halo
        halo(
            color = AuroraColors.amber(isDark),
            centerX = w * 0.82f + drift(-22f, 0.6f),
            centerY = h * 0.20f + drift(18f, 1.3f),
            radius = maxOf(w * 0.50f, 400f),
            intensity = if (isDark) 0.24f else 0.14f
        )

        // Whimsy mid-band halo
        halo(
            color = AuroraColors.whimsy(isDark),
            centerX = w * 0.22f + drift(24f, 0.9f),
            centerY = h * 0.50f + drift(-20f, 0.5f),
            radius = maxOf(w * 0.48f, 380f),
            intensity = if (isDark) 0.18f else 0.10f
        )

        // Mercury halo (Hermes section)
        halo(
            color = AuroraColors.hermesMercury,
            centerX = w * 0.78f + drift(-18f, 0.8f),
            centerY = h * 0.70f + drift(22f, 0.4f),
            radius = maxOf(w * 0.46f, 360f),
            intensity = if (isDark) 0.16f else 0.08f
        )

        // Blaze foot halo
        halo(
            color = AuroraColors.blaze,
            centerX = w * 0.50f + drift(14f, 1.1f),
            centerY = h * 0.92f + drift(-12f, 0.7f),
            radius = maxOf(w * 0.55f, 420f),
            intensity = if (isDark) 0.14f else 0.06f
        )
    }
}
