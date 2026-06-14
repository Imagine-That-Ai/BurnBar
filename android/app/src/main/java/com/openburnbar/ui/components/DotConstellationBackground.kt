// Compose/Canvas literals (dp/alpha/sample steps); token-per-line extraction obscures the field math.

package com.openburnbar.ui.components

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.R
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import com.openburnbar.ui.settings.rememberExcludeBrandShapesFromSwarm
import com.openburnbar.ui.settings.rememberProviderGlyphs
import com.openburnbar.ui.settings.rememberSwarmSparkles
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.android.awaitFrame
import kotlinx.coroutines.withContext

/**
 * The "Constellation" ambient backdrop ported from the web `DotCrestField`.
 *
 * A calm, slow field: ONE logo at a time resolves out of scattered dots at a
 * RANDOM position, holds while shimmering (per-dot twinkle + a diagonal
 * iridescent sheen), then its dots scatter apart and dissolve — and a DIFFERENT
 * logo resolves into being somewhere new. It cycles the BurnBar crest plus the
 * enabled provider logos (OpenAI, Claude, Codex, Antigravity, Hermes, OpenClaw,
 * Anthropic, Cursor, Gemini, Grok/xAI, Windsurf, Kimi, DeepSeek, Qwen, …). Each
 * dot carries the logo's REAL sampled colour. ~9.5s per logo, slow and elegant.
 *
 * This is a thin, platform-LOCAL renderer: the shared [SwarmSimulation] engine's
 * public API can't be tuned to "one randomly-placed crest-or-provider logo per
 * cycle", so this file owns its own calm cycle while reusing the same proven
 * bitmap-sampling approach (corner-background detection + foreground extraction).
 * Honours Reduce Motion with a single calm, static, fully-resolved frame.
 */
@Composable
fun DotConstellationBackground(modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val isDark = isSystemInDarkTheme()
    val context = LocalContext.current
    val enableSparkles by rememberSwarmSparkles()
    val providerGlyphs by rememberProviderGlyphs()
    val excludeBrandShapes by rememberExcludeBrandShapesFromSwarm()

    val field =
        remember(providerGlyphs, excludeBrandShapes) {
            ConstellationField(
                context = context.applicationContext,
                enabledProviders = providerGlyphs,
                includeCrest = !excludeBrandShapes,
            )
        }

    var version by remember { mutableStateOf(0) }

    // Pre-warm every logo's dot table OFF the main thread before the first draw,
    // so the Canvas never blocks on BitmapFactory.decodeResource. We warm on
    // Dispatchers.Default and bump `version` after each logo so the field fades
    // in as samples arrive rather than stalling a frame.
    LaunchedEffect(field) {
        withContext(Dispatchers.Default) {
            field.prewarm { version++ }
        }
    }

    // Slow ambient clock. Reduce Motion holds a single calm resolved frame.
    LaunchedEffect(reduceMotion) {
        while (!reduceMotion) {
            awaitFrame()
            // Sample the NEXT cycle's logo one cycle ahead, off the main thread,
            // so a logo swap never decodes a bitmap synchronously inside draw().
            field.prefetchNext()
            version++
        }
    }

    Box(
        modifier =
        modifier
            .fillMaxSize()
            // Match the app's deep backdrop so cards stay coherent over the field.
            .background(if (isDark) Color(0xFF050508) else Color(0xFFF3EFE7)),
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val tick = version // read so the Canvas recomposes each frame
            field.draw(
                size = size,
                nowNanos = System.nanoTime(),
                reduceMotion = reduceMotion,
                sparkle = enableSparkles,
                isDark = isDark,
            ) { center, radius, color ->
                drawCircle(color = color, radius = radius, center = center)
            }
        }
    }
}

/** A single sampled dot in a logo's constellation, carrying its real colour. */
private class ConstellationDot(
    val nx: Double,
    val ny: Double,
    val r: Float,
    val g: Float,
    val b: Float,
    val a: Float,
    val scatterX: Double,
    val scatterY: Double,
    val phase: Double,
)

/** One entry in the calm cycle: a logo bitmap reference + its on-screen scale. */
private data class ConstellationLogo(
    @param:DrawableRes val resId: Int,
    val scale: Double,
)

/**
 * Owns the constellation cycle: lazily samples each logo into coloured dots and,
 * each frame, paints exactly one logo through its resolve → hold → scatter arc.
 */
private class ConstellationField(
    private val context: Context,
    enabledProviders: Set<AgentProvider>,
    includeCrest: Boolean,
) {
    private val logos: List<ConstellationLogo> = buildLogoCycle(enabledProviders, includeCrest)

    // Lazily-sampled dot tables, one per logo. Null until first sampled; an empty
    // list means "sampled but unusable" so we skip it for the rest of the session.
    // @Volatile so a value written on Dispatchers.Default is visible to the draw
    // thread on the very next frame without a happens-before fence per element.
    @Volatile
    private var sampled: Array<List<ConstellationDot>?> = arrayOfNulls(logos.size)

    // The logo index draw() last asked to render — read by prefetchNext() so it can
    // sample the FOLLOWING cycle's logo one cycle ahead, off the main thread.
    @Volatile
    private var activeIndex: Int = 0

    private var startNanos: Long = 0L

    /**
     * Samples every logo into its dot table on the calling (background) thread,
     * invoking [onLogoReady] after each so the field can fade in as tables land.
     * Idempotent: an already-sampled logo is skipped.
     */
    fun prewarm(onLogoReady: () -> Unit) {
        for (i in logos.indices) {
            if (sampled[i] == null) {
                sampled[i] = computeSample(i)
                onLogoReady()
            }
        }
    }

    /**
     * Samples the logo that the NEXT cycle will show (one ahead of [activeIndex]),
     * if it isn't ready yet. Called once per frame from a coroutine so a cycle
     * boundary never triggers a synchronous decode inside [draw]. Cheap no-op once
     * the table exists.
     */
    fun prefetchNext() {
        if (logos.isEmpty()) return
        val next = (activeIndex + 1) % logos.size
        if (sampled[next] == null) {
            sampled[next] = computeSample(next)
        }
    }

    private fun buildLogoCycle(enabledProviders: Set<AgentProvider>, includeCrest: Boolean): List<ConstellationLogo> {
        val cycle = ArrayList<ConstellationLogo>()
        // The BurnBar crest anchors the cycle (mirrors the web crest entries).
        if (includeCrest) cycle.add(ConstellationLogo(R.drawable.app_logo, CREST_SCALE))
        // Provider logos in the curated showcase order, filtered to the user's
        // enabled glyphs so this style honours the same provider picker as the swarm.
        AgentProvider.swarmGlyphProviders
            .filter { enabledProviders.contains(it) }
            .forEach { provider -> cycle.add(ConstellationLogo(provider.logoRes, PROVIDER_SCALE)) }
        // A couple of extra brand marks the web reference shows that aren't in the
        // provider showcase set — referenced only because these drawables exist.
        if (includeCrest) {
            cycle.add(ConstellationLogo(R.drawable.logo_anthropic, PROVIDER_SCALE))
            cycle.add(ConstellationLogo(R.drawable.logo_qwen, PROVIDER_SCALE))
        }
        // Never end up with nothing to show: fall back to the crest.
        if (cycle.isEmpty()) cycle.add(ConstellationLogo(R.drawable.app_logo, CREST_SCALE))
        return cycle
    }

    /** Renders the active logo for this frame via [paint] (center, radius, colour). */
    fun draw(size: Size, nowNanos: Long, reduceMotion: Boolean, sparkle: Boolean, isDark: Boolean, paint: (Offset, Float, Color) -> Unit) {
        if (size.width <= 0f || size.height <= 0f || logos.isEmpty()) return
        if (startNanos == 0L) startNanos = nowNanos

        val width = size.width.toDouble()
        val height = size.height.toDouble()

        // baseT: seconds since start. Reduce Motion freezes mid-hold so the frame
        // shows one fully-resolved, calm logo (no animation, no scatter).
        val baseT = if (reduceMotion) 4.0 else (nowNanos - startNanos) / 1_000_000_000.0
        val cyc = baseT / PERIOD_SECONDS
        val cycleNum = floor(cyc).toLong()
        val index = if (reduceMotion) 0 else (cycleNum % logos.size).toInt()
        val phase = if (reduceMotion) 0.5 else (cyc - cycleNum)

        // Record which logo this frame wants so prefetchNext() warms the one after
        // it. NEVER decode here: draw() only reads tables prewarm/prefetch produced.
        activeIndex = index
        val dots = sampled[index] ?: return
        if (dots.isEmpty()) return

        // resolve in (0–0.22), hold, scatter+dissolve out (0.78–1).
        val coherence =
            if (reduceMotion) {
                0.92
            } else {
                smoothstep(0.0, 0.22, phase) * (1.0 - smoothstep(0.78, 1.0, phase))
            }
        if (coherence <= 0.01) return

        val logoSize = min(width, height) * logos[index].scale

        // A NEW place each cycle (hashed), with a gentle local breathing wander.
        val hx = if (reduceMotion) 0.5 else hash(cycleNum * 1.7 + 0.3)
        val hy = if (reduceMotion) 0.46 else hash(cycleNum * 2.3 + 7.1)
        val centerX = (0.2 + 0.6 * hx) * width + if (reduceMotion) 0.0 else sin(baseT * 0.5 + cycleNum) * width * 0.02
        val centerY = (0.22 + 0.54 * hy) * height + if (reduceMotion) 0.0 else cos(baseT * 0.6 + cycleNum) * height * 0.02

        val scatter = (1.0 - coherence) * logoSize * 0.6 // dots fly apart as it dissolves
        val baseDot = max(1.2, (logoSize / SAMPLE_SIDE) * SAMPLE_GAP * 0.5)
        // Diagonal iridescent sheen sweep (kept slow + elegant).
        val sheenSweep = nowNanos / 1_000_000_000.0 * 1.1

        for (d in dots) {
            val twinkle = if (reduceMotion || !sparkle) 0.92 else 0.66 + 0.34 * sin(baseT * 1.7 + d.phase)
            val jitterX = if (reduceMotion) 0.0 else sin(baseT * 2.1 + d.phase) * 0.6
            val jitterY = if (reduceMotion) 0.0 else cos(baseT * 1.8 + d.phase * 1.3) * 0.6

            // Diagonal iridescent sheen: a travelling highlight pushes dots toward white.
            val sheen = if (reduceMotion) 0.25 else (sin((d.nx - d.ny) * 5.5 - sheenSweep) + 1.0) / 2.0
            val highlight = sheen.pow(2.2)
            var red = d.r + (255f - d.r) * highlight.toFloat() * 0.5f
            var green = d.g + (255f - d.g) * highlight.toFloat() * 0.5f
            var blue = d.b + (255f - d.b) * highlight.toFloat() * 0.5f
            // Lift the floor a touch in light mode so deep brand colours still read.
            if (!isDark) {
                red = (red + 14f).coerceAtMost(255f)
                green = (green + 14f).coerceAtMost(255f)
                blue = (blue + 14f).coerceAtMost(255f)
            }

            val alpha = coherence * twinkle * d.a.toDouble() * (0.56 + highlight * 0.24)
            if (alpha <= 0.01) continue

            val px = centerX + d.nx * logoSize + d.scatterX * scatter + jitterX
            val py = centerY + d.ny * logoSize + d.scatterY * scatter + jitterY
            val radius = (baseDot * (0.5 + coherence * 0.5)).toFloat()

            paint(
                Offset(px.toFloat(), py.toFloat()),
                radius,
                Color(
                    red = (red / 255f).coerceIn(0f, 1f),
                    green = (green / 255f).coerceIn(0f, 1f),
                    blue = (blue / 255f).coerceIn(0f, 1f),
                    alpha = alpha.toFloat().coerceIn(0f, 1f),
                ),
            )
        }
    }

    /**
     * Decodes and samples one logo into its coloured dot table. Pure and
     * thread-safe (no shared mutable state); always called OFF the main thread by
     * [prewarm] / [prefetchNext]. An empty list means "decoded but unusable".
     */
    private fun computeSample(index: Int): List<ConstellationDot> = try {
        val bitmap = BitmapFactory.decodeResource(context.resources, logos[index].resId)
        if (bitmap == null) {
            emptyList()
        } else {
            try {
                sampleBitmap(bitmap)
            } finally {
                bitmap.recycle()
            }
        }
    } catch (_: Throwable) {
        emptyList()
    }

    /**
     * Samples a logo bitmap into coloured dots — same approach as the swarm engine:
     * detect the logo's own opaque background from a corner so transparent,
     * white-tile and dark-tile logos all extract cleanly, then keep foreground
     * pixels on a grid, normalised to a centred [-0.5, 0.5] coordinate space.
     */
    private fun sampleBitmap(source: Bitmap): List<ConstellationDot> {
        val width = source.width
        val height = source.height
        if (width <= 0 || height <= 0) return emptyList()

        // Render the logo into a square ARGB sampling buffer (contain-fit, 92%) so
        // spacing and dot density stay consistent regardless of source resolution
        // or config. drawBitmap handles any source config into the ARGB buffer.
        val side = SAMPLE_SIDE
        val buffer = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(buffer)
        val aspect = width.toDouble() / height.toDouble()
        var drawW = side * 0.92
        var drawH = side * 0.92
        if (aspect > 1.0) drawH = drawW / aspect else drawW = drawH * aspect
        val left = ((side - drawW) / 2.0).toFloat()
        val top = ((side - drawH) / 2.0).toFloat()
        canvas.drawBitmap(
            source,
            null,
            android.graphics.RectF(left, top, left + drawW.toFloat(), top + drawH.toFloat()),
            android.graphics.Paint().apply {
                isAntiAlias = true
                isFilterBitmap = true
            },
        )

        val pixels = IntArray(side * side)
        buffer.getPixels(pixels, 0, side, 0, 0, side, side)
        buffer.recycle()

        // Detect the logo's own background from the top-left sample (the contain
        // fit leaves the corners transparent unless the logo carries a tile).
        val corner = pixels[0]
        val bgR = (corner shr 16) and 0xFF
        val bgG = (corner shr 8) and 0xFF
        val bgB = corner and 0xFF
        val bgOpaque = ((corner ushr 24) and 0xFF) > 200

        val dots = ArrayList<ConstellationDot>()
        var y = 0
        while (y < side) {
            var x = 0
            while (x < side) {
                val pixel = pixels[y * side + x]
                val alpha = (pixel ushr 24) and 0xFF
                if (alpha < 48) {
                    x += SAMPLE_GAP
                    continue
                }
                val red = (pixel shr 16) and 0xFF
                val green = (pixel shr 8) and 0xFF
                val blue = pixel and 0xFF
                if (bgOpaque) {
                    val dr = red - bgR
                    val dg = green - bgG
                    val db = blue - bgB
                    if (dr * dr + dg * dg + db * db < 3000) {
                        x += SAMPLE_GAP
                        continue
                    }
                }
                val nx = x.toDouble() / side - 0.5
                val ny = y.toDouble() / side - 0.5
                val angle = pseudo(x * 1.7, y * 0.7) * PI * 2
                val radial = hypot(nx, ny).coerceAtLeast(0.001)
                dots.add(
                    ConstellationDot(
                        nx = nx,
                        ny = ny,
                        r = red.toFloat(),
                        g = green.toFloat(),
                        b = blue.toFloat(),
                        a = alpha / 255f,
                        scatterX = (nx / radial) * 0.65 + cos(angle) * 0.6,
                        scatterY = (ny / radial) * 0.65 + sin(angle) * 0.6,
                        phase = pseudo(x + 3.0, y + 7.0) * PI * 2,
                    ),
                )
                x += SAMPLE_GAP
            }
            y += SAMPLE_GAP
        }
        return dots
    }

    private companion object {
        const val PERIOD_SECONDS = 9.5 // seconds a logo holds before dissolving into the next
        const val SAMPLE_SIDE = 200
        const val SAMPLE_GAP = 4
        const val CREST_SCALE = 0.40
        const val PROVIDER_SCALE = 0.26

        fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
            val span = (edge1 - edge0).let { if (it == 0.0) 1.0 else it }
            val t = ((x - edge0) / span).coerceIn(0.0, 1.0)
            return t * t * (3 - 2 * t)
        }

        fun hash(n: Double): Double {
            val v = sin(n * 127.1 + 311.7) * 43758.5453
            return v - floor(v)
        }

        fun pseudo(x: Double, y: Double): Double {
            val v = sin(x * 12.9898 + y * 78.233) * 43758.5453
            return v - floor(v)
        }
    }
}
