package com.openburnbar.ui.components

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.UIMode
import kotlin.random.Random

internal class SwarmSimulation(
    private val particleCount: Int,
    pace: SwarmPace,
    context: Context? = null,
    enabledProviderGlyphs: Set<AgentProvider> = AgentProvider.swarmGlyphProviders.toSet(),
    val excludeBrandShapes: Boolean = false,
    val uiMode: UIMode = UIMode.STANDARD,
    private val clockNanos: () -> Long = System::nanoTime,
) {
    private val appContext = context?.applicationContext
    private val tables = SwarmShapeTables(appContext)

    enum class Mode {
        SWARM,
        SHAPE_DOLLAR,
        SHAPE_CODE,
        SHAPE_RINGS,
        SHAPE_ROUTER_FLOW,
        SHAPE_COOKING_5,
        SHAPE_XAI_LOGO,
        SHAPE_GROK_LOGO,
        SHAPE_PROVIDER_LOGOS,
    }

    class Particle(
        var x: Double,
        var y: Double,
        var vx: Double,
        var vy: Double,
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
        var flowProgress: Double = 0.0,
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

    // Per-advance dt scaling: 1.0 == one canonical 60Hz step (the cadence the
    // constants above were tuned at). Velocities stay in canonical
    // px-per-60Hz-frame units so the maxSpeed clamps keep their tuned meaning;
    // forces and position integration scale by stepScale, and drag — an
    // exponential per-step decay — is exponentiated, not multiplied.
    private var stepScale: Double = 1.0
    private var swarmDragStep: Double = 0.0
    private var morphDragStep: Double = 0.0

    // The render plan's speed scale (iOS `SwarmCanvasView.motionSpeedMultiplier`
    // feeding the simulation): 1.0 prominent, 0.55 subtle. Scales the noise
    // forces, attract forces, flow-time, path progress, and the speed cap —
    // the same sites iOS scales — so the subtle plan is calmer motion, not
    // just fewer/slower frames. Clamped to the iOS range.
    var motionSpeedMultiplier: Double = 1.0
        set(value) {
            field = value.coerceIn(0.35, 2.5)
        }

    private val speedMultiplier: Double
        get() = if (isEnergetic) 1.0 else 0.35

    private var enabledProviderLogos =
        normalizeProviderGlyphs(AgentProvider.swarmGlyphProviders, enabledProviderGlyphs)
    private var providerLogoBatches = enabledProviderLogos.chunked(6)
    private var providerLogoBatchIndex = 0
    private var shapePreference = "all"
    var paletteName: String = "System"
    var isRewinding: Boolean = false
    var isAvatarEnabled: Boolean = true
    var isBrandTextEnabled: Boolean = true

    /**
     * Render-plan auto-cycling gate (iOS: `allowsAutoCycling`). When false the
     * field keeps integrating physics but never advances to the next formation;
     * `nextCycleAtNanos` keeps bumping so re-enabling does not cycle instantly.
     */
    var isAutoCyclingEnabled: Boolean = true

    internal val providerLogoShowcaseKeys: Set<String>
        get() = AgentProvider.swarmGlyphProviders.mapTo(linkedSetOf()) { it.key }

    internal val enabledProviderLogoKeys: Set<String>
        get() = enabledProviderLogos.mapTo(linkedSetOf()) { it.key }

    private var activeModes = plannedModes()

    private fun plannedModes(): List<Mode> = defaultModes(uiMode, excludeBrandShapes, enabledProviderLogos, providerLogoBatches.size)

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

    private companion object {
        private const val SHAPE_ADMIRE_HOLD_NANOS = 5_000_000_000L
        private const val SHAPE_SETTLE_RECHECK_NANOS = 250_000_000L
        private const val SHAPE_SETTLE_FALLBACK_NANOS = 6_000_000_000L
        private const val SHAPE_SETTLED_PARTICLE_FRACTION = 0.95
    }

    init {
        setPace(pace)
        for (i in 0 until particleCount) {
            particles.add(makeSwarmParticle())
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
        enabledProviderLogos = normalizeProviderGlyphs(AgentProvider.swarmGlyphProviders, providers)
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
            "xai" ->
                activeModes =
                    if (enabledProviderLogos.contains(AgentProvider.XAI)) {
                        listOf(Mode.SHAPE_XAI_LOGO)
                    } else {
                        listOf(Mode.SWARM)
                    }
            "grok" ->
                activeModes =
                    if (enabledProviderLogos.contains(AgentProvider.XAI)) {
                        listOf(Mode.SHAPE_GROK_LOGO)
                    } else {
                        listOf(Mode.SWARM)
                    }
            "providers" -> {
                providerLogoBatchIndex = 0
                activeModes =
                    if (providerLogoBatches.isEmpty()) {
                        listOf(Mode.SWARM)
                    } else {
                        List(providerLogoBatches.size) { Mode.SHAPE_PROVIDER_LOGOS }
                    }
            }
            "all" -> activeModes = plannedModes()
            else -> activeModes = plannedModes()
        }
        cycleIndex = 0
        val nowNanos = if (lastTickNanos > 0L) lastTickNanos else clockNanos()
        assignMode(activeModes[0], nowNanos)
        nextCycleAtNanos = nowNanos + cycleIntervalNanos
    }

    fun prewarmShapePointTables(): Int = tables.prewarmShapePointTables(uiMode)

    // Internal (not private) so unit tests can assert prewarm/sync parity.
    internal fun providerLogoPoints(provider: AgentProvider): List<ShapePoint> = tables.providerLogoPoints(provider)

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

    fun advance(nowNanos: Long, pointer: Offset?, frameScale: Double = 1.0) {
        if (!initialized) {
            lastTickNanos = nowNanos
            nextCycleAtNanos = nowNanos + cycleIntervalNanos
            return
        }
        stepScale = frameScale
        swarmDragStep = Math.pow(swarmDrag, frameScale)
        morphDragStep = Math.pow(morphDrag, frameScale)
        if (nowNanos >= nextCycleAtNanos && activeModes.size > 1 && isAutoCyclingEnabled) {
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
        flowTime += timeStep * 1000.0 * motionSpeedMultiplier * frameScale

        val width = bounds.width.toDouble()
        val height = bounds.height.toDouble()
        val px = pointer?.x?.toDouble()
        val py = pointer?.y?.toDouble()

        for (i in particles.indices) {
            stepParticle(i, width, height, px, py)
        }
        lastTickNanos = nowNanos
    }

    private fun stepParticle(i: Int, width: Double, height: Double, pointerX: Double?, pointerY: Double?) {
        val p = particles[i]
        val (noiseX, noiseY) = flowFieldNoise(p.x, p.y, flowTime)
        val (pushX, pushY) = pointerPushVector(p, pointerX, pointerY, mouseForceMultiplier)
        val forces = SwarmStepForces(noiseX, noiseY, pushX, pushY)
        val cfg =
            SwarmStepConfig(
                stepScale = stepScale,
                swarmNoise = swarmNoise,
                swarmDragStep = swarmDragStep,
                morphNoise = morphNoise,
                morphDragStep = morphDragStep,
                morphAttract = morphAttract,
                maxSpeedGlyph = maxSpeedGlyph,
                maxSpeedPixel = maxSpeedPixel,
                isRewinding = isRewinding,
                motionSpeedMultiplier = motionSpeedMultiplier,
            )
        if (mode == Mode.SWARM) {
            stepSwarmParticle(p, forces, cfg, width, height)
        } else {
            if (mode == Mode.SHAPE_ROUTER_FLOW && uiMode != UIMode.COOKING && p.role != null) {
                retargetRouterFlowParticle(p, width, height, flowTime, isEnergetic, stepScale, motionSpeedMultiplier)
            }
            stepMorphedParticle(p, forces, cfg, width, height)
        }
        applyShapeBrightness(p, mode != Mode.SWARM && p.tx != null)
    }

    private fun assignMode(next: Mode, assignedAtNanos: Long = clockNanos()) {
        mode = next
        modeAssignedAtNanos = assignedAtNanos
        shapeSettledAtNanos = null
        if (next == Mode.SWARM) {
            for (p in particles) {
                p.tx = null
                p.ty = null
                p.role = null
                p.logoColor = null
            }
            return
        }

        when (next) {
            Mode.SHAPE_XAI_LOGO -> {
                assignProviderLogos(listOf(ProviderLogoSpec(AgentProvider.XAI, tables.xAiLogoPoints)))
                return
            }
            Mode.SHAPE_GROK_LOGO -> {
                assignProviderLogos(listOf(ProviderLogoSpec(AgentProvider.XAI, tables.grokLogoPoints)))
                return
            }
            Mode.SHAPE_PROVIDER_LOGOS -> {
                if (providerLogoBatches.isEmpty()) {
                    assignMode(Mode.SWARM, assignedAtNanos)
                    return
                }
                val batch =
                    providerLogoBatches
                        .getOrNull(providerLogoBatchIndex % providerLogoBatches.size)
                        ?: enabledProviderLogos
                providerLogoBatchIndex = (providerLogoBatchIndex + 1) % providerLogoBatches.size
                assignProviderLogos(
                    batch.map { provider ->
                        ProviderLogoSpec(provider, tables.providerLogoPoints(provider))
                    },
                )
                return
            }
            else -> Unit
        }

        val pts = tables.pointsForMode(next, uiMode)
        val width = bounds.width.toDouble()
        val height = bounds.height.toDouble()
        assignShapeTargets(particles, pts, shapeLayoutFor(next, width, height))
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
            assignLogoGroup(visibleSpecs[specIndex], groups[specIndex], slots[specIndex], height, visibleSpecs.size == 1)
        }
    }

    private fun assignLogoGroup(spec: ProviderLogoSpec, group: List<Int>, slot: ProviderLogoSlot, height: Double, singleLogo: Boolean) {
        val textPoints = providerTextPoints(spec.provider)
        val drawAvatar = isAvatarEnabled
        val drawText = isBrandTextEnabled && textPoints.isNotEmpty()

        if (drawAvatar && drawText && singleLogo) {
            distributeAvatarAndTextGroup(
                group,
                LogoPointTarget(spec.points, slot.centerX, slot.centerY, slot.scale),
                LogoPointTarget(textPoints, SWARM_TEXT_BADGE_CENTER_X, height - SWARM_TEXT_BADGE_BOTTOM_MARGIN, SWARM_TEXT_BADGE_SCALE),
                spec.provider.key,
                particles,
            )
        } else if (drawText && !drawAvatar && singleLogo) {
            // Form ONLY bottom-left text logo badge.
            distributeParticlesToLogo(
                group,
                LogoPointTarget(textPoints, SWARM_TEXT_BADGE_CENTER_X, height - SWARM_TEXT_BADGE_BOTTOM_MARGIN, SWARM_TEXT_BADGE_SCALE),
                spec.provider.key,
                particles,
            )
        } else if (drawAvatar) {
            // Form ONLY main central avatar logo.
            distributeParticlesToLogo(
                group,
                LogoPointTarget(spec.points, slot.centerX, slot.centerY, slot.scale),
                spec.provider.key,
                particles,
            )
        } else {
            // Neither avatar nor text are enabled: drift freely in pure swarm.
            for (particleIdx in group) {
                particles[particleIdx].tx = null
                particles[particleIdx].ty = null
                particles[particleIdx].role = null
                particles[particleIdx].logoColor = null
            }
        }
    }

    private val effectiveShapeSettleFallbackNanos: Long
        get() = (SHAPE_SETTLE_FALLBACK_NANOS / (speedMultiplier * motionSpeedMultiplier)).toLong()

    private fun shouldDelayCycleForAdmireHold(nowNanos: Long): Boolean {
        if (!mode.requiresSettledAdmireHold()) return false

        if (shapeSettledAtNanos == null) {
            if (
                formationIsSettled(particles, bounds, speedMultiplier * motionSpeedMultiplier, SHAPE_SETTLED_PARTICLE_FRACTION) ||
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

    private fun Mode.requiresSettledAdmireHold(): Boolean = this != Mode.SWARM && this != Mode.SHAPE_ROUTER_FLOW

    fun colorFor(p: Particle, accent: Color, isDark: Boolean = true): Color {
        val raw = p.opacity.toFloat().coerceIn(0f, 1f)
        // Lift the floor slightly in light mode so the deeper palette reads.
        val opacity = if (isDark) raw else (raw + 0.08f).coerceAtMost(1f)

        p.logoColor?.let { source ->
            return source.copy(alpha = (opacity * 1.62f).coerceAtMost(1f))
        }

        if (uiMode == UIMode.COOKING) {
            return cookingSwarmColor(p.colorIndex, opacity)
        }

        parseRoleAndProvider(p.role)?.let { (role, provider) ->
            p.logoColor?.let { source ->
                return contrastAdjustedSourceLogoColor(source).copy(alpha = (opacity * 1.62f).coerceAtMost(1f))
            }
            return providerLogoColor(provider, role, opacity, isDark)
        }

        val palette = swarmPaletteFor(paletteName, isDark)
        val role = p.role
        if (mode == Mode.SHAPE_ROUTER_FLOW && role != null) {
            return routerFlowColor(role, palette, accent, opacity)
        }
        return emberIndexColor(p.colorIndex, palette, opacity)
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
}
