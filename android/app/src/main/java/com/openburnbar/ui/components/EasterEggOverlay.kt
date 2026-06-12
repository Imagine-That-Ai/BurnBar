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
}

/**
 * Holds the rapid-scroll detector and the one-slot event channel between the
 * [NestedScrollConnection] (scroll thread) and the overlay's frame loop. Created
 * via [rememberEasterEggController]; idles with no running timers or particles.
 */
@Stable
class EasterEggController internal constructor() {
    // The pending SUMMON the overlay should play next; the engine clears it on read.
    // Boundary pops ride a separate epoch counter (below) so they coexist with a
    // running takeover instead of fighting it for this single slot.
    internal var pending by mutableStateOf<EggEvent.Summon?>(null)
        private set

    // Boundary channel: every pop bumps [boundaryEpoch] (observed reactively by the
    // engine) and stashes the side. The engine compares the epoch it last drained and
    // injects one row of coins per new epoch — independent of, and concurrent with, any
    // storm/rain takeover. This replaces the old "pending is Summon → drop" guard the
    // review flagged as ineffective (pending was cleared the instant a scene began, so
    // the guard let boundaries clobber an in-flight summon a frame later).
    internal var boundaryEpoch by mutableStateOf(0)
        private set
    @Volatile internal var queuedBoundarySide: EdgeSide = EdgeSide.TOP

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
                if (source == NestedScrollSource.UserInput) registerScroll(available.y)
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                // `available.y` left unconsumed after the child scrolled = the list could
                // not move = we're pinned at an extreme and the user is still pushing.
                // Positive leftover = pulled past the TOP, negative = past the BOTTOM —
                // the Android analog of the web's atTop()/atBottom() + push-further test.
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
        // Count direction CHANGES only (spec §2): a flip pushes one reversal timestamp.
        if (lastDir != 0 && dir != lastDir) {
            val now = System.currentTimeMillis()
            reversalTimes.addLast(now)
            // Evict reversals outside the 1.5 s sliding window.
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
        // Only when idle (no takeover queued or playing) and past the cooldown.
        if (now - lastSummonAtMs < SUMMON_COOLDOWN_MS) return
        if (pending != null) return
        lastSummonAtMs = now
        val kind = if (isDark) EggKind.LOGO_STORM else EggKind.CLOUD_TOKEN_RAIN
        pending = EggEvent.Summon(kind, reduceMotion)
    }

    private fun requestBoundary(side: EdgeSide) {
        val now = System.currentTimeMillis()
        if (now - lastBoundaryAtMs < BOUNDARY_COOLDOWN_MS) return
        lastBoundaryAtMs = now
        queuedBoundarySide = side
        boundaryEpoch++ // engine reacts and injects a pop, coexisting with any takeover
    }

    /** The engine calls this once it has begun playing [pending]. */
    internal fun consumeSummon() {
        pending = null
    }

    internal companion object {
        const val REVERSAL_TARGET = 5 // direction flips needed to summon
        const val REVERSAL_WINDOW_MS = 1500L // …within this 1.5 s window
        const val MIN_SCROLL_DELTA = 2f // ignore sub-pixel jitter as a "direction" (spec |d|>2)
        const val SUMMON_COOLDOWN_MS = 9000L // spec cooldown after a takeover
        const val BOUNDARY_COOLDOWN_MS = 1200L // spec boundary debounce
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

    val assets = remember(context) { EggAssets(context.applicationContext) }

    // ONE long-lived FX engine (spec §1 state machine). It owns mode {idle,storm,rain}
    // plus a boundary-pop pool that coexists with any takeover. `version` bumps each
    // frame to repaint the Canvas; `running` flips the single frame loop on/off.
    val engine = remember { FxEngine() }
    var version by remember { mutableStateOf(0) }
    var running by remember { mutableStateOf(false) }

    // Feed SUMMON events into the engine; it self-schedules its frame loop.
    val pending = controller.pending
    LaunchedEffect(pending) {
        val event = pending ?: return@LaunchedEffect
        controller.consumeSummon()
        val bundle = withContext(Dispatchers.Default) { assets.bundle(providerGlyphs) }
        engine.startSummon(event.kind, event.reduceMotion, bundle)
        running = true
    }

    // Feed BOUNDARY pops (epoch-driven) — they fire independently and coexist.
    val boundaryEpoch = controller.boundaryEpoch
    LaunchedEffect(boundaryEpoch) {
        if (boundaryEpoch == 0) return@LaunchedEffect
        if (reduceMotion) return@LaunchedEffect // spec §6: no boundary pop under reduce-motion
        val bundle = withContext(Dispatchers.Default) { assets.bundle(providerGlyphs) }
        engine.startBoundary(controller.queuedBoundarySide)
        running = true
    }

    // Single frame loop. Runs only while the engine has work; otherwise it parks and the
    // Canvas draws nothing (zero idle cost). Re-armed whenever `running` flips true.
    LaunchedEffect(running) {
        if (!running) return@LaunchedEffect
        while (true) {
            awaitFrame()
            val now = System.nanoTime()
            val alive = engine.tick(now)
            version++ // repaint
            if (!alive) {
                running = false
                version++ // one last clear frame
                break
            }
        }
    }

    // Only mount the Canvas while the engine has work — idle costs nothing (no Canvas in
    // the layout/draw tree, no frames pumping).
    if (running) {
        Canvas(modifier = modifier.fillMaxSize()) {
            val tick = version // read so the Canvas repaints each frame
            engine.draw(this)
        }
    }
}

// ───────────────────────────── Assets ─────────────────────────────

/** A logo loaded once and cached as an [ImageBitmap] for fast repeated draws. */
private class EggLogo(val image: ImageBitmap)

/**
 * The decoded asset bundle a takeover needs: a storm logo array (spec: 2 cloud crests +
 * up to 14 provider glyphs ≈ 16) and the cloud-crest list the rain perches on clouds.
 */
private class EggBundle(val logos: List<EggLogo>, val crests: List<EggLogo>)

/** Loads + caches the bundled crest/provider logos as [ImageBitmap]s, off-main. */
private class EggAssets(private val context: Context) {
    @Volatile private var cached: EggBundle? = null

    /**
     * Decode once: two cloud-tier crests + the BurnBar crest + the user's enabled
     * provider glyphs (capped near the web's 14) → the storm logo array; the two cloud
     * crests alone → the rain's cloud-cap images. Always call off the main thread.
     */
    fun bundle(enabledProviders: Set<AgentProvider>): EggBundle {
        cached?.let { return it }
        // Cloud crests (spec's "two cloud crests"): the Pro + Ultra tier crests.
        val crestIds = listOf(R.drawable.cloud_tier_crest_pro, R.drawable.cloud_tier_crest_ultra)
        val crests = crestIds.mapNotNull { id -> decode(id)?.let { EggLogo(it) } }

        val logoIds = ArrayList<Int>()
        crestIds.forEach { logoIds.add(it) } // crests ride along in the storm swarm too
        logoIds.add(R.drawable.app_logo) // the BurnBar crest anchors every burst
        AgentProvider.swarmGlyphProviders
            .asSequence()
            .filter { enabledProviders.contains(it) }
            .map { it.logoRes }
            .filter { it != 0 }
            .take(PROVIDER_CAP)
            .forEach { logoIds.add(it) }
        if (logoIds.size <= crestIds.size + 1) {
            // No providers enabled — still give the storm brand variety.
            listOf(
                R.drawable.logo_anthropic, R.drawable.logo_open_ai, R.drawable.logo_gemini_cli,
                R.drawable.logo_claude_code, R.drawable.logo_codex, R.drawable.logo_deep_seek,
            ).forEach { logoIds.add(it) }
        }
        val logos =
            logoIds.distinct().mapNotNull { id -> decode(id)?.let { EggLogo(it) } }
                .ifEmpty { decode(R.drawable.app_logo)?.let { listOf(EggLogo(it)) } ?: emptyList() }
        val bundle = EggBundle(logos, crests.ifEmpty { logos.take(2) })
        cached = bundle
        return bundle
    }

    private fun decode(@DrawableRes id: Int): ImageBitmap? =
        try {
            val opts = BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888 }
            BitmapFactory.decodeResource(context.resources, id, opts)?.asImageBitmap()
        } catch (_: Throwable) {
            null
        }

    private companion object {
        const val PROVIDER_CAP = 14 // spec: ~14 provider glyphs alongside the 2 crests → ≈16
    }
}

// ───────────────────────────── FX engine (spec §1 state machine) ─────────────────────────────

/** `mode ∈ {idle, storm, rain}` — what takeover, if any, is currently playing. */
private enum class FxMode { IDLE, STORM, RAIN }

/** Takeover length for BOTH storm and rain (spec FXDUR). */
private const val FX_DURATION_MS = 5000.0

/** The 4 typographic shapes the storm converges into (spec SHAPES). */
private val FX_SHAPES = listOf("$", ":)", "</>", "{ }")

private fun rand(rng: kotlin.random.Random, a: Double, b: Double): Double = a + rng.nextDouble() * (b - a)
private fun clamp01(x: Double): Double = if (x < 0.0) 0.0 else if (x > 1.0) 1.0 else x

/**
 * The single, long-lived easter-egg FX engine — the Android port of the website's
 * `#bgFx` overlay. It owns the `{idle,storm,rain}` state machine PLUS an independent
 * boundary-pop coin pool that COEXISTS with any takeover. One frame loop in the
 * composable drives it; when nothing is alive, [tick] returns false and the loop parks.
 *
 * All simulation runs in [draw] (the only place the live canvas size is known); [tick]
 * just stamps the wall-clock for `dt` and reports the last-known liveness so the loop
 * can stop. Particle objects are pooled / reused — no per-frame allocations on the hot
 * path beyond the occasional spawn, and the shape point-clouds are cached per glyph.
 */
private class FxEngine {
    private var mode = FxMode.IDLE
    private var reduceMotion = false

    // Clock. `nowMs`/`lastMs` are wall-clock ms; `dt` is the clamped per-frame step.
    private var nowMs = 0.0
    private var lastMs = -1.0
    private var dt = 0.016
    private var fxStartMs = 0.0

    // Live canvas size (CSS-px equivalent), refreshed every draw.
    private var w = 0.0
    private var h = 0.0

    // Storm state.
    private var logos: List<EggLogo> = emptyList()
    private val sparks = ArrayList<Spark>()
    private var phaseI = 0
    private val shapeCache = HashMap<String, List<DoubleArray>>() // text → normalized {x,y} points
    private var shapePick = 0
    private val stormRng = kotlin.random.Random(System.nanoTime())

    // Rain state.
    private var crests: List<EggLogo> = emptyList()
    private val clouds = ArrayList<Cloud>()
    private val tokens = ArrayList<Token>()
    private val ledges = ArrayList<DoubleArray>() // {l, r, t}
    private var nextEmitMs = 0.0
    private val rainRng = kotlin.random.Random(System.nanoTime() xor 0x5DEECE66DL)

    // Boundary-pop pool (coexists with any mode).
    private val popCoins = ArrayList<Token>()
    private val popRng = kotlin.random.Random(System.nanoTime() xor 0x12345L)

    private var aliveCache = false

    // ── particles ────────────────────────────────────────────────────────────
    private class Spark(
        var li: Int = 0,
        var x: Double = 0.0, var y: Double = 0.0,
        var vx: Double = 0.0, var vy: Double = 0.0,
        var size: Double = 0.0,
        var rot: Double = 0.0, var vr: Double = 0.0,
        var tw: Double = 0.0,
        var hasTarget: Boolean = false, var tx: Double = 0.0, var ty: Double = 0.0,
    )

    private class Cloud(
        var x: Double = 0.0, var y: Double = 0.0,
        var wid: Double = 0.0, var vx: Double = 0.0,
        var crest: Int = 0, var seed: Double = 0.0,
    )

    /** A coin used by BOTH the rain and the boundary pop (shared edge-flip rendering). */
    private class Token(
        var x: Double = 0.0, var y: Double = 0.0,
        var vx: Double = 0.0, var vy: Double = 0.0,
        var r: Double = 0.0,
        var gold: Boolean = true,
        var flip: Double = 0.0, var vflip: Double = 0.0,
        var tilt: Double = 0.0, var vtilt: Double = 0.0,
        var rest: Int = 0,
        // Boundary-pop only:
        var g: Double = 0.0, var t: Double = 0.0, var ballistic: Boolean = false,
    )

    // ── lifecycle entry points (called from composition) ─────────────────────
    fun startSummon(kind: EggKind, reduce: Boolean, bundle: EggBundle) {
        reduceMotion = reduce
        if (reduce) return // spec §6: reduce-motion disables takeovers entirely
        logos = bundle.logos
        crests = bundle.crests
        // Stamp the clock NOW so fxStart is on the same timeline as later frames.
        nowMs = System.nanoTime() / 1_000_000.0
        if (kind == EggKind.LOGO_STORM) startStorm() else startRain()
        // Re-arm dt so the first frame uses dt = 0.016 (spec).
        lastMs = -1.0
        aliveCache = true
    }

    fun startBoundary(side: EdgeSide) {
        if (reduceMotion) return
        // Defer the actual spawn to the first tick where we know w/h; stash intent.
        pendingPop = side
        aliveCache = true
    }

    private var pendingPop: EdgeSide? = null

    // ── frame loop hooks ──────────────────────────────────────────────────────
    /** Stamp the clock; return whether anything is still alive (loop keeps running). */
    fun tick(nowNanos: Long): Boolean {
        nowMs = nowNanos / 1_000_000.0
        dt = if (lastMs < 0.0) 0.016 else ((nowMs - lastMs) / 1000.0).coerceIn(0.0, 0.05)
        lastMs = nowMs
        return aliveCache
    }

    fun draw(scope: DrawScope) {
        val size = scope.size
        w = size.width.toDouble()
        h = size.height.toDouble()
        if (w <= 0.0 || h <= 0.0) return
        if (nowMs == 0.0) nowMs = System.nanoTime() / 1_000_000.0

        // Drain a queued boundary pop now that w/h are known.
        pendingPop?.let { side -> spawnBoundary(side); pendingPop = null }

        when (mode) {
            FxMode.STORM -> updateStorm(scope)
            FxMode.RAIN -> updateRain(scope)
            FxMode.IDLE -> {}
        }
        updatePop(scope)

        aliveCache = mode != FxMode.IDLE || popCoins.isNotEmpty()
    }

    // ── DARK LOGO STORM (spec §3) ─────────────────────────────────────────────
    private fun startStorm() {
        mode = FxMode.STORM
        fxStartMs = nowMs
        phaseI = 0
        sparks.clear()
        val n = if (logos.isEmpty()) 0 else SPARK_COUNT
        repeat(n) {
            sparks.add(
                Spark(
                    li = (stormRng.nextDouble() * logos.size).toInt().coerceIn(0, logos.size - 1),
                    x = rand(stormRng, 0.0, w), y = rand(stormRng, 0.0, h),
                    size = rand(stormRng, 22.0, 48.0),
                    rot = rand(stormRng, -0.5, 0.5), vr = rand(stormRng, -2.0, 2.0),
                    tw = rand(stormRng, 0.0, 6.28),
                ),
            )
        }
    }

    private fun pickShape(): String {
        val s = FX_SHAPES[shapePick % FX_SHAPES.size]
        shapePick++
        return s
    }

    private fun burstAll() {
        val cx = rand(stormRng, 0.2 * w, 0.8 * w)
        val cy = rand(stormRng, 0.2 * h, 0.62 * h)
        for (p in sparks) {
            p.hasTarget = false
            val ang = kotlin.math.atan2(p.y - cy, p.x - cx) + rand(stormRng, -0.5, 0.5)
            val sp = rand(stormRng, 140.0, 460.0)
            p.vx = cos(ang) * sp
            p.vy = sin(ang) * sp - rand(stormRng, 20.0, 140.0) // slight upward bias
            p.vr = rand(stormRng, -3.0, 3.0)
        }
    }

    private fun toShape(text: String) {
        val pts = samplePoints(text)
        if (pts.isEmpty()) { burstAll(); return }
        val n = sparks.size
        val use: List<DoubleArray> =
            if (pts.size > n) {
                val stride = pts.size.toDouble() / n
                List(n) { i -> pts[(i * stride).toInt().coerceIn(0, pts.size - 1)] }
            } else {
                pts
            }
        val cx = 0.5 * w
        val cy = 0.42 * h
        val sc = min(w, h) * 0.62
        for (j in sparks.indices) {
            val s = sparks[j]
            if (j < use.size) {
                val pt = use[j % use.size]
                s.hasTarget = true
                s.tx = cx + pt[0] * sc
                s.ty = cy + pt[1] * sc
            } else {
                s.hasTarget = false // leftover sparks drift free
            }
        }
    }

    /** Rasterize a glyph to a normalized origin-centred point cloud, cached per string. */
    private fun samplePoints(text: String): List<DoubleArray> {
        shapeCache[text]?.let { return it }
        val dim = 300
        val bmp = android.graphics.Bitmap.createBitmap(dim, dim, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(bmp)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            textAlign = android.graphics.Paint.Align.CENTER
            typeface = android.graphics.Typeface.MONOSPACE
            textSize = 170f
            isFakeBoldText = true
        }
        // Baseline-middle: shift by font metrics so the glyph centres on (150,150).
        val fm = paint.fontMetrics
        val baseline = 150f - (fm.ascent + fm.descent) / 2f
        c.drawText(text, 150f, baseline, paint)
        val pixels = IntArray(dim * dim)
        bmp.getPixels(pixels, 0, dim, 0, 0, dim, dim)
        bmp.recycle()
        val out = ArrayList<DoubleArray>()
        var y = 0
        while (y < dim) {
            var x = 0
            while (x < dim) {
                val alpha = (pixels[y * dim + x] ushr 24) and 0xFF
                if (alpha > 128) out.add(doubleArrayOf((x - 150) / 300.0, (y - 150) / 300.0))
                x += 7
            }
            y += 7
        }
        shapeCache[text] = out
        return out
    }

    private fun runDuePhases() {
        // Offsets from fxStart: +0 burst, +1050 shape, +2250 burst, +3050 shape, +4200 burst.
        val rel = nowMs - fxStartMs
        while (phaseI < PHASE_AT.size && rel >= PHASE_AT[phaseI]) {
            if (PHASE_IS_BURST[phaseI]) burstAll() else toShape(pickShape())
            phaseI++
        }
    }

    private fun updateStorm(scope: DrawScope) {
        runDuePhases()
        val env = clamp01((nowMs - fxStartMs) / 350.0) * clamp01((fxStartMs + FX_DURATION_MS - nowMs) / 650.0)
        val dragHalf = Math.pow(0.5, dt)
        for (p in sparks) {
            if (p.hasTarget) {
                val dx = p.tx - p.x
                val dy = p.ty - p.y
                p.vx += (dx * 150.0 - p.vx * 24.0) * dt
                p.vy += (dy * 150.0 - p.vy * 24.0) * dt
            } else {
                p.vx = p.vx * dragHalf + sin(nowMs * 0.001 + p.tw) * 7.0 * dt
                p.vy = p.vy * dragHalf + 14.0 * dt
            }
            p.x += p.vx * dt
            p.y += p.vy * dt
            p.rot += p.vr * dt
            val a = env * (0.85 + 0.15 * sin(nowMs * 0.012 + p.tw))
            if (a <= 0.0 || logos.isEmpty()) continue
            drawLogo(scope, logos[p.li % logos.size].image, p.x.toFloat(), p.y.toFloat(), p.size.toFloat(), p.rot, a.toFloat())
        }
        if (nowMs > fxStartMs + FX_DURATION_MS) {
            mode = FxMode.IDLE
            sparks.clear()
        }
    }

    // ── LIGHT CLOUD TOKEN RAIN (spec §4) ──────────────────────────────────────
    private fun startRain() {
        mode = FxMode.RAIN
        fxStartMs = nowMs
        tokens.clear()
        clouds.clear()
        nextEmitMs = nowMs + 150.0
        // Ledges: equivalent of the web's DOM rect query. Android has no DOM here, so
        // we synthesize a couple of plausible mid-screen ledges for coins to clatter off
        // (keeps the bounce physics visible without a live view tree).
        ledges.clear()
        ledges.add(doubleArrayOf(w * 0.10, w * 0.50, h * 0.46))
        ledges.add(doubleArrayOf(w * 0.55, w * 0.92, h * 0.62))
        val nc = CLOUD_COUNT
        for (i in 0 until nc) {
            clouds.add(
                Cloud(
                    x = ((i + 0.5) / nc) * w + rand(rainRng, -30.0, 30.0),
                    y = rand(rainRng, 26.0, 120.0),
                    wid = rand(rainRng, 210.0, 360.0),
                    vx = rand(rainRng, -10.0, 10.0),
                    crest = if (crests.isEmpty()) 0 else i % crests.size,
                    seed = rand(rainRng, 0.0, 99.0),
                ),
            )
        }
    }

    private fun emit() {
        for (cl in clouds) {
            val n = 2 + (rainRng.nextDouble() * 3).toInt() // 2..4
            repeat(n) {
                tokens.add(
                    Token(
                        x = cl.x + rand(rainRng, -0.42 * cl.wid, 0.42 * cl.wid),
                        y = cl.y + cl.wid * 0.18,
                        vx = rand(rainRng, -40.0, 40.0),
                        vy = rand(rainRng, 20.0, 90.0),
                        r = rand(rainRng, 5.0, 11.0),
                        gold = rainRng.nextDouble() < 0.5,
                        flip = rand(rainRng, 0.0, 6.28),
                        vflip = rand(rainRng, 5.0, 11.0) * (if (rainRng.nextDouble() < 0.5) 1.0 else -1.0),
                        tilt = rand(rainRng, 0.0, 6.28),
                        vtilt = rand(rainRng, -3.0, 3.0),
                    ),
                )
            }
        }
    }

    private fun updateRain(scope: DrawScope) {
        // Advance + draw clouds first.
        for (cl in clouds) {
            cl.x += cl.vx * dt
            if (cl.x < -cl.wid) cl.x = w + cl.wid
            if (cl.x > w + cl.wid) cl.x = -cl.wid
            val crest = if (crests.isEmpty()) null else crests[cl.crest % crests.size]
            drawCloud(scope, cl.x, cl.y + sin(nowMs * 0.0008 + cl.seed) * 4.0, cl.wid, crest)
        }
        if (nowMs >= nextEmitMs && nowMs < fxStartMs + 4000.0) {
            emit()
            nextEmitMs = nowMs + rand(rainRng, 85.0, 165.0)
        }
        val fade = if (nowMs > fxStartMs + 4300.0) clamp01((fxStartMs + FX_DURATION_MS + 700.0 - nowMs) / 1000.0) else 1.0
        val drag = Math.pow(0.55, dt)
        var i = tokens.size - 1
        while (i >= 0) {
            val t = tokens[i]
            t.vy += 980.0 * dt
            t.vx *= drag
            t.x += t.vx * dt
            t.y += t.vy * dt
            t.flip += t.vflip * dt
            t.tilt += t.vtilt * dt
            // Side walls.
            if (t.x < t.r) { t.x = t.r; t.vx = kotlin.math.abs(t.vx) * 0.5; t.vflip *= 0.85 }
            if (t.x > w - t.r) { t.x = w - t.r; t.vx = -kotlin.math.abs(t.vx) * 0.5; t.vflip *= 0.85 }
            // Ledges (top band only, while falling).
            if (t.vy > 0.0) {
                for (R in ledges) {
                    if (t.x > R[0] - t.r && t.x < R[1] + t.r && t.y > R[2] - t.r && t.y < R[2] + 12.0) {
                        t.y = R[2] - t.r
                        t.vy = -t.vy * 0.5
                        t.vx += rand(rainRng, -30.0, 30.0)
                        t.vflip *= 0.85
                    }
                }
            }
            // Floor.
            if (t.y > h - t.r) {
                t.y = h - t.r
                if (kotlin.math.abs(t.vy) > 55.0) {
                    t.vy = -kotlin.math.abs(t.vy) * 0.48
                    t.vx *= 0.7
                    t.vflip *= 0.7
                } else {
                    t.vy = 0.0
                    t.vx *= 0.82
                    t.vflip *= 0.86
                    t.rest++
                }
            }
            drawToken(scope, t.x, t.y, t.r, t.gold, t.flip, t.tilt, fade.toFloat())
            if (nowMs > fxStartMs + FX_DURATION_MS + 800.0 || t.rest > 26) tokens.removeAt(i)
            i--
        }
        if (nowMs > fxStartMs + FX_DURATION_MS && tokens.isEmpty()) {
            mode = FxMode.IDLE
            clouds.clear()
        }
    }

    // ── BOUNDARY POP (spec §5) ────────────────────────────────────────────────
    private fun spawnBoundary(side: EdgeSide) {
        val top = side == EdgeSide.TOP
        val y0 = if (top) 8.0 else h - 8.0
        val dir = if (top) 1.0 else -1.0
        for (k in 0 until 10) {
            popCoins.add(
                Token(
                    x = ((k + 0.5) / 10.0) * w + rand(popRng, -14.0, 14.0),
                    y = y0,
                    vy = dir * rand(popRng, 280.0, 460.0),
                    g = -dir * 1150.0, // reverse gravity: arcs out, returns to its edge
                    r = rand(popRng, 5.0, 9.0),
                    gold = popRng.nextDouble() < 0.5,
                    flip = rand(popRng, 0.0, 6.28),
                    vflip = rand(popRng, 6.0, 12.0),
                    tilt = rand(popRng, 0.0, 6.28),
                    vtilt = rand(popRng, -2.0, 2.0),
                    ballistic = true,
                ),
            )
        }
    }

    private fun updatePop(scope: DrawScope) {
        if (popCoins.isEmpty()) return
        var i = popCoins.size - 1
        while (i >= 0) {
            val c = popCoins[i]
            c.t += dt
            c.vy += c.g * dt
            c.y += c.vy * dt
            c.flip += c.vflip * dt
            c.tilt += c.vtilt * dt
            val fa = if (c.t > 0.55) clamp01((0.95 - c.t) / 0.4) else 1.0
            drawToken(scope, c.x, c.y, c.r, c.gold, c.flip, c.tilt, fa.toFloat())
            if (c.t > 0.95) popCoins.removeAt(i)
            i--
        }
    }

    private companion object {
        const val SPARK_COUNT = 96
        const val CLOUD_COUNT = 7
        // Phase timeline offsets (ms) from fxStart and whether each is a burst.
        val PHASE_AT = doubleArrayOf(0.0, 1050.0, 2250.0, 3050.0, 4200.0)
        val PHASE_IS_BURST = booleanArrayOf(true, false, true, false, true)
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

/**
 * A large, fluffy, well-defined cloud (spec §4 `puffPath`): four overlapping lobes over
 * a rectangular base, with a soft drop shadow, a vertical body gradient, a bright top
 * highlight, and an optional cloud-tier crest perched on its crest. `cx,cy` is the cloud
 * centre and `width` its full width in px; height = width × 0.46.
 */
private fun drawCloud(scope: DrawScope, cx: Double, cy: Double, width: Double, crest: EggLogo?) {
    val x = cx
    val y = cy
    val w = width
    val hgt = w * 0.46

    // 1) Shadow under the cloud.
    scope.drawPath(puffPath(x, y + 0.30 * hgt, 0.90 * w, 0.70 * hgt), color = Color(0x1A2C3038))

    // 2) Body — vertical light→dark grey gradient.
    val top = (y - 0.7 * hgt).toFloat()
    val bot = (y + 0.7 * hgt).toFloat()
    val body = androidx.compose.ui.graphics.Brush.verticalGradient(
        colorStops = arrayOf(
            0f to Color(0xF0D8DCE2),
            0.55f to Color(0xEBB2B8C0),
            1f to Color(0xE6969CA5),
        ),
        startY = top,
        endY = bot,
    )
    scope.drawPath(puffPath(x, y, w, hgt), brush = body)

    // 3) Highlight crest (bright top).
    scope.drawPath(puffPath(x, y - 0.20 * hgt, 0.66 * w, 0.50 * hgt), color = Color(0x57FFFFFF))

    // 4) Crest image perched above the cloud.
    crest?.let {
        val s = (hgt * 1.05)
        drawLogo(scope, it.image, (x).toFloat(), (y - s * 0.46).toFloat(), s.toFloat(), 0.0, 0.92f)
    }
}

/** Build the spec's closed puff path: 4 arcs + a base rectangle. */
private fun puffPath(x: Double, y: Double, w: Double, h: Double): androidx.compose.ui.graphics.Path {
    val path = androidx.compose.ui.graphics.Path()
    fun lobe(ox: Double, oy: Double, r: Double) {
        path.addOval(
            androidx.compose.ui.geometry.Rect(
                (x + ox - r).toFloat(), (y + oy - r).toFloat(),
                (x + ox + r).toFloat(), (y + oy + r).toFloat(),
            ),
        )
    }
    lobe(-0.34 * w, 0.05 * h, 0.50 * h)
    lobe(-0.12 * w, -0.12 * h, 0.64 * h)
    lobe(0.12 * w, -0.16 * h, 0.68 * h)
    lobe(0.34 * w, 0.02 * h, 0.54 * h)
    path.addRect(
        androidx.compose.ui.geometry.Rect(
            (x - 0.46 * w).toFloat(), (y - 2.0).toFloat(),
            (x - 0.46 * w + 0.92 * w).toFloat(), (y - 2.0 + 0.56 * h).toFloat(),
        ),
    )
    return path
}

/**
 * Gold/silver coin with the spec's EDGE-ON FLIP illusion (§4 `drawToken`): a horizontal
 * `scaleX = |cos(flip)|` squashes the disc toward an edge view, with an in-plane `tilt`
 * rotation. At the extreme it draws a thin rim bar; otherwise a radial-gradient face with
 * an inner rim ring and a specular highlight. Shared by the rain AND the boundary pop.
 */
private fun drawToken(scope: DrawScope, x: Double, y: Double, r: Double, gold: Boolean, flip: Double, tilt: Double, a: Float) {
    if (a <= 0f) return
    val rr = r.toFloat()
    val cx = x.toFloat()
    val cy = y.toFloat()
    val flipS = max(0.12f, kotlin.math.abs(cos(flip)).toFloat())
    scope.withTransform({
        rotate(degrees = (tilt * 180.0 / PI).toFloat(), pivot = Offset(cx, cy))
        scale(scaleX = flipS, scaleY = 1f, pivot = Offset(cx, cy))
    }) {
        if (flipS < 0.16f) {
            // Edge-on: a thin rim bar.
            val edge = if (gold) Color(0xFFB8860B) else Color(0xFF9AA3AD)
            drawRect(
                color = edge.copy(alpha = a),
                topLeft = Offset(cx - 0.22f * rr, cy - rr),
                size = Size(0.44f * rr, 2f * rr),
            )
        } else {
            // Face: radial gradient up-left.
            val faceStops: Array<Pair<Float, Color>> =
                if (gold) {
                    arrayOf(0f to Color(0xFFFFF6D8), 0.45f to Color(0xFFFDC42C), 1f to Color(0xFF9A6B0A))
                } else {
                    arrayOf(0f to Color(0xFFFFFFFF), 0.45f to Color(0xFFE3E9EE), 1f to Color(0xFF929AA6))
                }
            val face = androidx.compose.ui.graphics.Brush.radialGradient(
                colorStops = faceStops,
                center = Offset(cx - 0.35f * rr, cy - 0.40f * rr),
                radius = rr,
            )
            drawCircle(brush = face, radius = rr, center = Offset(cx, cy), alpha = a)
            // Inner rim ring.
            val ring = if (gold) Color(0xFF7C5208) else Color(0xFF7D858F)
            drawCircle(
                color = ring.copy(alpha = a * 0.6f),
                radius = 0.82f * rr,
                center = Offset(cx, cy),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = max(1f, 0.13f * rr)),
            )
            // Specular highlight.
            drawCircle(
                color = Color.White.copy(alpha = a * 0.85f * 0.75f),
                radius = 0.22f * rr,
                center = Offset(cx - 0.32f * rr, cy - 0.34f * rr),
            )
        }
    }
}

// ───────────────────────────── Easing ─────────────────────────────

/**
 * Overshoot ease (spec §7): defined for parity with the web engine. The storm/rain/
 * boundary paths use spring + ballistic integration directly and don't call it, so it is
 * kept the reference implementation hook rather than deleted it.
 */
private fun easeOutBack(x: Double): Double {
    val c1 = 1.70158
    val c3 = c1 + 1.0
    val t = x - 1.0
    return 1.0 + c3 * t * t * t + c1 * t * t
}
