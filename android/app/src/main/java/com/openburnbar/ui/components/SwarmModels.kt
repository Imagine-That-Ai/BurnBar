package com.openburnbar.ui.components

import androidx.compose.ui.graphics.Color
import com.openburnbar.data.models.AgentProvider
import kotlin.random.Random

/** Shared point/particle models for the swarm engine. */
internal data class ShapePoint(
    val x: Double,
    val y: Double,
    val role: String?,
    val progress: Double,
    val color: Color? = null,
)

internal data class ProviderLogoSpec(
    val provider: AgentProvider,
    val points: List<ShapePoint>,
)

internal data class ProviderLogoSlot(
    val centerX: Double,
    val centerY: Double,
    val scale: Double,
)

internal val SWARM_GLYPHS = listOf("$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache")

internal fun makeSwarmParticle(glyphs: List<String> = SWARM_GLYPHS): SwarmSimulation.Particle {
    val isGlyph = Random.nextDouble() < 0.08
    return SwarmSimulation.Particle(
        x = 0.0, y = 0.0,
        vx = (Random.nextDouble() - 0.5) * 1.5,
        vy = (Random.nextDouble() - 0.5) * 1.5,
        size = 1.2 + Random.nextDouble() * 1.8,
        isGlyph = isGlyph,
        glyph = glyphs[Random.nextInt(glyphs.size)],
        colorIndex = Random.nextDouble(),
        baseOpacity = 0.16 + Random.nextDouble() * 0.20,
        opacity = 0.16,
    )
}

internal data class RoutePoint(val x: Double, val y: Double, val role: String, val progress: Double)
