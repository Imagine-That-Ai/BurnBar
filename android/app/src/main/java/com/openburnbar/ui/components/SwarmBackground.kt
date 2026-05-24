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
import com.openburnbar.ui.settings.rememberSwarmSparkles
import com.openburnbar.ui.settings.rememberExcludeBrandShapesFromSwarm
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
    enabledProviderGlyphs: Set<AgentProvider>? = null,
    paletteName: String = "System",
    isAvatarEnabled: Boolean = true,
    isBrandTextEnabled: Boolean = true,
    excludeBrandShapes: Boolean = false
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val context = LocalContext.current
    val config = LocalConfiguration.current
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val enableSwarmSparkles by rememberSwarmSparkles()
    val excludeBrandShapesSetting by rememberExcludeBrandShapesFromSwarm()

    val actualExcludeBrandShapes = excludeBrandShapes || excludeBrandShapesSetting

    val selectedProviderGlyphs = enabledProviderGlyphs ?: AgentProvider.swarmGlyphProviders.toSet()
    val simulation = remember(particleCount, pace, selectedProviderGlyphs, actualExcludeBrandShapes) {
        SwarmSimulation(
            particleCount = particleCount,
            pace = pace,
            context = context.applicationContext,
            enabledProviderGlyphs = selectedProviderGlyphs,
            excludeBrandShapes = actualExcludeBrandShapes
        )
    }.apply {
        this.isAvatarEnabled = isAvatarEnabled
        this.isBrandTextEnabled = isBrandTextEnabled
        this.paletteName = paletteName
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

            simulation.particles.forEachIndexed { index, p ->
                if (p.isGlyph) return@forEachIndexed
                val color = simulation.colorFor(p, accentColor, isDark)
                val inShape = simulation.inShapeMode && p.tx != null

                var r = (p.size * if (inShape) 1.2 else 0.85).toDouble()
                var isSparkling = false
                var sparkleIntensity = 0.0

                if (enableSwarmSparkles && inShape && simulation.shapeSettledAtNanos != null) {
                    val pHash = ((index * 127) % 1000).toDouble() / 1000.0
                    val speed = 0.5 + ((index * 17) % 5) * 0.15
                    val sparkleVal = Math.sin(simulation.flowTime * speed + pHash * Math.PI * 2)
                    if (sparkleVal > 0.94) {
                        val normalized = (sparkleVal - 0.94) / 0.06
                        val intensity = Math.pow(normalized, 2.0)
                        r *= (1.0 + intensity * 0.06)
                        isSparkling = true
                        sparkleIntensity = intensity
                    }
                }

                drawCircle(
                    color = color,
                    radius = r.toFloat(),
                    center = Offset(p.x.toFloat(), p.y.toFloat())
                )

                if (isSparkling) {
                    // Draw core glint
                    val sr = r * 0.35
                    drawCircle(
                        color = Color.White.copy(alpha = (sparkleIntensity * 0.55).toFloat()),
                        radius = sr.toFloat(),
                        center = Offset(p.x.toFloat(), p.y.toFloat())
                    )
                    // Draw outer subtle glow halo
                    val glowR = r * 0.75
                    drawCircle(
                        color = Color.White.copy(alpha = (sparkleIntensity * 0.15).toFloat()),
                        radius = glowR.toFloat(),
                        center = Offset(p.x.toFloat(), p.y.toFloat())
                    )
                }
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
    val excludeBrandShapes: Boolean = false,
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
    var paletteName: String = "System"
    var isRewinding: Boolean = false
    var isAvatarEnabled: Boolean = true
    var isBrandTextEnabled: Boolean = true

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
    internal var shapeSettledAtNanos: Long? = null
    internal var flowTime = 0.0
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
        private const val SHAPE_ADMIRE_HOLD_NANOS = 5_000_000_000L
        private const val SHAPE_SETTLE_RECHECK_NANOS = 250_000_000L
        private const val SHAPE_SETTLE_FALLBACK_NANOS = 6_000_000_000L
        private const val SHAPE_SETTLED_PARTICLE_FRACTION = 0.95
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

            val textPoints = providerTextPoints(spec.provider)
            val drawAvatar = isAvatarEnabled
            val drawText = isBrandTextEnabled && textPoints.isNotEmpty()

            if (drawAvatar && drawText && visibleSpecs.size == 1) {
                // Split particles: 70% to central avatar, 30% to bottom-left text logo badge
                val avatarCount = (group.size * 0.70).toInt()
                for ((slot, particleIdx) in group.withIndex()) {
                    if (slot < avatarCount) {
                        val pointIndex = if (avatarCount <= points.size) {
                            val t = slot.toDouble() / (avatarCount - 1).coerceAtLeast(1).toDouble()
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
                    } else {
                        val textSlotIdx = slot - avatarCount
                        val textTotalCount = group.size - avatarCount
                        val pointIndex = if (textTotalCount <= textPoints.size) {
                            val t = textSlotIdx.toDouble() / (textTotalCount - 1).coerceAtLeast(1).toDouble()
                            ((textPoints.size - 1) * t).toInt().coerceAtMost(textPoints.size - 1)
                        } else {
                            textSlotIdx % textPoints.size
                        }
                        val pt = textPoints[pointIndex]
                        val role = pt.role ?: "logo-flame-inner"

                        val textCenterX = 135.0
                        val textCenterY = height - 55.0
                        val textScale = 110.0

                        particles[particleIdx].tx = textCenterX + pt.x * textScale
                        particles[particleIdx].ty = textCenterY + pt.y * textScale
                        particles[particleIdx].role = "$role:${spec.provider.key}"
                        particles[particleIdx].isGlyph = false
                        particles[particleIdx].logoColor = pt.color
                        particles[particleIdx].flowProgress = pt.progress
                    }
                }
            } else if (drawText && !drawAvatar && visibleSpecs.size == 1) {
                // Form ONLY bottom-left text logo badge
                for ((slot, particleIdx) in group.withIndex()) {
                    val pointIndex = if (group.size <= textPoints.size) {
                        val t = slot.toDouble() / (group.size - 1).coerceAtLeast(1).toDouble()
                        ((textPoints.size - 1) * t).toInt().coerceAtMost(textPoints.size - 1)
                    } else {
                        slot % textPoints.size
                    }
                    val pt = textPoints[pointIndex]
                    val role = pt.role ?: "logo-flame-inner"

                    val textCenterX = 135.0
                    val textCenterY = height - 55.0
                    val textScale = 110.0

                    particles[particleIdx].tx = textCenterX + pt.x * textScale
                    particles[particleIdx].ty = textCenterY + pt.y * textScale
                    particles[particleIdx].role = "$role:${spec.provider.key}"
                    particles[particleIdx].isGlyph = false
                    particles[particleIdx].logoColor = pt.color
                    particles[particleIdx].flowProgress = pt.progress
                }
            } else if (drawAvatar) {
                // Form ONLY main central avatar logo
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
            } else {
                // Neither avatar nor text are enabled: drift freely in pure swarm
                for (particleIdx in group) {
                    particles[particleIdx].tx = null
                    particles[particleIdx].ty = null
                    particles[particleIdx].role = null
                    particles[particleIdx].logoColor = null
                }
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

        val whimsy: Color
        val ember: Color
        val amber: Color
        val blaze: Color

        when (paletteName) {
            "AuroraTeal", "Aurora" -> {
                whimsy = if (isDark) Color(0xFF8B2DF2) else Color(0xFF7012C9)
                ember  = if (isDark) Color(0xFF008080) else Color(0xFF006666)
                amber  = if (isDark) Color(0xFF00F5FF) else Color(0xFF00C2CC)
                blaze  = if (isDark) Color(0xFF00FF80) else Color(0xFF00CC66)
            }
            "Crimson", "SunsetCrimson" -> {
                whimsy = if (isDark) Color(0xFF4A0082) else Color(0xFF380069)
                ember  = if (isDark) Color(0xFFFF1493) else Color(0xFFCC0A75)
                amber  = if (isDark) Color(0xFFFF4500) else Color(0xFFCC2E00)
                blaze  = if (isDark) Color(0xFFB22222) else Color(0xFF8E1414)
            }
            else -> {
                whimsy = if (isDark) Color(0xFF8080FF) else Color(0xFF514DDB)
                ember  = if (isDark) Color(0xFFFA6B06) else Color(0xFFCC4D00)
                amber  = if (isDark) Color(0xFFFFA800) else Color(0xFFC78500)
                blaze  = if (isDark) Color(0xFFEE1803) else Color(0xFFBD1200)
            }
        }

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
        if (excludeBrandShapes) {
            add(Mode.SWARM)
            if (enabledProviderLogos.contains(AgentProvider.XAI)) {
                add(Mode.SHAPE_GROK_LOGO)
            }
            repeat(providerLogoBatches.size) {
                add(Mode.SWARM)
                add(Mode.SHAPE_PROVIDER_LOGOS)
            }
        } else {
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

            private fun providerTextPoints(provider: AgentProvider): List<ShapePoint> {
        val data = SwarmTextCoordinates.getCoordinates(provider)
        val count = data.size / 2
        val pts = ArrayList<ShapePoint>(count)
        val denom = (count - 1).coerceAtLeast(1).toDouble()
        var idx = 0
        while (idx < data.size) {
            pts.add(ShapePoint(
                x = data[idx],
                y = data[idx + 1],
                role = "logo-flame-inner",
                progress = (idx / 2).toDouble() / denom
            ))
            idx += 2
        }
        return pts
    }

    fun forceCycleShape(forward: Boolean = true) {
        val allModes = Mode.values()
        val currentIdx = allModes.indexOf(mode)
        val delta = if (forward) 1 else -1
        val nextIdx = (currentIdx + delta + allModes.size) % allModes.size
        assignMode(allModes[nextIdx])
    }

    fun instantlySettle() {
        for (p in particles) {
            val tx = p.tx
            val ty = p.ty
            if (tx != null && ty != null) {
                p.x = tx
                p.y = ty
                p.vx = 0.0
                p.vy = 0.0
            }
        }
    }

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
            AgentProvider.OLLAMA -> generateOllamaLogoPoints()
            AgentProvider.HERMES -> generateHermesLogoPoints()
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

    private fun generateOllamaLogoPoints(): List<ShapePoint> {
        val coords = doubleArrayOf(
            -0.19965000000000002, -0.55, -0.19415000000000002, -0.54747, -0.18700000000000003, -0.54329, -0.18183000000000002, -0.53966, -0.17688, -0.5354800000000001, -0.16962000000000002, -0.5281100000000001, -0.16225, -0.51898, -0.15532, -0.50875, -0.14696, -0.49335000000000007, -0.14135, -0.4807, -0.13618, -0.4671700000000001, -0.13046000000000002, -0.44814000000000004, -0.12683, -0.43351000000000006, -0.12397000000000001, -0.41855000000000003, -0.12188, -0.40337000000000006, -0.12067000000000001, -0.39325, -0.12012000000000002, -0.39325, -0.11968000000000001, -0.39325, -0.11913, -0.39336, -0.11869, -0.39336, -0.10329, -0.39413000000000004, -0.07315, -0.39259000000000005, -0.05115, -0.38874000000000003, -0.0297, -0.38280000000000003, -0.00253, -0.3712500000000001, 0.00011000000000000002, -0.36982000000000004, 0.0027500000000000003, -0.36839, 0.0061600000000000005, -0.36630000000000007, 0.0088, -0.36487, 0.011330000000000002, -0.36322000000000004, 0.013750000000000002, -0.38313, 0.016280000000000003, -0.39787000000000006, 0.01958, -0.41239000000000003, 0.02508, -0.4310900000000001, 0.029920000000000002, -0.44462, 0.03531, -0.4576, 0.04136000000000001, -0.4697, 0.05016, -0.48411000000000004, 0.057420000000000006, -0.49357, 0.06468, -0.5000600000000001, 0.07392, -0.50248, 0.08096, -0.50336, 0.08800000000000001, -0.5032500000000001, 0.09735, -0.50182, 0.10659, -0.49896000000000007, 0.11649, -0.49434000000000006, 0.1287, -0.4862, 0.13706000000000002, -0.47872000000000003, 0.14476, -0.46992000000000006, 0.15345000000000003, -0.45738000000000006, 0.15906, -0.44715, 0.16401000000000002, -0.43604, 0.16984000000000002, -0.41976, 0.17347, -0.40656000000000003, 0.17853000000000002, -0.3806, 0.18249, -0.34144, 0.18315000000000003, -0.30899, 0.18194000000000002, -0.27379000000000003, 0.17886000000000002, -0.23606000000000002, 0.17941000000000001, -0.23562000000000002, 0.17996, -0.23529000000000003, 0.18040000000000003, -0.23496000000000003, 0.18095000000000003, -0.23441000000000004, 0.18139, -0.23419000000000004, 0.18172000000000002, -0.23397, 0.18205000000000002, -0.23364000000000001, 0.18227, -0.23353000000000002, 0.18249, -0.23331000000000002, 0.20702000000000004, -0.21109, 0.22275000000000003, -0.19184, 0.23606000000000002, -0.17072, 0.25014000000000003, -0.13981, 0.25905, -0.11033000000000001, 0.26521000000000006, -0.0704, 0.26389, -0.018150000000000003, 0.25608000000000003, 0.018150000000000003, 0.24266000000000001, 0.049830000000000006, 0.23045000000000002, 0.06798000000000001, 0.23023000000000005, 0.06831000000000001, 0.23001000000000002, 0.06842000000000001, 0.22979000000000002, 0.06886, 0.23683, 0.08239, 0.24585, 0.10285000000000001, 0.25322, 0.12375000000000001, 0.26015, 0.15213000000000002, 0.26312, 0.1738, 0.26378, 0.18139, 0.26378, 0.18183000000000002, 0.26378, 0.18216000000000002, 0.26389, 0.18249, 0.26323, 0.21989, 0.25883, 0.24805000000000002, 0.25124, 0.27599, 0.23573, 0.31317000000000006, 0.22572, 0.33176, 0.22561000000000003, 0.33198000000000005, 0.2255, 0.33242000000000005, 0.22572, 0.33275, 0.22583000000000003, 0.33308000000000004, 0.23353000000000002, 0.35365, 0.24211000000000002, 0.38412, 0.24761000000000002, 0.4147, 0.24992000000000003, 0.4555100000000001, 0.24783000000000002, 0.4862, 0.24640000000000004, 0.4965400000000001, 0.24629, 0.49698000000000003, 0.24629, 0.49742000000000003, 0.24618, 0.4977500000000001, 0.24618, 0.49808, 0.24893, 0.47102000000000005, 0.24849000000000002, 0.44374, 0.24486000000000002, 0.41635000000000005, 0.23496000000000003, 0.37972000000000006, 0.22363000000000002, 0.35211000000000003, 0.22385, 0.35189000000000004, 0.24200000000000002, 0.31955, 0.25157, 0.29557, 0.25795, 0.27181, 0.26158000000000003, 0.24024000000000004, 0.2607, 0.21780000000000002, 0.25762, 0.19745000000000001, 0.25014000000000003, 0.17061, 0.24200000000000002, 0.15070000000000003, 0.23177, 0.13123, 0.22407000000000002, 0.11825000000000001, 0.22418000000000002, 0.11803000000000001, 0.22847, 0.11473000000000001, 0.23650000000000002, 0.10505, 0.24189000000000002, 0.09537000000000001, 0.24651, 0.08371, 0.25036, 0.0704, 0.24519000000000002, 0.047850000000000004, 0.23727, 0.031240000000000004, 0.22781, 0.01617, 0.21274, -0.0016500000000000002, 0.19976000000000002, -0.013090000000000003, 0.18315000000000003, -0.023870000000000002, 0.15796000000000002, -0.03443, 0.13684000000000002, -0.039490000000000004, 0.11363000000000001, -0.04191, 0.08558, -0.0473, 0.07612000000000001, -0.06325000000000001, 0.06545000000000001, -0.07733000000000001, 0.049060000000000006, -0.09328, 0.03542, -0.10318000000000001, 0.014740000000000001, -0.10758000000000001, -0.02607, -0.09669000000000001, -0.05291, -0.08305, -0.07524000000000002, -0.06556000000000001, -0.09603, -0.03751, -0.11748000000000001, -0.02926, -0.14278000000000002, -0.026510000000000002, -0.16577, -0.02134, -0.19294000000000003, -0.011000000000000001, -0.21065000000000003, -0.0008800000000000001, -0.22484, 0.01012, -0.24024000000000004, 0.026510000000000002, -0.24981, 0.040260000000000004, -0.25784, 0.055330000000000004, -0.26587, 0.07722000000000001, -0.26246, 0.09141, -0.25806, 0.10439000000000001, -0.25102, 0.11957000000000001, -0.24508000000000002, 0.12903, -0.23870000000000002, 0.13662000000000002, -0.23848, 0.13684000000000002, -0.23826, 0.13695000000000002, -0.23353000000000002, 0.14289, -0.22990000000000002, 0.15202, -0.22913000000000003, 0.15939, -0.23023000000000005, 0.16665000000000002, -0.23628000000000002, 0.17930000000000001, -0.24497000000000002, 0.19789, -0.25234, 0.21868, -0.25828, 0.24101, -0.26345, 0.27214000000000005, -0.26499, 0.29667000000000004, -0.26389, 0.32219000000000003, -0.25806, 0.35376, -0.25036, 0.37532000000000004, -0.2398, 0.39468000000000003, -0.23089, 0.40656000000000003, -0.23067000000000001, 0.40678000000000003, -0.23056000000000001, 0.40700000000000003, -0.23518, 0.41800000000000004, -0.24706, 0.44869000000000003, -0.25509000000000004, 0.47729000000000005, -0.25993000000000005, 0.5119400000000001, -0.25916, 0.5354800000000001, -0.2585, 0.54098, -0.26169000000000003, 0.50336, -0.25949, 0.47344, -0.25333, 0.44198000000000004, -0.23914000000000002, 0.39787000000000006, -0.23441000000000004, 0.38621000000000005, -0.2343, 0.38588000000000006, -0.23408, 0.38544, -0.23397, 0.38522000000000006, -0.23386000000000004, 0.38489, -0.23397, 0.38456000000000007, -0.23419000000000004, 0.38423, -0.2343, 0.3840100000000001, -0.2343, 0.38368, -0.23441000000000004, 0.38335, -0.23232000000000003, 0.35937, -0.22858000000000003, 0.3355, -0.22110000000000002, 0.3047, -0.21384, 0.2827, -0.20537000000000002, 0.26224000000000003, -0.20515000000000003, 0.26191000000000003, -0.20504000000000003, 0.26169000000000003, -0.20493, 0.26136000000000004, -0.20482000000000003, 0.26092000000000004, -0.21219000000000002, 0.24937000000000004, -0.21868, 0.23672, -0.22616000000000003, 0.21846000000000002, -0.23067000000000001, 0.20394000000000004, -0.2343, 0.18865000000000004, -0.23441000000000004, 0.18821000000000002, -0.23452, 0.18788000000000002, -0.23452, 0.18755000000000002, -0.22638000000000003, 0.16412000000000002, -0.21175000000000002, 0.13519, -0.19778, 0.11539, -0.18150000000000002, 0.09735, -0.16225, 0.08096, -0.1606, 0.07975, -0.15895, 0.07865, -0.15675, 0.07711, -0.1551, 0.07590000000000001, -0.15532, 0.06226, -0.15829000000000001, 0.01331, -0.15829000000000001, -0.02035, -0.15631, -0.05126000000000001, -0.15070000000000003, -0.08800000000000001, -0.14641, -0.10538, -0.14245000000000002, -0.11792000000000001, -0.13607000000000002, -0.13343000000000002, -0.13068000000000002, -0.14399, -0.12463, -0.15367, -0.11506000000000001, -0.16577, -0.10692, -0.17369000000000004, -0.09801, -0.18040000000000003, -0.08855, -0.18590000000000004, -0.07502, -0.19107000000000002, -0.06798000000000001, -0.19261000000000003, -0.06094, -0.19327, -0.051590000000000004, -0.19272, -0.044550000000000006, -0.19140000000000001, -0.03773, -0.18909, -0.07821, -0.27940000000000004, -0.10857, -0.34705, -0.13893, -0.4147, -0.17941000000000001, -0.5049, -0.00715, -0.12485000000000002, 0.017050000000000003, -0.12331000000000002, 0.047740000000000005, -0.11682000000000001, 0.0693, -0.10868000000000001, 0.09537000000000001, -0.09383000000000001, 0.11264000000000002, -0.08019000000000001, 0.12694000000000003, -0.0649, 0.14179, -0.04268, 0.14926999999999999, -0.02486, 0.15400000000000003, -0.00033, 0.15334, 0.02101, 0.14883000000000002, 0.04202, 0.13695000000000002, 0.06677, 0.12386000000000001, 0.08272000000000002, 0.10120000000000001, 0.10043000000000002, 0.08393000000000002, 0.10934, 0.06468, 0.11638000000000001, 0.036300000000000006, 0.12287000000000001, 0.01331, 0.12551, -0.01111, 0.12650000000000003, -0.04521, 0.12419000000000001, -0.06875, 0.11968000000000001, -0.09735, 0.10989000000000002, -0.11627000000000001, 0.09999, -0.13299, 0.08789000000000001, -0.15103000000000003, 0.06908, -0.16104000000000002, 0.05324, -0.16984000000000002, 0.03036, -0.17259000000000002, 0.0121, -0.17193, -0.00649, -0.16522, -0.030910000000000003, -0.15631, -0.048510000000000005, -0.13937000000000002, -0.0704, -0.12342, -0.08514000000000001, -0.10483, -0.09812000000000001, -0.07733000000000001, -0.11176, -0.05489, -0.11891000000000002, -0.023430000000000003, -0.12419000000000001, -0.00715, -0.08294, -0.021560000000000003, -0.0693, -0.03212, -0.054560000000000004, -0.03751, -0.043230000000000005, -0.040810000000000006, -0.028160000000000004, -0.03993, -0.013420000000000001, -0.03542, 0.0007700000000000001, -0.027280000000000002, 0.01397, -0.019030000000000002, 0.02299, -0.00396, 0.03432, 0.015620000000000002, 0.043780000000000006, 0.038500000000000006, 0.05038, 0.06446, 0.053680000000000005, 0.08536, 0.05412000000000001, 0.11165000000000001, 0.05214, 0.13519, 0.047740000000000005, 0.15565, 0.04092, 0.16885, 0.034210000000000004, 0.18304, 0.02332, 0.19327, 0.0099, 0.19943, -0.005940000000000001, 0.20152, -0.024530000000000003, 0.20031000000000002, -0.03586, 0.19514, -0.05115, 0.18612, -0.06611, 0.17336000000000001, -0.08008000000000001, 0.15609, -0.09306, 0.14102000000000003, -0.10109, 0.11891000000000002, -0.10890000000000001, 0.09493000000000001, -0.11286, 0.07128, -0.10956, 0.04884000000000001, -0.10197000000000002, 0.032010000000000004, -0.09625, 0.00957, -0.08866000000000002, 0.023760000000000003, -0.026400000000000003, 0.024970000000000003, -0.02486, 0.027280000000000002, -0.018920000000000003, 0.02739, -0.014190000000000001, 0.02552, -0.00825, 0.022660000000000003, -0.0044, 0.018810000000000004, -0.0012100000000000001, 0.016280000000000003, 0.0007700000000000001, 0.012870000000000001, 0.0034100000000000003, 0.01023, 0.0055000000000000005, 0.007700000000000001, 0.0074800000000000005, 0.007700000000000001, 0.012650000000000002, 0.007700000000000001, 0.016610000000000003, 0.007700000000000001, 0.021780000000000004, 0.007700000000000001, 0.025740000000000002, 0.007700000000000001, 0.025630000000000003, 0.007700000000000001, 0.021670000000000002, 0.007700000000000001, 0.016280000000000003, 0.007700000000000001, 0.012210000000000002, 0.007700000000000001, 0.0068200000000000005, 0.00528, 0.00495, 0.0029700000000000004, 0.0029700000000000004, -0.00022000000000000003, 0.00044000000000000007, -0.00264, -0.00143, -0.0044, -0.00286, -0.0024200000000000003, -0.00132, 0.0, 0.00066, 0.00198, 0.0022, 0.0044, 0.0041800000000000006, 0.00638, 0.0036300000000000004, 0.00825, 0.0020900000000000003, 0.010890000000000002, 0.00011000000000000002, 0.01276, -0.00143, 0.015400000000000002, -0.0034100000000000003, 0.01694, -0.007810000000000001, 0.019030000000000002, -0.013530000000000002, 0.020680000000000004, -0.01782, 0.022770000000000002, -0.023540000000000002, -0.21197000000000002, -0.11616000000000001, -0.20779000000000003, -0.11594, -0.19987000000000002, -0.11429000000000002, -0.19613, -0.11297000000000001, -0.18931, -0.10912000000000001, -0.18612, -0.10681000000000002, -0.18326, -0.10417000000000001, -0.17831, -0.09812000000000001, -0.17633000000000001, -0.09482, -0.17457000000000003, -0.0913, -0.17226, -0.08360000000000001, -0.1716, -0.07953, -0.17138, -0.07535000000000001, -0.17644, -0.08052000000000001, -0.17897000000000002, -0.08305, -0.18403000000000003, -0.08811000000000001, -0.18656, -0.09064000000000001, -0.18909, -0.09317, -0.19415000000000002, -0.09834, -0.19668, -0.10087000000000002, -0.20174000000000003, -0.10593000000000001, -0.20438, -0.10846, -0.20691, -0.11099000000000002, -0.21197000000000002, -0.11616000000000001, 0.19525, -0.11616000000000001, 0.19943, -0.11594, 0.20735, -0.11429000000000002, 0.21109, -0.11297000000000001, 0.21791000000000002, -0.10912000000000001, 0.22110000000000002, -0.10681000000000002, 0.22396000000000002, -0.10417000000000001, 0.22891000000000003, -0.09812000000000001, 0.23089, -0.09482, 0.23265000000000002, -0.0913, 0.23496000000000003, -0.08360000000000001, 0.23562000000000002, -0.07953, 0.23584000000000002, -0.07535000000000001, 0.23078, -0.08052000000000001, 0.22825, -0.08305, 0.22319000000000003, -0.08811000000000001, 0.22066000000000002, -0.09064000000000001, 0.21802, -0.09317, 0.21296, -0.09834, 0.21043, -0.10087000000000002, 0.20537000000000002, -0.10593000000000001, 0.20284000000000002, -0.10846, 0.20031000000000002, -0.11099000000000002, 0.19525, -0.11616000000000001, -0.22143000000000002, -0.49346000000000007, -0.22165000000000004, -0.49324000000000007, -0.22176, -0.49313, -0.22418000000000002, -0.48950000000000005, -0.22759000000000001, -0.48356000000000005, -0.23078, -0.47663000000000005, -0.23276000000000002, -0.47157000000000004, -0.23551000000000002, -0.46332000000000007, -0.23804000000000003, -0.45408000000000004, -0.24189000000000002, -0.43472000000000005, -0.24376, -0.42042, -0.24552000000000004, -0.3971, -0.24607000000000004, -0.37158, -0.24563000000000001, -0.35321, -0.24387000000000003, -0.32406, -0.23232000000000003, -0.32714000000000004, -0.22044000000000002, -0.32978, -0.21241000000000002, -0.33132000000000006, -0.19987000000000002, -0.33308000000000004, -0.18700000000000003, -0.33451000000000003, -0.17809, -0.33506, -0.17798000000000003, -0.3351700000000001, -0.17765000000000003, -0.33528, -0.17754, -0.3355, -0.17743, -0.3357200000000001, -0.17721, -0.33605, -0.1771, -0.33638000000000007, -0.17688, -0.33671, -0.17600000000000002, -0.33814000000000005, -0.17479000000000003, -0.34034000000000003, -0.17347, -0.34243000000000007, -0.17270000000000002, -0.34375, -0.17127, -0.34584000000000004, -0.16995000000000002, -0.3479300000000001, -0.16775, -0.36883, -0.16753, -0.38335, -0.16885, -0.40535000000000004, -0.17215000000000003, -0.42735000000000006, -0.17732000000000003, -0.44869000000000003, -0.18172000000000002, -0.4622200000000001, -0.18546, -0.47135000000000005, -0.18931, -0.47971, -0.19195, -0.48477000000000003, -0.19602, -0.49148000000000003, -0.20020000000000002, -0.4970900000000001, -0.20416, -0.49984000000000006, -0.20647000000000001, -0.49896000000000007, -0.20988, -0.4976400000000001, -0.21329, -0.49643000000000004, -0.21681, -0.49511000000000005, -0.21912, -0.49423, 0.20768, -0.4915900000000001, 0.20614000000000002, -0.49005000000000004, 0.20339000000000002, -0.4866400000000001, 0.19932000000000002, -0.4805900000000001, 0.19514, -0.47355, 0.1925, -0.4682700000000001, 0.18876, -0.45958000000000004, 0.18634, -0.45342000000000005, 0.17974, -0.4317500000000001, 0.17501, -0.40887, 0.17314000000000002, -0.39336, 0.17215000000000003, -0.37004, 0.17336000000000001, -0.34749, 0.17556, -0.33308000000000004, 0.17611000000000002, -0.33231, 0.17666, -0.33143000000000006, 0.17699, -0.33088000000000006, 0.17743, -0.33, 0.17776, -0.32945, 0.17831, -0.32857000000000003, 0.17853000000000002, -0.32824000000000003, 0.17864, -0.32813000000000003, 0.17875000000000002, -0.32791, 0.17908000000000002, -0.32791, 0.17930000000000001, -0.32791, 0.17963, -0.32791, 0.17996, -0.32791, 0.18073000000000003, -0.3377, 0.18194000000000002, -0.36553, 0.18183000000000002, -0.39127000000000006, 0.18106, -0.40722, 0.17886000000000002, -0.42933, 0.17677000000000004, -0.44286000000000003, 0.17325000000000002, -0.45837000000000006, 0.17072, -0.46728000000000003, 0.16885, -0.47278000000000003, 0.16577, -0.48015, 0.16247, -0.48675000000000007, 0.16016000000000002, -0.49060000000000004, 0.15774000000000002, -0.49423, 0.15752, -0.49445000000000006, 0.16049000000000002, -0.49423, 0.16995000000000002, -0.49368, 0.17622000000000002, -0.49335000000000007, 0.18568, -0.49280000000000007, 0.19503000000000004, -0.4922500000000001, 0.2013, -0.49192
        )
        val pts = ArrayList<ShapePoint>()
        val count = coords.size / 2
        for (i in 0 until count) {
            val x = coords[i * 2]
            val y = coords[i * 2 + 1]
            val progress = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
            pts.add(
                ShapePoint(
                    x = x,
                    y = y,
                    role = if (i % 3 == 0) "logo-flame-spark" else "logo-flame-inner",
                    progress = progress
                )
            )
        }
        return pts
    }

    private fun generateHermesLogoPoints(): List<ShapePoint> {
        val coords = doubleArrayOf(
            -0.30448000000000003, 0.06732, -0.18700000000000003, -0.09614000000000002, -0.18722, -0.09581, -0.18744000000000002, -0.09548000000000001, -0.18755000000000002, -0.09515, -0.18425000000000002, -0.09405000000000001, -0.17567000000000002, -0.09185000000000001, -0.16885, -0.09020000000000002, -0.16192, -0.08844, -0.1606, -0.08723, -0.16104000000000002, -0.08624000000000001, -0.16159, -0.08514000000000001, -0.16203, -0.08415, -0.16159, -0.08327000000000001, -0.16093000000000002, -0.08239, -0.15994000000000003, -0.08129, -0.15928000000000003, -0.08041000000000001, -0.16071000000000002, -0.07931, -0.16214, -0.07832, -0.16357000000000002, -0.07722000000000001, -0.165, -0.07623, -0.16467, -0.07524000000000002, -0.16434, -0.07414000000000001, -0.16401000000000002, -0.07315, -0.16434, -0.07205, -0.16665000000000002, -0.07150000000000001, -0.16896, -0.07106000000000001, -0.17138, -0.07051000000000002, -0.17292000000000002, -0.06974000000000001, -0.17204000000000003, -0.06831000000000001, -0.17116, -0.06677, -0.17039, -0.06534000000000001, -0.17127, -0.06424, -0.17424000000000003, -0.06424, -0.17721, -0.06424, -0.18018, -0.06424, -0.18172000000000002, -0.06336, -0.18183000000000002, -0.06171, -0.18194000000000002, -0.06017, -0.18194000000000002, -0.05852, -0.18238000000000001, -0.05698, -0.18315000000000003, -0.055110000000000006, -0.18381, -0.053680000000000005, -0.18436000000000002, -0.05214, -0.18568, -0.051480000000000005, -0.18733000000000002, -0.05115, -0.18887, -0.050710000000000005, -0.19041000000000002, -0.05027, -0.19195, -0.05016, -0.19338000000000002, -0.05016, -0.19525, -0.05016, -0.19679000000000002, -0.05016, -0.19613, -0.052250000000000005, -0.19547, -0.054340000000000006, -0.19492, -0.05643, -0.19426000000000002, -0.058410000000000004, -0.19294000000000003, -0.06182000000000001, -0.19162, -0.06523000000000001, -0.1903, -0.06864, -0.18887, -0.07348, -0.18843000000000001, -0.07953, -0.18788000000000002, -0.08558, -0.18744000000000002, -0.09163, -0.20306, -0.03047, -0.01573, -0.5453800000000001, -0.01727, -0.54351, -0.018920000000000003, -0.54164, -0.02046, -0.5397700000000001, -0.022000000000000002, -0.53801, -0.021780000000000004, -0.53768, -0.02145, -0.53724, -0.02112, -0.53691, -0.02486, -0.53691, -0.02849, -0.53691, -0.03223, -0.53691, -0.03597, -0.53691, -0.03586, -0.53625, -0.03564, -0.5357000000000001, -0.035530000000000006, -0.53493, -0.03542, -0.53427, -0.03509, -0.53339, -0.034760000000000006, -0.5324, -0.03443, -0.5315200000000001, -0.03564, -0.53086, -0.041580000000000006, -0.53086, -0.04741, -0.53086, -0.05335000000000001, -0.53086, -0.05786000000000001, -0.53097, -0.05808000000000001, -0.5313, -0.058410000000000004, -0.53174, -0.05863, -0.53207, -0.06028000000000001, -0.5315200000000001, -0.06182000000000001, -0.53108, -0.06347000000000001, -0.5305300000000001, -0.06512000000000001, -0.5300900000000001, -0.09119000000000001, -0.5300900000000001, -0.11726, -0.5300900000000001, -0.14344, -0.5300900000000001, -0.16951, -0.5300900000000001, -0.17072, -0.5300900000000001, -0.17182000000000003, -0.5300900000000001, -0.17292000000000002, -0.5300900000000001, -0.17402000000000004, -0.5300900000000001, -0.21538000000000002, -0.5300900000000001, -0.25685, -0.5300900000000001, -0.30855000000000005, -0.5300900000000001, -0.33957, -0.5313, -0.33913000000000004, -0.53625, -0.33869000000000005, -0.5413100000000001, -0.33825, -0.5462600000000001, -0.31229, -0.5424100000000001, -0.23441000000000004, -0.52283, -0.18689, -0.5166700000000001, -0.15862, -0.51865, -0.13541, -0.5237100000000001, -0.10351000000000002, -0.5294300000000001, -0.07161000000000001, -0.5352600000000001, -0.03971, -0.5410900000000001, -0.10406000000000001, 0.54483, -0.10428, 0.54549, -0.10450000000000001, 0.54615, -0.10483, 0.54681, -0.10505, 0.54747, -0.10527, 0.5480200000000001, -0.10560000000000001, 0.5486800000000001, -0.10582, 0.54934, -0.10615000000000001, 0.55, -0.10626000000000002, 0.5498900000000001, -0.10648, 0.54978, -0.10659, 0.54967, -0.10681000000000002, 0.54956, -0.10703, 0.54934, -0.10714000000000001, 0.5492300000000001, -0.10736000000000001, 0.54912, -0.10714000000000001, 0.54879, -0.10681000000000002, 0.5482400000000001, -0.10637, 0.54769, -0.10593000000000001, 0.54725, -0.10549000000000001, 0.5467000000000001, -0.10505, 0.54615, -0.10461000000000001, 0.5456000000000001, -0.10417000000000001, 0.54505, -0.02519, 0.36828, -0.026290000000000004, 0.36949, -0.02849, 0.3718000000000001, -0.02959, 0.37290000000000006, -0.03179, 0.37521000000000004, -0.03289, 0.37642000000000003, -0.033990000000000006, 0.37752, -0.03619, 0.37983, -0.037290000000000004, 0.38104, -0.03839, 0.38214000000000004, -0.0407, 0.38445, -0.041800000000000004, 0.38555, -0.0429, 0.38676000000000005, -0.0407, 0.38445, -0.039490000000000004, 0.38324, -0.037290000000000004, 0.38104, -0.03619, 0.37983, -0.03509, 0.37873, -0.03289, 0.37642000000000003, -0.03179, 0.37521000000000004, -0.02959, 0.37290000000000006, -0.02849, 0.3718000000000001, -0.02739, 0.37059000000000003, -0.02519, 0.36828, -0.30448000000000003, 0.38093000000000005, 0.40953000000000006, 0.16181, 0.40942, 0.16192, 0.4092, 0.16203, 0.40909000000000006, 0.16203, 0.40898000000000007, 0.16214, 0.40887, 0.16225, 0.40865, 0.16236000000000003, 0.40854, 0.16247, 0.40843000000000007, 0.16258, 0.40821, 0.16269000000000003, 0.4081, 0.16269000000000003, 0.40799, 0.1628, 0.40799, 0.1628, 0.4081, 0.16269000000000003, 0.40821, 0.16269000000000003, 0.40832, 0.16258, 0.40854, 0.16247, 0.40865, 0.16236000000000003, 0.40876, 0.16225, 0.40898000000000007, 0.16214, 0.40909000000000006, 0.16203, 0.4092, 0.16203, 0.40931, 0.16192, 0.40953000000000006, 0.16181, -0.31119, -0.14982, -0.31141, -0.14740000000000003, -0.31163, -0.14509, -0.31196000000000007, -0.14190000000000003, -0.31218, -0.13948000000000002, -0.3124, -0.13717000000000001, -0.31251000000000007, -0.13739, -0.31273, -0.13761, -0.31295, -0.13805, -0.31372000000000005, -0.13816, -0.31548000000000004, -0.13783, -0.31735, -0.1375, -0.31911000000000006, -0.13717000000000001, -0.32153000000000004, -0.13673, -0.3229600000000001, -0.13684000000000002, -0.32384, -0.13805, -0.32472000000000006, -0.13926, -0.32582000000000005, -0.1408, -0.32659000000000005, -0.14201, -0.32615, -0.14322000000000001, -0.32318, -0.14454, -0.32021000000000005, -0.14586000000000002, -0.31625, -0.14762000000000003, -0.31317000000000006, -0.14894000000000002, 0.09933000000000002, 0.27841, 0.09889, 0.27874000000000004, 0.09801, 0.27929000000000004, 0.09757, 0.27951000000000004, 0.09669000000000001, 0.28006000000000003, 0.09625, 0.28028000000000003, 0.09581, 0.28061, 0.09493000000000001, 0.28116, 0.09449000000000002, 0.2813800000000001, 0.09405000000000001, 0.28171, 0.09317, 0.28215, 0.09273, 0.28248, 0.09229000000000001, 0.2827, 0.09317, 0.28215, 0.09361, 0.28193, 0.09449000000000002, 0.2813800000000001, 0.09493000000000001, 0.28116, 0.09537000000000001, 0.2808300000000001, 0.09625, 0.28028000000000003, 0.09669000000000001, 0.28006000000000003, 0.09757, 0.27951000000000004, 0.09801, 0.27929000000000004, 0.09845000000000001, 0.27896000000000004, 0.09933000000000002, 0.27841, 0.08701000000000002, 0.16335, 0.08679, 0.16071000000000002, 0.08635000000000001, 0.15543, 0.08624000000000001, 0.15279, 0.0858, 0.14751, 0.08558, 0.14487000000000003, 0.08536, 0.14223000000000002, 0.08492000000000001, 0.13684000000000002, 0.08481000000000001, 0.1342, 0.08459, 0.13156, 0.08415, 0.12628, 0.08393000000000002, 0.12364000000000001, 0.08371, 0.12100000000000001, 0.08415, 0.12628, 0.08437000000000001, 0.12892, 0.08481000000000001, 0.1342, 0.08492000000000001, 0.13684000000000002, 0.08514000000000001, 0.13959000000000002, 0.08558, 0.14487000000000003, 0.0858, 0.14751, 0.08624000000000001, 0.15279, 0.08635000000000001, 0.15543, 0.08657000000000001, 0.15807000000000002, 0.08701000000000002, 0.16335, 0.23419000000000004, -0.22506, 0.23540000000000003, -0.22165000000000004, 0.23661000000000004, -0.21824000000000002, 0.23771, -0.21483000000000002, 0.23859000000000002, -0.21230000000000002, 0.24409, -0.19393000000000002, 0.25102, -0.17061, 0.25795, -0.14729, 0.26488, -0.12408000000000001, 0.26686000000000004, -0.11825000000000001, 0.26730000000000004, -0.11836, 0.26774000000000003, -0.11847000000000002, 0.26719000000000004, -0.12177000000000002, 0.26642000000000005, -0.12606, 0.26565, -0.13035, 0.26477, -0.13475, 0.26389, -0.13783, 0.26246, -0.14179, 0.26114000000000004, -0.14586000000000002, 0.25971000000000005, -0.14982, 0.25586000000000003, -0.16104000000000002, 0.25124, -0.17468, 0.24508000000000002, -0.19305, 0.23881, -0.21131, -0.29073, 0.1375, -0.33825, 0.026510000000000002, -0.33539, -0.030250000000000003, -0.33539, -0.030030000000000005, -0.33539, -0.02959, -0.33539, -0.02926, -0.33539, -0.028820000000000002, -0.33539, -0.0286, -0.33539, -0.028270000000000003, -0.33539, -0.02783, -0.33539, -0.027610000000000003, -0.33539, -0.027280000000000002, -0.33539, -0.026840000000000003, -0.33539, -0.02662, -0.33539, -0.026290000000000004, -0.33539, -0.026840000000000003, -0.33539, -0.027060000000000004, -0.33539, -0.027610000000000003, -0.33539, -0.02783, -0.33539, -0.028050000000000002, -0.33539, -0.0286, -0.33539, -0.028820000000000002, -0.33539, -0.02926, -0.33539, -0.02959, -0.33539, -0.02981, -0.33539, -0.030250000000000003, -0.33616, -0.07656, -0.33561, -0.07612000000000001, -0.33506, -0.07557, -0.33451000000000003, -0.07513, -0.33396, -0.07469, -0.33341, -0.07425000000000001, -0.33286, -0.07381000000000001, -0.33231, -0.07337, -0.33176, -0.07282, -0.33319000000000004, -0.07293000000000001, -0.33462000000000003, -0.07293000000000001, -0.33605, -0.07293000000000001, -0.33748000000000006, -0.07293000000000001, -0.33968000000000004, -0.07304000000000001, -0.34111, -0.07304000000000001, -0.34254, -0.07304000000000001, -0.34276, -0.07326000000000002, -0.3418800000000001, -0.07370000000000002, -0.341, -0.07414000000000001, -0.34012, -0.07458000000000001, -0.33924000000000004, -0.07502, -0.33836, -0.07546, -0.33748000000000006, -0.07590000000000001, -0.3366, -0.07634, 0.15279, -0.06105000000000001, -0.20647000000000001, -0.23606000000000002, -0.20790000000000003, -0.23859000000000002, -0.21065000000000003, -0.24365000000000003, -0.21208000000000002, -0.24618, -0.21494000000000002, -0.25113, -0.21626, -0.25366, -0.21769000000000002, -0.25619000000000003, -0.22055000000000002, -0.26114000000000004, -0.22198000000000004, -0.26367, -0.22330000000000003, -0.2662, -0.22616000000000003, -0.27126000000000006, -0.22759000000000001, -0.27368000000000003, -0.22902, -0.27621, -0.22616000000000003, -0.27126000000000006, -0.22473000000000004, -0.26873, -0.22198000000000004, -0.26367, -0.22055000000000002, -0.26114000000000004, -0.21912, -0.25872, -0.21626, -0.25366, -0.21494000000000002, -0.25113, -0.21208000000000002, -0.24618, -0.21065000000000003, -0.24365000000000003, -0.20922000000000002, -0.24112000000000003, -0.20647000000000001, -0.23606000000000002, -0.09141, -0.5220600000000001, -0.08536, -0.5192, -0.0814, -0.5173300000000001, -0.07535000000000001, -0.5144700000000001, -0.07139000000000001, -0.51249, -0.06534000000000001, -0.50963, -0.05929000000000001, -0.50677, -0.05918, -0.50699, -0.058960000000000005, -0.50732, -0.05874000000000001, -0.50754, -0.05863, -0.5077600000000001, -0.05852, -0.50798, -0.05808000000000001, -0.5082000000000001, -0.05775, -0.50831, -0.0572, -0.50853, -0.05687000000000001, -0.50875, -0.05632000000000001, -0.50897, -0.05577000000000001, -0.50919, -0.05786000000000001, -0.51007, -0.06457, -0.51249, -0.06908, -0.51403, -0.07579000000000001, -0.51645, -0.0825, -0.51887, -0.08701000000000002, -0.5205200000000001, 0.22957000000000002, -0.2376, 0.22946000000000003, -0.23782000000000003, 0.22935, -0.23815000000000003, 0.22924000000000003, -0.23826, 0.22913000000000003, -0.23848, 0.22902, -0.23881, 0.2288, -0.23903000000000002, 0.22869000000000003, -0.23925000000000002, 0.22869000000000003, -0.23947000000000002, 0.22847, -0.23969000000000004, 0.22836000000000004, -0.23958000000000002, 0.22825, -0.23947000000000002, 0.22803000000000004, -0.23947000000000002, 0.22803000000000004, -0.23936000000000002, 0.22781, -0.23925000000000002, 0.22781, -0.23914000000000002, 0.22814, -0.23892000000000002, 0.22825, -0.23881, 0.22847, -0.23859000000000002, 0.22869000000000003, -0.23837000000000003, 0.22891000000000003, -0.23815000000000003, 0.22913000000000003, -0.23804000000000003, 0.22924000000000003, -0.23793, 0.22946000000000003, -0.23771, -0.39215, -0.35871000000000003, -0.39435000000000003, -0.35662, -0.39754, -0.35343, -0.39974000000000004, -0.35134000000000004, -0.40304, -0.34815, -0.40513000000000005, -0.34606000000000003, -0.40733, -0.34386, -0.40931, -0.34166, -0.40887, -0.34155, -0.40821, -0.34133, -0.40777, -0.34122, -0.40711, -0.34089, -0.40667, -0.34078, -0.40623000000000004, -0.34067, -0.40590000000000004, -0.34078, -0.40579000000000004, -0.34089, -0.40568000000000004, -0.34122, -0.40557000000000004, -0.34133, -0.40304, -0.34463000000000005, -0.40139, -0.3468300000000001, -0.39974000000000004, -0.34892, -0.39721, -0.35222000000000003, -0.39545, -0.35442, -0.39303000000000005, -0.35761000000000004, 0.22781, -0.24365000000000003, 0.22781, -0.24354000000000003, 0.22792, -0.24354000000000003, 0.22792, -0.24343, 0.22803000000000004, -0.24343, 0.22814, -0.24321, 0.22825, -0.2431, 0.22836000000000004, -0.24299000000000004, 0.22847, -0.24288, 0.22847, -0.24277000000000004, 0.22858000000000003, -0.24277000000000004, 0.22858000000000003, -0.24266000000000001, 0.22858000000000003, -0.24266000000000001, 0.22858000000000003, -0.24277000000000004, 0.22847, -0.24277000000000004, 0.22847, -0.24288, 0.22836000000000004, -0.24299000000000004, 0.22825, -0.2431, 0.22814, -0.24321, 0.22803000000000004, -0.24332000000000004, 0.22803000000000004, -0.24343, 0.22792, -0.24354000000000003, 0.22781, -0.24354000000000003, 0.22781, -0.24365000000000003, -0.38753000000000004, -0.33176, -0.38555, -0.33176, -0.3834600000000001, -0.33176, -0.38148000000000004, -0.33176, -0.37939, -0.33176, -0.3773000000000001, -0.33176, -0.37653000000000003, -0.33176, -0.37620000000000003, -0.33176, -0.37587000000000004, -0.33165, -0.37576000000000004, -0.33044, -0.37576000000000004, -0.32857000000000003, -0.37576000000000004, -0.3267, -0.37576000000000004, -0.32483, -0.37576000000000004, -0.32307, -0.37565000000000004, -0.32186000000000003, -0.37532000000000004, -0.32175, -0.37510000000000004, -0.32175, -0.37356000000000006, -0.32494, -0.36971000000000004, -0.33440000000000003, -0.3657500000000001, -0.34386, -0.36179000000000006, -0.35332, -0.35783, -0.36278, -0.35398, -0.37235000000000007, -0.35387, -0.37257, -0.35376, -0.37290000000000006, -0.35365, -0.37323, -0.35783, -0.36806000000000005, -0.36421000000000003, -0.36036, -0.37059000000000003, -0.35255000000000003, -0.37697, -0.34474000000000005, -0.38324, -0.33704, -0.28853, -0.36377000000000004, -0.28853, -0.36399000000000004, -0.28864000000000006, -0.36432000000000003, -0.28875000000000006, -0.36443000000000003, -0.28886, -0.36476000000000003, -0.28776, -0.3652, -0.28622000000000003, -0.36586, -0.28523, -0.36619, -0.28358, -0.36685000000000006, -0.28259000000000006, -0.36729, -0.28105, -0.36795000000000005, -0.2805, -0.36784, -0.2805, -0.36707, -0.2805, -0.36652, -0.2805, -0.36597, -0.2805, -0.3652, -0.2805, -0.36465000000000003, -0.2805, -0.36377000000000004, -0.28149, -0.36377000000000004, -0.28303, -0.36377000000000004, -0.28402, -0.36377000000000004, -0.28556000000000004, -0.36377000000000004, -0.28655, -0.36377000000000004, -0.28798, -0.36377000000000004, -0.09801, -0.38005, -0.09911, -0.38005, -0.09988000000000001, -0.38005, -0.10098000000000001, -0.38005, -0.10219, -0.38005, -0.10285000000000001, -0.38005, -0.10406000000000001, -0.38005, -0.10439000000000001, -0.38082000000000005, -0.10472000000000002, -0.38137000000000004, -0.10516000000000002, -0.38214000000000004, -0.10549000000000001, -0.38291000000000003, -0.10582, -0.3834600000000001, -0.10626000000000002, -0.38423, -0.10593000000000001, -0.38423, -0.10571000000000001, -0.38423, -0.10549000000000001, -0.38434, -0.10516000000000002, -0.38434, -0.10494, -0.38434, -0.10428, -0.38412, -0.10307000000000001, -0.38324, -0.10219, -0.38280000000000003, -0.10098000000000001, -0.38192000000000004, -0.09966000000000001, -0.38115, -0.09889, -0.3806, -0.2255, -0.3468300000000001, -0.22462000000000001, -0.34540000000000004, -0.22374000000000002, -0.34397, -0.22297, -0.34254, -0.22209, -0.341, -0.22132000000000002, -0.33957, -0.22044000000000002, -0.33814000000000005, -0.21956, -0.33671, -0.21879, -0.33528, -0.21901, -0.34397, -0.21923000000000004, -0.35277000000000003, -0.21956, -0.36146000000000006, -0.21978000000000003, -0.37015000000000003, -0.22011000000000003, -0.38324, -0.22044000000000002, -0.39193000000000006, -0.22066000000000002, -0.40073000000000003, -0.22110000000000002, -0.40139, -0.22165000000000004, -0.39413000000000004, -0.22220000000000004, -0.38687000000000005, -0.22286000000000003, -0.37961000000000006, -0.22341000000000003, -0.37224, -0.22396000000000002, -0.36498, -0.22462000000000001, -0.35772000000000004, -0.22517, -0.35046000000000005, -0.21219000000000002, -0.3296700000000001, -0.21175000000000002, -0.33, -0.21120000000000003, -0.33033, -0.21076, -0.33055, -0.21032000000000003, -0.33088000000000006, -0.20988, -0.33121, -0.20933000000000002, -0.33154, -0.20889000000000002, -0.33176, -0.20845000000000002, -0.33209000000000005, -0.20889000000000002, -0.33440000000000003, -0.20944000000000004, -0.33682000000000006, -0.20988, -0.33913000000000004, -0.21032000000000003, -0.34155, -0.21109, -0.34507, -0.21153000000000002, -0.3473800000000001, -0.21208000000000002, -0.34969000000000006, -0.21230000000000002, -0.34958000000000006, -0.21230000000000002, -0.34694, -0.21219000000000002, -0.34430000000000005, -0.21219000000000002, -0.34166, -0.21219000000000002, -0.33902, -0.21219000000000002, -0.33638000000000007, -0.21219000000000002, -0.33363000000000004, -0.21219000000000002, -0.33099, 0.27775000000000005, -0.41217, 0.27643000000000006, -0.4136, 0.27555, -0.41459000000000007, 0.27434000000000003, -0.41591, 0.27302000000000004, -0.41723000000000005, 0.27324000000000004, -0.41635000000000005, 0.27423000000000003, -0.4139300000000001, 0.27522, -0.41140000000000004, 0.27588000000000007, -0.40953000000000006, 0.27676, -0.40766, 0.27709000000000006, -0.40777, 0.27731, -0.4078800000000001, 0.27797, -0.40711, 0.27907, -0.40535000000000004, 0.27984000000000003, -0.40414000000000005, 0.28094, -0.40249, 0.28182, -0.4011700000000001, 0.28215, -0.40139, 0.28248, -0.40161, 0.28292, -0.40183, 0.28479000000000004, -0.39809000000000005, 0.28622000000000003, -0.39534, 0.28809000000000007, -0.39171000000000006, 0.28996000000000005, -0.38797000000000004, 0.29073, -0.3872, 0.29117000000000004, -0.38742000000000004, 0.29161000000000004, -0.38753000000000004, 0.29205000000000003, -0.3872, 0.29271, -0.38632000000000005, 0.29337, -0.38544, 0.29392, -0.38478, 0.29447, -0.38412, 0.29480000000000006, -0.38434, 0.29502, -0.38445, 0.29557, -0.38445, 0.29689, -0.38368, 0.29788000000000003, -0.38324, 0.2992, -0.38247000000000003, 0.30041, -0.38181000000000004, 0.30019, -0.38368, 0.29997, -0.3861, 0.29964, -0.38863000000000003, 0.29942, -0.3905, 0.29942, -0.39182000000000006, 0.29986, -0.39215, 0.30008, -0.39226, 0.30052, -0.39248000000000005, 0.30239, -0.39116000000000006, 0.30426000000000003, -0.38984, 0.30558, -0.38885000000000003, 0.30745000000000006, -0.38742000000000004, 0.30833, -0.38654, 0.30866000000000005, -0.38599, 0.30910000000000004, -0.38522000000000006, 0.30954, -0.38445, 0.30998000000000003, -0.38423, 0.31031000000000003, -0.38445, 0.31064, -0.38478, 0.30657, -0.38830000000000003, 0.29832000000000003, -0.39512, 0.29007, -0.40194, 0.28391, -0.40711, -0.03619, -0.39655, -0.04059000000000001, -0.39556, -0.04499, -0.39446, -0.05049000000000001, -0.39325, -0.05324, -0.3916, -0.05137, -0.38830000000000003, -0.0495, -0.385, -0.04752000000000001, -0.38181000000000004, -0.04587000000000001, -0.37906000000000006, -0.04488000000000001, -0.37818, -0.044000000000000004, -0.3773000000000001, -0.043120000000000006, -0.37653000000000003, -0.04191, -0.37598000000000004, -0.04048, -0.37543000000000004, -0.038610000000000005, -0.37488000000000005, -0.037070000000000006, -0.37444, -0.04015, -0.37169, -0.04488000000000001, -0.36828, -0.0495, -0.36487, -0.055330000000000004, -0.36069000000000007, -0.057420000000000006, -0.36311000000000004, -0.0594, -0.36564, -0.06138000000000001, -0.36806000000000005, -0.06347000000000001, -0.37059000000000003, -0.05665, -0.37708, -0.04807000000000001, -0.38522000000000006, -0.04125, -0.39171000000000006
        )
        val pts = ArrayList<ShapePoint>()
        val count = coords.size / 2
        for (i in 0 until count) {
            val x = coords[i * 2]
            val y = coords[i * 2 + 1]
            val progress = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
            pts.add(
                ShapePoint(
                    x = x,
                    y = y,
                    role = if (i % 3 == 0) "logo-flame-spark" else "logo-flame-inner",
                    progress = progress
                )
            )
        }
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
