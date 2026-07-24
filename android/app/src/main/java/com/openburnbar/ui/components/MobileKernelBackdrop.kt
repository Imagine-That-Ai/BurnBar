// Compose/Canvas literals (sample counts, alpha, and phase math) are deliberate
// because each kernel family needs a compact procedural native rendering.

package com.openburnbar.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import com.openburnbar.ui.settings.MobileBackdropKernel
import com.openburnbar.ui.settings.MobileBackdropKernelFamily
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

@Composable
fun MobileKernelBackdrop(kernel: MobileBackdropKernel, accentColor: Color, modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    if (reduceMotion) {
        MobileKernelBackdropCanvas(kernel = kernel, accentColor = accentColor, phase = 0f, modifier = modifier)
        return
    }
    val transition = rememberInfiniteTransition(label = "mobile-kernel-backdrop")
    val animatedPhase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 18_000, easing = LinearEasing), RepeatMode.Restart),
        label = "mobile-kernel-phase",
    )
    MobileKernelBackdropCanvas(kernel = kernel, accentColor = accentColor, phase = animatedPhase, modifier = modifier)
}

/**
 * Static catalog thumbnail for a kernel — a single frozen frame, never animated.
 *
 * Per `docs/LIVING_THEMES_MOBILE.md` catalog thumbnails are static and only the
 * selected hero preview animates, so this deliberately skips the infinite
 * transition used by [MobileKernelBackdrop] and renders one fixed frame.
 *
 * Phase units differ between platforms. iOS poses its catalog cells at an
 * absolute `time: 2.4` seconds, whereas this canvas takes a phase NORMALIZED to
 * 0..1 across the 18-second loop that [MobileKernelBackdrop] drives. The value
 * that matches iOS is therefore 2.4 / 18 ≈ 0.133 — passing 2.4f would wrap the
 * loop 2.4 times and land on an entirely different, unmatched frame.
 */
@Composable
fun MobileKernelBackdropThumbnail(kernel: MobileBackdropKernel, accentColor: Color, modifier: Modifier = Modifier) {
    MobileKernelBackdropCanvas(kernel = kernel, accentColor = accentColor, phase = THUMBNAIL_PHASE, modifier = modifier)
}

/** Seconds into the loop that iOS freezes its catalog thumbnails at. */
private const val THUMBNAIL_POSE_SECONDS = 2.4f

/** Length of one full kernel loop, matching the 18_000 ms tween in [MobileKernelBackdrop]. */
private const val KERNEL_LOOP_SECONDS = 18f

/** iOS's absolute-seconds pose expressed in this canvas's normalized 0..1 phase. */
private const val THUMBNAIL_PHASE = THUMBNAIL_POSE_SECONDS / KERNEL_LOOP_SECONDS

@Composable
private fun MobileKernelBackdropCanvas(kernel: MobileBackdropKernel, accentColor: Color, phase: Float, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.fillMaxSize()) {
        drawRect(
            brush = Brush.linearGradient(
                colors = kernel.palette(accentColor),
                start = Offset.Zero,
                end = Offset(size.width, size.height),
            ),
        )

        when (kernel.rendererFamily) {
            MobileBackdropKernelFamily.CONSTELLATION -> drawConstellation(phase)
            MobileBackdropKernelFamily.FLOW -> drawFlow(phase)
            MobileBackdropKernelFamily.RIBBONS -> drawRibbons(kernel, phase)
            MobileBackdropKernelFamily.ORBS -> drawOrbs(kernel, phase)
            MobileBackdropKernelFamily.LATTICE -> drawLattice(kernel, phase)
            MobileBackdropKernelFamily.CLOUDS -> drawClouds(kernel, phase)
            MobileBackdropKernelFamily.BLOOM -> drawBloom(phase)
            MobileBackdropKernelFamily.CRYSTAL -> drawCrystal(phase)
            MobileBackdropKernelFamily.MYCELIUM -> drawMycelium(phase)
            MobileBackdropKernelFamily.MARBLE -> drawMarble(kernel, phase)
            MobileBackdropKernelFamily.BEAM -> drawBeam(phase)
            MobileBackdropKernelFamily.STORM -> drawStorm(phase)
            MobileBackdropKernelFamily.PLASMA -> drawPlasma(phase)
            MobileBackdropKernelFamily.PAPER -> drawPaper(phase)
        }

        drawRect(Color.Black.copy(alpha = kernel.readabilityScrim()))
    }
}

private fun MobileBackdropKernel.palette(accentColor: Color): List<Color> = when (this) {
    MobileBackdropKernel.ORIGAMI -> listOf(Color(0xFFF0DEC0), Color(0xFFC78C6F), Color(0xFF5C2E2A))
    MobileBackdropKernel.STORM_SIGNAL -> listOf(Color(0xFF05070D), Color(0xFF1A2233), Color(0xFF59617A))
    MobileBackdropKernel.CLOUDFIELD, MobileBackdropKernel.VOLUMETRIC -> listOf(Color(0xFF080D1F), Color(0xFF22385F), Color(0xFF7F91C2))
    MobileBackdropKernel.PETROLEUM_SHEEN, MobileBackdropKernel.OILFIELD -> listOf(Color(0xFF020709), Color(0xFF0F423B), Color(0xFF6B2E8C))
    MobileBackdropKernel.INK_DIFFUSION, MobileBackdropKernel.SUMINAGASHI_DRIFT -> listOf(Color(0xFF0A0D17), Color(0xFF212E47), Color(0xFF9470C2))
    MobileBackdropKernel.RETRO_PLASMA -> listOf(Color(0xFF0A001A), Color(0xFF450D85), Color(0xFF009EC2))
    else -> listOf(Color(0xFF050509), accentColor.copy(alpha = 0.72f), Color(0xFFF57A2E))
}

private fun MobileBackdropKernel.readabilityScrim(): Float = when (this) {
    MobileBackdropKernel.ORIGAMI -> 0.18f
    MobileBackdropKernel.CONSTELLATION, MobileBackdropKernel.VOGEL_BLOOM, MobileBackdropKernel.MYCELIUM_MESH -> 0.28f
    MobileBackdropKernel.RETRO_PLASMA, MobileBackdropKernel.MOIRE, MobileBackdropKernel.LIQUID_LUMEN -> 0.46f
    else -> 0.36f
}

private fun DrawScope.drawConstellation(phase: Float) {
    val count = 90
    val cx = size.width * 0.5f
    val cy = size.height * 0.46f
    val maxRadius = minOf(size.width, size.height) * 0.44f
    repeat(count) { i ->
        val a = (i * 2.399963 + phase * PI * 2).toFloat()
        val r = sqrt(i.toFloat() / count) * maxRadius
        drawCircle(Color.White.copy(alpha = 0.18f), radius = 1.8f, center = Offset(cx + cos(a) * r, cy + sin(a) * r * 0.72f))
    }
}

private fun DrawScope.drawFlow(phase: Float) {
    repeat(18) { row ->
        val path = Path()
        val baseY = size.height * (row + 0.5f) / 18f
        repeat(73) { step ->
            val p = step / 72f
            val x = p * size.width
            val y = baseY + sin(p * PI.toFloat() * 4f + row * 0.55f + phase * 5f) * 28f + cos(p * PI.toFloat() * 2f + phase * 2f) * 10f
            if (step == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, Color.Cyan.copy(alpha = 0.12f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.2f))
    }
}

private fun DrawScope.drawRibbons(kernel: MobileBackdropKernel, phase: Float) {
    repeat(7) { band ->
        val path = Path()
        val base = size.height * (0.18f + band * 0.10f)
        path.moveTo(-20f, base)
        repeat(81) { step ->
            val p = step / 80f
            val x = p * (size.width + 40f) - 20f
            val y = base + sin(p * PI.toFloat() * 2.4f + phase * 4.5f + band) * (32f + band * 6f)
            path.lineTo(x, y)
        }
        val color = if (kernel == MobileBackdropKernel.NEURAL_BLOOM) Color(0xFFB884FF) else if (band % 2 == 0) Color.Cyan else Color(0xFFFF8A3D)
        drawPath(path, color.copy(alpha = 0.16f + band * 0.018f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 18f + band * 4f))
    }
}

private fun DrawScope.drawOrbs(kernel: MobileBackdropKernel, phase: Float) {
    val colors = if (kernel == MobileBackdropKernel.LIQUID_LUMEN) {
        listOf(Color(0xFFFF8A3D), Color(0xFFB884FF), Color.Cyan, Color(0xFFFF6BAA))
    } else {
        listOf(Color.Cyan, Color(0xFFFF8A3D), Color(0xFFB884FF), Color(0xFF75D99A))
    }
    repeat(8) { i ->
        val a = i * 1.7f + phase * PI.toFloat() * (1f + (i % 3) * 0.25f)
        val radius = minOf(size.width, size.height) * (0.11f + (i % 3) * 0.035f)
        val center = Offset(
            x = size.width * (0.18f + 0.64f * (0.5f + 0.5f * cos(a * 0.71f))),
            y = size.height * (0.16f + 0.68f * (0.5f + 0.5f * sin(a))),
        )
        drawCircle(colors[i % colors.size].copy(alpha = 0.18f), radius = radius, center = center)
    }
}

private fun DrawScope.drawLattice(kernel: MobileBackdropKernel, phase: Float) {
    val spacing = maxOf(34f, minOf(size.width, size.height) / 12f)
    val path = Path()
    var x = -spacing
    while (x < size.width + spacing) {
        path.moveTo(x + sin(phase * PI.toFloat() * 2f) * 12f, 0f)
        path.lineTo(x + size.height * 0.35f, size.height)
        x += spacing
    }
    var y = -spacing
    while (y < size.height + spacing) {
        path.moveTo(0f, y)
        path.lineTo(size.width, y + size.width * 0.18f)
        y += spacing
    }
    val color = if (kernel == MobileBackdropKernel.AETHER_LATTICE) Color(0xFF8FC0FF) else Color.Cyan
    drawPath(path, color.copy(alpha = 0.13f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1f))
}

private fun DrawScope.drawClouds(kernel: MobileBackdropKernel, phase: Float) {
    repeat(16) { i ->
        val a = i * 0.83f + phase * PI.toFloat() * 0.7f
        val w = size.width * (0.20f + (i % 4) * 0.045f)
        val h = w * 0.44f
        val cx = size.width * (0.05f + 0.90f * ((i % 5) / 4f)) + cos(a) * 26f
        val cy = size.height * (0.16f + 0.64f * ((i / 5) / 3f)) + sin(a * 0.8f) * 20f
        drawOval(
            color = Color.White.copy(alpha = if (kernel == MobileBackdropKernel.VOLUMETRIC) 0.10f else 0.14f),
            topLeft = Offset(cx - w / 2f, cy - h / 2f),
            size = androidx.compose.ui.geometry.Size(w, h),
        )
    }
}

private fun DrawScope.drawBloom(phase: Float) {
    val center = Offset(size.width * 0.5f, size.height * 0.48f)
    repeat(240) { i ->
        val angle = (i * 2.399963 + phase * PI * 2).toFloat()
        val radius = sqrt(i.toFloat() / 240f) * minOf(size.width, size.height) * 0.45f
        drawCircle(Color(0xFFFFB45A).copy(alpha = 0.20f), radius = 1.5f, center = Offset(center.x + cos(angle) * radius, center.y + sin(angle) * radius))
    }
}

private fun DrawScope.drawCrystal(phase: Float) {
    repeat(6) { row ->
        repeat(5) { col ->
            val cx = size.width * (col + 0.5f) / 5f
            val cy = size.height * (row + 0.5f) / 6f
            val r = minOf(size.width, size.height) * (0.08f + 0.01f * sin(phase * PI.toFloat() * 2f + row + col))
            val path = Path()
            repeat(6) { side ->
                val a = side * PI.toFloat() / 3f + phase * 0.2f
                val x = cx + cos(a) * r
                val y = cy + sin(a) * r
                if (side == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            path.close()
            drawPath(path, Color(0xFF76E0D0).copy(alpha = 0.16f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.4f))
        }
    }
}

private fun DrawScope.drawMycelium(phase: Float) {
    repeat(36) { i ->
        val path = Path()
        val sx = size.width * (i % 9) / 8f
        val sy = size.height * (i / 9) / 4f
        path.moveTo(sx, sy)
        repeat(18) { stepIndex ->
            val p = (stepIndex + 1) / 18f
            val x = sx + cos(i.toFloat() + p * 4f + phase * PI.toFloat() * 1.4f) * p * 150f
            val y = sy + sin(i.toFloat() * 1.7f + p * 5f) * p * 110f
            path.lineTo(x, y)
        }
        drawPath(path, Color(0xFF6FD0B0).copy(alpha = 0.12f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.5f))
    }
}

private fun DrawScope.drawMarble(kernel: MobileBackdropKernel, phase: Float) {
    val colors = if (kernel == MobileBackdropKernel.PETROLEUM_SHEEN) {
        listOf(Color.Cyan, Color(0xFFB884FF), Color.Green, Color(0xFFFF8A3D))
    } else {
        listOf(Color(0xFF8FB0E0), Color(0xFFB884FF), Color(0xFFFF8A3D), Color.White)
    }
    repeat(18) { i ->
        val path = Path()
        val y0 = size.height * i / 17f
        repeat(81) { step ->
            val p = step / 80f
            val x = p * size.width
            val y = y0 + sin(p * 10f + i * 0.6f + phase * 3f) * 26f + sin(p * 22f + phase * 1.8f) * 10f
            if (step == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, colors[i % colors.size].copy(alpha = 0.10f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 9f))
    }
}

private fun DrawScope.drawBeam(phase: Float) {
    val sweep = sin(phase * PI.toFloat() * 2f) * size.width * 0.20f
    val cone = Path().apply {
        moveTo(size.width * 0.5f + sweep, size.height * 0.92f)
        lineTo(size.width * 0.15f, size.height * 0.08f)
        lineTo(size.width * 0.78f, size.height * 0.05f)
        close()
    }
    drawPath(cone, Color.White.copy(alpha = 0.16f))
    drawPath(cone, Color(0xFFBFD0FF).copy(alpha = 0.20f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f))
}

private fun DrawScope.drawStorm(phase: Float) {
    drawClouds(MobileBackdropKernel.STORM_SIGNAL, phase)
    repeat(3) { i ->
        val bolt = Path()
        val x = size.width * (0.25f + i * 0.24f) + sin(phase * PI.toFloat() * 2f + i) * 20f
        bolt.moveTo(x, size.height * 0.18f)
        for (step in 1..6) {
            bolt.lineTo(x + (if (step % 2 == 0) -24f else 24f), size.height * (0.18f + step * 0.08f))
        }
        drawPath(bolt, Color.White.copy(alpha = 0.16f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f))
    }
}

private fun DrawScope.drawPlasma(phase: Float) {
    val rows = 18
    val cols = 12
    repeat(rows) { row ->
        repeat(cols) { col ->
            val value = sin(row.toFloat() * 0.8f + phase * 8f) + cos(col.toFloat() * 0.9f + phase * 6f)
            val color = if (value > 0f) Color(0xFF6CE0E8) else Color(0xFFB884FF)
            drawRect(
                color.copy(alpha = 0.09f),
                topLeft = Offset(size.width * col / cols, size.height * row / rows),
                size = androidx.compose.ui.geometry.Size(size.width / cols + 1f, size.height / rows + 1f),
            )
        }
    }
}

private fun DrawScope.drawPaper(phase: Float) {
    repeat(80) { i ->
        val path = Path()
        val y = size.height * i / 80f + sin(i.toFloat() + phase * PI.toFloat()) * 2f
        path.moveTo(0f, y)
        path.lineTo(size.width, y + sin(i * 0.4f) * 6f)
        drawPath(path, Color(0xFF5C2E2A).copy(alpha = 0.05f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 0.6f))
    }
}
