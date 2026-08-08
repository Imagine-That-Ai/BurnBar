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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.max

// ── Inbox (letter tray catching a signal) ──────────────────────────────────
//
// Lives in its own file rather than in `AuroraNavGlyphs.kt` because that file is
// stamped `generated-by: scripts/generate-aurora-nav-glyphs` and carries per-file
// detekt exemptions; a hand-authored glyph does not belong inside generated
// output.
//
// The drawing is the surface's argument in one mark: a tray (the inbox), with a
// signal arriving into it from above (something happened while you were away).
// Selection lights the arriving signal, because the arrival is the news.

@Composable
fun InboxGlyph(size: Dp, isSelected: Boolean, modifier: Modifier = Modifier) {
    val reduce = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "inbox-signal")
    val arrival by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(durationMillis = 2400, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "inbox-arrival",
    )

    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = max(1.3f, w * 0.075f)
        val brush =
            if (isSelected) {
                Brush.linearGradient(
                    colors = listOf(AuroraColors.ember, AuroraColors.amber),
                    start = Offset(0f, h),
                    end = Offset(w, 0f),
                )
            } else {
                Brush.linearGradient(colors = listOf(AuroraColors.hermesMercury, AuroraColors.hermesMercury))
            }

        drawInboxTray(w = w, h = h, stroke = stroke, brush = brush, isSelected = isSelected)
        // When motion is allowed the signal falls on a loop; otherwise it rests
        // at the tray mouth so the glyph still reads correctly at a glance.
        drawInboxSignal(w = w, h = h, stroke = stroke, brush = brush, travel = if (reduce || !isSelected) 1f else arrival)
    }
}

/**
 * An open-topped box whose upper edge dips in the middle, so the silhouette
 * reads as a receptacle rather than a closed envelope. Selection fills the floor
 * — the tray has something in it.
 */
private fun DrawScope.drawInboxTray(w: Float, h: Float, stroke: Float, brush: Brush, isSelected: Boolean) {
    val left = w * 0.12f
    val right = w * 0.88f
    val top = h * 0.52f
    val bottom = h * 0.86f
    val notch = w * 0.20f
    val lip = top + h * 0.10f

    if (isSelected) {
        val floor =
            Path().apply {
                moveTo(left + stroke * 0.5f, lip)
                lineTo(right - stroke * 0.5f, lip)
                lineTo(right - stroke * 0.5f, bottom - stroke * 0.5f)
                lineTo(left + stroke * 0.5f, bottom - stroke * 0.5f)
                close()
            }
        drawPath(
            path = floor,
            brush =
            Brush.verticalGradient(
                colors = listOf(AuroraColors.amber.copy(alpha = 0.34f), Color.Transparent),
                startY = top,
                endY = bottom,
            ),
        )
    }

    val tray =
        Path().apply {
            moveTo(left, top)
            lineTo(left, bottom)
            lineTo(right, bottom)
            lineTo(right, top)
            // Inner lip folding down to the slot.
            moveTo(left, top)
            lineTo(left + notch, lip)
            lineTo(right - notch, lip)
            lineTo(right, top)
        }
    drawPath(
        path = tray,
        brush = brush,
        style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round),
    )
}

/** A short stroke descending into the slot with a leading dot: something arriving. */
private fun DrawScope.drawInboxSignal(w: Float, h: Float, stroke: Float, brush: Brush, travel: Float) {
    val startY = h * 0.10f
    val endY = h * 0.52f * 0.94f
    val dotY = startY + (endY - startY) * travel
    drawLine(
        brush = brush,
        start = Offset(w * 0.5f, startY),
        end = Offset(w * 0.5f, dotY),
        strokeWidth = stroke * 0.8f,
        cap = StrokeCap.Round,
    )
    drawCircle(brush = brush, radius = w * 0.075f, center = Offset(w * 0.5f, dotY))
}
