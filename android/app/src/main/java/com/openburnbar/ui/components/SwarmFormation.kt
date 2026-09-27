package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Size
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.UIMode
import kotlin.math.min
import kotlin.math.sqrt

/** Mode planning, settle detection, and logo-particle distribution for the swarm engine. */
internal fun normalizeProviderGlyphs(showcase: List<AgentProvider>, providers: Set<AgentProvider>): List<AgentProvider> =
    showcase.filter { providers.contains(it) }

internal fun formationIsSettled(particles: List<SwarmSimulation.Particle>, bounds: Size, speedMultiplier: Double, settledFraction: Double): Boolean {
    // Tighten the threshold at slower speeds so particles must form a sharper,
    // fully-settled shape before starting the hold/admire timer.
    val baseThreshold = maxOf(22.0, min(bounds.width, bounds.height).toDouble() * 0.022)
    val threshold = baseThreshold * speedMultiplier.coerceIn(0.5, 1.0)

    var targeted = 0
    var close = 0
    var totalDistance = 0.0

    for (p in particles) {
        val tx = p.tx
        val ty = p.ty
        if (tx == null || ty == null) continue
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
    return closeFraction >= settledFraction && averageDistance <= threshold * 1.75
}

internal fun defaultModes(
    uiMode: UIMode,
    excludeBrandShapes: Boolean,
    enabledProviderLogos: List<AgentProvider>,
    providerLogoBatchCount: Int,
): List<SwarmSimulation.Mode> = buildList {
    if (uiMode == UIMode.COOKING) {
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_DOLLAR) // Apple
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_CODE) // Cherry
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_RINGS) // Banana
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_ROUTER_FLOW) // Cookie
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_COOKING_5) // Cupcake
    } else if (excludeBrandShapes) {
        add(SwarmSimulation.Mode.SWARM)
        if (enabledProviderLogos.contains(AgentProvider.XAI)) {
            add(SwarmSimulation.Mode.SHAPE_GROK_LOGO)
        }
        repeat(providerLogoBatchCount) {
            add(SwarmSimulation.Mode.SWARM)
            add(SwarmSimulation.Mode.SHAPE_PROVIDER_LOGOS)
        }
    } else {
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_DOLLAR)
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_CODE)
        add(SwarmSimulation.Mode.SWARM)
        if (enabledProviderLogos.contains(AgentProvider.XAI)) {
            add(SwarmSimulation.Mode.SHAPE_GROK_LOGO)
        }
        repeat(providerLogoBatchCount) {
            add(SwarmSimulation.Mode.SWARM)
            add(SwarmSimulation.Mode.SHAPE_PROVIDER_LOGOS)
        }
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_RINGS)
        add(SwarmSimulation.Mode.SWARM)
        add(SwarmSimulation.Mode.SHAPE_ROUTER_FLOW)
    }
}

internal data class ShapeLayout(val centerX: Double, val centerY: Double, val scale: Double)

internal fun shapeLayoutFor(next: SwarmSimulation.Mode, width: Double, height: Double): ShapeLayout {
    var centerX = width * 0.5
    var centerY = height * 0.45
    var scaleFactor = 0.35
    if (width > 960) {
        // Wide layouts: shapes off to the side and high, clear of content.
        when (next) {
            SwarmSimulation.Mode.SHAPE_RINGS -> {
                centerX = width * 0.78
                centerY = height * 0.30
                scaleFactor = 0.50
            }
            SwarmSimulation.Mode.SHAPE_ROUTER_FLOW -> {
                centerX = width * 0.5
                centerY = height * 0.26
                scaleFactor = 0.85
            }
            else -> {
                centerX = width * 0.74
                centerY = height * 0.28
                scaleFactor = 0.45
            }
        }
    } else {
        // Phones: present shapes in the emptier upper band under the nav.
        when (next) {
            SwarmSimulation.Mode.SHAPE_RINGS -> {
                centerY = height * 0.24
                scaleFactor = 0.48
            }
            SwarmSimulation.Mode.SHAPE_ROUTER_FLOW -> {
                centerX = width * 0.5
                centerY = height * 0.24
                scaleFactor = 0.85
            }
            else -> {
                centerY = height * 0.22
                scaleFactor = 0.45
            }
        }
    }
    return ShapeLayout(centerX, centerY, min(width, height) * scaleFactor)
}

internal fun assignShapeTargets(particles: MutableList<SwarmSimulation.Particle>, pts: List<ShapePoint>, layout: ShapeLayout) {
    val indices = particles.indices.toMutableList().also { it.shuffle() }
    for (slot in indices.indices) {
        val p = particles[indices[slot]]
        if (slot < pts.size) {
            val pt = pts[slot]
            p.tx = layout.centerX + pt.x * layout.scale
            p.ty = layout.centerY + pt.y * layout.scale
            p.role = pt.role
            p.logoColor = pt.color
            p.flowProgress = pt.progress
        } else {
            p.tx = null
            p.ty = null
            p.role = null
            p.logoColor = null
        }
    }
}

internal fun spreadPointIndex(slot: Int, groupSize: Int, pointsSize: Int): Int {
    if (groupSize <= pointsSize) {
        val t = slot.toDouble() / (groupSize - 1).coerceAtLeast(1).toDouble()
        return ((pointsSize - 1) * t).toInt().coerceAtMost(pointsSize - 1)
    }
    return slot % pointsSize
}

internal data class LogoPointTarget(
    val points: List<ShapePoint>,
    val centerX: Double,
    val centerY: Double,
    val scale: Double,
)

internal fun distributeParticlesToLogo(group: List<Int>, target: LogoPointTarget, providerKey: String, particles: MutableList<SwarmSimulation.Particle>) {
    for ((slot, particleIdx) in group.withIndex()) {
        val pt = target.points[spreadPointIndex(slot, group.size, target.points.size)]
        val p = particles[particleIdx]
        p.tx = target.centerX + pt.x * target.scale
        p.ty = target.centerY + pt.y * target.scale
        p.role = "${pt.role ?: "logo-flame-inner"}:$providerKey"
        p.isGlyph = false
        p.logoColor = pt.color
        p.flowProgress = pt.progress
    }
}

internal const val SWARM_TEXT_BADGE_CENTER_X = 135.0
internal const val SWARM_TEXT_BADGE_BOTTOM_MARGIN = 55.0
internal const val SWARM_TEXT_BADGE_SCALE = 110.0

internal fun distributeAvatarAndTextGroup(
    group: List<Int>,
    avatar: LogoPointTarget,
    text: LogoPointTarget,
    providerKey: String,
    particles: MutableList<SwarmSimulation.Particle>,
) {
    // Split particles: 70% to central avatar, 30% to bottom-left text logo badge.
    val avatarCount = (group.size * 0.70).toInt()
    distributeParticlesToLogo(group.subList(0, avatarCount), avatar, providerKey, particles)
    distributeParticlesToLogo(group.subList(avatarCount, group.size), text, providerKey, particles)
}
