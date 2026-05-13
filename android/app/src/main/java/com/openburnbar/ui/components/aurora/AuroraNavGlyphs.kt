package com.openburnbar.ui.components.aurora

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * Compose-Canvas port of the iOS `AuroraNavigationIcons` custom-drawn nav
 * glyphs. The iOS originals are bespoke SwiftUI Path+Canvas drawings (no
 * SF Symbols, no bundled SVGs); this file reconstructs the geometry in
 * Compose so the Android tray reads the same.
 *
 * Each glyph is a self-contained `@Composable` that fills the supplied
 * size. Selection state drives gradient fills + motion; idle state stays
 * mono-ink. Motion is gated by `LocalAuroraReduceMotion`.
 */

// ── Pulse (heartbeat waveform) ─────────────────────────────────────────────

@Composable
fun PulseGlyph(
    size: Dp,
    isSelected: Boolean,
    modifier: Modifier = Modifier
) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val midY = h * 0.55f
        val padX = w * 0.08f

        // ECG-style heartbeat: long flat → small up tick → sharp R-spike →
        // deep S-trough → bounce-back → flat. Eight control points sketched
        // across the available width.
        val pts = listOf(
            Offset(padX, midY),
            Offset(w * 0.22f, midY),
            Offset(w * 0.32f, midY * 0.85f),
            Offset(w * 0.38f, h * 0.12f),    // sharp peak
            Offset(w * 0.46f, h * 0.88f),    // deep trough
            Offset(w * 0.55f, midY * 0.95f),
            Offset(w * 0.68f, midY),
            Offset(w - padX, midY)
        )

        val line = Path().apply {
            moveTo(pts.first().x, pts.first().y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
        }

        if (isSelected) {
            // Filled area beneath the waveform — ember→amber gradient.
            val area = Path().apply {
                moveTo(pts.first().x, h)
                lineTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                lineTo(pts.last().x, h)
                close()
            }
            drawPath(
                path = area,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        AuroraColors.ember.copy(alpha = 0.55f),
                        AuroraColors.amber.copy(alpha = 0.25f),
                        Color.Transparent
                    )
                )
            )
            drawPath(
                path = line,
                brush = Brush.horizontalGradient(
                    colors = listOf(AuroraColors.ember, AuroraColors.amber)
                ),
                style = Stroke(width = max(1.5f, w * 0.07f), cap = StrokeCap.Round, join = StrokeJoin.Round)
            )
            // Specular highlight blip at the peak
            drawCircle(
                color = Color.White.copy(alpha = 0.85f),
                radius = w * 0.05f,
                center = pts[3]
            )
        } else {
            drawPath(
                path = line,
                color = AuroraColors.hermesMercury.copy(alpha = 0.78f),
                style = Stroke(width = max(1.5f, w * 0.07f), cap = StrokeCap.Round, join = StrokeJoin.Round)
            )
        }
    }
}

// ── Burn (flame + particles) ───────────────────────────────────────────────

@Composable
fun BurnGlyph(
    size: Dp,
    isSelected: Boolean,
    modifier: Modifier = Modifier
) {
    val reduce = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "burn-fire")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "burn-phase"
    )

    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height

        // Flame teardrop — wider at the base, tapering to a point at the top.
        val cx = w / 2f
        val baseY = h * 0.94f
        val tipY = h * 0.10f
        val flame = Path().apply {
            moveTo(cx, tipY)
            cubicTo(
                w * 0.78f, h * 0.30f,
                w * 0.88f, h * 0.65f,
                cx, baseY
            )
            cubicTo(
                w * 0.12f, h * 0.65f,
                w * 0.22f, h * 0.30f,
                cx, tipY
            )
            close()
        }

        // Wick / coal base — a charcoal-tinted rounded bar under the flame.
        val wickRect = Rect(
            offset = Offset(w * 0.30f, h * 0.88f),
            size = Size(w * 0.40f, h * 0.08f)
        )
        val wickPath = Path().apply {
            addRoundRect(RoundRect(wickRect, cornerRadius = androidx.compose.ui.geometry.CornerRadius(h * 0.04f)))
        }

        if (isSelected) {
            // Gradient body
            drawPath(
                path = flame,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        AuroraColors.amber,
                        AuroraColors.ember,
                        AuroraColors.blaze.copy(alpha = 0.85f)
                    )
                )
            )
            // Inner brighter core (heart of the flame)
            val core = Path().apply {
                moveTo(cx, h * 0.30f)
                cubicTo(
                    w * 0.66f, h * 0.46f,
                    w * 0.72f, h * 0.74f,
                    cx, h * 0.82f
                )
                cubicTo(
                    w * 0.28f, h * 0.74f,
                    w * 0.34f, h * 0.46f,
                    cx, h * 0.30f
                )
                close()
            }
            drawPath(
                path = core,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.85f),
                        AuroraColors.amber.copy(alpha = 0.85f),
                        AuroraColors.ember.copy(alpha = 0.3f)
                    )
                ),
                blendMode = BlendMode.Plus
            )
            // Charcoal log
            drawPath(
                path = wickPath,
                brush = Brush.verticalGradient(
                    colors = listOf(Color(0xFF3A1F18), Color(0xFF1B0E0A))
                )
            )
            // Ember dots near the wick edges
            drawCircle(AuroraColors.amber.copy(alpha = 0.85f), w * 0.04f, Offset(w * 0.32f, h * 0.91f))
            drawCircle(AuroraColors.ember.copy(alpha = 0.85f), w * 0.04f, Offset(w * 0.68f, h * 0.91f))

            // Particle simulation — 24 deterministic embers rising from the
            // wick, each on its own offset of the global phase. Reduce-motion
            // freezes them at half-life.
            val particles = 24
            for (i in 0 until particles) {
                val seed = i / particles.toFloat()
                val localPhase = ((phase + seed) % 1f).let { if (reduce) 0.5f else it }
                val lifetime = 1f - localPhase
                if (lifetime <= 0.01f) continue

                // Drift in a cone from wick to above the flame tip.
                val angle = (sin(seed * 2.0 * PI) * 0.45).toFloat()  // -0.45..0.45 radians
                val drift = angle * (localPhase * w * 0.18f)
                val px = cx + drift
                val py = baseY - localPhase * (baseY - tipY * 0.8f)
                // Radius shrinks as they cool.
                val r = (w * 0.035f) * (1f - localPhase * 0.7f)
                val alpha = 0.85f * (1f - localPhase)
                drawCircle(
                    color = lerpColor(AuroraColors.amber, AuroraColors.ember, localPhase).copy(alpha = alpha),
                    radius = r,
                    center = Offset(px, py),
                    blendMode = BlendMode.Plus
                )
            }
        } else {
            // Dormant ember silhouette
            drawPath(
                path = flame,
                color = AuroraColors.hermesMercury.copy(alpha = 0.42f)
            )
            drawPath(
                path = flame,
                color = AuroraColors.hermesMercury.copy(alpha = 0.78f),
                style = Stroke(width = max(1.5f, w * 0.06f), cap = StrokeCap.Round, join = StrokeJoin.Round)
            )
            drawPath(
                path = wickPath,
                color = AuroraColors.hermesMercury.copy(alpha = 0.55f)
            )
        }
    }
}

// ── Streams (vintage TV + SMPTE bars) ──────────────────────────────────────

@Composable
fun StreamsGlyph(
    size: Dp,
    isSelected: Boolean,
    modifier: Modifier = Modifier
) {
    val reduce = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "streams-tv")
    val sweep by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1800, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "streams-sweep"
    )
    val wiggle by transition.animateFloat(
        initialValue = -1f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 620, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "streams-wiggle"
    )

    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height

        // Cabinet (rounded rect, lower 75% of height)
        val cabinetRect = Rect(
            offset = Offset(w * 0.05f, h * 0.30f),
            size = Size(w * 0.90f, h * 0.62f)
        )
        val cabinetPath = Path().apply {
            addRoundRect(RoundRect(cabinetRect, cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.07f)))
        }

        // Screen inside the cabinet
        val screenInset = w * 0.10f
        val screenRect = Rect(
            offset = Offset(cabinetRect.left + screenInset, cabinetRect.top + screenInset),
            size = Size(cabinetRect.width - screenInset * 2, cabinetRect.height - screenInset * 2)
        )
        val screenPath = Path().apply {
            addRoundRect(RoundRect(screenRect, cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.04f)))
        }

        // Antennae — two diagonal lines from top of cabinet
        val antennaBaseLeft = Offset(w * 0.35f, h * 0.32f)
        val antennaBaseRight = Offset(w * 0.65f, h * 0.32f)
        val wiggleAmt = if (reduce) 0f else wiggle * w * 0.02f
        val antennaTipLeft = Offset(w * 0.18f + wiggleAmt, h * 0.06f)
        val antennaTipRight = Offset(w * 0.82f - wiggleAmt, h * 0.06f)

        // Cabinet body
        drawPath(
            path = cabinetPath,
            color = if (isSelected) Color(0xFF1B1729) else AuroraColors.hermesMercury.copy(alpha = 0.42f)
        )
        // Cabinet outline
        drawPath(
            path = cabinetPath,
            color = if (isSelected) AuroraColors.hermesMercury.copy(alpha = 0.7f)
                    else AuroraColors.hermesMercury.copy(alpha = 0.78f),
            style = Stroke(width = max(1.2f, w * 0.04f), join = StrokeJoin.Round)
        )

        // Screen
        if (isSelected) {
            // SMPTE 7-bar pattern revealed by a CRT downward sweep.
            val bars = listOf(
                Color(0xFFFFFFFF), Color(0xFFE5E020), Color(0xFF20DDE5), Color(0xFF36D451),
                Color(0xFFE03BC1), Color(0xFFE03B3B), Color(0xFF3B5BE0)
            )
            val barW = screenRect.width / bars.size
            for ((i, c) in bars.withIndex()) {
                drawRect(
                    color = c.copy(alpha = 0.92f),
                    topLeft = Offset(screenRect.left + i * barW, screenRect.top),
                    size = Size(barW, screenRect.height)
                )
            }
            // Re-clip screen to the rounded screen path so the rectangles
            // don't poke beyond the bezel corners.
            drawPath(
                path = screenPath,
                color = Color.Transparent,
                style = Stroke(width = 0f)
            )
            // Subtle CRT scan line moving down
            val phase = if (reduce) 0.5f else sweep
            val scanY = screenRect.top + screenRect.height * phase
            drawRect(
                color = Color.White.copy(alpha = 0.22f),
                topLeft = Offset(screenRect.left, scanY - 1f),
                size = Size(screenRect.width, max(1.5f, h * 0.012f)),
                blendMode = BlendMode.Plus
            )
            // Bezel highlight
            drawPath(
                path = screenPath,
                color = Color.White.copy(alpha = 0.08f),
                style = Stroke(width = max(1f, w * 0.025f))
            )
        } else {
            drawPath(
                path = screenPath,
                color = Color(0xFF14121E)
            )
            drawPath(
                path = screenPath,
                color = AuroraColors.hermesMercury.copy(alpha = 0.55f),
                style = Stroke(width = max(1f, w * 0.03f))
            )
        }

        // Knobs / chin row
        val chinY = cabinetRect.bottom - h * 0.06f
        for (kx in listOf(w * 0.30f, w * 0.50f, w * 0.70f)) {
            drawCircle(
                color = AuroraColors.hermesMercury.copy(alpha = if (isSelected) 0.85f else 0.55f),
                radius = w * 0.025f,
                center = Offset(kx, chinY)
            )
        }

        // Antennae
        val antennaColor = if (isSelected) AuroraColors.hermesAureate else AuroraColors.hermesMercury.copy(alpha = 0.78f)
        drawLine(
            color = antennaColor,
            start = antennaBaseLeft,
            end = antennaTipLeft,
            strokeWidth = max(1.5f, w * 0.05f),
            cap = StrokeCap.Round
        )
        drawLine(
            color = antennaColor,
            start = antennaBaseRight,
            end = antennaTipRight,
            strokeWidth = max(1.5f, w * 0.05f),
            cap = StrokeCap.Round
        )
        drawCircle(antennaColor, w * 0.025f, antennaTipLeft)
        drawCircle(antennaColor, w * 0.025f, antennaTipRight)
    }
}

// ── Hermes (robot face) ────────────────────────────────────────────────────

@Composable
fun HermesGlyph(
    size: Dp,
    isSelected: Boolean,
    modifier: Modifier = Modifier
) {
    val reduce = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "hermes-pulse")
    val heartPulse by transition.animateFloat(
        initialValue = 0.85f,
        targetValue = 1.15f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1400, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "hermes-heart"
    )

    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val cx = w / 2f
        val accent = if (isSelected) AuroraColors.hermesAureate else AuroraColors.hermesMercury.copy(alpha = 0.78f)
        val muted = AuroraColors.hermesMercury.copy(alpha = 0.45f)

        // Head — rounded square slightly taller than wide
        val headRect = Rect(
            offset = Offset(w * 0.15f, h * 0.22f),
            size = Size(w * 0.70f, h * 0.62f)
        )
        val headPath = Path().apply {
            addRoundRect(RoundRect(headRect, cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.18f)))
        }

        // Earcups (headphones) — small ovals on left/right of head
        val earL = Rect(Offset(headRect.left - w * 0.06f, h * 0.40f), Size(w * 0.10f, h * 0.22f))
        val earR = Rect(Offset(headRect.right - w * 0.04f, h * 0.40f), Size(w * 0.10f, h * 0.22f))
        val earLPath = Path().apply {
            addRoundRect(RoundRect(earL, cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.04f)))
        }
        val earRPath = Path().apply {
            addRoundRect(RoundRect(earR, cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.04f)))
        }

        // Antenna line + heart
        val antennaBottom = Offset(cx, headRect.top)
        val antennaTop = Offset(cx, h * 0.06f)

        if (isSelected) {
            // Head — gradient fill
            drawPath(
                path = headPath,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        AuroraColors.hermesMercury.copy(alpha = 0.85f),
                        AuroraColors.hermesAureate.copy(alpha = 0.65f)
                    )
                )
            )
            drawPath(path = headPath, color = accent, style = Stroke(width = max(1.2f, w * 0.04f)))
            // Earcups
            drawPath(path = earLPath, brush = Brush.verticalGradient(listOf(AuroraColors.hermesMercury, AuroraColors.hermesAureate.copy(alpha = 0.6f))))
            drawPath(path = earRPath, brush = Brush.verticalGradient(listOf(AuroraColors.hermesMercury, AuroraColors.hermesAureate.copy(alpha = 0.6f))))
            // Eyes — radial-gradient glow
            val eyeR = w * 0.075f
            val eyeY = h * 0.50f
            val leftEye = Offset(cx - w * 0.13f, eyeY)
            val rightEye = Offset(cx + w * 0.13f, eyeY)
            for (eyeCenter in listOf(leftEye, rightEye)) {
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(Color.White, AuroraColors.ember, AuroraColors.ember.copy(alpha = 0f)),
                        center = eyeCenter,
                        radius = eyeR * 1.6f
                    ),
                    radius = eyeR,
                    center = eyeCenter
                )
                drawCircle(
                    color = Color.White,
                    radius = eyeR * 0.35f,
                    center = eyeCenter
                )
            }
            // Smile arc
            val smileRect = Rect(
                offset = Offset(cx - w * 0.16f, h * 0.60f),
                size = Size(w * 0.32f, h * 0.12f)
            )
            drawArc(
                color = AuroraColors.ember,
                startAngle = 10f,
                sweepAngle = 160f,
                useCenter = false,
                topLeft = smileRect.topLeft,
                size = smileRect.size,
                style = Stroke(width = max(1.5f, w * 0.05f), cap = StrokeCap.Round)
            )
            // Eye smile arcs (small)
            for ((sx, dir) in listOf(leftEye.x to 1f, rightEye.x to -1f)) {
                val r = Rect(Offset(sx - w * 0.05f, eyeY + h * 0.02f), Size(w * 0.10f, h * 0.05f))
                drawArc(
                    color = AuroraColors.ember.copy(alpha = 0.8f),
                    startAngle = if (dir > 0) 20f else 0f,
                    sweepAngle = 140f,
                    useCenter = false,
                    topLeft = r.topLeft,
                    size = r.size,
                    style = Stroke(width = max(0.8f, w * 0.025f), cap = StrokeCap.Round)
                )
            }
            // Antenna
            drawLine(
                color = accent,
                start = antennaBottom,
                end = antennaTop,
                strokeWidth = max(1.5f, w * 0.04f),
                cap = StrokeCap.Round
            )
            // Heart on antenna
            val pulse = if (reduce) 1f else heartPulse
            drawHeart(
                center = Offset(antennaTop.x, antennaTop.y - h * 0.025f),
                size = w * 0.18f * pulse,
                brush = Brush.verticalGradient(
                    colors = listOf(AuroraColors.ember, AuroraColors.amber)
                )
            )
        } else {
            // Idle: clean outline + soft fill
            drawPath(path = headPath, color = muted)
            drawPath(path = headPath, color = accent, style = Stroke(width = max(1.2f, w * 0.035f)))
            drawPath(path = earLPath, color = muted)
            drawPath(path = earRPath, color = muted)
            // Eyes — solid dots
            val eyeR = w * 0.055f
            val eyeY = h * 0.50f
            drawCircle(accent, eyeR, Offset(cx - w * 0.13f, eyeY))
            drawCircle(accent, eyeR, Offset(cx + w * 0.13f, eyeY))
            // Tiny mouth dash
            drawLine(
                color = accent,
                start = Offset(cx - w * 0.06f, h * 0.66f),
                end = Offset(cx + w * 0.06f, h * 0.66f),
                strokeWidth = max(1.2f, w * 0.035f),
                cap = StrokeCap.Round
            )
            // Antenna
            drawLine(
                color = accent,
                start = antennaBottom,
                end = antennaTop,
                strokeWidth = max(1.2f, w * 0.035f),
                cap = StrokeCap.Round
            )
            drawCircle(accent, w * 0.04f, antennaTop)
        }
    }
}

// ── You (avatar + rotating halo) ───────────────────────────────────────────

@Composable
fun YouGlyph(
    size: Dp,
    isSelected: Boolean,
    photoUrl: String? = null,
    initials: String? = null,
    modifier: Modifier = Modifier
) {
    val reduce = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "you-halo")
    val rotation by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 16_000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "you-rotation"
    )

    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center
    ) {
        // Rotating halo — sweep gradient ring drawn behind the avatar.
        if (isSelected) {
            Canvas(
                modifier = Modifier
                    .size(size)
                    .rotate(if (reduce) 0f else rotation)
            ) {
                val r = this.size.minDimension / 2f
                val center = Offset(this.size.width / 2f, this.size.height / 2f)
                drawCircle(
                    brush = Brush.sweepGradient(
                        colors = listOf(
                            AuroraColors.ember,
                            AuroraColors.amber,
                            AuroraColors.blaze,
                            AuroraColors.ember.copy(alpha = 0f),
                            AuroraColors.ember
                        ),
                        center = center
                    ),
                    radius = r,
                    center = center,
                    style = Stroke(width = r * 0.18f)
                )
            }
        }

        // Avatar — Coil image with initial-fallback circle
        val avatarSize = size * 0.78f
        Box(
            modifier = Modifier
                .size(avatarSize)
                .clip(CircleShape)
                .background(AuroraColors.whimsy.copy(alpha = 0.35f))
                .border(
                    width = if (isSelected) 0.5.dp else 1.dp,
                    color = if (isSelected) AuroraColors.amber.copy(alpha = 0.4f)
                            else AuroraColors.hermesMercury.copy(alpha = 0.55f),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            if (!photoUrl.isNullOrBlank()) {
                AsyncImage(
                    model = photoUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(avatarSize)
                        .clip(CircleShape)
                )
            } else if (!initials.isNullOrBlank()) {
                androidx.compose.material3.Text(
                    text = initials,
                    color = Color.White,
                    fontSize = (avatarSize.value * 0.38f).let { androidx.compose.ui.unit.TextUnit(it, androidx.compose.ui.unit.TextUnitType.Sp) },
                    fontWeight = androidx.compose.ui.text.font.FontWeight.Bold
                )
            }
        }
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

private fun lerpColor(from: Color, to: Color, t: Float): Color {
    val tt = t.coerceIn(0f, 1f)
    return Color(
        red = from.red + (to.red - from.red) * tt,
        green = from.green + (to.green - from.green) * tt,
        blue = from.blue + (to.blue - from.blue) * tt,
        alpha = from.alpha + (to.alpha - from.alpha) * tt
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawHeart(
    center: Offset,
    size: Float,
    brush: Brush
) {
    val half = size / 2f
    val path = Path().apply {
        moveTo(center.x, center.y + half * 0.35f)
        cubicTo(
            center.x + half * 1.2f, center.y - half * 0.4f,
            center.x + half * 0.6f, center.y - half * 1.1f,
            center.x, center.y - half * 0.45f
        )
        cubicTo(
            center.x - half * 0.6f, center.y - half * 1.1f,
            center.x - half * 1.2f, center.y - half * 0.4f,
            center.x, center.y + half * 0.35f
        )
        close()
    }
    drawPath(path = path, brush = brush)
}

// ── Insights (sparkles/star constellation) ─────────────────────────────────

@Composable
fun InsightsGlyph(
    size: Dp,
    isSelected: Boolean,
    isPressed: Boolean = false
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val infiniteTransition = rememberInfiniteTransition(label = "insights")

    val shimmer by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "insightsShimmer"
    )

    Canvas(modifier = Modifier.size(size)) {
        val half = size.toPx() / 2f
        val center = Offset(size.toPx() / 2f, size.toPx() / 2f)
        val brush = if (isSelected) {
            Brush.linearGradient(
                colors = listOf(AuroraColors.purple, AuroraColors.whimsy),
                start = Offset(center.x - half * 0.5f, center.y - half * 0.5f),
                end = Offset(center.x + half * 0.5f, center.y + half * 0.5f)
            )
        } else {
            Brush.linearGradient(
                colors = listOf(AuroraColors.darkTextSecondary, AuroraColors.darkTextSecondary)
            )
        }

        // 4-point star (sparkle) — central
        val starSize = half * 0.7f
        val sparkPath = Path().apply {
            // Vertical diamond
            moveTo(center.x, center.y - starSize)
            lineTo(center.x + starSize * 0.28f, center.y)
            lineTo(center.x, center.y + starSize)
            lineTo(center.x - starSize * 0.28f, center.y)
            close()
            // Horizontal diamond
            moveTo(center.x - starSize, center.y)
            lineTo(center.x, center.y - starSize * 0.28f)
            lineTo(center.x + starSize, center.y)
            lineTo(center.x, center.y + starSize * 0.28f)
            close()
        }
        drawPath(path = sparkPath, brush = brush)

        // Small accent dots around the star
        val dotRadius = size.toPx() * 0.035f
        val dotAlpha = if (isSelected && !reduceMotion) {
            (0.4f + 0.6f * ((shimmer * 4f) % 1f)).coerceIn(0f, 1f)
        } else 0.5f

        drawCircle(
            brush = brush,
            radius = dotRadius,
            center = Offset(center.x + half * 0.65f, center.y - half * 0.65f),
            alpha = dotAlpha
        )
        drawCircle(
            brush = brush,
            radius = dotRadius * 0.8f,
            center = Offset(center.x - half * 0.55f, center.y + half * 0.55f),
            alpha = dotAlpha * 0.7f
        )
    }
}
