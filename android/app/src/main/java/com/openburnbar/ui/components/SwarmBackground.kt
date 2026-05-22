package com.openburnbar.ui.components

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlinx.coroutines.android.awaitFrame
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * The active, reconverging token-ember swarm from burnbar.ai, ported to Compose.
 *
 * Hundreds of particles murmurate across the screen, periodically reconverging
 * into "$", "</>", provider logos, Grok/xAI marks, concentric quota rings, and
 * a router failover S-curve — then breaking apart again. Touches push nearby
 * particles away. Reduce Motion pauses the cycling and silences the noise field.
 */
@Composable
fun SwarmBackground(
    accentColor: Color,
    modifier: Modifier = Modifier,
    pace: SwarmPace = SwarmPace.ENERGETIC,
    particleCount: Int = adaptiveParticleCount(),
    enabledProviderGlyphs: Set<AgentProvider>? = null
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val context = LocalContext.current
    val config = LocalConfiguration.current
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()

    val selectedProviderGlyphs = enabledProviderGlyphs ?: AgentProvider.swarmGlyphProviders.toSet()
    val simulation = remember(particleCount, pace, selectedProviderGlyphs) {
        SwarmSimulation(
            particleCount = particleCount,
            pace = pace,
            context = context.applicationContext,
            enabledProviderGlyphs = selectedProviderGlyphs
        )
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
    val base = if (isTabletish) 1080 else 520
    return if (low) base / 2 else base
}

// MARK: - Simulation core

internal class SwarmSimulation(
    private val particleCount: Int,
    pace: SwarmPace,
    context: Context? = null,
    enabledProviderGlyphs: Set<AgentProvider> = AgentProvider.swarmGlyphProviders.toSet(),
    private val clockNanos: () -> Long = System::nanoTime
) {
    private val appContext = context?.applicationContext

    enum class Mode {
        SWARM,
        SHAPE_DOLLAR,
        SHAPE_CODE,
        SHAPE_RINGS,
        SHAPE_ROUTER_FLOW,
        SHAPE_XAI_LOGO,
        SHAPE_GROK_LOGO,
        SHAPE_PROVIDER_LOGOS
    }

    class Particle(
        var x: Double, var y: Double,
        var vx: Double, var vy: Double,
        var size: Double,
        var isGlyph: Boolean,
        val glyph: String,
        val colorIndex: Double,
        val baseOpacity: Double,
        var opacity: Double,
        var tx: Double? = null,
        var ty: Double? = null,
        var role: String? = null,
        var logoColor: Color? = null,
        var flowProgress: Double = 0.0
    )

    data class ShapePoint(
        val x: Double,
        val y: Double,
        val role: String?,
        val progress: Double,
        val color: Color? = null
    )

    private data class ProviderLogoSpec(
        val provider: AgentProvider,
        val points: List<ShapePoint>
    )

    private data class ProviderLogoSlot(
        val centerX: Double,
        val centerY: Double,
        val scale: Double
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

    private val providerLogoShowcase = AgentProvider.swarmGlyphProviders
    private var enabledProviderLogos = normalizeProviderGlyphs(enabledProviderGlyphs)
    private var providerLogoBatches = enabledProviderLogos.chunked(6)
    private var providerLogoBatchIndex = 0
    private var shapePreference = "all"

    internal val providerLogoShowcaseKeys: Set<String>
        get() = providerLogoShowcase.mapTo(linkedSetOf()) { it.key }

    internal val enabledProviderLogoKeys: Set<String>
        get() = enabledProviderLogos.mapTo(linkedSetOf()) { it.key }

    private val glyphs = listOf("$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache")
    private var activeModes = defaultModes()

    val particles: MutableList<Particle> = ArrayList(particleCount)
    private var mode: Mode = Mode.SWARM

    /** True while the swarm is reformed into a shape (not free murmuration). */
    val inShapeMode: Boolean get() = mode != Mode.SWARM
    private var cycleIndex = 0
    private var nextCycleAtNanos: Long = 0
    private var modeAssignedAtNanos: Long = 0
    private var shapeSettledAtNanos: Long? = null
    private var flowTime = 0.0
    private var lastTickNanos: Long = 0
    private var bounds: Size = Size.Zero
    private var initialized = false

    val glyphPaint: Paint by lazy {
        Paint().apply {
            isAntiAlias = true
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            textSize = 20f
            textAlign = Paint.Align.CENTER
        }
    }

    private val dollarPoints by lazy { sampleTextPoints("$", 280f) }
    private val codePoints by lazy { sampleTextPoints("</>", 220f) }
    private val ringPoints by lazy { generateRingPoints() }
    private val routerFlowPoints by lazy { generateRouterFlowPoints() }
    private val providerLogoPointCache by lazy {
        providerLogoShowcase.associateWith { provider ->
            logoPoints(provider, fallbackLogoPoints(provider))
        }
    }
    private val xAiLogoPoints by lazy { generateXAILogoPoints() }
    private val grokLogoPoints by lazy { logoPoints(AgentProvider.XAI, generateGrokLogoPoints()) }

    private companion object {
        private const val SHAPE_ADMIRE_HOLD_NANOS = 4_000_000_000L
        private const val SHAPE_SETTLE_RECHECK_NANOS = 250_000_000L
        private const val SHAPE_SETTLE_FALLBACK_NANOS = 6_000_000_000L
        private const val SHAPE_SETTLED_PARTICLE_FRACTION = 0.82
    }

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

    fun setEnabledProviderGlyphs(providers: Set<AgentProvider>) {
        enabledProviderLogos = normalizeProviderGlyphs(providers)
        providerLogoBatches = enabledProviderLogos.chunked(6)
        providerLogoBatchIndex = 0
        applyShapeMode(shapePreference)
    }

    fun setShapeMode(shapePref: String) {
        shapePreference = shapePref
        applyShapeMode(shapePref)
    }

    private fun applyShapeMode(shapePref: String) {
        when (shapePref) {
            "swarm" -> activeModes = listOf(Mode.SWARM)
            "dollar" -> activeModes = listOf(Mode.SHAPE_DOLLAR)
            "code" -> activeModes = listOf(Mode.SHAPE_CODE)
            "rings" -> activeModes = listOf(Mode.SHAPE_RINGS)
            "router" -> activeModes = listOf(Mode.SHAPE_ROUTER_FLOW)
            "xai" -> activeModes = if (enabledProviderLogos.contains(AgentProvider.XAI)) {
                listOf(Mode.SHAPE_XAI_LOGO)
            } else {
                listOf(Mode.SWARM)
            }
            "grok" -> activeModes = if (enabledProviderLogos.contains(AgentProvider.XAI)) {
                listOf(Mode.SHAPE_GROK_LOGO)
            } else {
                listOf(Mode.SWARM)
            }
            "providers" -> {
                providerLogoBatchIndex = 0
                activeModes = if (providerLogoBatches.isEmpty()) {
                    listOf(Mode.SWARM)
                } else {
                    List(providerLogoBatches.size) { Mode.SHAPE_PROVIDER_LOGOS }
                }
            }
            "all" -> activeModes = defaultModes()
            else -> activeModes = defaultModes()
        }
        cycleIndex = 0
        val nowNanos = if (lastTickNanos > 0L) lastTickNanos else clockNanos()
        assignMode(activeModes[0], nowNanos)
        nextCycleAtNanos = nowNanos + cycleIntervalNanos
    }

    private fun normalizeProviderGlyphs(providers: Set<AgentProvider>): List<AgentProvider> =
        providerLogoShowcase.filter { providers.contains(it) }

    fun ensureBounds(size: Size) {
        if (size == bounds) return
        if (!initialized) {
            bounds = size
            for (p in particles) {
                p.x = Random.nextDouble() * size.width
                p.y = Random.nextDouble() * size.height
            }
            initialized = true
            if (mode != Mode.SWARM) {
                assignMode(mode, lastTickNanos.takeIf { it > 0L } ?: clockNanos())
            }
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
            if (shouldDelayCycleForAdmireHold(nowNanos)) {
                nextCycleAtNanos = nowNanos + SHAPE_SETTLE_RECHECK_NANOS
            } else {
                cycleIndex = (cycleIndex + 1) % activeModes.size
                assignMode(activeModes[cycleIndex], nowNanos)
                nextCycleAtNanos = nowNanos + cycleIntervalNanos
            }
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

    private fun assignMode(next: Mode, assignedAtNanos: Long = clockNanos()) {
        mode = next
        modeAssignedAtNanos = assignedAtNanos
        shapeSettledAtNanos = null
        if (next == Mode.SWARM) {
            for (p in particles) {
                p.tx = null; p.ty = null; p.role = null; p.logoColor = null
            }
            return
        }

        when (next) {
            Mode.SHAPE_XAI_LOGO -> {
                assignProviderLogos(listOf(ProviderLogoSpec(AgentProvider.XAI, xAiLogoPoints)))
                return
            }
            Mode.SHAPE_GROK_LOGO -> {
                assignProviderLogos(listOf(ProviderLogoSpec(AgentProvider.XAI, grokLogoPoints)))
                return
            }
            Mode.SHAPE_PROVIDER_LOGOS -> {
                if (providerLogoBatches.isEmpty()) {
                    assignMode(Mode.SWARM, assignedAtNanos)
                    return
                }
                val batch = providerLogoBatches
                    .getOrNull(providerLogoBatchIndex % providerLogoBatches.size)
                    ?: enabledProviderLogos
                providerLogoBatchIndex = (providerLogoBatchIndex + 1) % providerLogoBatches.size
                assignProviderLogos(batch.map { provider ->
                    ProviderLogoSpec(provider, providerLogoPoints(provider))
                })
                return
            }
            else -> Unit
        }

        val pts: List<ShapePoint> = when (next) {
            Mode.SHAPE_DOLLAR -> dollarPoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
            Mode.SHAPE_CODE -> codePoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
            Mode.SHAPE_RINGS -> ringPoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
            Mode.SHAPE_ROUTER_FLOW -> routerFlowPoints.map { ShapePoint(it.x, it.y, it.role, it.progress) }
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
                particles[particleIdx].logoColor = null
                particles[particleIdx].flowProgress = pt.progress
            } else {
                particles[particleIdx].tx = null
                particles[particleIdx].ty = null
                particles[particleIdx].role = null
                particles[particleIdx].logoColor = null
            }
        }
    }

    private fun assignProviderLogos(specs: List<ProviderLogoSpec>) {
        val visibleSpecs = specs.filter { it.points.isNotEmpty() }
        if (visibleSpecs.isEmpty()) {
            assignMode(Mode.SWARM)
            return
        }

        val groups: List<MutableList<Int>> = List(visibleSpecs.size) { mutableListOf() }
        val indices = particles.indices.toMutableList().also { it.shuffle() }
        for ((slot, particleIdx) in indices.withIndex()) {
            groups[slot % visibleSpecs.size].add(particleIdx)
        }

        val width = bounds.width.toDouble()
        val height = bounds.height.toDouble()
        val slots = providerLogoSlots(visibleSpecs.size, width, height)

        for (specIndex in visibleSpecs.indices) {
            val spec = visibleSpecs[specIndex]
            val points = spec.points
            val logoSlot = slots[specIndex]
            val group = groups[specIndex]
            for ((slot, particleIdx) in group.withIndex()) {
                val pointIndex = if (group.size <= points.size) {
                    val t = slot.toDouble() / (group.size - 1).coerceAtLeast(1).toDouble()
                    ((points.size - 1) * t).toInt().coerceAtMost(points.size - 1)
                } else {
                    slot % points.size
                }
                val pt = points[pointIndex]
                val role = pt.role ?: "logo-flame-inner"
                particles[particleIdx].tx = logoSlot.centerX + pt.x * logoSlot.scale
                particles[particleIdx].ty = logoSlot.centerY + pt.y * logoSlot.scale
                particles[particleIdx].role = "$role:${spec.provider.key}"
                particles[particleIdx].isGlyph = false
                particles[particleIdx].logoColor = pt.color
                particles[particleIdx].flowProgress = pt.progress
            }
        }
    }

    private fun shouldDelayCycleForAdmireHold(nowNanos: Long): Boolean {
        if (!mode.requiresSettledAdmireHold()) return false

        if (shapeSettledAtNanos == null) {
            if (
                currentShapeIsSettled() ||
                nowNanos - modeAssignedAtNanos >= cycleIntervalNanos + SHAPE_SETTLE_FALLBACK_NANOS
            ) {
                shapeSettledAtNanos = nowNanos
            } else {
                return true
            }
        }

        val settledAt = shapeSettledAtNanos ?: return true
        return nowNanos < settledAt + SHAPE_ADMIRE_HOLD_NANOS
    }

    private fun Mode.requiresSettledAdmireHold(): Boolean =
        this != Mode.SWARM && this != Mode.SHAPE_ROUTER_FLOW

    private fun currentShapeIsSettled(): Boolean {
        val threshold = maxOf(22.0, min(bounds.width, bounds.height).toDouble() * 0.022)
        var targeted = 0
        var close = 0
        var totalDistance = 0.0

        for (p in particles) {
            val tx = p.tx ?: continue
            val ty = p.ty ?: continue
            targeted++
            val distance = sqrt((tx - p.x) * (tx - p.x) + (ty - p.y) * (ty - p.y))
            totalDistance += distance
            if (distance <= threshold) {
                close++
            }
        }

        if (targeted == 0) return true
        val closeFraction = close.toDouble() / targeted.toDouble()
        val averageDistance = totalDistance / targeted.toDouble()
        return closeFraction >= SHAPE_SETTLED_PARTICLE_FRACTION && averageDistance <= threshold * 1.75
    }

    private fun providerLogoPoints(provider: AgentProvider): List<ShapePoint> {
        if (provider == AgentProvider.XAI) return xAiLogoPoints
        return providerLogoPointCache[provider] ?: logoPoints(provider, fallbackLogoPoints(provider))
    }

    fun colorFor(p: Particle, accent: Color, isDark: Boolean = true): Color {
        val raw = p.opacity.toFloat().coerceIn(0f, 1f)
        // Lift the floor slightly in light mode so the deeper palette reads.
        val opacity = if (isDark) raw else (raw + 0.08f).coerceAtMost(1f)

        parseRoleAndProvider(p.role)?.let { (role, provider) ->
            p.logoColor?.let { source ->
                return contrastAdjustedSourceLogoColor(source).copy(alpha = (opacity * 1.62f).coerceAtMost(1f))
            }
            return providerLogoColor(provider, role, opacity, isDark)
        }

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

    private fun providerLogoColor(provider: AgentProvider, role: String, opacity: Float, isDark: Boolean): Color {
        val brand = if (provider == AgentProvider.XAI && isDark) {
            Color(0xFFECEFF4)
        } else {
            Color(provider.brandColor)
        }
        val accent = Color(provider.accentColor)
        val hot = blend(brand, Color.White, if (role == "logo-flame-inner") 0.28f else 0.16f)
        val shadow = blend(brand, if (isDark) Color.Black else Color.DarkGray, if (role == "logo-flame-outer") 0.34f else 0.18f)
        val spark = blend(accent, Color.White, 0.34f)
        val color = when (role) {
            "logo-flame-outer" -> blend(shadow, brand, 0.34f)
            "logo-flame-spark" -> spark
            else -> blend(brand, hot, 0.52f)
        }
        val alphaMultiplier = when (role) {
            "logo-flame-outer" -> 1.44f
            "logo-flame-spark" -> 1.72f
            else -> 1.62f
        }
        return color.copy(alpha = (opacity * alphaMultiplier).coerceAtMost(1f))
    }

    private fun contrastAdjustedSourceLogoColor(color: Color): Color {
        val luminance = 0.2126f * color.red + 0.7152f * color.green + 0.0722f * color.blue
        return when {
            luminance < 0.08f -> Color(0xFFD6DBE5)
            luminance < 0.22f -> blend(color, Color.White, 0.46f)
            else -> color
        }
    }

    private fun parseRoleAndProvider(role: String?): Pair<String, AgentProvider>? {
        if (role == null) return null
        val separator = role.lastIndexOf(':')
        if (separator <= 0 || separator >= role.lastIndex) return null
        val cleanRole = role.substring(0, separator)
        val provider = AgentProvider.fromKey(role.substring(separator + 1)) ?: return null
        return cleanRole to provider
    }

    private fun blend(lhs: Color, rhs: Color, amount: Float): Color {
        val t = amount.coerceIn(0f, 1f)
        return Color(
            red = lhs.red * (1f - t) + rhs.red * t,
            green = lhs.green * (1f - t) + rhs.green * t,
            blue = lhs.blue * (1f - t) + rhs.blue * t,
            alpha = 1f
        )
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

    private fun defaultModes(): List<Mode> = buildList {
        add(Mode.SWARM)
        add(Mode.SHAPE_DOLLAR)
        add(Mode.SWARM)
        add(Mode.SHAPE_CODE)
        add(Mode.SWARM)
        if (enabledProviderLogos.contains(AgentProvider.XAI)) {
            add(Mode.SHAPE_GROK_LOGO)
        }
        repeat(providerLogoBatches.size) {
            add(Mode.SWARM)
            add(Mode.SHAPE_PROVIDER_LOGOS)
        }
        add(Mode.SWARM)
        add(Mode.SHAPE_RINGS)
        add(Mode.SWARM)
        add(Mode.SHAPE_ROUTER_FLOW)
    }

    private fun providerLogoSlots(count: Int, width: Double, height: Double): List<ProviderLogoSlot> {
        if (count <= 0) return emptyList()
        if (count == 1) {
            return listOf(
                ProviderLogoSlot(
                    centerX = if (width > 960) width * 0.74 else width * 0.5,
                    centerY = if (width > 960) height * 0.30 else height * 0.24,
                    scale = min(width, height) * 0.34
                )
            )
        }

        val maxColumns = when {
            width >= 1320 -> 5
            width >= 920 -> 4
            else -> 2
        }
        val columns = min(count, maxColumns)
        val rows = ceil(count.toDouble() / columns.toDouble()).toInt()
        val xStep = (width * 0.78 / (columns - 1).coerceAtLeast(1)).coerceIn(180.0, 300.0)
        val yStep = (height * 0.44 / (rows - 1).coerceAtLeast(1)).coerceIn(130.0, 210.0)
        val gridHeight = yStep * (rows - 1).coerceAtLeast(0)
        val gridCenterY = height * if (rows > 1) 0.40 else 0.34
        val scale = min(
            min(width, height) * 0.32,
            (min(xStep, if (rows > 1) yStep else height * 0.32) * 0.72).coerceAtLeast(110.0)
        )

        return (0 until count).map { index ->
            val row = index / columns
            val column = index % columns
            val rowCount = min(columns, count - row * columns)
            val rowWidth = xStep * (rowCount - 1).coerceAtLeast(0)
            ProviderLogoSlot(
                centerX = width * 0.5 - rowWidth / 2.0 + xStep * column,
                centerY = gridCenterY - gridHeight / 2.0 + yStep * row,
                scale = scale
            )
        }
    }

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

    private fun splinePoints(controlPoints: List<Pair<Double, Double>>, stepsPerSegment: Int, role: String): List<ShapePoint> {
        if (controlPoints.size < 3) return emptyList()
        val pts = ArrayList<ShapePoint>()
        val n = controlPoints.size
        for (i in 0 until n) {
            val p0 = controlPoints[(i - 1 + n) % n]
            val p1 = controlPoints[i]
            val p2 = controlPoints[(i + 1) % n]
            val p3 = controlPoints[(i + 2) % n]
            for (j in 0 until stepsPerSegment) {
                val t = j.toDouble() / stepsPerSegment.toDouble()
                val t2 = t * t
                val t3 = t2 * t
                val x = 0.5 * (
                    2.0 * p1.first +
                        (-p0.first + p2.first) * t +
                        (2.0 * p0.first - 5.0 * p1.first + 4.0 * p2.first - p3.first) * t2 +
                        (-p0.first + 3.0 * p1.first - 3.0 * p2.first + p3.first) * t3
                    )
                val y = 0.5 * (
                    2.0 * p1.second +
                        (-p0.second + p2.second) * t +
                        (2.0 * p0.second - 5.0 * p1.second + 4.0 * p2.second - p3.second) * t2 +
                        (-p0.second + 3.0 * p1.second - 3.0 * p2.second + p3.second) * t3
                    )
                pts.add(ShapePoint(x, y, role, (i * stepsPerSegment + j).toDouble() / (n * stepsPerSegment).toDouble()))
            }
        }
        return pts
    }

    private fun logoPoints(provider: AgentProvider, fallback: List<ShapePoint>): List<ShapePoint> {
        val context = appContext ?: return fallback
        val bitmap = BitmapFactory.decodeResource(context.resources, provider.logoRes)
            ?: return fallback
        return try {
            sampleLogoBitmap(bitmap, maxPoints = 1600).ifEmpty { fallback }
        } finally {
            bitmap.recycle()
        }
    }

    private fun sampleLogoBitmap(bitmap: Bitmap, maxPoints: Int): List<ShapePoint> {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return emptyList()

        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val background = inferredOpaqueBackgroundColor(pixels, width, height)
        val borderBackgroundMask = connectedBackgroundMask(pixels, width, height, background)

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for (y in 0 until height) {
            for (x in 0 until width) {
                val pixelIndex = y * width + x
                if (isLogoForegroundPixel(pixels[pixelIndex], pixelIndex, borderBackgroundMask, background)) {
                    if (x < minX) minX = x
                    if (y < minY) minY = y
                    if (x > maxX) maxX = x
                    if (y > maxY) maxY = y
                }
            }
        }
        if (minX > maxX || minY > maxY) return emptyList()

        val occupiedWidth = (maxX - minX + 1).coerceAtLeast(1)
        val occupiedHeight = (maxY - minY + 1).coerceAtLeast(1)
        val step = ceil(sqrt((occupiedWidth * occupiedHeight).toDouble() / maxPoints.toDouble())).toInt().coerceAtLeast(2)
        val centerX = (minX + maxX).toDouble() / 2.0
        val centerY = (minY + maxY).toDouble() / 2.0
        val scale = maxOf(occupiedWidth, occupiedHeight).toDouble() / 2.0
        val points = ArrayList<ShapePoint>(maxPoints)

        var y = minY
        while (y <= maxY) {
            var x = minX
            while (x <= maxX) {
                val pixel = pixels[y * width + x]
                val pixelIndex = y * width + x
                if (isLogoForegroundPixel(pixel, pixelIndex, borderBackgroundMask, background)) {
                    val alpha = ((pixel ushr 24) and 0xFF) / 255f
                    val red = ((pixel ushr 16) and 0xFF) / 255f
                    val green = ((pixel ushr 8) and 0xFF) / 255f
                    val blue = (pixel and 0xFF) / 255f
                    val source = Color(red, green, blue, alpha)
                    val luminance = 0.2126f * red + 0.7152f * green + 0.0722f * blue
                    val role = when {
                        luminance < 0.30f -> "logo-flame-outer"
                        luminance > 0.76f -> "logo-flame-spark"
                        else -> "logo-flame-inner"
                    }
                    points.add(
                        ShapePoint(
                            x = (x.toDouble() - centerX) / scale,
                            y = (y.toDouble() - centerY) / scale,
                            role = role,
                            progress = (points.size % maxPoints).toDouble() / (maxPoints - 1).coerceAtLeast(1).toDouble(),
                            color = source
                        )
                    )
                }
                x += step
            }
            y += step
        }

        if (points.size <= maxPoints) return points
        return (0 until maxPoints).map { index ->
            val t = index.toDouble() / (maxPoints - 1).coerceAtLeast(1).toDouble()
            points[((points.size - 1) * t).toInt().coerceAtMost(points.size - 1)]
        }
    }

    private fun inferredOpaqueBackgroundColor(pixels: IntArray, width: Int, height: Int): Color? {
        val cornerSide = (min(width, height) / 10).coerceIn(1, 8)
        val xRanges = listOf(0 until cornerSide, (width - cornerSide).coerceAtLeast(0) until width)
        val yRanges = listOf(0 until cornerSide, (height - cornerSide).coerceAtLeast(0) until height)

        var red = 0f
        var green = 0f
        var blue = 0f
        var alpha = 0f
        var count = 0
        for (xRange in xRanges) {
            for (yRange in yRanges) {
                for (y in yRange) {
                    for (x in xRange) {
                        val pixel = pixels[y * width + x]
                        val a = ((pixel ushr 24) and 0xFF) / 255f
                        if (a <= 0.85f) continue
                        alpha += a
                        red += ((pixel ushr 16) and 0xFF) / 255f
                        green += ((pixel ushr 8) and 0xFF) / 255f
                        blue += (pixel and 0xFF) / 255f
                        count += 1
                    }
                }
            }
        }

        if (count < 4 || alpha / count <= 0.88f) return null
        return Color(red / count, green / count, blue / count, alpha / count)
    }

    private fun connectedBackgroundMask(pixels: IntArray, width: Int, height: Int, background: Color?): BooleanArray? {
        if (background == null) return null
        val visited = BooleanArray(width * height)
        val queue = ArrayDeque<Int>()

        fun enqueue(x: Int, y: Int) {
            if (x !in 0 until width || y !in 0 until height) return
            val index = y * width + x
            if (visited[index]) return
            if (!isBackgroundLikePixel(pixels[index], background)) return
            visited[index] = true
            queue.add(index)
        }

        for (x in 0 until width) {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for (y in 0 until height) {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        while (queue.isNotEmpty()) {
            val index = queue.removeFirst()
            val x = index % width
            val y = index / width
            enqueue(x + 1, y)
            enqueue(x - 1, y)
            enqueue(x, y + 1)
            enqueue(x, y - 1)
        }

        return visited
    }

    private fun isBackgroundLikePixel(pixel: Int, background: Color): Boolean {
        val alpha = ((pixel ushr 24) and 0xFF) / 255f
        if (alpha <= 0.22f) return true
        val red = ((pixel ushr 16) and 0xFF) / 255f
        val green = ((pixel ushr 8) and 0xFF) / 255f
        val blue = (pixel and 0xFF) / 255f
        val distance = sqrt(
            ((red - background.red) * (red - background.red) +
                (green - background.green) * (green - background.green) +
                (blue - background.blue) * (blue - background.blue)).toDouble()
        ).toFloat()
        val luminance = relativeLuminance(red, green, blue)
        val maxChannel = maxOf(red, green, blue)
        val minChannel = minOf(red, green, blue)
        val saturation = maxChannel - minChannel
        return distance < 0.12f || (relativeLuminance(background) > 0.86f && luminance > 0.88f && saturation < 0.10f)
    }

    private fun isLogoForegroundPixel(
        pixel: Int,
        pixelIndex: Int,
        borderBackgroundMask: BooleanArray?,
        background: Color?
    ): Boolean {
        val alpha = ((pixel ushr 24) and 0xFF) / 255f
        if (alpha <= 0.22f) return false
        borderBackgroundMask?.let { return pixelIndex !in it.indices || !it[pixelIndex] }

        val red = ((pixel ushr 16) and 0xFF) / 255f
        val green = ((pixel ushr 8) and 0xFF) / 255f
        val blue = (pixel and 0xFF) / 255f
        if (background == null) return true

        val distance = sqrt(
            ((red - background.red) * (red - background.red) +
                (green - background.green) * (green - background.green) +
                (blue - background.blue) * (blue - background.blue)).toDouble()
        ).toFloat()
        val luminance = relativeLuminance(red, green, blue)
        val maxChannel = maxOf(red, green, blue)
        val minChannel = minOf(red, green, blue)
        val saturation = maxChannel - minChannel

        if (distance < 0.09f) return false
        if (relativeLuminance(background) > 0.86f && luminance > 0.88f && saturation < 0.10f) return false
        return true
    }

    private fun relativeLuminance(color: Color): Float =
        relativeLuminance(color.red, color.green, color.blue)

    private fun relativeLuminance(red: Float, green: Float, blue: Float): Float =
        0.2126f * red + 0.7152f * green + 0.0722f * blue

    private fun fallbackLogoPoints(provider: AgentProvider): List<ShapePoint> =
        when (provider) {
            AgentProvider.OPEN_AI -> generateOpenAILogoPoints()
            AgentProvider.CODEX -> generateCodexLogoPoints()
            AgentProvider.CLAUDE_CODE -> generateAnthropicLogoPoints()
            AgentProvider.GEMINI_CLI -> generateGeminiLogoPoints()
            AgentProvider.ANTIGRAVITY -> generateAntigravityLogoPoints()
            AgentProvider.CURSOR -> generateCursorLogoPoints()
            AgentProvider.OPENCODE -> generateOpenCodeLogoPoints()
            AgentProvider.XAI -> generateXAILogoPoints()
            else -> initialsLogoPoints(provider)
        }

    private fun initialsLogoPoints(provider: AgentProvider): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()

        fun appendLine(
            startX: Double,
            startY: Double,
            endX: Double,
            endY: Double,
            count: Int,
            role: String
        ) {
            for (i in 0 until count) {
                val t = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
                pts.add(
                    ShapePoint(
                        x = startX + (endX - startX) * t,
                        y = startY + (endY - startY) * t,
                        role = role,
                        progress = t
                    )
                )
            }
        }

        val sides = 3 + (provider.ordinal % 5)
        val radius = 0.34
        val vertices = (0 until sides).map { index ->
            val angle = -PI / 2.0 + (PI * 2.0 * index / sides)
            cos(angle) * radius to sin(angle) * radius
        }
        for (index in vertices.indices) {
            val start = vertices[index]
            val end = vertices[(index + 1) % vertices.size]
            appendLine(start.first, start.second, end.first, end.second, 42, "logo-flame-outer")
        }

        when (provider.ordinal % 4) {
            0 -> {
                appendLine(-0.20, -0.24, -0.20, 0.24, 70, "logo-flame-inner")
                appendLine(-0.20, 0.0, 0.20, 0.0, 70, "logo-flame-spark")
                appendLine(0.20, -0.24, 0.20, 0.24, 70, "logo-flame-inner")
            }
            1 -> {
                appendLine(-0.24, 0.24, 0.24, -0.24, 95, "logo-flame-inner")
                appendLine(-0.24, -0.24, 0.24, 0.24, 95, "logo-flame-spark")
            }
            2 -> {
                appendLine(-0.26, -0.20, 0.0, 0.26, 80, "logo-flame-inner")
                appendLine(0.0, 0.26, 0.26, -0.20, 80, "logo-flame-spark")
            }
            else -> {
                appendLine(-0.24, -0.22, 0.24, -0.22, 70, "logo-flame-inner")
                appendLine(-0.24, 0.0, 0.18, 0.0, 70, "logo-flame-spark")
                appendLine(-0.24, 0.22, 0.24, 0.22, 70, "logo-flame-inner")
            }
        }

        val denominator = (pts.size - 1).coerceAtLeast(1).toDouble()
        return pts.mapIndexed { index, point ->
            point.copy(progress = index.toDouble() / denominator)
        }
    }

    private fun generateOpenAILogoPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val a = 0.22
        val b = 0.07
        val d = 0.12
        val alpha = 0.2
        val steps = 70
        for (i in 0 until 6) {
            val theta = i.toDouble() * (PI / 3.0)
            for (j in 0 until steps) {
                val t = j.toDouble() / steps.toDouble() * (PI * 2.0)
                val localX = d + a * cos(t) * cos(alpha) - b * sin(t) * sin(alpha)
                val localY = a * cos(t) * sin(alpha) + b * sin(t) * cos(alpha)
                pts.add(
                    ShapePoint(
                        x = localX * cos(theta) - localY * sin(theta),
                        y = localX * sin(theta) + localY * cos(theta),
                        role = "logo-flame-inner",
                        progress = j.toDouble() / steps.toDouble()
                    )
                )
            }
        }
        return pts
    }

    private fun generateAnthropicLogoPoints(): List<ShapePoint> {
        val outer = listOf(
            -0.22 to -0.30, -0.07 to 0.32, 0.07 to 0.32, 0.22 to -0.30,
            0.12 to -0.30, 0.0 to 0.02, -0.12 to -0.30
        )
        val inner = listOf(0.0 to 0.20, 0.05 to 0.08, -0.05 to 0.08)
        return splinePoints(outer, 35, "logo-flame-outer") +
            splinePoints(inner, 35, "logo-flame-inner")
    }

    private fun generateGeminiLogoPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        fun appendAstroid(radius: Double, count: Int, role: String) {
            for (i in 0 until count) {
                val t = i.toDouble() / count.toDouble() * (PI * 2.0)
                pts.add(
                    ShapePoint(
                        x = radius * cos(t) * cos(t) * cos(t),
                        y = radius * sin(t) * sin(t) * sin(t),
                        role = role,
                        progress = i.toDouble() / count.toDouble()
                    )
                )
            }
        }
        appendAstroid(0.34, 220, "logo-flame-outer")
        appendAstroid(0.18, 150, "logo-flame-inner")
        return pts
    }

    private fun generateCursorLogoPoints(): List<ShapePoint> =
        splinePoints(
            listOf(0.0 to 0.32, 0.18 to -0.18, 0.0 to -0.05, -0.18 to -0.18),
            90,
            "logo-flame-inner"
        )

    private fun generateOpenCodeLogoPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        fun appendLine(
            startX: Double,
            startY: Double,
            endX: Double,
            endY: Double,
            count: Int,
            role: String
        ) {
            for (i in 0 until count) {
                val t = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
                pts.add(
                    ShapePoint(
                        x = startX + (endX - startX) * t,
                        y = startY + (endY - startY) * t,
                        role = role,
                        progress = t
                    )
                )
            }
        }

        appendLine(-0.34, 0.0, -0.12, -0.22, 90, "logo-flame-outer")
        appendLine(-0.34, 0.0, -0.12, 0.22, 90, "logo-flame-inner")
        appendLine(0.34, 0.0, 0.12, -0.22, 90, "logo-flame-outer")
        appendLine(0.34, 0.0, 0.12, 0.22, 90, "logo-flame-inner")
        appendLine(-0.04, 0.30, 0.08, -0.30, 120, "logo-flame-spark")
        return pts
    }

    private fun generateXAILogoPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val diagonalCount = 140
        for (i in 0 until diagonalCount) {
            val t = i.toDouble() / diagonalCount.toDouble()
            val x = -0.22 + t * 0.44
            val y = 0.25 - t * 0.50
            pts.add(ShapePoint(x - 0.015, y, "logo-flame-outer", t))
            pts.add(ShapePoint(x + 0.015, y, "logo-flame-inner", t))
        }
        val segmentCount = 60
        for (i in 0 until segmentCount) {
            val t = i.toDouble() / segmentCount.toDouble()
            pts.add(ShapePoint(-0.22 + t * 0.16, -0.25 + t * 0.18, "logo-flame-spark", t * 0.5))
            pts.add(ShapePoint(0.06 + t * 0.16, 0.07 + t * 0.18, "logo-flame-spark", 0.5 + t * 0.5))
        }
        return pts
    }

    private fun generateGrokLogoPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        fun appendArc(radius: Double, start: Double, end: Double, count: Int, role: String) {
            for (i in 0 until count) {
                val t = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
                val angle = start + (end - start) * t
                pts.add(ShapePoint(cos(angle) * radius, sin(angle) * radius, role, t))
            }
        }
        appendArc(0.34, 0.70, 2.85, 130, "logo-flame-outer")
        appendArc(0.23, 0.80, 2.65, 95, "logo-flame-inner")
        appendArc(0.34, 3.65, 6.02, 145, "logo-flame-outer")
        appendArc(0.23, 3.90, 5.78, 95, "logo-flame-inner")
        val slashCount = 180
        for (i in 0 until slashCount) {
            val t = i.toDouble() / (slashCount - 1).toDouble()
            val x = -0.42 + t * 0.84
            val y = 0.40 - t * 0.82
            val normal = 0.018
            for (lane in listOf(-1.0, 0.0, 1.0)) {
                pts.add(
                    ShapePoint(
                        x = x + lane * normal,
                        y = y + lane * normal * 0.45,
                        role = if (lane == 0.0) "logo-flame-spark" else "logo-flame-inner",
                        progress = t
                    )
                )
            }
        }
        return pts
    }

    private fun generateCodexLogoPoints(): List<ShapePoint> {
        val leftBrace = listOf(
            -0.06 to 0.28,
            -0.18 to 0.26,
            -0.16 to 0.12,
            -0.28 to 0.0,
            -0.16 to -0.12,
            -0.18 to -0.26,
            -0.06 to -0.28
        )
        val rightBrace = listOf(
            0.06 to 0.28,
            0.18 to 0.26,
            0.16 to 0.12,
            0.28 to 0.0,
            0.16 to -0.12,
            0.18 to -0.26,
            0.06 to -0.28
        )
        val leftPts = splinePoints(leftBrace, stepsPerSegment = 50, role = "logo-flame-outer")
        val rightPts = splinePoints(rightBrace, stepsPerSegment = 50, role = "logo-flame-inner")
        return leftPts + rightPts
    }

    private fun generateAntigravityLogoPoints(): List<ShapePoint> {
        val diamond = listOf(
            0.0 to 0.32,
            0.24 to 0.0,
            0.0 to -0.32,
            -0.24 to 0.0
        )
        val triangle = listOf(
            0.0 to 0.12,
            0.10 to -0.08,
            -0.10 to -0.08
        )
        val diamondPts = splinePoints(diamond, stepsPerSegment = 60, role = "logo-flame-outer")
        val trianglePts = splinePoints(triangle, stepsPerSegment = 60, role = "logo-flame-inner")
        return diamondPts + trianglePts
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
