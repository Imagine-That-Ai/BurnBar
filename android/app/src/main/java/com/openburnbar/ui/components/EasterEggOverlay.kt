@file:Suppress("MagicNumber")
// Canvas/particle field math (velocities, gravity, alpha curves, dp/px literals);
// token-per-line extraction would obscure the physics, so values stay inline.

package com.openburnbar.ui.components

import android.content.Context
import android.graphics.BitmapFactory
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Velocity
import com.openburnbar.R
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import com.openburnbar.ui.settings.rememberProviderGlyphs
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.android.awaitFrame
import kotlinx.coroutines.withContext

/**
 * Full-bleed, hit-test-DISABLED celebration overlay that idles at zero cost until
 * "summoned", then plays ONE theme-appropriate easter egg above all content.
 *
 * Triggers (parity with web + iOS):
 *  - **Summon**: rapidly scrolling the main view UP-and-DOWN — ≥ 5 scroll-direction
 *    reversals within ~1.5s — fires a single celebration, then an ~8s cooldown so it
 *    can't spam.
 *      · DARK appearance → **Logo Storm**: BurnBar crests + provider logos POP in
 *        (scale up from 0), drift outward, twinkle, and fade — a few bursts over ~4.5s.
 *      · LIGHT appearance → **Cloud Token Rain**: soft grey clouds wearing cloud-tier
 *        crests drift across the TOP and rain gold/silver token coins that fall under
 *        gravity and BOUNCE off the screen edges as they tumble down (~5.5s).
 *  - **Boundary** ("you've reached the end"): at the very TOP or BOTTOM, trying to
 *    scroll further pops a small cute row of gold/silver tokens that bounce once with
 *    a soft squash (~0.8s), throttled.
 *
 * Reuses ONLY the logos already bundled for the swarm/constellation backgrounds
 * ([AgentProvider.logoRes] + the [R.drawable.app_logo] crest). Honours Reduce Motion
 * (skips bursty motion; plays a single calm frame instead). The Canvas carries NO
 * pointer-input modifier, so it never intercepts touches meant for the content below.
 *
 * Drive it by installing [EasterEggController.nestedScrollConnection] via
 * `Modifier.nestedScroll(...)` on the root that wraps the scrollable content, and
 * mounting [EasterEggOverlay] as the TOP layer of that same root Box.
 */

/** The kind of celebration a summon resolves to, chosen by the colour scheme. */
internal enum class EggKind { LOGO_STORM, CLOUD_TOKEN_RAIN }

/** Which screen edge a boundary nudge fired at. */
internal enum class EdgeSide { TOP, BOTTOM }

/**
 * A queued event the overlay's frame loop consumes exactly once. `internal` (not
 * `private`) so [EasterEggController.pending] — read reactively by the overlay in the
 * same module — does not leak a private-in-file type.
 */
internal sealed interface EggEvent {
    data class Summon(val kind: EggKind, val reduceMotion: Boolean) : EggEvent
    data class Boundary(val side: EdgeSide) : EggEvent
}

/**
 * Holds the rapid-scroll detector and the one-slot event channel between the
 * [NestedScrollConnection] (scroll thread) and the overlay's frame loop. Created
 * via [rememberEasterEggController]; idles with no running timers or particles.
 */
@Stable
class EasterEggController internal constructor() {
    // The pending event the overlay should play next; the loop clears it on read.
    internal var pending by mutableStateOf<EggEvent?>(null)
        private set

    // Direction-reversal ring: timestamps (ms) of recent scroll-direction flips.
    private val reversalTimes = ArrayDeque<Long>(REVERSAL_TARGET + 2)
    private var lastDir = 0 // -1, 0, +1 — sign of the last non-trivial scroll delta
    private var lastSummonAtMs = 0L
    private var lastBoundaryAtMs = 0L

    // Appearance + reduce-motion are pushed in from composition each frame so the
    // scroll-thread callback can pick the right egg without reading composition.
    @Volatile internal var isDark = true
    @Volatile internal var reduceMotion = false

    internal val nestedScrollConnection: NestedScrollConnection =
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                registerScroll(available.y)
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                // `available.y` left unconsumed after the child scrolled = overscroll
                // at an extreme. Positive = pulled past the TOP, negative = past BOTTOM.
                if (source == NestedScrollSource.UserInput && available.y != 0f) {
                    if (available.y > BOUNDARY_THRESHOLD) requestBoundary(EdgeSide.TOP)
                    else if (available.y < -BOUNDARY_THRESHOLD) requestBoundary(EdgeSide.BOTTOM)
                }
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity = Velocity.Zero
        }

    private fun registerScroll(deltaY: Float) {
        if (kotlin.math.abs(deltaY) < MIN_SCROLL_DELTA) return
        val dir = if (deltaY > 0) 1 else -1
        if (lastDir != 0 && dir != lastDir) {
            val now = System.currentTimeMillis()
            reversalTimes.addLast(now)
            // Drop reversals older than the detection window.
            while (reversalTimes.isNotEmpty() && now - reversalTimes.first() > REVERSAL_WINDOW_MS) {
                reversalTimes.removeFirst()
            }
            if (reversalTimes.size >= REVERSAL_TARGET) {
                reversalTimes.clear()
                requestSummon(now)
            }
        }
        lastDir = dir
    }

    private fun requestSummon(now: Long) {
        if (now - lastSummonAtMs < SUMMON_COOLDOWN_MS) return
        lastSummonAtMs = now
        val kind = if (isDark) EggKind.LOGO_STORM else EggKind.CLOUD_TOKEN_RAIN
        pending = EggEvent.Summon(kind, reduceMotion)
    }

    private fun requestBoundary(side: EdgeSide) {
        val now = System.currentTimeMillis()
        if (now - lastBoundaryAtMs < BOUNDARY_COOLDOWN_MS) return
        // Don't let a boundary nudge talk over an active summon celebration.
        if (pending is EggEvent.Summon) return
        lastBoundaryAtMs = now
        pending = EggEvent.Boundary(side)
    }

    /** The overlay's frame loop calls this once it has begun playing [pending]. */
    internal fun consume() {
        pending = null
    }

    internal companion object {
        const val REVERSAL_TARGET = 5 // direction flips needed to summon
        const val REVERSAL_WINDOW_MS = 1500L // …within this window
        const val MIN_SCROLL_DELTA = 1.5f // ignore sub-pixel jitter as a "direction"
        const val SUMMON_COOLDOWN_MS = 8000L
        const val BOUNDARY_COOLDOWN_MS = 1400L
        const val BOUNDARY_THRESHOLD = 6f
    }
}

@Composable
fun rememberEasterEggController(): EasterEggController = remember { EasterEggController() }

/**
 * The TOP-layer celebration canvas. Place it last inside the root Box (over content)
 * and pass the same [controller] whose [EasterEggController.nestedScrollConnection]
 * drives the root's `Modifier.nestedScroll`. Carries NO pointer modifier, so touches
 * pass straight through to the content below.
 */
@Composable
fun EasterEggOverlay(controller: EasterEggController, modifier: Modifier = Modifier) {
    val isDark = isSystemInDarkTheme()
    val reduceMotion = LocalAuroraReduceMotion.current
    val context = LocalContext.current
    val providerGlyphs by rememberProviderGlyphs()

    // Keep the scroll-thread callback's view of appearance current.
    controller.isDark = isDark
    controller.reduceMotion = reduceMotion

    val assets =
        remember(context) { EggAssets(context.applicationContext) }

    // The live scene; null while idle so the Canvas draws nothing and no frames pump.
    var scene by remember { mutableStateOf<EggScene?>(null) }
    var version by remember { mutableStateOf(0) }

    val pending = controller.pending
    LaunchedEffect(pending) {
        val event = pending ?: return@LaunchedEffect
        controller.consume()
        // Load (once, off the main thread) the logos this event needs.
        val logos = withContext(Dispatchers.Default) { assets.logos(providerGlyphs) }
        scene =
            when (event) {
                is EggEvent.Summon ->
                    when (event.kind) {
                        EggKind.LOGO_STORM -> LogoStormScene(logos, event.reduceMotion)
                        EggKind.CLOUD_TOKEN_RAIN -> CloudTokenRainScene(logos, event.reduceMotion)
                    }
                is EggEvent.Boundary -> BoundaryScene(event.side, reduceMotion)
            }
        // Pump frames until the scene reports it has fully faded out, then tear down.
        val started = System.nanoTime()
        while (true) {
            awaitFrame()
            val tSec = (System.nanoTime() - started) / 1_000_000_000.0
            version++ // recompose the Canvas
            if (scene?.isFinished(tSec) != false) break
        }
        scene = null
    }

    val active = scene
    if (active != null) {
        Canvas(modifier = modifier.fillMaxSize()) {
            @Suppress("UNUSED_VARIABLE")
            val tick = version // read so the Canvas repaints each frame
            active.draw(this)
        }
    }
}

// ───────────────────────────── Scenes ─────────────────────────────

/** A self-contained celebration: advances itself from `nowNanos` and paints. */
private interface EggScene {
    /** Paint this frame. Implementations read [System.nanoTime] for their own clock. */
    fun draw(scope: DrawScope)

    /** True once the scene has fully played out (overlay then tears down). */
    fun isFinished(elapsedSeconds: Double): Boolean
}

/** A logo loaded once and cached as an [ImageBitmap] for fast repeated draws. */
private class EggLogo(val image: ImageBitmap)

/** Loads + caches the bundled crest/provider logos as [ImageBitmap]s, off-main. */
private class EggAssets(private val context: Context) {
    @Volatile private var cached: List<EggLogo>? = null

    /**
     * The crest plus the user's enabled provider glyphs, decoded once. Always call
     * from a background dispatcher (decode + RGBA copy is not free).
     */
    fun logos(enabledProviders: Set<AgentProvider>): List<EggLogo> {
        cached?.let { return it }
        val ids = ArrayList<Int>()
        ids.add(R.drawable.app_logo) // the BurnBar crest anchors every burst
        AgentProvider.swarmGlyphProviders
            .filter { enabledProviders.contains(it) }
            .forEach { ids.add(it.logoRes) }
        if (ids.size == 1) {
            // No providers enabled — still give the storm a little variety.
            ids.add(R.drawable.logo_anthropic)
            ids.add(R.drawable.logo_open_ai)
        }
        val result =
            ids.mapNotNull { id -> decode(id)?.let { EggLogo(it) } }
                .ifEmpty { decode(R.drawable.app_logo)?.let { listOf(EggLogo(it)) } ?: emptyList() }
        cached = result
        return result
    }

    private fun decode(@DrawableRes id: Int): ImageBitmap? =
        try {
            val opts = BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888 }
            BitmapFactory.decodeResource(context.resources, id, opts)?.asImageBitmap()
        } catch (_: Throwable) {
            null
        }
}

private fun hash(n: Int): Double {
    val v = sin(n * 127.1 + 311.7) * 43758.5453
    return v - kotlin.math.floor(v)
}

/**
 * DARK "Logo Storm": logos POP in (scale 0→1 with overshoot), drift outward,
 * twinkle, and fade — across a few staggered bursts over ~4.5s. Elegant, not chaotic.
 */
private class LogoStormScene(
    private val logos: List<EggLogo>,
    private val reduceMotion: Boolean,
) : EggScene {
    private val startNanos = System.nanoTime()
    private var seeded = false
    private val sprites = ArrayList<LogoSprite>()

    private class LogoSprite(
        val logo: EggLogo,
        val birth: Double, // seconds after scene start
        val life: Double,
        val originX: Double, // 0..1 of width
        val originY: Double, // 0..1 of height
        val driftX: Double, // px over its life
        val driftY: Double,
        val sizeFrac: Double, // of min(w,h)
        val spin: Double,
        val twinklePhase: Double,
    )

    private fun seed(size: Size) {
        if (seeded || logos.isEmpty()) return
        seeded = true
        if (reduceMotion) {
            // A single calm frame: a gentle ring of crests, no motion.
            val count = min(6, max(3, logos.size))
            for (i in 0 until count) {
                val a = i.toDouble() / count * PI * 2
                sprites.add(
                    LogoSprite(
                        logo = logos[i % logos.size],
                        birth = 0.0,
                        life = CALM_LIFE,
                        originX = 0.5 + cos(a) * 0.26,
                        originY = 0.42 + sin(a) * 0.20,
                        driftX = 0.0,
                        driftY = 0.0,
                        sizeFrac = 0.13,
                        spin = 0.0,
                        twinklePhase = 0.0,
                    ),
                )
            }
            return
        }
        var idx = 0
        for (burst in 0 until BURSTS) {
            val burstAt = burst * BURST_GAP
            val perBurst = 7 + (burst % 2) * 3
            for (k in 0 until perBurst) {
                val h0 = hash(idx * 3 + 1)
                val h1 = hash(idx * 5 + 9)
                val h2 = hash(idx * 7 + 17)
                val h3 = hash(idx * 11 + 23)
                val angle = h2 * PI * 2
                val reach = 90.0 + h3 * 220.0
                sprites.add(
                    LogoSprite(
                        logo = logos[idx % logos.size],
                        birth = burstAt + h0 * 0.5,
                        life = 1.5 + h1 * 1.3,
                        originX = 0.14 + h0 * 0.72,
                        originY = 0.16 + h1 * 0.6,
                        driftX = cos(angle) * reach,
                        driftY = sin(angle) * reach - 40.0, // a gentle upward bias
                        sizeFrac = 0.07 + h3 * 0.07,
                        spin = (h2 - 0.5) * 0.9,
                        twinklePhase = h1 * PI * 2,
                    ),
                )
                idx++
            }
        }
    }

    override fun draw(scope: DrawScope) {
        val size = scope.size
        if (size.width <= 0f || size.height <= 0f) return
        seed(size)
        val t = (System.nanoTime() - startNanos) / 1_000_000_000.0
        val minDim = min(size.width, size.height).toDouble()

        for (s in sprites) {
            val local = t - s.birth
            if (local < 0.0) continue
            if (!reduceMotion && local > s.life) continue
            val p = if (reduceMotion) 0.55 else (local / s.life).coerceIn(0.0, 1.0)

            // Pop-in with overshoot, then ease out; fade in fast, fade out late.
            val popIn = popOvershoot((local / 0.32).coerceIn(0.0, 1.0))
            val fade =
                if (reduceMotion) {
                    0.9
                } else {
                    val rise = (local / 0.25).coerceIn(0.0, 1.0)
                    val fall = 1.0 - smooth(0.62, 1.0, p)
                    rise * fall
                }
            val twinkle = if (reduceMotion) 1.0 else 0.78 + 0.22 * sin(t * 7.0 + s.twinklePhase)
            val alpha = (fade * twinkle).coerceIn(0.0, 1.0)
            if (alpha <= 0.01) continue

            val drift = ease(p)
            val cx = s.originX * size.width + s.driftX * drift
            val cy = s.originY * size.height + s.driftY * drift
            val dim = (minDim * s.sizeFrac * popIn).toFloat()
            if (dim <= 0.5f) continue
            drawLogo(scope, s.logo.image, cx.toFloat(), cy.toFloat(), dim, (s.spin * drift), alpha.toFloat())
        }
    }

    override fun isFinished(elapsedSeconds: Double): Boolean =
        if (reduceMotion) elapsedSeconds > CALM_HOLD else elapsedSeconds > TOTAL

    private companion object {
        const val BURSTS = 3
        const val BURST_GAP = 1.1
        const val TOTAL = 4.8
        const val CALM_LIFE = 99.0
        const val CALM_HOLD = 2.0
    }
}

/**
 * LIGHT "Cloud Token Rain": soft grey clouds wearing cloud-tier crests drift across
 * the TOP and rain gold/silver token coins that fall under gravity and BOUNCE off the
 * screen boundaries as they tumble down, then settle and fade. ~5.5s.
 */
private class CloudTokenRainScene(
    private val logos: List<EggLogo>,
    private val reduceMotion: Boolean,
) : EggScene {
    private var lastNanos = System.nanoTime()
    private var seeded = false
    private val clouds = ArrayList<Cloud>()
    private val coins = ArrayList<Coin>()

    private class Cloud(
        var x: Double,
        val y: Double,
        val vx: Double,
        val scale: Double,
        val crest: EggLogo?,
        var rainTimer: Double,
    )

    private class Coin(
        var x: Double,
        var y: Double,
        var vx: Double,
        var vy: Double,
        val radius: Double,
        val gold: Boolean,
        var spin: Double,
        val spinRate: Double,
        var ttl: Double,
    )

    private fun seed(size: Size) {
        if (seeded) return
        seeded = true
        val crest = logos.firstOrNull()
        val cloudCount = if (reduceMotion) 2 else 3
        for (i in 0 until cloudCount) {
            val h = hash(i * 9 + 3)
            clouds.add(
                Cloud(
                    x = (-0.2 + i * 0.4) * size.width,
                    y = (0.06 + h * 0.10) * size.height.toDouble(),
                    vx = if (reduceMotion) 0.0 else (24.0 + h * 26.0),
                    scale = 0.9 + h * 0.5,
                    crest = crest,
                    rainTimer = h * 0.3,
                ),
            )
        }
    }

    override fun draw(scope: DrawScope) {
        val size = scope.size
        if (size.width <= 0f || size.height <= 0f) return
        seed(size)
        val now = System.nanoTime()
        val dt = ((now - lastNanos) / 1_000_000_000.0).coerceIn(0.0, 0.05)
        lastNanos = now
        val w = size.width.toDouble()
        val h = size.height.toDouble()

        // Advance + draw clouds; each periodically drops a coin.
        for (c in clouds) {
            c.x += c.vx * dt
            if (c.x - 120.0 * c.scale > w) c.x = -160.0 * c.scale
            drawCloud(scope, c.x.toFloat(), c.y.toFloat(), c.scale.toFloat())
            c.crest?.let { drawLogo(scope, it.image, c.x.toFloat(), c.y.toFloat(), (44.0 * c.scale).toFloat(), 0.0, 0.95f) }

            if (!reduceMotion) {
                c.rainTimer -= dt
                if (c.rainTimer <= 0.0 && coins.size < MAX_COINS) {
                    c.rainTimer = 0.22 + hash((c.x.toInt())) * 0.25
                    spawnCoin(c.x + (hash(coins.size * 13) - 0.5) * 90.0 * c.scale, c.y + 18.0 * c.scale)
                }
            }
        }

        if (reduceMotion && coins.isEmpty()) {
            // One calm frame: a few settled coins under each cloud, no physics.
            for (c in clouds) {
                for (k in 0 until 3) {
                    spawnCoin(c.x + (k - 1) * 26.0, h - 30.0 - k * 4.0).apply { vy = 0.0; vx = 0.0 }
                }
            }
        }

        // Advance + draw coins with gravity + boundary bounces.
        val it = coins.iterator()
        while (it.hasNext()) {
            val coin = it.next()
            if (!reduceMotion) {
                coin.vy += GRAVITY * dt
                coin.x += coin.vx * dt
                coin.y += coin.vy * dt
                coin.spin += coin.spinRate * dt
                // Bounce off the side walls.
                if (coin.x < coin.radius) { coin.x = coin.radius; coin.vx = -coin.vx * RESTITUTION }
                if (coin.x > w - coin.radius) { coin.x = w - coin.radius; coin.vx = -coin.vx * RESTITUTION }
                // Bounce off the floor, losing energy until it settles.
                if (coin.y > h - coin.radius) {
                    coin.y = h - coin.radius
                    coin.vy = -coin.vy * RESTITUTION
                    coin.vx *= 0.82
                    if (kotlin.math.abs(coin.vy) < 26.0) { coin.vy = 0.0; coin.ttl -= dt * 1.5 }
                }
                if (coin.y >= h - coin.radius - 0.5 && kotlin.math.abs(coin.vy) < 1.0) coin.ttl -= dt
            }
            coin.ttl -= dt * 0.25
            if (coin.ttl <= 0.0) { it.remove(); continue }
            val alpha = coin.ttl.coerceIn(0.0, 1.0).toFloat()
            drawCoin(scope, coin.x.toFloat(), coin.y.toFloat(), coin.radius.toFloat(), coin.gold, coin.spin, alpha)
        }
    }

    private fun spawnCoin(x: Double, y: Double): Coin {
        val seed = coins.size * 31 + 7
        val coin =
            Coin(
                x = x,
                y = y,
                vx = (hash(seed) - 0.5) * 120.0,
                vy = 20.0 + hash(seed + 1) * 40.0,
                radius = 9.0 + hash(seed + 2) * 5.0,
                gold = hash(seed + 3) > 0.42,
                spin = hash(seed + 4) * PI * 2,
                spinRate = (hash(seed + 5) - 0.5) * 6.0,
                ttl = 2.4 + hash(seed + 6) * 0.8,
            )
        coins.add(coin)
        return coin
    }

    override fun isFinished(elapsedSeconds: Double): Boolean =
        if (reduceMotion) elapsedSeconds > 2.2 else elapsedSeconds > TOTAL && coins.isEmpty()

    private companion object {
        const val GRAVITY = 1500.0
        const val RESTITUTION = 0.62
        const val MAX_COINS = 60
        const val TOTAL = 5.6
    }
}

/**
 * Boundary "you've reached the end": a small row of gold/silver tokens pops up at the
 * struck edge and bounces once with a soft squash, then fades. ~0.8s.
 */
private class BoundaryScene(
    private val side: EdgeSide,
    private val reduceMotion: Boolean,
) : EggScene {
    private val startNanos = System.nanoTime()
    private val count = 5

    override fun draw(scope: DrawScope) {
        val size = scope.size
        if (size.width <= 0f || size.height <= 0f) return
        val t = (System.nanoTime() - startNanos) / 1_000_000_000.0
        val p = (t / DURATION).coerceIn(0.0, 1.0)
        // One up-and-down hop with a soft squash at the apex; quick fade at the end.
        val hop = sin(p * PI) // 0→1→0
        val squash = 1.0 + 0.18 * sin(p * PI * 2)
        val fade = (1.0 - smooth(0.7, 1.0, p)).toFloat()
        if (fade <= 0.01f) return

        val baseY = if (side == EdgeSide.TOP) size.height * 0.085f else size.height * 0.915f
        val dir = if (side == EdgeSide.TOP) 1.0 else -1.0
        val rise = (if (reduceMotion) 6.0 else 26.0) * hop * dir
        val spacing = min(size.width / (count + 1), 64f)
        val startX = size.width / 2f - spacing * (count - 1) / 2f

        for (i in 0 until count) {
            val cx = startX + spacing * i
            val cy = baseY - rise.toFloat()
            val gold = (i % 2 == 0)
            val r = spacing * 0.16f
            drawCoinSquashed(scope, cx, cy, r, squash.toFloat(), gold, fade)
        }
    }

    override fun isFinished(elapsedSeconds: Double): Boolean = elapsedSeconds > DURATION

    private companion object {
        const val DURATION = 0.8
    }
}

// ───────────────────────────── Drawing helpers ─────────────────────────────

private fun drawLogo(scope: DrawScope, image: ImageBitmap, cx: Float, cy: Float, dim: Float, rotationRad: Double, alpha: Float) {
    if (dim <= 0.5f) return
    val srcW = image.width.toFloat()
    val srcH = image.height.toFloat()
    if (srcW <= 0f || srcH <= 0f) return
    val aspect = srcW / srcH
    var w = dim
    var h = dim
    if (aspect > 1f) h = dim / aspect else w = dim * aspect
    // Map the intrinsic-sized bitmap into a `w`×`h` box centred on (cx, cy), spun by
    // `rotationRad`. A single transform stack keeps the draw cheap per frame.
    scope.withTransform({
        rotate(degrees = (rotationRad * 180.0 / PI).toFloat(), pivot = Offset(cx, cy))
        translate(left = cx - w / 2f, top = cy - h / 2f)
        scale(scaleX = w / srcW, scaleY = h / srcH, pivot = Offset.Zero)
    }) {
        drawImage(image = image, alpha = alpha.coerceIn(0f, 1f))
    }
}

/** A soft, layered grey cloud built from overlapping translucent lobes. */
private fun drawCloud(scope: DrawScope, cx: Float, cy: Float, scale: Float) {
    val base = 30f * scale
    val lobes = listOf(
        Triple(-1.1f, 0.15f, 0.9f),
        Triple(0f, -0.25f, 1.25f),
        Triple(1.1f, 0.15f, 0.95f),
        Triple(0.1f, 0.35f, 1.1f),
    )
    for ((dx, dy, s) in lobes) {
        scope.drawCircle(
            color = Color(0xFFB8C0CC).copy(alpha = 0.28f),
            radius = base * s,
            center = Offset(cx + dx * base, cy + dy * base),
        )
    }
    for ((dx, dy, s) in lobes) {
        scope.drawCircle(
            color = Color.White.copy(alpha = 0.55f),
            radius = base * s * 0.86f,
            center = Offset(cx + dx * base, cy + dy * base - base * 0.12f),
        )
    }
}

/** A spinning coin: side-on width shrinks with spin to fake a flat disc tumbling. */
private fun drawCoin(scope: DrawScope, cx: Float, cy: Float, radius: Float, gold: Boolean, spin: Double, alpha: Float) {
    val widthScale = (0.35f + 0.65f * kotlin.math.abs(cos(spin)).toFloat())
    drawCoinFace(scope, cx, cy, radius, widthScale, 1f, gold, alpha)
}

/** A coin with a vertical squash factor (boundary hop). */
private fun drawCoinSquashed(scope: DrawScope, cx: Float, cy: Float, radius: Float, squash: Float, gold: Boolean, alpha: Float) {
    drawCoinFace(scope, cx, cy, radius, 1f, squash, gold, alpha)
}

private fun drawCoinFace(scope: DrawScope, cx: Float, cy: Float, radius: Float, widthScale: Float, heightScale: Float, gold: Boolean, alpha: Float) {
    val rim = if (gold) Color(0xFFB8860B) else Color(0xFF8A8D91)
    val face = if (gold) Color(0xFFFFD24A) else Color(0xFFD9DDE3)
    val shine = if (gold) Color(0xFFFFF1B8) else Color(0xFFF7F9FC)
    scope.withTransform({ scale(scaleX = max(0.05f, widthScale), scaleY = max(0.05f, heightScale), pivot = Offset(cx, cy)) }) {
        drawCircle(color = rim.copy(alpha = alpha), radius = radius, center = Offset(cx, cy), style = Fill)
        drawCircle(color = face.copy(alpha = alpha), radius = radius * 0.82f, center = Offset(cx, cy))
        drawCircle(color = shine.copy(alpha = alpha * 0.85f), radius = radius * 0.28f, center = Offset(cx - radius * 0.22f, cy - radius * 0.22f))
    }
}

// ───────────────────────────── Easing ─────────────────────────────

private fun smooth(edge0: Double, edge1: Double, x: Double): Double {
    val span = (edge1 - edge0).let { if (it == 0.0) 1.0 else it }
    val t = ((x - edge0) / span).coerceIn(0.0, 1.0)
    return t * t * (3 - 2 * t)
}

private fun ease(x: Double): Double = 1.0 - (1.0 - x) * (1.0 - x) // easeOutQuad

/** Pop-in with a gentle overshoot then settle (back-out style). */
private fun popOvershoot(x: Double): Double {
    val c1 = 1.70158
    val c3 = c1 + 1.0
    val t = x - 1.0
    return (1.0 + c3 * t * t * t + c1 * t * t).coerceIn(0.0, 1.25)
}
