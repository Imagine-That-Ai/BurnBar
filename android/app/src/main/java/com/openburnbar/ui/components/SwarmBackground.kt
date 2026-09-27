package com.openburnbar.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.settings.rememberExcludeBrandShapesFromSwarm
import com.openburnbar.ui.settings.rememberSwarmSparkles
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.ui.theme.LocalUIMode
import com.openburnbar.ui.theme.UIMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.android.awaitFrame
import kotlinx.coroutines.withContext

/**
 * The active, reconverging token-ember swarm from burnbar.ai, ported to Compose.
 *
 * Hundreds of particles murmurate across the screen, periodically reconverging
 * into "$", "</>", provider logos, Grok/xAI marks, concentric quota rings, and
 * a router failover S-curve — then breaking apart again. Touches push nearby
 * particles away. Reduce Motion pauses the cycling and silences the noise field.
 *
 * The swarm is gated by [SwarmBackgroundPowerPolicy] (the Kotlin port of the
 * iOS gate in `SwarmBackgroundPreferences.swift`, consumed on iOS by
 * `ConstellationBackgroundView`): prefs + platform sensors resolve to a
 * [SwarmBackgroundRenderPlan], and only [SwarmRenderMode.LIVE] runs the
 * simulation and its frame loop. Static/disabled plans render the flat field
 * color with no Canvas and no loop, matching the iOS static/disabled
 * fallbacks. Live plans apply the plan's frame-rate cap, particle scale,
 * auto-cycling, and sparkle gates.
 *
 * @param preferences Swarm prefs. Defaults to the persisted Where/When pickers
 * ([SwarmBackgroundPreferencesStore], everywhere/always when unset) so the
 * historical always-on behavior is preserved until the user picks otherwise
 * in Settings → Theme. Tests inject explicit prefs.
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
    excludeBrandShapes: Boolean = false,
    // Editorial / Paper skin: force the light rendering (paper backdrop + the
    // AA-legible darker dot colours) regardless of the OS dark-mode setting, so
    // the dot-crest reads on paper. The light-locked editorial dot-crest.
    forceLight: Boolean = false,
    preferences: SwarmBackgroundPreferences = persistedSwarmBackgroundPreferences(),
    visibility: MobileBackgroundVisibility = MobileBackgroundVisibility.PROMINENT,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val isDark = if (forceLight) false else androidx.compose.foundation.isSystemInDarkTheme()

    // Enforcement gate: resolve the render plan before touching the
    // simulation. The guard chain is order-sensitive and lives in the policy;
    // the shared helper supplies the platform sensors + surface eligibility.
    // (Same gate shape as SwarmPlanGate, kept inline because the live body
    // consumes the plan: sparkle/auto-cycle/frame-rate/particle/motion scales.)
    val plan = rememberSwarmRenderPlan(visibility = visibility, preferences = preferences)
    when (plan.mode) {
        SwarmRenderMode.LIVE -> {}
        SwarmRenderMode.DISABLED_FALLBACK -> {
            AuroraAnimatedBackdrop(isDark = isDark, density = AuroraDensity.FULL, reduceMotion = reduceMotion)
            return
        }
        SwarmRenderMode.STATIC_BACKDROP -> {
            SwarmStaticBackdrop(modifier = modifier, isDark = isDark)
            return
        }
    }

    val enableSwarmSparkles by rememberSwarmSparkles()
    val excludeBrandShapesSetting by rememberExcludeBrandShapesFromSwarm()
    val actualExcludeBrandShapes = excludeBrandShapes || excludeBrandShapesSetting
    val allowsSparkles = enableSwarmSparkles && plan.allowsSparkles
    val effectiveParticleCount = scaledSwarmParticleCount(particleCount, plan)
    val uiMode = LocalUIMode.current
    val selectedProviderGlyphs = enabledProviderGlyphs ?: AgentProvider.swarmGlyphProviders.toSet()
    val simulation =
        rememberSwarmSimulation(effectiveParticleCount, pace, selectedProviderGlyphs, actualExcludeBrandShapes, uiMode).apply {
            this.isAvatarEnabled = isAvatarEnabled
            this.isBrandTextEnabled = isBrandTextEnabled
            this.isAutoCyclingEnabled = plan.allowsAutoCycling
            this.paletteName = paletteName
            this.motionSpeedMultiplier = plan.motionSpeedMultiplierScale
        }
    var pointer by remember { mutableStateOf<Offset?>(null) }
    var version by remember { mutableIntStateOf(0) }
    SwarmPrewarmEffect(simulation)
    SwarmFrameLoop(simulation, reduceMotion, swarmFrameIntervalNanos(plan), pointer) { version++ }
    SwarmPointerBox(modifier, isDark, onPointerChange = { pointer = it }) {
        SwarmParticleCanvas(simulation, accentColor, isDark, version, allowsSparkles)
    }
}

@Composable
private fun rememberSwarmSimulation(
    particleCount: Int,
    pace: SwarmPace,
    selectedProviderGlyphs: Set<AgentProvider>,
    actualExcludeBrandShapes: Boolean,
    uiMode: UIMode,
): SwarmSimulation {
    val context = LocalContext.current
    return remember(particleCount, pace, selectedProviderGlyphs, actualExcludeBrandShapes, uiMode) {
        SwarmSimulation(
            particleCount = particleCount,
            pace = pace,
            context = context.applicationContext,
            enabledProviderGlyphs = selectedProviderGlyphs,
            excludeBrandShapes = actualExcludeBrandShapes,
            uiMode = uiMode,
        )
    }
}

@Composable
private fun SwarmPrewarmEffect(simulation: SwarmSimulation) {
    // Pre-warm every shape's point table OFF the main thread before the first
    // reconvergence, so assignMode() never decodes + flood-fills the provider
    // logo bitmaps synchronously inside the awaitFrame loop (the same prewarm
    // DotConstellationBackground does). Each table is a SYNCHRONIZED lazy that
    // stays the cache-miss path: a racing first formation just blocks exactly
    // as it did before, and the sampled points are identical either way.
    LaunchedEffect(simulation) {
        withContext(Dispatchers.Default) { simulation.prewarmShapePointTables() }
    }
}

@Composable
private fun SwarmFrameLoop(simulation: SwarmSimulation, reduceMotion: Boolean, minStepIntervalNanos: Long, pointer: Offset?, onStepped: () -> Unit) {
    val currentPointer by rememberUpdatedState(pointer)
    LaunchedEffect(reduceMotion, minStepIntervalNanos) {
        var lastStepNanos = 0L
        while (!reduceMotion) {
            val frameNanos = awaitFrame()
            // Cap physics + redraw at the plan's frame rate (30fps prominent,
            // 15fps subtle) so 90/120Hz panels skip vsyncs instead of running
            // extra simulation steps.
            val elapsedNanos = frameNanos - lastStepNanos
            if (elapsedNanos < minStepIntervalNanos) continue
            lastStepNanos = frameNanos
            simulation.advance(frameNanos, currentPointer, frameScaleFor(elapsedNanos))
            onStepped() // trigger recomposition for the Canvas
        }
    }
}

@Composable
private fun SwarmPointerBox(modifier: Modifier, isDark: Boolean, onPointerChange: (Offset?) -> Unit, content: @Composable () -> Unit) {
    Box(
        modifier =
        modifier
            .fillMaxSize()
            // Match app appearance so cards stay coherent over the swarm.
            .background(if (isDark) Color(0xFF050508) else Color(0xFFF3EFE7))
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { onPointerChange(it) },
                    onDragEnd = { onPointerChange(null) },
                    onDragCancel = { onPointerChange(null) },
                ) { change, _ ->
                    onPointerChange(change.position)
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        onPointerChange(it)
                        tryAwaitRelease()
                        onPointerChange(null)
                    },
                )
            },
    ) {
        content()
    }
}

@Composable
private fun SwarmParticleCanvas(simulation: SwarmSimulation, accentColor: Color, isDark: Boolean, version: Int, allowsSparkles: Boolean) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        // `version` read inside an enclosing snapshot — read once so Canvas
        // recomposes each frame.
        val tick = version

        simulation.ensureBounds(size)
        drawSwarmDots(simulation, accentColor, isDark, allowsSparkles)
        drawSwarmGlyphs(simulation, accentColor, isDark)
    }
}

private fun DrawScope.drawSwarmDots(simulation: SwarmSimulation, accentColor: Color, isDark: Boolean, allowsSparkles: Boolean) {
    simulation.particles.forEachIndexed { index, p ->
        if (p.isGlyph) return@forEachIndexed
        val color = simulation.colorFor(p, accentColor, isDark)
        val inShape = simulation.inShapeMode && p.tx != null

        var r = (p.size * if (inShape) 1.2 else 0.85).toDouble()
        var isSparkling = false
        var sparkleIntensity = 0.0

        if (allowsSparkles && inShape && simulation.shapeSettledAtNanos != null) {
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
            center = Offset(p.x.toFloat(), p.y.toFloat()),
        )

        if (isSparkling) {
            // Draw core glint
            val sr = r * 0.35
            drawCircle(
                color = Color.White.copy(alpha = (sparkleIntensity * 0.55).toFloat()),
                radius = sr.toFloat(),
                center = Offset(p.x.toFloat(), p.y.toFloat()),
            )
            // Draw outer subtle glow halo
            val glowR = r * 0.75
            drawCircle(
                color = Color.White.copy(alpha = (sparkleIntensity * 0.15).toFloat()),
                radius = glowR.toFloat(),
                center = Offset(p.x.toFloat(), p.y.toFloat()),
            )
        }
    }
}

private fun DrawScope.drawSwarmGlyphs(simulation: SwarmSimulation, accentColor: Color, isDark: Boolean) {
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

enum class SwarmPace { ENERGETIC, CINEMATIC }

// Step cadence: the swarm physics were tuned at 60Hz, so each step is scaled
// by the real elapsed time (frameScaleFor) and the plan's frame-rate cap sets
// the loop floor — 60Hz is only the fallback when a plan carries no cap.
private const val CANONICAL_FRAME_NANOS = 16_666_667.0

private fun frameScaleFor(elapsedNanos: Long): Double {
    val scale = elapsedNanos / CANONICAL_FRAME_NANOS
    // Snap near-canonical steps to exactly 1.0 so 60Hz panels (and capped
    // 120Hz panels) run the bit-identical historical step; long gaps (first
    // frame, resume from background) collapse to at most two steps.
    return if (scale in 0.98..1.02) 1.0 else scale.coerceIn(0.5, 2.0)
}
