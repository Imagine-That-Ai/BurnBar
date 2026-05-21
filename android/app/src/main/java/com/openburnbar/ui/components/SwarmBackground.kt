package com.openburnbar.ui.components

import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Typeface
import android.os.PowerManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.drawscope.Stroke
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlinx.coroutines.android.awaitFrame
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * The active, reconverging token-ember swarm from burnbar.ai, ported to Compose.
 *
 * Hundreds of particles murmurate across the screen, periodically reconverging
 * into "$", "</>", concentric quota rings, and a router failover S-curve —
 * then breaking apart again. Touches push nearby particles away. Reduce
 * Motion pauses the cycling and silences the noise field.
 */
@Composable
fun SwarmBackground(
    accentColor: Color,
    modifier: Modifier = Modifier,
    pace: SwarmPace = SwarmPace.ENERGETIC,
    particleCount: Int = adaptiveParticleCount()
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val config = LocalConfiguration.current
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()

    val simulation = remember(particleCount, pace) {
        SwarmSimulation(particleCount = particleCount, pace = pace)
    }

    var pointer by remember { mutableStateOf<Offset?>(null) }
    var version by remember { mutableStateOf(0) }

    LaunchedEffect(reduceMotion) {
        while (!reduceMotion) {
            awaitFrame()
            simulation.advance(System.nanoTime(), pointer)
            version++  // trigger recomposition for the Canvas
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            // Match app appearance so cards stay coherent over the swarm.
            .background(if (isDark) Color(0xFF050508) else Color(0xFFF3EFE7))
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { pointer = it },
                    onDragEnd = { pointer = null },
                    onDragCancel = { pointer = null }
                ) { change, _ ->
                    pointer = change.position
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        pointer = it
                        tryAwaitRelease()
                        pointer = null
                    }
                )
            }
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            // `version` read inside an enclosing snapshot — read once so Canvas
            // recomposes each frame.
            @Suppress("UNUSED_VARIABLE") val tick = version

            simulation.ensureBounds(size)

            simulation.particles.forEach { p ->
                if (p.isGlyph) return@forEach
                val color = simulation.colorFor(p, accentColor, isDark)
                // Particles forming the active shape render larger so the glyph
                // reads through any glass cards layered on top.
                val inShape = simulation.inShapeMode && p.tx != null
                drawCircle(
                    color = color,
                    radius = (p.size * if (inShape) 1.2 else 0.85).toFloat(),
                    center = Offset(p.x.toFloat(), p.y.toFloat())
                )
            }

            // Glyphs are far fewer — render via native canvas drawText.
            val nativeCanvas = drawContext.canvas.nativeCanvas
            val paint = simulation.glyphPaint
            simulation.particles.forEach { p ->
                if (!p.isGlyph) return@forEach
                val color = simulation.colorFor(p, accentColor, isDark)
                paint.color = color.toArgb()
                nativeCanvas.drawText(p.glyph, p.x.toFloat(), p.y.toFloat(), paint)
            }
        }
    }
}

enum class SwarmPace { ENERGETIC, CINEMATIC }

@Composable
private fun adaptiveParticleCount(): Int {
    val ctx = LocalContext.current
    val pm = ctx.getSystemService(PowerManager::class.java)
    val low = pm?.isPowerSaveMode == true
    val config = LocalConfiguration.current
    val isTabletish = config.smallestScreenWidthDp >= 600
    val base = if (isTabletish) 700 else 360
    return if (low) base / 2 else base
}

// MARK: - Simulation core

internal class SwarmSimulation(
    private val particleCount: Int,
    pace: SwarmPace
) {
    enum class Mode { SWARM, SHAPE_DOLLAR, SHAPE_CODE, SHAPE_RINGS, SHAPE_ROUTER_FLOW }

    class Particle(
        var x: Double, var y: Double,
        var vx: Double, var vy: Double,
        var size: Double,
        val isGlyph: Boolean,
        val glyph: String,
        val colorIndex: Double,
        val baseOpacity: Double,
        var opacity: Double,
        var tx: Double? = null,
        var ty: Double? = null,
        var role: String? = null,
        var flowProgress: Double = 0.0
    )

    // Pace constants — mirror the website.
    private var timeStep: Double = 0.0
    private var swarmNoise: Double = 0.0
    private var swarmDrag: Double = 0.0
    private var maxSpeedGlyph: Double = 0.0
    private var maxSpeedPixel: Double = 0.0
    private var morphAttract: Double = 0.0
    private var morphNoise: Double = 0.0
    private var morphDrag: Double = 0.0
    private var cycleIntervalNanos: Long = 0L
    private var mouseForceMultiplier: Double = 0.0
    private var isEnergetic: Boolean = false

    private val glyphs = listOf("$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache")
    private var activeModes = listOf(
        Mode.SWARM, Mode.SHAPE_DOLLAR, Mode.SWARM, Mode.SHAPE_CODE,
        Mode.SWARM, Mode.SHAPE_RINGS, Mode.SWARM, Mode.SHAPE_ROUTER_FLOW
    )

    val particles: MutableList<Particle> = ArrayList(particleCount)
    private var mode: Mode = Mode.SWARM

    /** True while the swarm is reformed into a shape (not free murmuration). */
    val inShapeMode: Boolean get() = mode != Mode.SWARM
    private var cycleIndex = 0
    private var nextCycleAtNanos: Long = 0
    private var flowTime = 0.0
    private var lastTickNanos: Long = 0
    private var bounds: Size = Size.Zero
    private var initialized = false

    val glyphPaint: Paint = Paint().apply {
        isAntiAlias = true
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        textSize = 20f
        textAlign = Paint.Align.CENTER
    }

    private val dollarPoints by lazy { sampleTextPoints("$", 280f) }
    private val codePoints by lazy { sampleTextPoints("</>", 220f) }
    private val ringPoints by lazy { generateRingPoints() }
    private val routerFlowPoints by lazy { generateRouterFlowPoints() }

    init {
        setPace(pace)
        for (i in 0 until particleCount) {
            particles.add(makeParticle())
        }
    }

    fun setPace(newPace: SwarmPace) {
        when (newPace) {
            SwarmPace.ENERGETIC -> {
                timeStep = 0.000018
                swarmNoise = 0.12
                swarmDrag = 0.985
                maxSpeedGlyph = 1.4
                maxSpeedPixel = 2.4
                morphAttract = 0.6
                morphNoise = 0.045
                morphDrag = 0.88
                cycleIntervalNanos = 8_000_000_000L
                mouseForceMultiplier = 1.8
                isEnergetic = true
            }
            SwarmPace.CINEMATIC -> {
                timeStep = 0.000004
                swarmNoise = 0.02
                swarmDrag = 0.97
                maxSpeedGlyph = 0.35
                maxSpeedPixel = 0.6
                morphAttract = 0.12
                morphNoise = 0.008
                morphDrag = 0.9
                cycleIntervalNanos = 14_000_000_000L
                mouseForceMultiplier = 0.7
                isEnergetic = false
            }
        }
    }

    fun setShapeMode(shapePref: String) {
        when (shapePref) {
            "swarm" -> activeModes = listOf(Mode.SWARM)
            "dollar" -> activeModes = listOf(Mode.SHAPE_DOLLAR)
            "code" -> activeModes = listOf(Mode.SHAPE_CODE)
            "rings" -> activeModes = listOf(Mode.SHAPE_RINGS)
            "router" -> activeModes = listOf(Mode.SHAPE_ROUTER_FLOW)
            "all" -> activeModes = listOf(
                Mode.SWARM, Mode.SHAPE_DOLLAR, Mode.SWARM, Mode.SHAPE_CODE,
                Mode.SWARM, Mode.SHAPE_RINGS, Mode.SWARM, Mode.SHAPE_ROUTER_FLOW
            )
            else -> activeModes = listOf(
                Mode.SWARM, Mode.SHAPE_DOLLAR, Mode.SWARM, Mode.SHAPE_CODE,
                Mode.SWARM, Mode.SHAPE_RINGS, Mode.SWARM, Mode.SHAPE_ROUTER_FLOW
            )
        }
        if (mode !in activeModes) {
            cycleIndex = 0
            assignMode(activeModes[0])
        }
    }

    fun ensureBounds(size: Size) {
        if (size == bounds) return
        if (!initialized) {
            bounds = size
            for (p in particles) {
                p.x = Random.nextDouble() * size.width
                p.y = Random.nextDouble() * size.height
            }
            initialized = true
            return
        }
        val sx = size.width / bounds.width.coerceAtLeast(1f)
        val sy = size.height / bounds.height.coerceAtLeast(1f)
        for (p in particles) {
            p.x *= sx
            p.y *= sy
            p.tx?.let { p.tx = it * sx }
            p.ty?.let { p.ty = it * sy }
        }
        bounds = size
    }

    fun advance(nowNanos: Long, pointer: Offset?) {
        if (!initialized) {
            lastTickNanos = nowNanos
            nextCycleAtNanos = nowNanos + cycleIntervalNanos
            return
        }
        if (nowNanos >= nextCycleAtNanos && activeModes.size > 1) {
            cycleIndex = (cycleIndex + 1) % activeModes.size
            assignMode(activeModes[cycleIndex])
            nextCycleAtNanos = nowNanos + cycleIntervalNanos
        } else if (nowNanos >= nextCycleAtNanos) {
            nextCycleAtNanos = nowNanos + cycleIntervalNanos
        }
        flowTime += timeStep * 1000.0

        val width = bounds.width.toDouble()
        val height = bounds.height.toDouble()
        val px = pointer?.x?.toDouble()
        val py = pointer?.y?.toDouble()

        for (i in particles.indices) {
            stepParticle(i, width, height, px, py)
        }
        lastTickNanos = nowNanos
    }

    private fun stepParticle(
        i: Int,
        width: Double,
        height: Double,
        pointerX: Double?,
        pointerY: Double?
    ) {
        val p = particles[i]
        val noiseX = sin(p.y * 0.005 + flowTime * 2) * cos(p.x * 0.003 + flowTime)
        val noiseY = cos(p.x * 0.005 + flowTime * 3) * sin(p.y * 0.003 + flowTime * 2)

        var pushX = 0.0
        var pushY = 0.0
        if (pointerX != null && pointerY != null) {
            val dx = p.x - pointerX
            val dy = p.y - pointerY
            val dist = sqrt(dx * dx + dy * dy)
            if (dist in 0.001..140.0) {
                val force = (140.0 - dist) / 140.0
                pushX = (dx / dist) * force * mouseForceMultiplier
                pushY = (dy / dist) * force * mouseForceMultiplier
            }
        }

        when (mode) {
            Mode.SWARM -> {
                p.vx += noiseX * swarmNoise + pushX
                p.vy += noiseY * swarmNoise + pushY
                p.vx *= swarmDrag
                p.vy *= swarmDrag
                val speed = sqrt(p.vx * p.vx + p.vy * p.vy)
                val maxSpeed = if (p.isGlyph) maxSpeedGlyph else maxSpeedPixel
                if (speed > maxSpeed && speed > 0) {
                    p.vx = (p.vx / speed) * maxSpeed
                    p.vy = (p.vy / speed) * maxSpeed
                }
                p.x += p.vx
                p.y += p.vy
                if (p.x < 0) p.x = width
                if (p.x > width) p.x = 0.0
                if (p.y < 0) p.y = height
                if (p.y > height) p.y = 0.0
            }
            else -> {
                if (mode == Mode.SHAPE_ROUTER_FLOW && p.role != null) {
                    val role = p.role!!
                    val centerX = width * 0.5
                    val centerY = height * 0.48
                    val scaleFactor = if (width > 960) 0.7 else 0.8
                    val scale = min(width, height) * scaleFactor

                    when {
                        role == "gateway" -> {
                            val angle = p.colorIndex * PI * 2 + flowTime * 15
                            p.tx = centerX + (-0.45 + cos(angle) * 0.08) * scale
                            p.ty = centerY + (sin(angle) * 0.08) * scale
                        }
                        role.startsWith("target-") -> {
                            val tgtY = when (role) {
                                "target-1" -> -0.28
                                "target-3" -> 0.28
                                else -> 0.0
                            }
                            val angle = p.colorIndex * PI * 2 + flowTime * 12
                            p.tx = centerX + (0.45 + cos(angle) * 0.05) * scale
                            p.ty = centerY + (tgtY + sin(angle) * 0.05) * scale
                        }
                        role.startsWith("path-") -> {
                            val tgtY = when (role) {
                                "path-1" -> -0.28
                                "path-3" -> 0.28
                                else -> 0.0
                            }
                            p.flowProgress += if (isEnergetic) 0.006 else 0.003
                            if (p.flowProgress > 1.0) p.flowProgress = 0.0
                            val t = p.flowProgress
                            val pxn = -0.45 + 0.9 * t
                            val pyn = tgtY * (3 * t * t - 2 * t * t * t)
                            p.tx = centerX + pxn * scale
                            p.ty = centerY + pyn * scale
                        }
                    }
                }

                val tx = p.tx
                val ty = p.ty
                if (tx != null && ty != null) {
                    val dx = tx - p.x
                    val dy = ty - p.y
                    val dist = sqrt(dx * dx + dy * dy)
                    if (dist > 1) {
                        p.vx += (dx / dist) * morphAttract
                        p.vy += (dy / dist) * morphAttract
                    }
                    p.vx += noiseX * morphNoise + pushX
                    p.vy += noiseY * morphNoise + pushY
                    p.vx *= morphDrag
                    p.vy *= morphDrag
                    p.x += p.vx
                    p.y += p.vy
                } else {
                    p.vx += noiseX * swarmNoise * 0.75 + pushX
                    p.vy += noiseY * swarmNoise * 0.75 + pushY
                    p.vx *= swarmDrag
                    p.vy *= swarmDrag
                    p.x += p.vx
                    p.y += p.vy
                    if (p.x < 0) p.x = width
                    if (p.x > width) p.x = 0.0
                    if (p.y < 0) p.y = height
                    if (p.y > height) p.y = 0.0
                }
            }
        }
        // Particles that are part of an active shape get a brightness boost so
        // the reformed glyph / rings / router-flow read through glass cards.
        val shapeBoost = if (mode != Mode.SWARM && p.tx != null) 1.7 else 1.0
        p.opacity = (p.baseOpacity * shapeBoost).coerceAtMost(1.0)
    }

    private fun assignMode(next: Mode) {
        mode = next
        if (next == Mode.SWARM) {
            for (p in particles) {
                p.tx = null; p.ty = null; p.role = null
            }
            return
        }

        data class Pt(val x: Double, val y: Double, val role: String?, val progress: Double)
        val pts: List<Pt> = when (next) {
            Mode.SHAPE_DOLLAR -> dollarPoints.map { Pt(it.first, it.second, null, Random.nextDouble()) }
            Mode.SHAPE_CODE -> codePoints.map { Pt(it.first, it.second, null, Random.nextDouble()) }
            Mode.SHAPE_RINGS -> ringPoints.map { Pt(it.first, it.second, null, Random.nextDouble()) }
            Mode.SHAPE_ROUTER_FLOW -> routerFlowPoints.map { Pt(it.x, it.y, it.role, it.progress) }
            else -> emptyList()
        }

        val width = bounds.width.toDouble()
        val height = bounds.height.toDouble()
        var centerX = width * 0.5
        var centerY = height * 0.45
        var scaleFactor = 0.35
        if (width > 960) {
            // Wide layouts: shapes off to the side and high, clear of content.
            when (next) {
                Mode.SHAPE_RINGS -> { centerX = width * 0.78; centerY = height * 0.30; scaleFactor = 0.50 }
                Mode.SHAPE_ROUTER_FLOW -> { centerX = width * 0.5; centerY = height * 0.26; scaleFactor = 0.85 }
                else -> { centerX = width * 0.74; centerY = height * 0.28; scaleFactor = 0.45 }
            }
        } else {
            // Phones: present shapes in the emptier upper band under the nav.
            when (next) {
                Mode.SHAPE_RINGS -> { centerY = height * 0.24; scaleFactor = 0.48 }
                Mode.SHAPE_ROUTER_FLOW -> { centerX = width * 0.5; centerY = height * 0.24; scaleFactor = 0.85 }
                else -> { centerY = height * 0.22; scaleFactor = 0.45 }
            }
        }
        val scale = min(width, height) * scaleFactor

        val indices = particles.indices.toMutableList().also { it.shuffle() }
        for (slot in indices.indices) {
            val particleIdx = indices[slot]
            if (slot < pts.size) {
                val pt = pts[slot]
                particles[particleIdx].tx = centerX + pt.x * scale
                particles[particleIdx].ty = centerY + pt.y * scale
                particles[particleIdx].role = pt.role
                particles[particleIdx].flowProgress = pt.progress
            } else {
                particles[particleIdx].tx = null
                particles[particleIdx].ty = null
                particles[particleIdx].role = null
            }
        }
    }

    fun colorFor(p: Particle, accent: Color, isDark: Boolean = true): Color {
        val raw = p.opacity.toFloat().coerceIn(0f, 1f)
        // Lift the floor slightly in light mode so the deeper palette reads.
        val opacity = if (isDark) raw else (raw + 0.08f).coerceAtMost(1f)

        // Dark mode: bright warm embers on near-black. Light mode: deeper,
        // saturated versions that hold up against the off-white wash.
        val whimsy = if (isDark) Color(0xFF8080FF) else Color(0xFF514DDB)
        val ember  = if (isDark) Color(0xFFFA6B06) else Color(0xFFCC4D00)
        val amber  = if (isDark) Color(0xFFFDC42C) else Color(0xFFC78500)
        val blaze  = if (isDark) Color(0xFFEE1803) else Color(0xFFBD1200)

        if (mode == Mode.SHAPE_ROUTER_FLOW && p.role != null) {
            return when (p.role) {
                "gateway" -> whimsy.copy(alpha = (opacity * 1.6f).coerceAtMost(1f))
                "path-1", "target-1" -> blaze.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
                "path-2", "target-2" -> amber.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
                "path-3", "target-3" -> ember.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
                else -> blaze.copy(alpha = (opacity * 0.35f).coerceAtMost(1f))
            }
        }
        return when {
            p.colorIndex < 0.08 -> whimsy.copy(alpha = opacity)
            p.colorIndex < 0.35 -> ember.copy(alpha = opacity)
            p.colorIndex < 0.62 -> amber.copy(alpha = opacity)
            else -> blaze.copy(alpha = opacity)
        }
    }

    private fun makeParticle(): Particle {
        val isGlyph = Random.nextDouble() < 0.08
        return Particle(
            x = 0.0, y = 0.0,
            vx = (Random.nextDouble() - 0.5) * 1.5,
            vy = (Random.nextDouble() - 0.5) * 1.5,
            size = 1.2 + Random.nextDouble() * 1.8,
            isGlyph = isGlyph,
            glyph = glyphs[Random.nextInt(glyphs.size)],
            colorIndex = Random.nextDouble(),
            baseOpacity = 0.16 + Random.nextDouble() * 0.20,
            opacity = 0.16
        )
    }

    // MARK: shape helpers

    private fun sampleTextPoints(text: String, fontSize: Float): List<Pair<Double, Double>> {
        val side = 400
        val bmp = Bitmap.createBitmap(side, side, Bitmap.Config.ALPHA_8)
        val canvas = android.graphics.Canvas(bmp)
        val paint = Paint().apply {
            isAntiAlias = true
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            textSize = fontSize
            textAlign = Paint.Align.CENTER
            color = 0xFFFFFFFF.toInt()
        }
        val metrics = paint.fontMetrics
        val baseline = side / 2f - (metrics.ascent + metrics.descent) / 2f
        canvas.drawText(text, side / 2f, baseline, paint)

        val pixels = IntArray(side * side)
        val argbBmp = bmp.copy(Bitmap.Config.ARGB_8888, false)
        argbBmp.getPixels(pixels, 0, side, 0, 0, side, side)

        val pts = ArrayList<Pair<Double, Double>>()
        val gap = 5
        var y = 0
        while (y < side) {
            var x = 0
            while (x < side) {
                if ((pixels[y * side + x] ushr 24) and 0xFF > 128) {
                    pts.add(
                        ((x - side / 2).toDouble() / (side / 2)) to
                        ((y - side / 2).toDouble() / (side / 2))
                    )
                }
                x += gap
            }
            y += gap
        }
        bmp.recycle()
        argbBmp.recycle()
        return pts
    }

    private fun generateRingPoints(numRings: Int = 3): List<Pair<Double, Double>> {
        val pts = ArrayList<Pair<Double, Double>>()
        for (ring in 0 until numRings) {
            val radius = 0.2 + ring * 0.25
            val count = 80 + ring * 50
            for (i in 0 until count) {
                val angle = i.toDouble() / count * PI * 2
                pts.add((cos(angle) * radius) to (sin(angle) * radius))
            }
        }
        return pts
    }

    data class RoutePoint(val x: Double, val y: Double, val role: String, val progress: Double)

    private fun generateRouterFlowPoints(): List<RoutePoint> {
        val pts = ArrayList<RoutePoint>()
        val gatewayCount = 100
        for (i in 0 until gatewayCount) {
            val angle = i.toDouble() / gatewayCount * PI * 2
            val r = 0.08
            pts.add(RoutePoint(-0.45 + cos(angle) * r, sin(angle) * r, "gateway", i.toDouble() / gatewayCount))
        }
        data class Tgt(val x: Double, val y: Double, val role: String)
        val targets = listOf(
            Tgt(0.45, -0.28, "target-1"),
            Tgt(0.45,  0.00, "target-2"),
            Tgt(0.45,  0.28, "target-3")
        )
        for (tgt in targets) {
            val count = 50
            for (i in 0 until count) {
                val angle = i.toDouble() / count * PI * 2
                val r = 0.05
                pts.add(RoutePoint(tgt.x + cos(angle) * r, tgt.y + sin(angle) * r, tgt.role, i.toDouble() / count))
            }
        }
        for ((idx, tgt) in targets.withIndex()) {
            val count = 60
            val role = "path-${idx + 1}"
            for (i in 0 until count) {
                val t = i.toDouble() / count
                val px = -0.45 + (tgt.x - -0.45) * t
                val py = tgt.y * (3 * t * t - 2 * t * t * t)
                pts.add(RoutePoint(px, py, role, t))
            }
        }
        return pts
    }
}
