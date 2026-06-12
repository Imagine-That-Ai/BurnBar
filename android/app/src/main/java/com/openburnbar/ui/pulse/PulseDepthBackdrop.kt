// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

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
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.openburnbar.ui.settings.rememberWebsiteBackground
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.PI
import kotlin.math.sin

internal const val DRIFT_CYCLE_MILLIS = 22_000

// The drift amplitudes top out at 28px over a 22s cycle (max velocity
// ~8px/s), so a 30Hz phase grid moves each halo at most ~0.27px per step —
// imperceptible, while cutting halo redraws ~75% on 120Hz displays.
internal const val QUANTIZED_PHASE_STEPS = 660 // 22s × 30Hz

/** Reduce Motion renders one static frame at this rest step (the cycle-start phase). */
internal const val PULSE_DEPTH_REST_STEP = 0

/**
 * Render gate: the depth halos draw only on the AURORA backdrop. Under the
 * custom dark backdrops (`rememberWebsiteBackground()` true) the layer skips
 * itself entirely — see the [PulseDepthBackdrop] doc for the visual rationale.
 */
internal fun pulseDepthRendersHalos(useWebsiteBackground: Boolean): Boolean = !useWebsiteBackground

/** The 30Hz grid cell for a raw animated phase in `[0, 1]` (Float.toInt truncation). */
internal fun pulseDepthQuantizedStep(phase: Float): Int = (phase * QUANTIZED_PHASE_STEPS).toInt()

/** The drift phase the draw block reconstructs from a quantized step. */
internal fun pulseDepthPhaseForStep(step: Int): Float = step / QUANTIZED_PHASE_STEPS.toFloat()

/** Sinusoidal drift offset for one halo axis: `sin(phase · 2π · freq) · amount`. */
internal fun pulseDepthDrift(phase: Float, amount: Float, freq: Float): Float {
    val theta = phase * (PI * 2 * freq).toFloat()
    return sin(theta) * amount
}

/**
 * Secondary aurora layer that sits between the Pulse `AuroraBackdrop` and the
 * card stack. Adds **depth** — soft brand-tinted halos that drift slowly and
 * anchor each scroll band to a warm spot of light.
 *
 * Without this layer the Android Pulse page renders as a flat list of pale
 * cards stacked on the same surface. With it, the scroll feels like it sits
 * inside a slowly breathing volume of color.
 *
 * The halos were designed for the AURORA backdrop and render only there:
 * under the custom dark backdrops (token-ember swarm / dot constellation)
 * the warm glow muddies card contrast over an already-animated near-black
 * field while costing five full-screen radial-gradient fills per frame, so
 * this layer skips itself entirely there. `rememberWebsiteBackground()` is
 * the app-wide gate for "custom dark backdrop active" and already encodes
 * the Editorial exception (Editorial forces a light paper surface, where the
 * halos keep rendering exactly as before).
 */
@Composable
fun PulseDepthBackdrop(modifier: Modifier = Modifier) {
    val useWebsiteBackground by rememberWebsiteBackground()
    if (!pulseDepthRendersHalos(useWebsiteBackground)) return

    val isDark = isSystemInDarkTheme()
    val reduceMotion = LocalAuroraReduceMotion.current
    val phaseStep = rememberPulseDepthPhaseStep(reduceMotion)

    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        // Snapshot read inside the draw scope — only this draw block
        // re-executes when the quantized phase advances, and the five
        // gradient brushes below are rebuilt only on those 30Hz steps
        // (or on size change), not per display frame.
        val phase = pulseDepthPhaseForStep(phaseStep.value)

        fun drift(amount: Float, freq: Float): Float = pulseDepthDrift(phase, amount, freq)

        fun halo(color: Color, centerX: Float, centerY: Float, radius: Float, intensity: Float) {
            drawCircle(
                brush =
                Brush.radialGradient(
                    colors =
                    listOf(
                        color.copy(alpha = intensity),
                        color.copy(alpha = intensity * 0.35f),
                        Color.Transparent,
                    ),
                    center = Offset(centerX, centerY),
                    radius = radius,
                ),
                radius = radius,
                center = Offset(centerX, centerY),
            )
        }

        // Hero ember halo — anchors the top hero card.
        halo(
            color = AuroraColors.ember(isDark),
            centerX = w * 0.18f + drift(28f, 1.0f),
            centerY = h * 0.10f + drift(16f, 0.7f),
            radius = maxOf(w * 0.55f, 460f),
            intensity = if (isDark) 0.32f else 0.20f,
        )

        // Amber forecast halo
        halo(
            color = AuroraColors.amber(isDark),
            centerX = w * 0.82f + drift(-22f, 0.6f),
            centerY = h * 0.20f + drift(18f, 1.3f),
            radius = maxOf(w * 0.50f, 400f),
            intensity = if (isDark) 0.24f else 0.14f,
        )

        // Whimsy mid-band halo
        halo(
            color = AuroraColors.whimsy(isDark),
            centerX = w * 0.22f + drift(24f, 0.9f),
            centerY = h * 0.50f + drift(-20f, 0.5f),
            radius = maxOf(w * 0.48f, 380f),
            intensity = if (isDark) 0.18f else 0.10f,
        )

        // Mercury halo (Hermes section)
        halo(
            color = AuroraColors.hermesMercury,
            centerX = w * 0.78f + drift(-18f, 0.8f),
            centerY = h * 0.70f + drift(22f, 0.4f),
            radius = maxOf(w * 0.46f, 360f),
            intensity = if (isDark) 0.16f else 0.08f,
        )

        // Blaze foot halo
        halo(
            color = AuroraColors.blaze,
            centerX = w * 0.50f + drift(14f, 1.1f),
            centerY = h * 0.92f + drift(-12f, 0.7f),
            radius = maxOf(w * 0.55f, 420f),
            intensity = if (isDark) 0.14f else 0.06f,
        )
    }
}

@Composable
private fun rememberPulseDepthPhaseStep(reduceMotion: Boolean): State<Int> {
    if (reduceMotion) {
        return remember { mutableIntStateOf(PULSE_DEPTH_REST_STEP) }
    }
    val transition = rememberInfiniteTransition(label = "pulse-depth")
    val phase = transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(durationMillis = DRIFT_CYCLE_MILLIS, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "phase",
    )
    return remember { derivedStateOf { pulseDepthQuantizedStep(phase.value) } }
}
