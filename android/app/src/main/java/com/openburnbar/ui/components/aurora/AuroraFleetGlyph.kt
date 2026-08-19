package com.openburnbar.ui.components.aurora

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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.max

// ── Fleet (radar sweep over agent blips) ───────────────────────────────────
//
// Lives in its own file rather than in `AuroraNavGlyphs.kt` because that file
// is stamped `generated-by: scripts/generate-aurora-nav-glyphs`; hand-authored
// glyphs (see `AuroraInboxGlyph.kt`) do not belong inside generated output.
//
// The drawing is the surface's argument in one mark: a radar dish watching a
// constellation of agent blips. The fleet dashboard never invents liveness —
// it only reports what a probe observed — and a radar is exactly that: a
// watcher, not a controller. Selection animates the sweep, because the news is
// that watching is live.

@Composable
fun FleetGlyph(size: Dp, isSelected: Boolean, modifier: Modifier = Modifier) {
    val reduce = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "fleet-sweep")
    val sweep by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(durationMillis = 2600, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "fleet-sweep-phase",
    )

    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = max(1.3f, w * 0.07f)
        val brush =
            if (isSelected) {
                Brush.linearGradient(
                    colors = listOf(AuroraColors.success, AuroraColors.whimsy),
                    start = Offset(0f, h),
                    end = Offset(w, 0f),
                )
            } else {
                Brush.linearGradient(colors = listOf(AuroraColors.hermesMercury, AuroraColors.hermesMercury))
            }

        drawFleetRings(w = w, h = h, stroke = stroke, brush = brush)
        drawFleetBlips(w = w, h = h, brush = brush, isSelected = isSelected)
        if (isSelected) {
            drawFleetSweep(w = w, h = h, stroke = stroke, phase = if (reduce) 0.32f else sweep)
        }
    }
}

/** Two concentric arcs open at the top — the radar's field of view. */
private fun DrawScope.drawFleetRings(w: Float, h: Float, stroke: Float, brush: Brush) {
    val center = Offset(w * 0.5f, h * 0.58f)
    for (radius in listOf(w * 0.20f, w * 0.38f)) {
        drawArc(
            brush = brush,
            startAngle = 150f,
            sweepAngle = 240f,
            useCenter = false,
            topLeft = Offset(center.x - radius, center.y - radius),
            size = androidx.compose.ui.geometry.Size(radius * 2f, radius * 2f),
            style = Stroke(width = stroke * 0.75f, cap = StrokeCap.Round),
        )
    }
    // The dish's own position.
    drawCircle(brush = brush, radius = stroke * 0.85f, center = center)
}

/** Three observed agent blips inside the field of view. */
private fun DrawScope.drawFleetBlips(w: Float, h: Float, brush: Brush, isSelected: Boolean) {
    val blipR = w * 0.065f
    val blips =
        listOf(
            Offset(w * 0.30f, h * 0.34f),
            Offset(w * 0.66f, h * 0.24f),
            Offset(w * 0.76f, h * 0.52f),
        )
    for ((index, blip) in blips.withIndex()) {
        val radius = if (index == 1) blipR else blipR * 0.8f
        if (isSelected) {
            drawCircle(brush = brush, radius = radius, center = blip)
        } else {
            drawCircle(
                color = AuroraColors.hermesMercury.copy(alpha = 0.78f),
                radius = radius,
                center = blip,
            )
        }
    }
}

/** The rotating sweep line, lit only while selected. */
private fun DrawScope.drawFleetSweep(w: Float, h: Float, stroke: Float, phase: Float) {
    val center = Offset(w * 0.5f, h * 0.58f)
    // Matches the rings' 150°..390° field of view.
    val angleDegrees = 150.0 + 240.0 * phase
    val angle = Math.toRadians(angleDegrees)
    val reach = w * 0.40f
    val tip =
        Offset(
            center.x + (kotlin.math.cos(angle) * reach).toFloat(),
            center.y + (kotlin.math.sin(angle) * reach).toFloat(),
        )
    drawLine(
        brush =
        Brush.linearGradient(
            colors = listOf(AuroraColors.success, AuroraColors.success.copy(alpha = 0.15f)),
            start = center,
            end = tip,
        ),
        start = center,
        end = tip,
        strokeWidth = stroke * 0.7f,
        cap = StrokeCap.Round,
    )
    drawCircle(color = AuroraColors.success.copy(alpha = 0.9f), radius = stroke * 0.55f, center = tip)
}
