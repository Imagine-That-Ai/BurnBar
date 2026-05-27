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
import com.openburnbar.ui.theme.LocalUIMode
import com.openburnbar.ui.theme.UIMode
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

    val uiMode = LocalUIMode.current
    val selectedProviderGlyphs = enabledProviderGlyphs ?: AgentProvider.swarmGlyphProviders.toSet()
    val simulation = remember(particleCount, pace, selectedProviderGlyphs, actualExcludeBrandShapes, uiMode) {
        SwarmSimulation(
            particleCount = particleCount,
            pace = pace,
            context = context.applicationContext,
            enabledProviderGlyphs = selectedProviderGlyphs,
            excludeBrandShapes = actualExcludeBrandShapes,
            uiMode = uiMode
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
    val uiMode: UIMode = UIMode.STANDARD,
    private val clockNanos: () -> Long = System::nanoTime
) {
    private val appContext = context?.applicationContext

    enum class Mode {
        SWARM,
        SHAPE_DOLLAR,
        SHAPE_CODE,
        SHAPE_RINGS,
        SHAPE_ROUTER_FLOW,
        SHAPE_COOKING_5,
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

    private val speedMultiplier: Double
        get() = if (isEnergetic) 1.0 else 0.35

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
    private val skilletPoints by lazy { sampleTextPoints("🍳", 220f) }
    private val applePoints by lazy { sampleTextPoints("🍎", 220f) }
    private val chefHatPoints by lazy { sampleTextPoints("👨‍🍳", 220f) }
    private val chiliPoints by lazy { sampleTextPoints("🌶️", 220f) }
    private val appleSplinePoints by lazy { generateApplePoints() }
    private val cherrySplinePoints by lazy { generateCherryPoints() }
    private val bananaSplinePoints by lazy { generateBananaPoints() }
    private val cookieSplinePoints by lazy { generateCookiePoints() }
    private val cupcakeSplinePoints by lazy { generateCupcakePoints() }
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
                val role = p.role
                if (mode == Mode.SHAPE_ROUTER_FLOW && uiMode != UIMode.COOKING && role != null) {
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
                        val attract = if (isRewinding) -morphAttract * 1.5 else morphAttract
                        p.vx += (dx / dist) * attract
                        p.vy += (dy / dist) * attract
                    }
                    p.vx += noiseX * morphNoise + pushX
                    p.vy += noiseY * morphNoise + pushY
                    p.vx *= morphDrag
                    p.vy *= morphDrag
                    p.x += p.vx
                    p.y += p.vy
                    if (p.x < 0) p.x = width
                    if (p.x > width) p.x = 0.0
                    if (p.y < 0) p.y = height
                    if (p.y > height) p.y = 0.0
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

        val pts: List<ShapePoint> = if (uiMode == UIMode.COOKING) {
            when (next) {
                Mode.SHAPE_DOLLAR -> appleSplinePoints
                Mode.SHAPE_CODE -> cherrySplinePoints
                Mode.SHAPE_RINGS -> bananaSplinePoints
                Mode.SHAPE_ROUTER_FLOW -> cookieSplinePoints
                Mode.SHAPE_COOKING_5 -> cupcakeSplinePoints
                else -> emptyList()
            }
        } else {
            when (next) {
                Mode.SHAPE_DOLLAR -> dollarPoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
                Mode.SHAPE_CODE -> codePoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
                Mode.SHAPE_RINGS -> ringPoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
                Mode.SHAPE_ROUTER_FLOW -> routerFlowPoints.map { ShapePoint(it.x, it.y, it.role, it.progress) }
                else -> emptyList()
            }
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
                particles[particleIdx].logoColor = pt.color
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

    private val effectiveShapeSettleFallbackNanos: Long
        get() = (SHAPE_SETTLE_FALLBACK_NANOS / speedMultiplier).toLong()

    private fun shouldDelayCycleForAdmireHold(nowNanos: Long): Boolean {
        if (!mode.requiresSettledAdmireHold()) return false

        if (shapeSettledAtNanos == null) {
            if (
                currentShapeIsSettled() ||
                nowNanos - modeAssignedAtNanos >= cycleIntervalNanos + effectiveShapeSettleFallbackNanos
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
        // Tighten the threshold at slower speeds so particles must form a sharper,
        // fully-settled shape before starting the hold/admire timer.
        val baseThreshold = maxOf(22.0, min(bounds.width, bounds.height).toDouble() * 0.022)
        val threshold = baseThreshold * speedMultiplier.coerceIn(0.5, 1.0)

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

        p.logoColor?.let { source ->
            return source.copy(alpha = (opacity * 1.62f).coerceAtMost(1f))
        }

        if (uiMode == UIMode.COOKING) {
            val fruityColors = listOf(
                Color(0xFFFF2A6D), // Dragonfruit Pink
                Color(0xFFFF5E3A), // Tangerine Orange
                Color(0xFFFFD700), // Honey Mango Yellow
                Color(0xFF2ECC71), // Mint Basil Green
                Color(0xFF00F5FF), // Electric Blueberry Blue
                Color(0xFF9B59B6), // Fig Plum Purple
                Color(0xFFFF1493), // Strawberry Pink
                Color(0xFF7FFF00)  // Lime Kiwi Green
            )
            val idx = (p.colorIndex * fruityColors.size).toInt().coerceIn(0, fruityColors.size - 1)
            val baseColor = fruityColors[idx]
            return baseColor.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
        }

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
        if (uiMode == UIMode.COOKING) {
            add(Mode.SWARM)
            add(Mode.SHAPE_DOLLAR)       // Apple
            add(Mode.SWARM)
            add(Mode.SHAPE_CODE)         // Cherry
            add(Mode.SWARM)
            add(Mode.SHAPE_RINGS)        // Banana
            add(Mode.SWARM)
            add(Mode.SHAPE_ROUTER_FLOW)  // Cookie
            add(Mode.SWARM)
            add(Mode.SHAPE_COOKING_5)    // Cupcake
        } else if (excludeBrandShapes) {
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

    private fun generateSpline(
        controlPoints: List<Pair<Double, Double>>,
        stepsPerSegment: Int,
        colorStart: Color,
        colorEnd: Color = colorStart,
        isClosed: Boolean = true,
        role: String = "cooking"
    ): List<ShapePoint> {
        if (controlPoints.isEmpty()) return emptyList()
        val pts = ArrayList<ShapePoint>()
        val n = controlPoints.size

        if (isClosed) {
            if (n < 3) return emptyList()
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
                    val progress = (i * stepsPerSegment + j).toDouble() / (n * stepsPerSegment).toDouble()
                    val color = blend(colorStart, colorEnd, progress.toFloat())
                    pts.add(ShapePoint(x, y, role, progress, color))
                }
            }
        } else {
            if (n < 2) return emptyList()
            val padded = ArrayList<Pair<Double, Double>>()
            padded.add(controlPoints.first())
            padded.addAll(controlPoints)
            padded.add(controlPoints.last())

            val pn = padded.size
            val segments = pn - 3
            for (i in 0 until segments) {
                val p0 = padded[i]
                val p1 = padded[i + 1]
                val p2 = padded[i + 2]
                val p3 = padded[i + 3]
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
                    val progress = (i * stepsPerSegment + j).toDouble() / (segments * stepsPerSegment).toDouble()
                    val color = blend(colorStart, colorEnd, progress.toFloat())
                    pts.add(ShapePoint(x, y, role, progress, color))
                }
            }
        }
        return pts
    }

    private fun generateApplePoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val bodyCtrls = listOf(
            0.0 to -0.22,
            0.18 to -0.42,
            0.46 to -0.32,
            0.56 to -0.06,
            0.42 to 0.28,
            0.16 to 0.44,
            0.0 to 0.36,
            -0.16 to 0.44,
            -0.42 to 0.28,
            -0.56 to -0.06,
            -0.46 to -0.32,
            -0.18 to -0.42
        )
        pts.addAll(generateSpline(bodyCtrls, 30, Color(0xFFFF2A6D), Color(0xFFFF5E3A), isClosed = true))

        val stemCtrls = listOf(
            0.0 to -0.25,
            0.02 to -0.38,
            0.08 to -0.50,
            0.15 to -0.58
        )
        pts.addAll(generateSpline(stemCtrls, 15, Color(0xFF8E5A32), Color(0xFF5C4033), isClosed = false))

        val leafCtrls = listOf(
            0.06 to -0.46,
            0.18 to -0.58,
            0.32 to -0.58,
            0.18 to -0.42
        )
        pts.addAll(generateSpline(leafCtrls, 20, Color(0xFF2ECC71), Color(0xFF7FFF00), isClosed = true))
        return pts
    }

    private fun generateCherryPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val leftCherryCtrls = listOf(
            -0.25 to 0.06,
            -0.13 to 0.12,
            -0.08 to 0.22,
            -0.14 to 0.32,
            -0.25 to 0.38,
            -0.36 to 0.32,
            -0.42 to 0.22,
            -0.36 to 0.12
        )
        pts.addAll(generateSpline(leftCherryCtrls, 25, Color(0xFFFF1493), Color(0xFFFF2A6D), isClosed = true))

        val rightCherryCtrls = listOf(
            0.22 to 0.14,
            0.33 to 0.20,
            0.38 to 0.30,
            0.32 to 0.40,
            0.22 to 0.46,
            0.12 to 0.40,
            0.06 to 0.30,
            0.12 to 0.20
        )
        pts.addAll(generateSpline(rightCherryCtrls, 25, Color(0xFFFF2A6D), Color(0xFF9B59B6), isClosed = true))

        val leftStemCtrls = listOf(
            0.0 to -0.32,
            -0.05 to -0.18,
            -0.15 to -0.05,
            -0.25 to 0.08
        )
        pts.addAll(generateSpline(leftStemCtrls, 15, Color(0xFF2ECC71), Color(0xFF27AE60), isClosed = false))

        val rightStemCtrls = listOf(
            0.0 to -0.32,
            0.08 to -0.15,
            0.16 to 0.0,
            0.22 to 0.16
        )
        pts.addAll(generateSpline(rightStemCtrls, 15, Color(0xFF2ECC71), Color(0xFF27AE60), isClosed = false))

        val leafCtrls = listOf(
            0.0 to -0.32,
            0.12 to -0.45,
            0.28 to -0.48,
            0.15 to -0.30
        )
        pts.addAll(generateSpline(leafCtrls, 20, Color(0xFF7FFF00), Color(0xFF2ECC71), isClosed = true))
        return pts
    }

    private fun generateBananaPoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val bananaCtrls = listOf(
            0.15 to -0.48,
            0.18 to -0.38,
            0.05 to -0.15,
            -0.12 to 0.08,
            -0.22 to 0.30,
            -0.24 to 0.40,
            -0.16 to 0.34,
            0.02 to 0.12,
            0.16 to -0.15,
            0.08 to -0.42
        )
        val splinePoints = generateSpline(bananaCtrls, 45, Color(0xFFFFD700), Color(0xFFFF5E3A), isClosed = true)
        val texturedPoints = splinePoints.map { pt ->
            val color = when {
                pt.progress < 0.18 -> Color(0xFF5C4033)
                pt.progress < 0.28 -> Color(0xFF7FFF00)
                pt.progress < 0.85 -> Color(0xFFFFD700)
                else -> Color(0xFF2C3E50)
            }
            pt.copy(color = color)
        }
        pts.addAll(texturedPoints)
        return pts
    }

    private fun generateCookiePoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val baseCtrls = ArrayList<Pair<Double, Double>>()
        val segments = 12
        for (i in 0 until segments) {
            val angle = PI * 2.0 * i.toDouble() / segments.toDouble()
            val bump = 0.03 * sin(angle * 3.5)
            val r = 0.45 + bump
            baseCtrls.add(cos(angle) * r to sin(angle) * r)
        }
        pts.addAll(generateSpline(baseCtrls, 30, Color(0xFFE5A96A), Color(0xFFC68B59), isClosed = true))

        val chipCenters = listOf(
            -0.15 to -0.15,
            0.18 to -0.10,
            0.05 to 0.18,
            -0.18 to 0.12,
            0.0 to -0.28
        )
        for ((cx, cy) in chipCenters) {
            val chipCtrls = listOf(
                cx - 0.04 to cy,
                cx to cy - 0.03,
                cx + 0.05 to cy,
                cx to cy + 0.04
            )
            pts.addAll(generateSpline(chipCtrls, 8, Color(0xFF3D2723), Color(0xFF1E1610), isClosed = true))
        }
        return pts
    }

    private fun generateCupcakePoints(): List<ShapePoint> {
        val pts = ArrayList<ShapePoint>()
        val linerCtrls = listOf(
            -0.30 to 0.35,
            0.30 to 0.35,
            0.36 to 0.05,
            -0.36 to 0.05
        )
        pts.addAll(generateSpline(linerCtrls, 40, Color(0xFF5DADE2), Color(0xFF3498DB), isClosed = true))

        val pleatsX = listOf(-0.2, -0.1, 0.0, 0.1, 0.2)
        for (px in pleatsX) {
            val startX = px * 0.9
            val endX = px * 1.05
            val pleatCtrls = listOf(
                startX to 0.35,
                (startX + endX) * 0.5 to 0.20,
                endX to 0.05
            )
            pts.addAll(generateSpline(pleatCtrls, 12, Color(0xFF2E86C1), Color(0xFF5DADE2), isClosed = false))
        }

        val frostingCtrls = listOf(
            -0.38 to 0.05,
            -0.36 to -0.10,
            -0.28 to -0.15,
            -0.25 to -0.28,
            -0.14 to -0.32,
            0.0 to -0.45,
            0.14 to -0.32,
            0.25 to -0.28,
            0.28 to -0.15,
            0.36 to -0.10,
            0.38 to 0.05,
            0.0 to 0.08
        )
        pts.addAll(generateSpline(frostingCtrls, 25, Color(0xFF8E44AD), Color(0xFFFFB7B2), isClosed = true))

        val cherryCtrls = listOf(
            0.0 to -0.46,
            0.05 to -0.51,
            0.0 to -0.56,
            -0.05 to -0.51
        )
        pts.addAll(generateSpline(cherryCtrls, 12, Color(0xFFFF2A6D), Color(0xFFFF1493), isClosed = true))

        val stemCtrls = listOf(
            0.0 to -0.54,
            0.04 to -0.62,
            0.12 to -0.68
        )
        pts.addAll(generateSpline(stemCtrls, 10, Color(0xFF8E5A32), Color(0xFF5C4033), isClosed = false))
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
        return listOf(
            ShapePoint(x = -0.2187, y = -0.0278, role = "logo-flame-spark", progress = 0.000000),
            ShapePoint(x = -0.2072, y = -0.0314, role = "logo-flame-inner", progress = 0.001311),
            ShapePoint(x = -0.1368, y = 0.0863, role = "logo-flame-inner", progress = 0.002621),
            ShapePoint(x = -0.1251, y = 0.0878, role = "logo-flame-inner", progress = 0.003932),
            ShapePoint(x = -0.1139, y = 0.0874, role = "logo-flame-spark", progress = 0.005242),
            ShapePoint(x = -0.1022, y = 0.0834, role = "logo-flame-inner", progress = 0.006553),
            ShapePoint(x = -0.0917, y = 0.0793, role = "logo-flame-inner", progress = 0.007864),
            ShapePoint(x = -0.0834, y = 0.0705, role = "logo-flame-inner", progress = 0.009174),
            ShapePoint(x = -0.0725, y = 0.0649, role = "logo-flame-spark", progress = 0.010485),
            ShapePoint(x = -0.0623, y = 0.0595, role = "logo-flame-inner", progress = 0.011796),
            ShapePoint(x = -0.0521, y = 0.0551, role = "logo-flame-inner", progress = 0.013106),
            ShapePoint(x = -0.0632, y = 0.0485, role = "logo-flame-inner", progress = 0.014417),
            ShapePoint(x = -0.0679, y = 0.0379, role = "logo-flame-spark", progress = 0.015727),
            ShapePoint(x = -0.0778, y = 0.0315, role = "logo-flame-inner", progress = 0.017038),
            ShapePoint(x = -0.0871, y = 0.0251, role = "logo-flame-inner", progress = 0.018349),
            ShapePoint(x = -0.0969, y = 0.0196, role = "logo-flame-inner", progress = 0.019659),
            ShapePoint(x = -0.1078, y = 0.0190, role = "logo-flame-spark", progress = 0.020970),
            ShapePoint(x = -0.1190, y = 0.0200, role = "logo-flame-inner", progress = 0.022280),
            ShapePoint(x = -0.1300, y = 0.0206, role = "logo-flame-inner", progress = 0.023591),
            ShapePoint(x = -0.1402, y = 0.0255, role = "logo-flame-inner", progress = 0.024902),
            ShapePoint(x = -0.1506, y = 0.0292, role = "logo-flame-spark", progress = 0.026212),
            ShapePoint(x = -0.0796, y = 0.0428, role = "logo-flame-inner", progress = 0.027523),
            ShapePoint(x = -0.0852, y = 0.0530, role = "logo-flame-inner", progress = 0.028834),
            ShapePoint(x = -0.0954, y = 0.0489, role = "logo-flame-inner", progress = 0.030144),
            ShapePoint(x = -0.0981, y = 0.0370, role = "logo-flame-spark", progress = 0.031455),
            ShapePoint(x = -0.1100, y = 0.0329, role = "logo-flame-inner", progress = 0.032765),
            ShapePoint(x = -0.1243, y = 0.0340, role = "logo-flame-inner", progress = 0.034076),
            ShapePoint(x = -0.1308, y = 0.0434, role = "logo-flame-inner", progress = 0.035387),
            ShapePoint(x = -0.1339, y = 0.0549, role = "logo-flame-spark", progress = 0.036697),
            ShapePoint(x = -0.1451, y = 0.0515, role = "logo-flame-inner", progress = 0.038008),
            ShapePoint(x = -0.1531, y = 0.0596, role = "logo-flame-inner", progress = 0.039318),
            ShapePoint(x = -0.1567, y = 0.0702, role = "logo-flame-inner", progress = 0.040629),
            ShapePoint(x = -0.1484, y = 0.0805, role = "logo-flame-spark", progress = 0.041940),
            ShapePoint(x = -0.1480, y = 0.0404, role = "logo-flame-inner", progress = 0.043250),
            ShapePoint(x = -0.0173, y = 0.3997, role = "logo-flame-inner", progress = 0.044561),
            ShapePoint(x = -0.0060, y = 0.4000, role = "logo-flame-inner", progress = 0.045872),
            ShapePoint(x = 0.0054, y = 0.3997, role = "logo-flame-spark", progress = 0.047182),
            ShapePoint(x = 0.0177, y = 0.3990, role = "logo-flame-inner", progress = 0.048493),
            ShapePoint(x = 0.0300, y = 0.3976, role = "logo-flame-inner", progress = 0.049803),
            ShapePoint(x = 0.0420, y = 0.3955, role = "logo-flame-inner", progress = 0.051114),
            ShapePoint(x = 0.0539, y = 0.3928, role = "logo-flame-spark", progress = 0.052425),
            ShapePoint(x = 0.0658, y = 0.3897, role = "logo-flame-inner", progress = 0.053735),
            ShapePoint(x = 0.0789, y = 0.3857, role = "logo-flame-inner", progress = 0.055046),
            ShapePoint(x = 0.0926, y = 0.3810, role = "logo-flame-inner", progress = 0.056356),
            ShapePoint(x = 0.1061, y = 0.3756, role = "logo-flame-spark", progress = 0.057667),
            ShapePoint(x = 0.1313, y = 0.3568, role = "logo-flame-inner", progress = 0.058978),
            ShapePoint(x = 0.1476, y = 0.3422, role = "logo-flame-inner", progress = 0.060288),
            ShapePoint(x = 0.1640, y = 0.3275, role = "logo-flame-inner", progress = 0.061599),
            ShapePoint(x = 0.1804, y = 0.3128, role = "logo-flame-spark", progress = 0.062910),
            ShapePoint(x = 0.1968, y = 0.2981, role = "logo-flame-inner", progress = 0.064220),
            ShapePoint(x = 0.2132, y = 0.2834, role = "logo-flame-inner", progress = 0.065531),
            ShapePoint(x = 0.2188, y = 0.2740, role = "logo-flame-inner", progress = 0.066841),
            ShapePoint(x = 0.2241, y = 0.2643, role = "logo-flame-spark", progress = 0.068152),
            ShapePoint(x = 0.2290, y = 0.2544, role = "logo-flame-inner", progress = 0.069463),
            ShapePoint(x = 0.2336, y = 0.2444, role = "logo-flame-inner", progress = 0.070773),
            ShapePoint(x = 0.2378, y = 0.2341, role = "logo-flame-inner", progress = 0.072084),
            ShapePoint(x = 0.2422, y = 0.2230, role = "logo-flame-spark", progress = 0.073394),
            ShapePoint(x = 0.2466, y = 0.2119, role = "logo-flame-inner", progress = 0.074705),
            ShapePoint(x = 0.2508, y = 0.2007, role = "logo-flame-inner", progress = 0.076016),
            ShapePoint(x = 0.2548, y = 0.1894, role = "logo-flame-inner", progress = 0.077326),
            ShapePoint(x = 0.2586, y = 0.1780, role = "logo-flame-spark", progress = 0.078637),
            ShapePoint(x = 0.2623, y = 0.1649, role = "logo-flame-inner", progress = 0.079948),
            ShapePoint(x = 0.2656, y = 0.1516, role = "logo-flame-inner", progress = 0.081258),
            ShapePoint(x = 0.2685, y = 0.1383, role = "logo-flame-inner", progress = 0.082569),
            ShapePoint(x = 0.2712, y = 0.1249, role = "logo-flame-spark", progress = 0.083879),
            ShapePoint(x = 0.2738, y = 0.1115, role = "logo-flame-inner", progress = 0.085190),
            ShapePoint(x = 0.2767, y = 0.0963, role = "logo-flame-inner", progress = 0.086501),
            ShapePoint(x = 0.2795, y = 0.0812, role = "logo-flame-inner", progress = 0.087811),
            ShapePoint(x = 0.2824, y = 0.0661, role = "logo-flame-spark", progress = 0.089122),
            ShapePoint(x = 0.2851, y = 0.0539, role = "logo-flame-inner", progress = 0.090433),
            ShapePoint(x = 0.2883, y = 0.0395, role = "logo-flame-inner", progress = 0.091743),
            ShapePoint(x = 0.2916, y = 0.0251, role = "logo-flame-inner", progress = 0.093054),
            ShapePoint(x = 0.2950, y = 0.0107, role = "logo-flame-spark", progress = 0.094364),
            ShapePoint(x = 0.2983, y = -0.0037, role = "logo-flame-inner", progress = 0.095675),
            ShapePoint(x = 0.3018, y = -0.0190, role = "logo-flame-inner", progress = 0.096986),
            ShapePoint(x = 0.3058, y = -0.0352, role = "logo-flame-inner", progress = 0.098296),
            ShapePoint(x = 0.3099, y = -0.0513, role = "logo-flame-spark", progress = 0.099607),
            ShapePoint(x = 0.3142, y = -0.0674, role = "logo-flame-inner", progress = 0.100917),
            ShapePoint(x = 0.3187, y = -0.0834, role = "logo-flame-inner", progress = 0.102228),
            ShapePoint(x = 0.3220, y = -0.0949, role = "logo-flame-inner", progress = 0.103539),
            ShapePoint(x = 0.3249, y = -0.1056, role = "logo-flame-spark", progress = 0.104849),
            ShapePoint(x = 0.3277, y = -0.1164, role = "logo-flame-inner", progress = 0.106160),
            ShapePoint(x = 0.3304, y = -0.1271, role = "logo-flame-inner", progress = 0.107471),
            ShapePoint(x = 0.3335, y = -0.1402, role = "logo-flame-inner", progress = 0.108781),
            ShapePoint(x = 0.3361, y = -0.1535, role = "logo-flame-spark", progress = 0.110092),
            ShapePoint(x = 0.3383, y = -0.1668, role = "logo-flame-inner", progress = 0.111402),
            ShapePoint(x = 0.3398, y = -0.1796, role = "logo-flame-inner", progress = 0.112713),
            ShapePoint(x = 0.3408, y = -0.1907, role = "logo-flame-inner", progress = 0.114024),
            ShapePoint(x = 0.3412, y = -0.2040, role = "logo-flame-spark", progress = 0.115334),
            ShapePoint(x = 0.3409, y = -0.2187, role = "logo-flame-inner", progress = 0.116645),
            ShapePoint(x = 0.3403, y = -0.2326, role = "logo-flame-inner", progress = 0.117955),
            ShapePoint(x = 0.3387, y = -0.2448, role = "logo-flame-inner", progress = 0.119266),
            ShapePoint(x = 0.3364, y = -0.2569, role = "logo-flame-spark", progress = 0.120577),
            ShapePoint(x = 0.3332, y = -0.2689, role = "logo-flame-inner", progress = 0.121887),
            ShapePoint(x = 0.3230, y = -0.2872, role = "logo-flame-inner", progress = 0.123198),
            ShapePoint(x = 0.3128, y = -0.3055, role = "logo-flame-inner", progress = 0.124509),
            ShapePoint(x = 0.3027, y = -0.3238, role = "logo-flame-spark", progress = 0.125819),
            ShapePoint(x = 0.3143, y = -0.3183, role = "logo-flame-inner", progress = 0.127130),
            ShapePoint(x = 0.3248, y = -0.3065, role = "logo-flame-inner", progress = 0.128440),
            ShapePoint(x = 0.3322, y = -0.2969, role = "logo-flame-inner", progress = 0.129751),
            ShapePoint(x = 0.3389, y = -0.2869, role = "logo-flame-spark", progress = 0.131062),
            ShapePoint(x = 0.3451, y = -0.2765, role = "logo-flame-inner", progress = 0.132372),
            ShapePoint(x = 0.3507, y = -0.2657, role = "logo-flame-inner", progress = 0.133683),
            ShapePoint(x = 0.3552, y = -0.2507, role = "logo-flame-inner", progress = 0.134993),
            ShapePoint(x = 0.3588, y = -0.2316, role = "logo-flame-spark", progress = 0.136304),
            ShapePoint(x = 0.3624, y = -0.2125, role = "logo-flame-inner", progress = 0.137615),
            ShapePoint(x = 0.3639, y = -0.1987, role = "logo-flame-inner", progress = 0.138925),
            ShapePoint(x = 0.3623, y = -0.1862, role = "logo-flame-inner", progress = 0.140236),
            ShapePoint(x = 0.3592, y = -0.1741, role = "logo-flame-spark", progress = 0.141547),
            ShapePoint(x = 0.3542, y = -0.1625, role = "logo-flame-inner", progress = 0.142857),
            ShapePoint(x = 0.3752, y = -0.1895, role = "logo-flame-inner", progress = 0.144168),
            ShapePoint(x = 0.3790, y = -0.2003, role = "logo-flame-inner", progress = 0.145478),
            ShapePoint(x = 0.3815, y = -0.2114, role = "logo-flame-spark", progress = 0.146789),
            ShapePoint(x = 0.3829, y = -0.2229, role = "logo-flame-inner", progress = 0.148100),
            ShapePoint(x = 0.3806, y = -0.2397, role = "logo-flame-inner", progress = 0.149410),
            ShapePoint(x = 0.3780, y = -0.2507, role = "logo-flame-inner", progress = 0.150721),
            ShapePoint(x = 0.3754, y = -0.2616, role = "logo-flame-spark", progress = 0.152031),
            ShapePoint(x = 0.3728, y = -0.2725, role = "logo-flame-inner", progress = 0.153342),
            ShapePoint(x = 0.3702, y = -0.2835, role = "logo-flame-inner", progress = 0.154653),
            ShapePoint(x = 0.3676, y = -0.2944, role = "logo-flame-inner", progress = 0.155963),
            ShapePoint(x = 0.3597, y = -0.3069, role = "logo-flame-spark", progress = 0.157274),
            ShapePoint(x = 0.3506, y = -0.3180, role = "logo-flame-inner", progress = 0.158585),
            ShapePoint(x = 0.3404, y = -0.3280, role = "logo-flame-inner", progress = 0.159895),
            ShapePoint(x = 0.3290, y = -0.3368, role = "logo-flame-inner", progress = 0.161206),
            ShapePoint(x = 0.3167, y = -0.3446, role = "logo-flame-spark", progress = 0.162516),
            ShapePoint(x = 0.3069, y = -0.3499, role = "logo-flame-inner", progress = 0.163827),
            ShapePoint(x = 0.2969, y = -0.3549, role = "logo-flame-inner", progress = 0.165138),
            ShapePoint(x = 0.2886, y = -0.3627, role = "logo-flame-inner", progress = 0.166448),
            ShapePoint(x = 0.2857, y = -0.3738, role = "logo-flame-spark", progress = 0.167759),
            ShapePoint(x = 0.2856, y = -0.3852, role = "logo-flame-inner", progress = 0.169069),
            ShapePoint(x = 0.2746, y = -0.3816, role = "logo-flame-inner", progress = 0.170380),
            ShapePoint(x = 0.2721, y = -0.3698, role = "logo-flame-inner", progress = 0.171691),
            ShapePoint(x = 0.2679, y = -0.3583, role = "logo-flame-spark", progress = 0.173001),
            ShapePoint(x = 0.2596, y = -0.3449, role = "logo-flame-inner", progress = 0.174312),
            ShapePoint(x = 0.2515, y = -0.3348, role = "logo-flame-inner", progress = 0.175623),
            ShapePoint(x = 0.2434, y = -0.3247, role = "logo-flame-inner", progress = 0.176933),
            ShapePoint(x = 0.2344, y = -0.3168, role = "logo-flame-spark", progress = 0.178244),
            ShapePoint(x = 0.2244, y = -0.3109, role = "logo-flame-inner", progress = 0.179554),
            ShapePoint(x = 0.2144, y = -0.3051, role = "logo-flame-inner", progress = 0.180865),
            ShapePoint(x = 0.2018, y = -0.3007, role = "logo-flame-inner", progress = 0.182176),
            ShapePoint(x = 0.1902, y = -0.2986, role = "logo-flame-spark", progress = 0.183486),
            ShapePoint(x = 0.1791, y = -0.2982, role = "logo-flame-inner", progress = 0.184797),
            ShapePoint(x = 0.2703, y = -0.3920, role = "logo-flame-inner", progress = 0.186107),
            ShapePoint(x = 0.2620, y = -0.3845, role = "logo-flame-inner", progress = 0.187418),
            ShapePoint(x = 0.2522, y = -0.3700, role = "logo-flame-spark", progress = 0.188729),
            ShapePoint(x = 0.2443, y = -0.3607, role = "logo-flame-inner", progress = 0.190039),
            ShapePoint(x = 0.2364, y = -0.3515, role = "logo-flame-inner", progress = 0.191350),
            ShapePoint(x = 0.2285, y = -0.3423, role = "logo-flame-inner", progress = 0.192661),
            ShapePoint(x = 0.2206, y = -0.3330, role = "logo-flame-spark", progress = 0.193971),
            ShapePoint(x = 0.2127, y = -0.3238, role = "logo-flame-inner", progress = 0.195282),
            ShapePoint(x = 0.2025, y = -0.3164, role = "logo-flame-inner", progress = 0.196592),
            ShapePoint(x = 0.1910, y = -0.3119, role = "logo-flame-inner", progress = 0.197903),
            ShapePoint(x = 0.1721, y = -0.3079, role = "logo-flame-spark", progress = 0.199214),
            ShapePoint(x = 0.1604, y = -0.3075, role = "logo-flame-inner", progress = 0.200524),
            ShapePoint(x = 0.1479, y = -0.3086, role = "logo-flame-inner", progress = 0.201835),
            ShapePoint(x = 0.1351, y = -0.3096, role = "logo-flame-inner", progress = 0.203145),
            ShapePoint(x = 0.1229, y = -0.3143, role = "logo-flame-spark", progress = 0.204456),
            ShapePoint(x = 0.1106, y = -0.3189, role = "logo-flame-inner", progress = 0.205767),
            ShapePoint(x = 0.1013, y = -0.3269, role = "logo-flame-inner", progress = 0.207077),
            ShapePoint(x = 0.0921, y = -0.3349, role = "logo-flame-inner", progress = 0.208388),
            ShapePoint(x = 0.0828, y = -0.3429, role = "logo-flame-spark", progress = 0.209699),
            ShapePoint(x = 0.0730, y = -0.3533, role = "logo-flame-inner", progress = 0.211009),
            ShapePoint(x = 0.0635, y = -0.3638, role = "logo-flame-inner", progress = 0.212320),
            ShapePoint(x = 0.0541, y = -0.3745, role = "logo-flame-inner", progress = 0.213630),
            ShapePoint(x = 0.0458, y = -0.3845, role = "logo-flame-spark", progress = 0.214941),
            ShapePoint(x = 0.0405, y = -0.3958, role = "logo-flame-inner", progress = 0.216252),
            ShapePoint(x = 0.0302, y = -0.4000, role = "logo-flame-inner", progress = 0.217562),
            ShapePoint(x = 0.0260, y = -0.3893, role = "logo-flame-inner", progress = 0.218873),
            ShapePoint(x = 0.0293, y = -0.3765, role = "logo-flame-spark", progress = 0.220183),
            ShapePoint(x = 0.0342, y = -0.3642, role = "logo-flame-inner", progress = 0.221494),
            ShapePoint(x = 0.0396, y = -0.3543, role = "logo-flame-inner", progress = 0.222805),
            ShapePoint(x = 0.0493, y = -0.3485, role = "logo-flame-inner", progress = 0.224115),
            ShapePoint(x = 0.0584, y = -0.3364, role = "logo-flame-spark", progress = 0.225426),
            ShapePoint(x = 0.0689, y = -0.3256, role = "logo-flame-inner", progress = 0.226737),
            ShapePoint(x = 0.0797, y = -0.3172, role = "logo-flame-inner", progress = 0.228047),
            ShapePoint(x = 0.0914, y = -0.3096, role = "logo-flame-inner", progress = 0.229358),
            ShapePoint(x = 0.1035, y = -0.3026, role = "logo-flame-spark", progress = 0.230668),
            ShapePoint(x = 0.0679, y = -0.3133, role = "logo-flame-inner", progress = 0.231979),
            ShapePoint(x = 0.0571, y = -0.3195, role = "logo-flame-inner", progress = 0.233290),
            ShapePoint(x = 0.0471, y = -0.3261, role = "logo-flame-inner", progress = 0.234600),
            ShapePoint(x = 0.0375, y = -0.3339, role = "logo-flame-spark", progress = 0.235911),
            ShapePoint(x = 0.0303, y = -0.3450, role = "logo-flame-inner", progress = 0.237221),
            ShapePoint(x = 0.0244, y = -0.3549, role = "logo-flame-inner", progress = 0.238532),
            ShapePoint(x = 0.0185, y = -0.3647, role = "logo-flame-inner", progress = 0.239843),
            ShapePoint(x = 0.0125, y = -0.3745, role = "logo-flame-spark", progress = 0.241153),
            ShapePoint(x = 0.0066, y = -0.3843, role = "logo-flame-inner", progress = 0.242464),
            ShapePoint(x = 0.0006, y = -0.3941, role = "logo-flame-inner", progress = 0.243775),
            ShapePoint(x = -0.0114, y = -0.4000, role = "logo-flame-inner", progress = 0.245085),
            ShapePoint(x = -0.0133, y = -0.3889, role = "logo-flame-spark", progress = 0.246396),
            ShapePoint(x = -0.0054, y = -0.3806, role = "logo-flame-inner", progress = 0.247706),
            ShapePoint(x = 0.0581, y = -0.3080, role = "logo-flame-inner", progress = 0.249017),
            ShapePoint(x = 0.0460, y = -0.3137, role = "logo-flame-inner", progress = 0.250328),
            ShapePoint(x = 0.0361, y = -0.3195, role = "logo-flame-spark", progress = 0.251638),
            ShapePoint(x = 0.0262, y = -0.3252, role = "logo-flame-inner", progress = 0.252949),
            ShapePoint(x = 0.0139, y = -0.3320, role = "logo-flame-inner", progress = 0.254260),
            ShapePoint(x = 0.0016, y = -0.3388, role = "logo-flame-inner", progress = 0.255570),
            ShapePoint(x = -0.0103, y = -0.3462, role = "logo-flame-spark", progress = 0.256881),
            ShapePoint(x = -0.0199, y = -0.3527, role = "logo-flame-inner", progress = 0.258191),
            ShapePoint(x = -0.0318, y = -0.3598, role = "logo-flame-inner", progress = 0.259502),
            ShapePoint(x = -0.0438, y = -0.3667, role = "logo-flame-inner", progress = 0.260813),
            ShapePoint(x = -0.0556, y = -0.3665, role = "logo-flame-spark", progress = 0.262123),
            ShapePoint(x = -0.0638, y = -0.3756, role = "logo-flame-inner", progress = 0.263434),
            ShapePoint(x = -0.0720, y = -0.3852, role = "logo-flame-inner", progress = 0.264744),
            ShapePoint(x = -0.0795, y = -0.3938, role = "logo-flame-inner", progress = 0.266055),
            ShapePoint(x = -0.0933, y = -0.4000, role = "logo-flame-spark", progress = 0.267366),
            ShapePoint(x = -0.1058, y = -0.4000, role = "logo-flame-inner", progress = 0.268676),
            ShapePoint(x = -0.1183, y = -0.4000, role = "logo-flame-inner", progress = 0.269987),
            ShapePoint(x = -0.1213, y = -0.3893, role = "logo-flame-inner", progress = 0.271298),
            ShapePoint(x = -0.1306, y = -0.3954, role = "logo-flame-spark", progress = 0.272608),
            ShapePoint(x = -0.1417, y = -0.3940, role = "logo-flame-inner", progress = 0.273919),
            ShapePoint(x = -0.1523, y = -0.3991, role = "logo-flame-inner", progress = 0.275229),
            ShapePoint(x = -0.1706, y = -0.4000, role = "logo-flame-inner", progress = 0.276540),
            ShapePoint(x = -0.1851, y = -0.4000, role = "logo-flame-spark", progress = 0.277851),
            ShapePoint(x = -0.1997, y = -0.4000, role = "logo-flame-inner", progress = 0.279161),
            ShapePoint(x = -0.2142, y = -0.4000, role = "logo-flame-inner", progress = 0.280472),
            ShapePoint(x = -0.2287, y = -0.4000, role = "logo-flame-inner", progress = 0.281782),
            ShapePoint(x = -0.2433, y = -0.4000, role = "logo-flame-spark", progress = 0.283093),
            ShapePoint(x = -0.2358, y = -0.3908, role = "logo-flame-inner", progress = 0.284404),
            ShapePoint(x = -0.2269, y = -0.3803, role = "logo-flame-inner", progress = 0.285714),
            ShapePoint(x = -0.2191, y = -0.3679, role = "logo-flame-inner", progress = 0.287025),
            ShapePoint(x = -0.2139, y = -0.3574, role = "logo-flame-spark", progress = 0.288336),
            ShapePoint(x = -0.2095, y = -0.3465, role = "logo-flame-inner", progress = 0.289646),
            ShapePoint(x = -0.2059, y = -0.3353, role = "logo-flame-inner", progress = 0.290957),
            ShapePoint(x = -0.2031, y = -0.3238, role = "logo-flame-inner", progress = 0.292267),
            ShapePoint(x = -0.2169, y = -0.3379, role = "logo-flame-spark", progress = 0.293578),
            ShapePoint(x = -0.2256, y = -0.3449, role = "logo-flame-inner", progress = 0.294889),
            ShapePoint(x = -0.2386, y = -0.3514, role = "logo-flame-inner", progress = 0.296199),
            ShapePoint(x = -0.2497, y = -0.3534, role = "logo-flame-inner", progress = 0.297510),
            ShapePoint(x = -0.2615, y = -0.3533, role = "logo-flame-spark", progress = 0.298820),
            ShapePoint(x = -0.2729, y = -0.3512, role = "logo-flame-inner", progress = 0.300131),
            ShapePoint(x = -0.2869, y = -0.3443, role = "logo-flame-inner", progress = 0.301442),
            ShapePoint(x = -0.2966, y = -0.3349, role = "logo-flame-inner", progress = 0.302752),
            ShapePoint(x = -0.3028, y = -0.3229, role = "logo-flame-spark", progress = 0.304063),
            ShapePoint(x = -0.3052, y = -0.3119, role = "logo-flame-inner", progress = 0.305374),
            ShapePoint(x = -0.3177, y = -0.3029, role = "logo-flame-inner", progress = 0.306684),
            ShapePoint(x = -0.3310, y = -0.2964, role = "logo-flame-inner", progress = 0.307995),
            ShapePoint(x = -0.3443, y = -0.2899, role = "logo-flame-spark", progress = 0.309305),
            ShapePoint(x = -0.3555, y = -0.2804, role = "logo-flame-inner", progress = 0.310616),
            ShapePoint(x = -0.3645, y = -0.2678, role = "logo-flame-inner", progress = 0.311927),
            ShapePoint(x = -0.3734, y = -0.2553, role = "logo-flame-inner", progress = 0.313237),
            ShapePoint(x = -0.3788, y = -0.2421, role = "logo-flame-spark", progress = 0.314548),
            ShapePoint(x = -0.3806, y = -0.2282, role = "logo-flame-inner", progress = 0.315858),
            ShapePoint(x = -0.3824, y = -0.2144, role = "logo-flame-inner", progress = 0.317169),
            ShapePoint(x = -0.3674, y = -0.2442, role = "logo-flame-inner", progress = 0.318480),
            ShapePoint(x = -0.3578, y = -0.2548, role = "logo-flame-spark", progress = 0.319790),
            ShapePoint(x = -0.3462, y = -0.2630, role = "logo-flame-inner", progress = 0.321101),
            ShapePoint(x = -0.3334, y = -0.2689, role = "logo-flame-inner", progress = 0.322412),
            ShapePoint(x = -0.3193, y = -0.2727, role = "logo-flame-inner", progress = 0.323722),
            ShapePoint(x = -0.3050, y = -0.2727, role = "logo-flame-spark", progress = 0.325033),
            ShapePoint(x = -0.2944, y = -0.2696, role = "logo-flame-inner", progress = 0.326343),
            ShapePoint(x = -0.2840, y = -0.2620, role = "logo-flame-inner", progress = 0.327654),
            ShapePoint(x = -0.2737, y = -0.2545, role = "logo-flame-inner", progress = 0.328965),
            ShapePoint(x = -0.2649, y = -0.2435, role = "logo-flame-spark", progress = 0.330275),
            ShapePoint(x = -0.2582, y = -0.2314, role = "logo-flame-inner", progress = 0.331586),
            ShapePoint(x = -0.2533, y = -0.2183, role = "logo-flame-inner", progress = 0.332896),
            ShapePoint(x = -0.2771, y = -0.2413, role = "logo-flame-inner", progress = 0.334207),
            ShapePoint(x = -0.2860, y = -0.2478, role = "logo-flame-spark", progress = 0.335518),
            ShapePoint(x = -0.2958, y = -0.2533, role = "logo-flame-inner", progress = 0.336828),
            ShapePoint(x = -0.3065, y = -0.2576, role = "logo-flame-inner", progress = 0.338139),
            ShapePoint(x = -0.3175, y = -0.2598, role = "logo-flame-inner", progress = 0.339450),
            ShapePoint(x = -0.3382, y = -0.2551, role = "logo-flame-spark", progress = 0.340760),
            ShapePoint(x = -0.3490, y = -0.2480, role = "logo-flame-inner", progress = 0.342071),
            ShapePoint(x = -0.3672, y = -0.2322, role = "logo-flame-inner", progress = 0.343381),
            ShapePoint(x = -0.3713, y = -0.2219, role = "logo-flame-inner", progress = 0.344692),
            ShapePoint(x = -0.3773, y = -0.2016, role = "logo-flame-spark", progress = 0.346003),
            ShapePoint(x = -0.3770, y = -0.1868, role = "logo-flame-inner", progress = 0.347313),
            ShapePoint(x = -0.3759, y = -0.1723, role = "logo-flame-inner", progress = 0.348624),
            ShapePoint(x = -0.3700, y = -0.1567, role = "logo-flame-inner", progress = 0.349934),
            ShapePoint(x = -0.3643, y = -0.1467, role = "logo-flame-spark", progress = 0.351245),
            ShapePoint(x = -0.3549, y = -0.1362, role = "logo-flame-inner", progress = 0.352556),
            ShapePoint(x = -0.3587, y = -0.1605, role = "logo-flame-inner", progress = 0.353866),
            ShapePoint(x = -0.3595, y = -0.1742, role = "logo-flame-inner", progress = 0.355177),
            ShapePoint(x = -0.3580, y = -0.1871, role = "logo-flame-spark", progress = 0.356488),
            ShapePoint(x = -0.3530, y = -0.1988, role = "logo-flame-inner", progress = 0.357798),
            ShapePoint(x = -0.3443, y = -0.2087, role = "logo-flame-inner", progress = 0.359109),
            ShapePoint(x = -0.3324, y = -0.2143, role = "logo-flame-inner", progress = 0.360419),
            ShapePoint(x = -0.3211, y = -0.2149, role = "logo-flame-spark", progress = 0.361730),
            ShapePoint(x = -0.3104, y = -0.2112, role = "logo-flame-inner", progress = 0.363041),
            ShapePoint(x = -0.3011, y = -0.2032, role = "logo-flame-inner", progress = 0.364351),
            ShapePoint(x = -0.2944, y = -0.1907, role = "logo-flame-inner", progress = 0.365662),
            ShapePoint(x = -0.2906, y = -0.1791, role = "logo-flame-spark", progress = 0.366972),
            ShapePoint(x = -0.2879, y = -0.1672, role = "logo-flame-inner", progress = 0.368283),
            ShapePoint(x = -0.2857, y = -0.1552, role = "logo-flame-inner", progress = 0.369594),
            ShapePoint(x = -0.2838, y = -0.1433, role = "logo-flame-inner", progress = 0.370904),
            ShapePoint(x = -0.2821, y = -0.1314, role = "logo-flame-spark", progress = 0.372215),
            ShapePoint(x = -0.2805, y = -0.1198, role = "logo-flame-inner", progress = 0.373526),
            ShapePoint(x = -0.2791, y = -0.1085, role = "logo-flame-inner", progress = 0.374836),
            ShapePoint(x = -0.2778, y = -0.0972, role = "logo-flame-inner", progress = 0.376147),
            ShapePoint(x = -0.2766, y = -0.0856, role = "logo-flame-spark", progress = 0.377457),
            ShapePoint(x = -0.2754, y = -0.0740, role = "logo-flame-inner", progress = 0.378768),
            ShapePoint(x = -0.2741, y = -0.0626, role = "logo-flame-inner", progress = 0.380079),
            ShapePoint(x = -0.2728, y = -0.0513, role = "logo-flame-inner", progress = 0.381389),
            ShapePoint(x = -0.2716, y = -0.0399, role = "logo-flame-spark", progress = 0.382700),
            ShapePoint(x = -0.2705, y = -0.0285, role = "logo-flame-inner", progress = 0.384010),
            ShapePoint(x = -0.2696, y = -0.0173, role = "logo-flame-inner", progress = 0.385321),
            ShapePoint(x = -0.2686, y = -0.0052, role = "logo-flame-inner", progress = 0.386632),
            ShapePoint(x = -0.2675, y = 0.0069, role = "logo-flame-spark", progress = 0.387942),
            ShapePoint(x = -0.2664, y = 0.0194, role = "logo-flame-inner", progress = 0.389253),
            ShapePoint(x = -0.2690, y = 0.0302, role = "logo-flame-inner", progress = 0.390564),
            ShapePoint(x = -0.2799, y = 0.0395, role = "logo-flame-inner", progress = 0.391874),
            ShapePoint(x = -0.2883, y = 0.0475, role = "logo-flame-spark", progress = 0.393185),
            ShapePoint(x = -0.2954, y = 0.0565, role = "logo-flame-inner", progress = 0.394495),
            ShapePoint(x = -0.2798, y = 0.0279, role = "logo-flame-inner", progress = 0.395806),
            ShapePoint(x = -0.2916, y = 0.0295, role = "logo-flame-inner", progress = 0.397117),
            ShapePoint(x = -0.3059, y = 0.0386, role = "logo-flame-spark", progress = 0.398427),
            ShapePoint(x = -0.3202, y = 0.0477, role = "logo-flame-inner", progress = 0.399738),
            ShapePoint(x = -0.3315, y = 0.0572, role = "logo-flame-inner", progress = 0.401048),
            ShapePoint(x = -0.3386, y = 0.0677, role = "logo-flame-inner", progress = 0.402359),
            ShapePoint(x = -0.3440, y = 0.0790, role = "logo-flame-spark", progress = 0.403670),
            ShapePoint(x = -0.3479, y = 0.0908, role = "logo-flame-inner", progress = 0.404980),
            ShapePoint(x = -0.3503, y = 0.1033, role = "logo-flame-inner", progress = 0.406291),
            ShapePoint(x = -0.3510, y = 0.1156, role = "logo-flame-inner", progress = 0.407602),
            ShapePoint(x = -0.3508, y = 0.1273, role = "logo-flame-spark", progress = 0.408912),
            ShapePoint(x = -0.3507, y = 0.1391, role = "logo-flame-inner", progress = 0.410223),
            ShapePoint(x = -0.3498, y = 0.1510, role = "logo-flame-inner", progress = 0.411533),
            ShapePoint(x = -0.3477, y = 0.1629, role = "logo-flame-inner", progress = 0.412844),
            ShapePoint(x = -0.3451, y = 0.1746, role = "logo-flame-spark", progress = 0.414155),
            ShapePoint(x = -0.3418, y = 0.1862, role = "logo-flame-inner", progress = 0.415465),
            ShapePoint(x = -0.3378, y = 0.1976, role = "logo-flame-inner", progress = 0.416776),
            ShapePoint(x = -0.3324, y = 0.2107, role = "logo-flame-inner", progress = 0.418087),
            ShapePoint(x = -0.3272, y = 0.2217, role = "logo-flame-spark", progress = 0.419397),
            ShapePoint(x = -0.3218, y = 0.2327, role = "logo-flame-inner", progress = 0.420708),
            ShapePoint(x = -0.3159, y = 0.2438, role = "logo-flame-inner", progress = 0.422018),
            ShapePoint(x = -0.3090, y = 0.2551, role = "logo-flame-inner", progress = 0.423329),
            ShapePoint(x = -0.3012, y = 0.2657, role = "logo-flame-spark", progress = 0.424640),
            ShapePoint(x = -0.2926, y = 0.2758, role = "logo-flame-inner", progress = 0.425950),
            ShapePoint(x = -0.2820, y = 0.2866, role = "logo-flame-inner", progress = 0.427261),
            ShapePoint(x = -0.2709, y = 0.2967, role = "logo-flame-inner", progress = 0.428571),
            ShapePoint(x = -0.2593, y = 0.3063, role = "logo-flame-spark", progress = 0.429882),
            ShapePoint(x = -0.2473, y = 0.3154, role = "logo-flame-inner", progress = 0.431193),
            ShapePoint(x = -0.2350, y = 0.3240, role = "logo-flame-inner", progress = 0.432503),
            ShapePoint(x = -0.2205, y = 0.3335, role = "logo-flame-inner", progress = 0.433814),
            ShapePoint(x = -0.2056, y = 0.3424, role = "logo-flame-spark", progress = 0.435125),
            ShapePoint(x = -0.1905, y = 0.3506, role = "logo-flame-inner", progress = 0.436435),
            ShapePoint(x = -0.1749, y = 0.3582, role = "logo-flame-inner", progress = 0.437746),
            ShapePoint(x = -0.1591, y = 0.3651, role = "logo-flame-inner", progress = 0.439056),
            ShapePoint(x = -0.1487, y = 0.3694, role = "logo-flame-spark", progress = 0.440367),
            ShapePoint(x = -0.1383, y = 0.3734, role = "logo-flame-inner", progress = 0.441678),
            ShapePoint(x = -0.1278, y = 0.3772, role = "logo-flame-inner", progress = 0.442988),
            ShapePoint(x = -0.1171, y = 0.3806, role = "logo-flame-inner", progress = 0.444299),
            ShapePoint(x = -0.1063, y = 0.3835, role = "logo-flame-spark", progress = 0.445609),
            ShapePoint(x = -0.0932, y = 0.3868, role = "logo-flame-inner", progress = 0.446920),
            ShapePoint(x = -0.0801, y = 0.3900, role = "logo-flame-inner", progress = 0.448231),
            ShapePoint(x = -0.0669, y = 0.3929, role = "logo-flame-inner", progress = 0.449541),
            ShapePoint(x = -0.0536, y = 0.3954, role = "logo-flame-spark", progress = 0.450852),
            ShapePoint(x = -0.0403, y = 0.3974, role = "logo-flame-inner", progress = 0.452163),
            ShapePoint(x = -0.0288, y = 0.3988, role = "logo-flame-inner", progress = 0.453473),
            ShapePoint(x = -0.0789, y = -0.3610, role = "logo-flame-inner", progress = 0.454784),
            ShapePoint(x = -0.0881, y = -0.3697, role = "logo-flame-spark", progress = 0.456094),
            ShapePoint(x = -0.0973, y = -0.3808, role = "logo-flame-inner", progress = 0.457405),
            ShapePoint(x = -0.0239, y = -0.2378, role = "logo-flame-inner", progress = 0.458716),
            ShapePoint(x = -0.0347, y = -0.2477, role = "logo-flame-inner", progress = 0.460026),
            ShapePoint(x = -0.0456, y = -0.2576, role = "logo-flame-spark", progress = 0.461337),
            ShapePoint(x = -0.0538, y = -0.2661, role = "logo-flame-inner", progress = 0.462647),
            ShapePoint(x = -0.0642, y = -0.2746, role = "logo-flame-inner", progress = 0.463958),
            ShapePoint(x = -0.0757, y = -0.2798, role = "logo-flame-inner", progress = 0.465269),
            ShapePoint(x = -0.0865, y = -0.2818, role = "logo-flame-spark", progress = 0.466579),
            ShapePoint(x = -0.0845, y = -0.2938, role = "logo-flame-inner", progress = 0.467890),
            ShapePoint(x = -0.0785, y = -0.3034, role = "logo-flame-inner", progress = 0.469201),
            ShapePoint(x = -0.0726, y = -0.3129, role = "logo-flame-inner", progress = 0.470511),
            ShapePoint(x = -0.0658, y = -0.3239, role = "logo-flame-spark", progress = 0.471822),
            ShapePoint(x = -0.0600, y = -0.3341, role = "logo-flame-inner", progress = 0.473132),
            ShapePoint(x = -0.0560, y = -0.3450, role = "logo-flame-inner", progress = 0.474443),
            ShapePoint(x = -0.0430, y = -0.3420, role = "logo-flame-inner", progress = 0.475754),
            ShapePoint(x = -0.0314, y = -0.3365, role = "logo-flame-spark", progress = 0.477064),
            ShapePoint(x = -0.0199, y = -0.3310, role = "logo-flame-inner", progress = 0.478375),
            ShapePoint(x = -0.0091, y = -0.3261, role = "logo-flame-inner", progress = 0.479685),
            ShapePoint(x = 0.0014, y = -0.3207, role = "logo-flame-inner", progress = 0.480996),
            ShapePoint(x = 0.0117, y = -0.3140, role = "logo-flame-spark", progress = 0.482307),
            ShapePoint(x = 0.0218, y = -0.3071, role = "logo-flame-inner", progress = 0.483617),
            ShapePoint(x = 0.0319, y = -0.3001, role = "logo-flame-inner", progress = 0.484928),
            ShapePoint(x = 0.0240, y = -0.2893, role = "logo-flame-inner", progress = 0.486239),
            ShapePoint(x = 0.0140, y = -0.2824, role = "logo-flame-spark", progress = 0.487549),
            ShapePoint(x = 0.0035, y = -0.2741, role = "logo-flame-inner", progress = 0.488860),
            ShapePoint(x = -0.0077, y = -0.2648, role = "logo-flame-inner", progress = 0.490170),
            ShapePoint(x = -0.0146, y = -0.2539, role = "logo-flame-inner", progress = 0.491481),
            ShapePoint(x = -0.2188, y = -0.2466, role = "logo-flame-spark", progress = 0.492792),
            ShapePoint(x = -0.2262, y = -0.2620, role = "logo-flame-inner", progress = 0.494102),
            ShapePoint(x = -0.2324, y = -0.2732, role = "logo-flame-inner", progress = 0.495413),
            ShapePoint(x = -0.2386, y = -0.2844, role = "logo-flame-inner", progress = 0.496723),
            ShapePoint(x = -0.2459, y = -0.2947, role = "logo-flame-spark", progress = 0.498034),
            ShapePoint(x = -0.2556, y = -0.3019, role = "logo-flame-inner", progress = 0.499345),
            ShapePoint(x = -0.2671, y = -0.3065, role = "logo-flame-inner", progress = 0.500655),
            ShapePoint(x = -0.2786, y = -0.3085, role = "logo-flame-inner", progress = 0.501966),
            ShapePoint(x = -0.2904, y = -0.3088, role = "logo-flame-spark", progress = 0.503277),
            ShapePoint(x = -0.2859, y = -0.3197, role = "logo-flame-inner", progress = 0.504587),
            ShapePoint(x = -0.2748, y = -0.3227, role = "logo-flame-inner", progress = 0.505898),
            ShapePoint(x = -0.2628, y = -0.3220, role = "logo-flame-inner", progress = 0.507208),
            ShapePoint(x = -0.2513, y = -0.3168, role = "logo-flame-spark", progress = 0.508519),
            ShapePoint(x = -0.2419, y = -0.3082, role = "logo-flame-inner", progress = 0.509830),
            ShapePoint(x = -0.2348, y = -0.2983, role = "logo-flame-inner", progress = 0.511140),
            ShapePoint(x = 0.2794, y = -0.0937, role = "logo-flame-inner", progress = 0.512451),
            ShapePoint(x = 0.2816, y = -0.1050, role = "logo-flame-spark", progress = 0.513761),
            ShapePoint(x = 0.2833, y = -0.1171, role = "logo-flame-inner", progress = 0.515072),
            ShapePoint(x = 0.2848, y = -0.1281, role = "logo-flame-inner", progress = 0.516383),
            ShapePoint(x = 0.2856, y = -0.1415, role = "logo-flame-inner", progress = 0.517693),
            ShapePoint(x = 0.2858, y = -0.1553, role = "logo-flame-spark", progress = 0.519004),
            ShapePoint(x = 0.2849, y = -0.1691, role = "logo-flame-inner", progress = 0.520315),
            ShapePoint(x = 0.2835, y = -0.1817, role = "logo-flame-inner", progress = 0.521625),
            ShapePoint(x = 0.2819, y = -0.1944, role = "logo-flame-inner", progress = 0.522936),
            ShapePoint(x = 0.2784, y = -0.2091, role = "logo-flame-spark", progress = 0.524246),
            ShapePoint(x = 0.2733, y = -0.2259, role = "logo-flame-inner", progress = 0.525557),
            ShapePoint(x = 0.2682, y = -0.2428, role = "logo-flame-inner", progress = 0.526868),
            ShapePoint(x = 0.2651, y = -0.2536, role = "logo-flame-inner", progress = 0.528178),
            ShapePoint(x = 0.2791, y = -0.2402, role = "logo-flame-spark", progress = 0.529489),
            ShapePoint(x = 0.2861, y = -0.2304, role = "logo-flame-inner", progress = 0.530799),
            ShapePoint(x = 0.2918, y = -0.2198, role = "logo-flame-inner", progress = 0.532110),
            ShapePoint(x = 0.2964, y = -0.2086, role = "logo-flame-inner", progress = 0.533421),
            ShapePoint(x = 0.3006, y = -0.1935, role = "logo-flame-spark", progress = 0.534731),
            ShapePoint(x = 0.3024, y = -0.1782, role = "logo-flame-inner", progress = 0.536042),
            ShapePoint(x = 0.3019, y = -0.1627, role = "logo-flame-inner", progress = 0.537353),
            ShapePoint(x = 0.3001, y = -0.1511, role = "logo-flame-inner", progress = 0.538663),
            ShapePoint(x = 0.2971, y = -0.1383, role = "logo-flame-spark", progress = 0.539974),
            ShapePoint(x = -0.2234, y = 0.1237, role = "logo-flame-inner", progress = 0.541284),
            ShapePoint(x = -0.2191, y = 0.1111, role = "logo-flame-inner", progress = 0.542595),
            ShapePoint(x = -0.2140, y = 0.1011, role = "logo-flame-inner", progress = 0.543906),
            ShapePoint(x = -0.2089, y = 0.0912, role = "logo-flame-spark", progress = 0.545216),
            ShapePoint(x = -0.2207, y = 0.0856, role = "logo-flame-inner", progress = 0.546527),
            ShapePoint(x = -0.2325, y = 0.0821, role = "logo-flame-inner", progress = 0.547837),
            ShapePoint(x = -0.2336, y = 0.0710, role = "logo-flame-inner", progress = 0.549148),
            ShapePoint(x = -0.2247, y = 0.0637, role = "logo-flame-spark", progress = 0.550459),
            ShapePoint(x = -0.2166, y = 0.0549, role = "logo-flame-inner", progress = 0.551769),
            ShapePoint(x = -0.2119, y = 0.0446, role = "logo-flame-inner", progress = 0.553080),
            ShapePoint(x = -0.2126, y = 0.0308, role = "logo-flame-inner", progress = 0.554391),
            ShapePoint(x = -0.2172, y = 0.0181, role = "logo-flame-spark", progress = 0.555701),
            ShapePoint(x = -0.2245, y = 0.0070, role = "logo-flame-inner", progress = 0.557012),
            ShapePoint(x = -0.2346, y = -0.0023, role = "logo-flame-inner", progress = 0.558322),
            ShapePoint(x = -0.2423, y = -0.0118, role = "logo-flame-inner", progress = 0.559633),
            ShapePoint(x = -0.2407, y = -0.0230, role = "logo-flame-spark", progress = 0.560944),
            ShapePoint(x = -0.2335, y = -0.0331, role = "logo-flame-inner", progress = 0.562254),
            ShapePoint(x = -0.2251, y = -0.0415, role = "logo-flame-inner", progress = 0.563565),
            ShapePoint(x = -0.2213, y = -0.0523, role = "logo-flame-inner", progress = 0.564875),
            ShapePoint(x = -0.2234, y = -0.0635, role = "logo-flame-spark", progress = 0.566186),
            ShapePoint(x = -0.2185, y = -0.0741, role = "logo-flame-inner", progress = 0.567497),
            ShapePoint(x = -0.2066, y = -0.0751, role = "logo-flame-inner", progress = 0.568807),
            ShapePoint(x = -0.1953, y = -0.0780, role = "logo-flame-inner", progress = 0.570118),
            ShapePoint(x = -0.1855, y = -0.0835, role = "logo-flame-spark", progress = 0.571429),
            ShapePoint(x = -0.1748, y = -0.0893, role = "logo-flame-inner", progress = 0.572739),
            ShapePoint(x = -0.1636, y = -0.0910, role = "logo-flame-inner", progress = 0.574050),
            ShapePoint(x = -0.1707, y = -0.0997, role = "logo-flame-inner", progress = 0.575360),
            ShapePoint(x = -0.1814, y = -0.1028, role = "logo-flame-spark", progress = 0.576671),
            ShapePoint(x = -0.1892, y = -0.0942, role = "logo-flame-inner", progress = 0.577982),
            ShapePoint(x = -0.2009, y = -0.0947, role = "logo-flame-inner", progress = 0.579292),
            ShapePoint(x = -0.2060, y = -0.1048, role = "logo-flame-inner", progress = 0.580603),
            ShapePoint(x = -0.1952, y = -0.1091, role = "logo-flame-spark", progress = 0.581913),
            ShapePoint(x = -0.2049, y = -0.1159, role = "logo-flame-inner", progress = 0.583224),
            ShapePoint(x = -0.2157, y = -0.1134, role = "logo-flame-inner", progress = 0.584535),
            ShapePoint(x = -0.2216, y = -0.1023, role = "logo-flame-inner", progress = 0.585845),
            ShapePoint(x = -0.2230, y = -0.0914, role = "logo-flame-spark", progress = 0.587156),
            ShapePoint(x = -0.2300, y = -0.0756, role = "logo-flame-inner", progress = 0.588467),
            ShapePoint(x = -0.2490, y = -0.0306, role = "logo-flame-inner", progress = 0.589777),
            ShapePoint(x = -0.2499, y = -0.0418, role = "logo-flame-inner", progress = 0.591088),
            ShapePoint(x = -0.2496, y = -0.0530, role = "logo-flame-spark", progress = 0.592398),
            ShapePoint(x = -0.2480, y = -0.0641, role = "logo-flame-inner", progress = 0.593709),
            ShapePoint(x = -0.2455, y = -0.0750, role = "logo-flame-inner", progress = 0.595020),
            ShapePoint(x = -0.2419, y = -0.0867, role = "logo-flame-inner", progress = 0.596330),
            ShapePoint(x = -0.2374, y = -0.0986, role = "logo-flame-spark", progress = 0.597641),
            ShapePoint(x = -0.2321, y = -0.1101, role = "logo-flame-inner", progress = 0.598952),
            ShapePoint(x = -0.2255, y = -0.1227, role = "logo-flame-inner", progress = 0.600262),
            ShapePoint(x = -0.2202, y = -0.1327, role = "logo-flame-inner", progress = 0.601573),
            ShapePoint(x = -0.2148, y = -0.1427, role = "logo-flame-spark", progress = 0.602883),
            ShapePoint(x = -0.2094, y = -0.1527, role = "logo-flame-inner", progress = 0.604194),
            ShapePoint(x = -0.2039, y = -0.1627, role = "logo-flame-inner", progress = 0.605505),
            ShapePoint(x = -0.1980, y = -0.1724, role = "logo-flame-inner", progress = 0.606815),
            ShapePoint(x = -0.1900, y = -0.1802, role = "logo-flame-spark", progress = 0.608126),
            ShapePoint(x = -0.1780, y = -0.1851, role = "logo-flame-inner", progress = 0.609436),
            ShapePoint(x = -0.1660, y = -0.1858, role = "logo-flame-inner", progress = 0.610747),
            ShapePoint(x = -0.1539, y = -0.1853, role = "logo-flame-inner", progress = 0.612058),
            ShapePoint(x = -0.1411, y = -0.1839, role = "logo-flame-spark", progress = 0.613368),
            ShapePoint(x = -0.1293, y = -0.1824, role = "logo-flame-inner", progress = 0.614679),
            ShapePoint(x = -0.1168, y = -0.1806, role = "logo-flame-inner", progress = 0.615990),
            ShapePoint(x = -0.1058, y = -0.1790, role = "logo-flame-inner", progress = 0.617300),
            ShapePoint(x = -0.0944, y = -0.1793, role = "logo-flame-spark", progress = 0.618611),
            ShapePoint(x = -0.0848, y = -0.1855, role = "logo-flame-inner", progress = 0.619921),
            ShapePoint(x = -0.0771, y = -0.1936, role = "logo-flame-inner", progress = 0.621232),
            ShapePoint(x = -0.0699, y = -0.2022, role = "logo-flame-inner", progress = 0.622543),
            ShapePoint(x = -0.0617, y = -0.2132, role = "logo-flame-spark", progress = 0.623853),
            ShapePoint(x = -0.0546, y = -0.2250, role = "logo-flame-inner", progress = 0.625164),
            ShapePoint(x = -0.0452, y = -0.2309, role = "logo-flame-inner", progress = 0.626474),
            ShapePoint(x = -0.0360, y = -0.2224, role = "logo-flame-inner", progress = 0.627785),
            ShapePoint(x = -0.0316, y = -0.2085, role = "logo-flame-spark", progress = 0.629096),
            ShapePoint(x = -0.0330, y = -0.1953, role = "logo-flame-inner", progress = 0.630406),
            ShapePoint(x = -0.0339, y = -0.1833, role = "logo-flame-inner", progress = 0.631717),
            ShapePoint(x = -0.0334, y = -0.1707, role = "logo-flame-inner", progress = 0.633028),
            ShapePoint(x = -0.0326, y = -0.1595, role = "logo-flame-spark", progress = 0.634338),
            ShapePoint(x = -0.0314, y = -0.1483, role = "logo-flame-inner", progress = 0.635649),
            ShapePoint(x = -0.0294, y = -0.1356, role = "logo-flame-inner", progress = 0.636959),
            ShapePoint(x = -0.0274, y = -0.1228, role = "logo-flame-inner", progress = 0.638270),
            ShapePoint(x = -0.0254, y = -0.1100, role = "logo-flame-spark", progress = 0.639581),
            ShapePoint(x = -0.0233, y = -0.0973, role = "logo-flame-inner", progress = 0.640891),
            ShapePoint(x = -0.0213, y = -0.0845, role = "logo-flame-inner", progress = 0.642202),
            ShapePoint(x = -0.0193, y = -0.0717, role = "logo-flame-inner", progress = 0.643512),
            ShapePoint(x = -0.0167, y = -0.0570, role = "logo-flame-spark", progress = 0.644823),
            ShapePoint(x = -0.0139, y = -0.0422, role = "logo-flame-inner", progress = 0.646134),
            ShapePoint(x = -0.0113, y = -0.0274, role = "logo-flame-inner", progress = 0.647444),
            ShapePoint(x = -0.0092, y = -0.0156, role = "logo-flame-inner", progress = 0.648755),
            ShapePoint(x = -0.0069, y = -0.0017, role = "logo-flame-spark", progress = 0.650066),
            ShapePoint(x = -0.0050, y = 0.0123, role = "logo-flame-inner", progress = 0.651376),
            ShapePoint(x = -0.0038, y = 0.0232, role = "logo-flame-inner", progress = 0.652687),
            ShapePoint(x = -0.0031, y = 0.0343, role = "logo-flame-inner", progress = 0.653997),
            ShapePoint(x = -0.0027, y = 0.0464, role = "logo-flame-spark", progress = 0.655308),
            ShapePoint(x = -0.0027, y = 0.0597, role = "logo-flame-inner", progress = 0.656619),
            ShapePoint(x = -0.0028, y = 0.0730, role = "logo-flame-inner", progress = 0.657929),
            ShapePoint(x = -0.0040, y = 0.0846, role = "logo-flame-inner", progress = 0.659240),
            ShapePoint(x = -0.0153, y = 0.0882, role = "logo-flame-spark", progress = 0.660550),
            ShapePoint(x = -0.0288, y = 0.0906, role = "logo-flame-inner", progress = 0.661861),
            ShapePoint(x = -0.0366, y = 0.0989, role = "logo-flame-inner", progress = 0.663172),
            ShapePoint(x = -0.0458, y = 0.0922, role = "logo-flame-inner", progress = 0.664482),
            ShapePoint(x = -0.0591, y = 0.0925, role = "logo-flame-spark", progress = 0.665793),
            ShapePoint(x = -0.0734, y = 0.0924, role = "logo-flame-inner", progress = 0.667104),
            ShapePoint(x = -0.0876, y = 0.0920, role = "logo-flame-inner", progress = 0.668414),
            ShapePoint(x = -0.1047, y = 0.0948, role = "logo-flame-inner", progress = 0.669725),
            ShapePoint(x = -0.1117, y = 0.1035, role = "logo-flame-spark", progress = 0.671035),
            ShapePoint(x = -0.1230, y = 0.1003, role = "logo-flame-inner", progress = 0.672346),
            ShapePoint(x = -0.1607, y = 0.0810, role = "logo-flame-inner", progress = 0.673657),
            ShapePoint(x = -0.1710, y = 0.0769, role = "logo-flame-inner", progress = 0.674967),
            ShapePoint(x = -0.1637, y = 0.0920, role = "logo-flame-spark", progress = 0.676278),
            ShapePoint(x = -0.1758, y = 0.0929, role = "logo-flame-inner", progress = 0.677588),
            ShapePoint(x = -0.1872, y = 0.0898, role = "logo-flame-inner", progress = 0.678899),
            ShapePoint(x = 0.0630, y = -0.1751, role = "logo-flame-inner", progress = 0.680210),
            ShapePoint(x = 0.0515, y = -0.1821, role = "logo-flame-spark", progress = 0.681520),
            ShapePoint(x = 0.0405, y = -0.1888, role = "logo-flame-inner", progress = 0.682831),
            ShapePoint(x = 0.0306, y = -0.1951, role = "logo-flame-inner", progress = 0.684142),
            ShapePoint(x = 0.0240, y = -0.2047, role = "logo-flame-inner", progress = 0.685452),
            ShapePoint(x = 0.0286, y = -0.2147, role = "logo-flame-spark", progress = 0.686763),
            ShapePoint(x = 0.0378, y = -0.2216, role = "logo-flame-inner", progress = 0.688073),
            ShapePoint(x = 0.0500, y = -0.2205, role = "logo-flame-inner", progress = 0.689384),
            ShapePoint(x = 0.0608, y = -0.2137, role = "logo-flame-inner", progress = 0.690695),
            ShapePoint(x = 0.0670, y = -0.2041, role = "logo-flame-spark", progress = 0.692005),
            ShapePoint(x = 0.0667, y = -0.1917, role = "logo-flame-inner", progress = 0.693316),
            ShapePoint(x = 0.0544, y = -0.0948, role = "logo-flame-inner", progress = 0.694626),
            ShapePoint(x = 0.0500, y = -0.1067, role = "logo-flame-inner", progress = 0.695937),
            ShapePoint(x = 0.0459, y = -0.1189, role = "logo-flame-spark", progress = 0.697248),
            ShapePoint(x = 0.0421, y = -0.1295, role = "logo-flame-inner", progress = 0.698558),
            ShapePoint(x = 0.0377, y = -0.1425, role = "logo-flame-inner", progress = 0.699869),
            ShapePoint(x = 0.0333, y = -0.1558, role = "logo-flame-inner", progress = 0.701180),
            ShapePoint(x = 0.0291, y = -0.1692, role = "logo-flame-spark", progress = 0.702490),
            ShapePoint(x = 0.0444, y = -0.1606, role = "logo-flame-inner", progress = 0.703801),
            ShapePoint(x = 0.0549, y = -0.1541, role = "logo-flame-inner", progress = 0.705111),
            ShapePoint(x = 0.0593, y = -0.1440, role = "logo-flame-inner", progress = 0.706422),
            ShapePoint(x = 0.0581, y = -0.1299, role = "logo-flame-spark", progress = 0.707733),
            ShapePoint(x = 0.1571, y = 0.1762, role = "logo-flame-inner", progress = 0.709043),
            ShapePoint(x = 0.1612, y = 0.1644, role = "logo-flame-inner", progress = 0.710354),
            ShapePoint(x = 0.1652, y = 0.1527, role = "logo-flame-inner", progress = 0.711664),
            ShapePoint(x = 0.1716, y = 0.1321, role = "logo-flame-spark", progress = 0.712975),
            ShapePoint(x = 0.1749, y = 0.1212, role = "logo-flame-inner", progress = 0.714286),
            ShapePoint(x = 0.1781, y = 0.1104, role = "logo-flame-inner", progress = 0.715596),
            ShapePoint(x = 0.1813, y = 0.0995, role = "logo-flame-inner", progress = 0.716907),
            ShapePoint(x = 0.1845, y = 0.0887, role = "logo-flame-spark", progress = 0.718218),
            ShapePoint(x = 0.1878, y = 0.0778, role = "logo-flame-inner", progress = 0.719528),
            ShapePoint(x = 0.1915, y = 0.0652, role = "logo-flame-inner", progress = 0.720839),
            ShapePoint(x = 0.1952, y = 0.0526, role = "logo-flame-inner", progress = 0.722149),
            ShapePoint(x = 0.1989, y = 0.0400, role = "logo-flame-spark", progress = 0.723460),
            ShapePoint(x = 0.2026, y = 0.0274, role = "logo-flame-inner", progress = 0.724771),
            ShapePoint(x = 0.2064, y = 0.0147, role = "logo-flame-inner", progress = 0.726081),
            ShapePoint(x = 0.2098, y = 0.0033, role = "logo-flame-inner", progress = 0.727392),
            ShapePoint(x = 0.2133, y = -0.0082, role = "logo-flame-spark", progress = 0.728702),
            ShapePoint(x = 0.2167, y = -0.0196, role = "logo-flame-inner", progress = 0.730013),
            ShapePoint(x = 0.2198, y = -0.0312, role = "logo-flame-inner", progress = 0.731324),
            ShapePoint(x = 0.2228, y = -0.0446, role = "logo-flame-inner", progress = 0.732634),
            ShapePoint(x = 0.2253, y = -0.0563, role = "logo-flame-spark", progress = 0.733945),
            ShapePoint(x = 0.2278, y = -0.0692, role = "logo-flame-inner", progress = 0.735256),
            ShapePoint(x = 0.2299, y = -0.0802, role = "logo-flame-inner", progress = 0.736566),
            ShapePoint(x = -0.2403, y = 0.0403, role = "logo-flame-inner", progress = 0.737877),
            ShapePoint(x = -0.2438, y = 0.0287, role = "logo-flame-spark", progress = 0.739187),
            ShapePoint(x = -0.2424, y = 0.0171, role = "logo-flame-inner", progress = 0.740498),
            ShapePoint(x = -0.2460, y = 0.0712, role = "logo-flame-inner", progress = 0.741809),
            ShapePoint(x = -0.2571, y = 0.0679, role = "logo-flame-inner", progress = 0.743119),
            ShapePoint(x = -0.2551, y = 0.0562, role = "logo-flame-spark", progress = 0.744430),
            ShapePoint(x = -0.2435, y = 0.0526, role = "logo-flame-inner", progress = 0.745740),
            ShapePoint(x = -0.2322, y = 0.0530, role = "logo-flame-inner", progress = 0.747051),
            ShapePoint(x = 0.1003, y = 0.0617, role = "logo-flame-inner", progress = 0.748362),
            ShapePoint(x = 0.0876, y = 0.0592, role = "logo-flame-spark", progress = 0.749672),
            ShapePoint(x = 0.0781, y = 0.0527, role = "logo-flame-inner", progress = 0.750983),
            ShapePoint(x = 0.1068, y = 0.0527, role = "logo-flame-inner", progress = 0.752294),
            ShapePoint(x = 0.1187, y = 0.0491, role = "logo-flame-inner", progress = 0.753604),
            ShapePoint(x = 0.1309, y = 0.0493, role = "logo-flame-spark", progress = 0.754915),
            ShapePoint(x = 0.1145, y = 0.0608, role = "logo-flame-inner", progress = 0.756225),
            ShapePoint(x = -0.1503, y = 0.1839, role = "logo-flame-inner", progress = 0.757536),
            ShapePoint(x = -0.1479, y = 0.1698, role = "logo-flame-inner", progress = 0.758847),
            ShapePoint(x = -0.1447, y = 0.1570, role = "logo-flame-spark", progress = 0.760157),
            ShapePoint(x = -0.1411, y = 0.1436, role = "logo-flame-inner", progress = 0.761468),
            ShapePoint(x = -0.1371, y = 0.1323, role = "logo-flame-inner", progress = 0.762779),
            ShapePoint(x = -0.1323, y = 0.1213, role = "logo-flame-inner", progress = 0.764089),
            ShapePoint(x = -0.1270, y = 0.1106, role = "logo-flame-spark", progress = 0.765400),
            ShapePoint(x = -0.1200, y = 0.3686, role = "logo-flame-inner", progress = 0.766710),
            ShapePoint(x = -0.1088, y = 0.3686, role = "logo-flame-inner", progress = 0.768021),
            ShapePoint(x = -0.0969, y = 0.3674, role = "logo-flame-inner", progress = 0.769332),
            ShapePoint(x = -0.0855, y = 0.3657, role = "logo-flame-spark", progress = 0.770642),
            ShapePoint(x = -0.0728, y = 0.3625, role = "logo-flame-inner", progress = 0.771953),
            ShapePoint(x = -0.0599, y = 0.3575, role = "logo-flame-inner", progress = 0.773263),
            ShapePoint(x = -0.0475, y = 0.3512, role = "logo-flame-inner", progress = 0.774574),
            ShapePoint(x = -0.0350, y = 0.3433, role = "logo-flame-spark", progress = 0.775885),
            ShapePoint(x = -0.0260, y = 0.3368, role = "logo-flame-inner", progress = 0.777195),
            ShapePoint(x = -0.0174, y = 0.3298, role = "logo-flame-inner", progress = 0.778506),
            ShapePoint(x = -0.0092, y = 0.3224, role = "logo-flame-inner", progress = 0.779817),
            ShapePoint(x = -0.0014, y = 0.3146, role = "logo-flame-spark", progress = 0.781127),
            ShapePoint(x = 0.0064, y = 0.3058, role = "logo-flame-inner", progress = 0.782438),
            ShapePoint(x = 0.0140, y = 0.2961, role = "logo-flame-inner", progress = 0.783748),
            ShapePoint(x = 0.0210, y = 0.2858, role = "logo-flame-inner", progress = 0.785059),
            ShapePoint(x = 0.0274, y = 0.2747, role = "logo-flame-spark", progress = 0.786370),
            ShapePoint(x = 0.0332, y = 0.2631, role = "logo-flame-inner", progress = 0.787680),
            ShapePoint(x = 0.0386, y = 0.2512, role = "logo-flame-inner", progress = 0.788991),
            ShapePoint(x = 0.0434, y = 0.2390, role = "logo-flame-inner", progress = 0.790301),
            ShapePoint(x = 0.0476, y = 0.2265, role = "logo-flame-spark", progress = 0.791612),
            ShapePoint(x = 0.0512, y = 0.2139, role = "logo-flame-inner", progress = 0.792923),
            ShapePoint(x = 0.0545, y = 0.2012, role = "logo-flame-inner", progress = 0.794233),
            ShapePoint(x = 0.0571, y = 0.1895, role = "logo-flame-inner", progress = 0.795544),
            ShapePoint(x = 0.0593, y = 0.1773, role = "logo-flame-spark", progress = 0.796855),
            ShapePoint(x = 0.0682, y = 0.1696, role = "logo-flame-inner", progress = 0.798165),
            ShapePoint(x = 0.0714, y = 0.1589, role = "logo-flame-inner", progress = 0.799476),
            ShapePoint(x = 0.0635, y = 0.1486, role = "logo-flame-inner", progress = 0.800786),
            ShapePoint(x = 0.0690, y = 0.1923, role = "logo-flame-spark", progress = 0.802097),
            ShapePoint(x = 0.0799, y = 0.1943, role = "logo-flame-inner", progress = 0.803408),
            ShapePoint(x = 0.0910, y = 0.1960, role = "logo-flame-inner", progress = 0.804718),
            ShapePoint(x = 0.1019, y = 0.1943, role = "logo-flame-inner", progress = 0.806029),
            ShapePoint(x = 0.1038, y = 0.1828, role = "logo-flame-spark", progress = 0.807339),
            ShapePoint(x = 0.0952, y = 0.1752, role = "logo-flame-inner", progress = 0.808650),
            ShapePoint(x = 0.0981, y = 0.1633, role = "logo-flame-inner", progress = 0.809961),
            ShapePoint(x = 0.1093, y = 0.1565, role = "logo-flame-inner", progress = 0.811271),
            ShapePoint(x = 0.1205, y = 0.1512, role = "logo-flame-spark", progress = 0.812582),
            ShapePoint(x = 0.1029, y = 0.2058, role = "logo-flame-inner", progress = 0.813893),
            ShapePoint(x = 0.0960, y = 0.2259, role = "logo-flame-inner", progress = 0.815203),
            ShapePoint(x = 0.0914, y = 0.2372, role = "logo-flame-inner", progress = 0.816514),
            ShapePoint(x = 0.0869, y = 0.2485, role = "logo-flame-spark", progress = 0.817824),
            ShapePoint(x = 0.0823, y = 0.2598, role = "logo-flame-inner", progress = 0.819135),
            ShapePoint(x = 0.0777, y = 0.2711, role = "logo-flame-inner", progress = 0.820446),
            ShapePoint(x = 0.0731, y = 0.2824, role = "logo-flame-inner", progress = 0.821756),
            ShapePoint(x = 0.0654, y = 0.2924, role = "logo-flame-spark", progress = 0.823067),
            ShapePoint(x = 0.0576, y = 0.3025, role = "logo-flame-inner", progress = 0.824377),
            ShapePoint(x = 0.0499, y = 0.3125, role = "logo-flame-inner", progress = 0.825688),
            ShapePoint(x = 0.0422, y = 0.3225, role = "logo-flame-inner", progress = 0.826999),
            ShapePoint(x = 0.0345, y = 0.3326, role = "logo-flame-spark", progress = 0.828309),
            ShapePoint(x = 0.0268, y = 0.3426, role = "logo-flame-inner", progress = 0.829620),
            ShapePoint(x = 0.0137, y = 0.3517, role = "logo-flame-inner", progress = 0.830931),
            ShapePoint(x = 0.0006, y = 0.3609, role = "logo-flame-inner", progress = 0.832241),
            ShapePoint(x = -0.0125, y = 0.3700, role = "logo-flame-spark", progress = 0.833552),
            ShapePoint(x = -0.0238, y = 0.3737, role = "logo-flame-inner", progress = 0.834862),
            ShapePoint(x = -0.0351, y = 0.3773, role = "logo-flame-inner", progress = 0.836173),
            ShapePoint(x = -0.0464, y = 0.3810, role = "logo-flame-inner", progress = 0.837484),
            ShapePoint(x = -0.0582, y = 0.3822, role = "logo-flame-spark", progress = 0.838794),
            ShapePoint(x = -0.2799, y = 0.2694, role = "logo-flame-inner", progress = 0.840105),
            ShapePoint(x = -0.2898, y = 0.2605, role = "logo-flame-inner", progress = 0.841415),
            ShapePoint(x = -0.2984, y = 0.2520, role = "logo-flame-inner", progress = 0.842726),
            ShapePoint(x = -0.3213, y = 0.2097, role = "logo-flame-spark", progress = 0.844037),
            ShapePoint(x = -0.3228, y = 0.1972, role = "logo-flame-inner", progress = 0.845347),
            ShapePoint(x = -0.3262, y = 0.1867, role = "logo-flame-inner", progress = 0.846658),
            ShapePoint(x = -0.3110, y = 0.2173, role = "logo-flame-inner", progress = 0.847969),
            ShapePoint(x = -0.3058, y = 0.2279, role = "logo-flame-spark", progress = 0.849279),
            ShapePoint(x = -0.3002, y = 0.2382, role = "logo-flame-inner", progress = 0.850590),
            ShapePoint(x = 0.1527, y = 0.1892, role = "logo-flame-inner", progress = 0.851900),
            ShapePoint(x = -0.2767, y = 0.2507, role = "logo-flame-inner", progress = 0.853211),
            ShapePoint(x = -0.2838, y = 0.2420, role = "logo-flame-spark", progress = 0.854522),
            ShapePoint(x = -0.3106, y = 0.2062, role = "logo-flame-inner", progress = 0.855832),
            ShapePoint(x = -0.2987, y = 0.2060, role = "logo-flame-inner", progress = 0.857143),
            ShapePoint(x = -0.2994, y = 0.1946, role = "logo-flame-inner", progress = 0.858453),
            ShapePoint(x = -0.2897, y = 0.2125, role = "logo-flame-spark", progress = 0.859764),
            ShapePoint(x = -0.2843, y = 0.2025, role = "logo-flame-inner", progress = 0.861075),
            ShapePoint(x = -0.2753, y = 0.1955, role = "logo-flame-inner", progress = 0.862385),
            ShapePoint(x = -0.2699, y = 0.2061, role = "logo-flame-inner", progress = 0.863696),
            ShapePoint(x = -0.2650, y = 0.2178, role = "logo-flame-spark", progress = 0.865007),
            ShapePoint(x = -0.2601, y = 0.2296, role = "logo-flame-inner", progress = 0.866317),
            ShapePoint(x = -0.2721, y = 0.2285, role = "logo-flame-inner", progress = 0.867628),
            ShapePoint(x = -0.2700, y = 0.2398, role = "logo-flame-inner", progress = 0.868938),
            ShapePoint(x = -0.2076, y = 0.2730, role = "logo-flame-spark", progress = 0.870249),
            ShapePoint(x = -0.2151, y = 0.2638, role = "logo-flame-inner", progress = 0.871560),
            ShapePoint(x = -0.2224, y = 0.2527, role = "logo-flame-inner", progress = 0.872870),
            ShapePoint(x = -0.2284, y = 0.2431, role = "logo-flame-inner", progress = 0.874181),
            ShapePoint(x = -0.2343, y = 0.2336, role = "logo-flame-spark", progress = 0.875491),
            ShapePoint(x = -0.2433, y = 0.2249, role = "logo-flame-inner", progress = 0.876802),
            ShapePoint(x = -0.2531, y = 0.2196, role = "logo-flame-inner", progress = 0.878113),
            ShapePoint(x = -0.2485, y = 0.2360, role = "logo-flame-inner", progress = 0.879423),
            ShapePoint(x = -0.2587, y = 0.2040, role = "logo-flame-spark", progress = 0.880734),
            ShapePoint(x = -0.2385, y = 0.2148, role = "logo-flame-inner", progress = 0.882045),
            ShapePoint(x = -0.2360, y = 0.2037, role = "logo-flame-inner", progress = 0.883355),
            ShapePoint(x = -0.2283, y = 0.2206, role = "logo-flame-inner", progress = 0.884666),
            ShapePoint(x = -0.0747, y = 0.2843, role = "logo-flame-spark", progress = 0.885976),
            ShapePoint(x = -0.0718, y = 0.2723, role = "logo-flame-inner", progress = 0.887287),
            ShapePoint(x = -0.0693, y = 0.2602, role = "logo-flame-inner", progress = 0.888598),
            ShapePoint(x = -0.0693, y = 0.2490, role = "logo-flame-inner", progress = 0.889908),
            ShapePoint(x = -0.0806, y = 0.2459, role = "logo-flame-spark", progress = 0.891219),
            ShapePoint(x = -0.0900, y = 0.2401, role = "logo-flame-inner", progress = 0.892529),
            ShapePoint(x = -0.1013, y = 0.2391, role = "logo-flame-inner", progress = 0.893840),
            ShapePoint(x = -0.1117, y = 0.2343, role = "logo-flame-inner", progress = 0.895151),
            ShapePoint(x = -0.1102, y = 0.2234, role = "logo-flame-spark", progress = 0.896461),
            ShapePoint(x = -0.0992, y = 0.2175, role = "logo-flame-inner", progress = 0.897772),
            ShapePoint(x = -0.0882, y = 0.2131, role = "logo-flame-inner", progress = 0.899083),
            ShapePoint(x = -0.0774, y = 0.2160, role = "logo-flame-inner", progress = 0.900393),
            ShapePoint(x = -0.0684, y = 0.2096, role = "logo-flame-spark", progress = 0.901704),
            ShapePoint(x = -0.0678, y = 0.2234, role = "logo-flame-inner", progress = 0.903014),
            ShapePoint(x = -0.0566, y = 0.2063, role = "logo-flame-inner", progress = 0.904325),
            ShapePoint(x = -0.0545, y = 0.2177, role = "logo-flame-inner", progress = 0.905636),
            ShapePoint(x = -0.0452, y = 0.2063, role = "logo-flame-spark", progress = 0.906946),
            ShapePoint(x = -0.0443, y = 0.2221, role = "logo-flame-inner", progress = 0.908257),
            ShapePoint(x = -0.0429, y = 0.2354, role = "logo-flame-inner", progress = 0.909567),
            ShapePoint(x = -0.0488, y = 0.2478, role = "logo-flame-inner", progress = 0.910878),
            ShapePoint(x = -0.0558, y = 0.2603, role = "logo-flame-spark", progress = 0.912189),
            ShapePoint(x = -0.1636, y = 0.2611, role = "logo-flame-inner", progress = 0.913499),
            ShapePoint(x = -0.1679, y = 0.2497, role = "logo-flame-inner", progress = 0.914810),
            ShapePoint(x = -0.1715, y = 0.2384, role = "logo-flame-inner", progress = 0.916121),
            ShapePoint(x = -0.1818, y = 0.2329, role = "logo-flame-spark", progress = 0.917431),
            ShapePoint(x = -0.1930, y = 0.2335, role = "logo-flame-inner", progress = 0.918742),
            ShapePoint(x = -0.2036, y = 0.2370, role = "logo-flame-inner", progress = 0.920052),
            ShapePoint(x = -0.2138, y = 0.2418, role = "logo-flame-inner", progress = 0.921363),
            ShapePoint(x = -0.2195, y = 0.2313, role = "logo-flame-spark", progress = 0.922674),
            ShapePoint(x = -0.2172, y = 0.2135, role = "logo-flame-inner", progress = 0.923984),
            ShapePoint(x = -0.2055, y = 0.2142, role = "logo-flame-inner", progress = 0.925295),
            ShapePoint(x = -0.1925, y = 0.2151, role = "logo-flame-inner", progress = 0.926606),
            ShapePoint(x = -0.1810, y = 0.2187, role = "logo-flame-spark", progress = 0.927916),
            ShapePoint(x = -0.1701, y = 0.2156, role = "logo-flame-inner", progress = 0.929227),
            ShapePoint(x = -0.1627, y = 0.2287, role = "logo-flame-inner", progress = 0.930537),
            ShapePoint(x = -0.1543, y = 0.2492, role = "logo-flame-inner", progress = 0.931848),
            ShapePoint(x = -0.1521, y = 0.2228, role = "logo-flame-spark", progress = 0.933159),
            ShapePoint(x = -0.1396, y = 0.2210, role = "logo-flame-inner", progress = 0.934469),
            ShapePoint(x = -0.1273, y = 0.2206, role = "logo-flame-inner", progress = 0.935780),
            ShapePoint(x = -0.1202, y = 0.2433, role = "logo-flame-inner", progress = 0.937090),
            ShapePoint(x = -0.1315, y = 0.2464, role = "logo-flame-spark", progress = 0.938401),
            ShapePoint(x = -0.1433, y = 0.2480, role = "logo-flame-inner", progress = 0.939712),
            ShapePoint(x = 0.1920, y = 0.2870, role = "logo-flame-inner", progress = 0.941022),
            ShapePoint(x = 0.1912, y = 0.2750, role = "logo-flame-inner", progress = 0.942333),
            ShapePoint(x = 0.1806, y = 0.2783, role = "logo-flame-spark", progress = 0.943644),
            ShapePoint(x = 0.1714, y = 0.2876, role = "logo-flame-inner", progress = 0.944954),
            ShapePoint(x = 0.1703, y = 0.2744, role = "logo-flame-inner", progress = 0.946265),
            ShapePoint(x = 0.1601, y = 0.2696, role = "logo-flame-inner", progress = 0.947575),
            ShapePoint(x = 0.1573, y = 0.2586, role = "logo-flame-spark", progress = 0.948886),
            ShapePoint(x = 0.1479, y = 0.2522, role = "logo-flame-inner", progress = 0.950197),
            ShapePoint(x = 0.1369, y = 0.2540, role = "logo-flame-inner", progress = 0.951507),
            ShapePoint(x = 0.1257, y = 0.2568, role = "logo-flame-inner", progress = 0.952818),
            ShapePoint(x = 0.1175, y = 0.2647, role = "logo-flame-spark", progress = 0.954128),
            ShapePoint(x = 0.1141, y = 0.2539, role = "logo-flame-inner", progress = 0.955439),
            ShapePoint(x = 0.1029, y = 0.2527, role = "logo-flame-inner", progress = 0.956750),
            ShapePoint(x = 0.1087, y = 0.2425, role = "logo-flame-inner", progress = 0.958060),
            ShapePoint(x = 0.1189, y = 0.2369, role = "logo-flame-spark", progress = 0.959371),
            ShapePoint(x = 0.1269, y = 0.2282, role = "logo-flame-inner", progress = 0.960682),
            ShapePoint(x = 0.1368, y = 0.2233, role = "logo-flame-inner", progress = 0.961992),
            ShapePoint(x = 0.1306, y = 0.2406, role = "logo-flame-inner", progress = 0.963303),
            ShapePoint(x = 0.1524, y = 0.2417, role = "logo-flame-spark", progress = 0.964613),
            ShapePoint(x = 0.1633, y = 0.2434, role = "logo-flame-inner", progress = 0.965924),
            ShapePoint(x = 0.1743, y = 0.2394, role = "logo-flame-inner", progress = 0.967235),
            ShapePoint(x = 0.1794, y = 0.2292, role = "logo-flame-inner", progress = 0.968545),
            ShapePoint(x = 0.1847, y = 0.2189, role = "logo-flame-spark", progress = 0.969856),
            ShapePoint(x = 0.1909, y = 0.2281, role = "logo-flame-inner", progress = 0.971166),
            ShapePoint(x = 0.1896, y = 0.2394, role = "logo-flame-inner", progress = 0.972477),
            ShapePoint(x = 0.1932, y = 0.2499, role = "logo-flame-inner", progress = 0.973788),
            ShapePoint(x = 0.2022, y = 0.2431, role = "logo-flame-spark", progress = 0.975098),
            ShapePoint(x = 0.1967, y = 0.2614, role = "logo-flame-inner", progress = 0.976409),
            ShapePoint(x = 0.2030, y = 0.2717, role = "logo-flame-inner", progress = 0.977720),
            ShapePoint(x = 0.2037, y = 0.2894, role = "logo-flame-inner", progress = 0.979030),
            ShapePoint(x = -0.0315, y = 0.2959, role = "logo-flame-spark", progress = 0.980341),
            ShapePoint(x = -0.0292, y = 0.2848, role = "logo-flame-inner", progress = 0.981651),
            ShapePoint(x = -0.0394, y = 0.2796, role = "logo-flame-inner", progress = 0.982962),
            ShapePoint(x = -0.0432, y = 0.2681, role = "logo-flame-inner", progress = 0.984273),
            ShapePoint(x = -0.0375, y = 0.2467, role = "logo-flame-spark", progress = 0.985583),
            ShapePoint(x = -0.0261, y = 0.2459, role = "logo-flame-inner", progress = 0.986894),
            ShapePoint(x = -0.0155, y = 0.2489, role = "logo-flame-inner", progress = 0.988204),
            ShapePoint(x = -0.0065, y = 0.2565, role = "logo-flame-inner", progress = 0.989515),
            ShapePoint(x = -0.0046, y = 0.2674, role = "logo-flame-spark", progress = 0.990826),
            ShapePoint(x = -0.0014, y = 0.2782, role = "logo-flame-inner", progress = 0.992136),
            ShapePoint(x = 0.0070, y = 0.2710, role = "logo-flame-inner", progress = 0.993447),
            ShapePoint(x = 0.0142, y = 0.2603, role = "logo-flame-inner", progress = 0.994758),
            ShapePoint(x = 0.0206, y = 0.2491, role = "logo-flame-spark", progress = 0.996068),
            ShapePoint(x = 0.0306, y = 0.2429, role = "logo-flame-inner", progress = 0.997379),
            ShapePoint(x = -0.0007, y = 0.2893, role = "logo-flame-inner", progress = 0.998689),
            ShapePoint(x = -0.0117, y = 0.2896, role = "logo-flame-inner", progress = 1.000000)
        )
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
