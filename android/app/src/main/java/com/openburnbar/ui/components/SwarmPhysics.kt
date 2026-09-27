package com.openburnbar.ui.components

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Per-step force/noise sampling and particle integration for the swarm engine. */
internal data class SwarmStepForces(
    val noiseX: Double,
    val noiseY: Double,
    val pushX: Double,
    val pushY: Double,
)

internal data class SwarmStepConfig(
    val stepScale: Double,
    val swarmNoise: Double,
    val swarmDragStep: Double,
    val morphNoise: Double,
    val morphDragStep: Double,
    val morphAttract: Double,
    val maxSpeedGlyph: Double,
    val maxSpeedPixel: Double,
    val isRewinding: Boolean,
    // Render-plan speed scale (see SwarmSimulation.motionSpeedMultiplier).
    val motionSpeedMultiplier: Double = 1.0,
)

internal fun flowFieldNoise(x: Double, y: Double, flowTime: Double): Pair<Double, Double> {
    val noiseX = sin(y * 0.005 + flowTime * 2) * cos(x * 0.003 + flowTime)
    val noiseY = cos(x * 0.005 + flowTime * 3) * sin(y * 0.003 + flowTime * 2)
    return noiseX to noiseY
}

internal fun pointerPushVector(p: SwarmSimulation.Particle, pointerX: Double?, pointerY: Double?, mouseForceMultiplier: Double): Pair<Double, Double> {
    if (pointerX == null || pointerY == null) return 0.0 to 0.0
    val dx = p.x - pointerX
    val dy = p.y - pointerY
    val dist = sqrt(dx * dx + dy * dy)
    if (dist !in 0.001..140.0) return 0.0 to 0.0
    val force = (140.0 - dist) / 140.0
    return ((dx / dist) * force * mouseForceMultiplier) to ((dy / dist) * force * mouseForceMultiplier)
}

internal fun wrapParticleInBounds(p: SwarmSimulation.Particle, width: Double, height: Double) {
    if (p.x < 0) p.x = width
    if (p.x > width) p.x = 0.0
    if (p.y < 0) p.y = height
    if (p.y > height) p.y = 0.0
}

internal fun stepSwarmParticle(p: SwarmSimulation.Particle, forces: SwarmStepForces, cfg: SwarmStepConfig, width: Double, height: Double) {
    p.vx += (forces.noiseX * cfg.swarmNoise * cfg.motionSpeedMultiplier + forces.pushX) * cfg.stepScale
    p.vy += (forces.noiseY * cfg.swarmNoise * cfg.motionSpeedMultiplier + forces.pushY) * cfg.stepScale
    p.vx *= cfg.swarmDragStep
    p.vy *= cfg.swarmDragStep
    val speed = sqrt(p.vx * p.vx + p.vy * p.vy)
    val maxSpeed = (if (p.isGlyph) cfg.maxSpeedGlyph else cfg.maxSpeedPixel) * cfg.motionSpeedMultiplier
    if (speed > maxSpeed && speed > 0) {
        p.vx = (p.vx / speed) * maxSpeed
        p.vy = (p.vy / speed) * maxSpeed
    }
    p.x += p.vx * cfg.stepScale
    p.y += p.vy * cfg.stepScale
    wrapParticleInBounds(p, width, height)
}

internal fun stepMorphedParticle(p: SwarmSimulation.Particle, forces: SwarmStepForces, cfg: SwarmStepConfig, width: Double, height: Double) {
    val tx = p.tx
    val ty = p.ty
    if (tx == null || ty == null) {
        stepDriftingParticle(p, forces, cfg, width, height)
        return
    }
    val dx = tx - p.x
    val dy = ty - p.y
    val dist = sqrt(dx * dx + dy * dy)
    if (dist > 1) {
        val attract = if (cfg.isRewinding) -cfg.morphAttract * 1.5 else cfg.morphAttract
        p.vx += (dx / dist) * attract * cfg.motionSpeedMultiplier * cfg.stepScale
        p.vy += (dy / dist) * attract * cfg.motionSpeedMultiplier * cfg.stepScale
    }
    p.vx += (forces.noiseX * cfg.morphNoise * cfg.motionSpeedMultiplier + forces.pushX) * cfg.stepScale
    p.vy += (forces.noiseY * cfg.morphNoise * cfg.motionSpeedMultiplier + forces.pushY) * cfg.stepScale
    p.vx *= cfg.morphDragStep
    p.vy *= cfg.morphDragStep
    p.x += p.vx * cfg.stepScale
    p.y += p.vy * cfg.stepScale
    wrapParticleInBounds(p, width, height)
}

internal fun stepDriftingParticle(p: SwarmSimulation.Particle, forces: SwarmStepForces, cfg: SwarmStepConfig, width: Double, height: Double) {
    p.vx += (forces.noiseX * cfg.swarmNoise * 0.75 * cfg.motionSpeedMultiplier + forces.pushX) * cfg.stepScale
    p.vy += (forces.noiseY * cfg.swarmNoise * 0.75 * cfg.motionSpeedMultiplier + forces.pushY) * cfg.stepScale
    p.vx *= cfg.swarmDragStep
    p.vy *= cfg.swarmDragStep
    p.x += p.vx * cfg.stepScale
    p.y += p.vy * cfg.stepScale
    wrapParticleInBounds(p, width, height)
}

internal fun retargetRouterFlowParticle(
    p: SwarmSimulation.Particle,
    width: Double,
    height: Double,
    flowTime: Double,
    isEnergetic: Boolean,
    stepScale: Double,
    motionSpeedMultiplier: Double = 1.0,
) {
    val role = p.role ?: return
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
            val tgtY =
                when (role) {
                    "target-1" -> -0.28
                    "target-3" -> 0.28
                    else -> 0.0
                }
            val angle = p.colorIndex * PI * 2 + flowTime * 12
            p.tx = centerX + (0.45 + cos(angle) * 0.05) * scale
            p.ty = centerY + (tgtY + sin(angle) * 0.05) * scale
        }
        role.startsWith("path-") -> {
            val tgtY =
                when (role) {
                    "path-1" -> -0.28
                    "path-3" -> 0.28
                    else -> 0.0
                }
            p.flowProgress += (if (isEnergetic) 0.006 else 0.003) * stepScale * motionSpeedMultiplier
            if (p.flowProgress > 1.0) p.flowProgress = 0.0
            val t = p.flowProgress
            val pxn = -0.45 + 0.9 * t
            val pyn = tgtY * (3 * t * t - 2 * t * t * t)
            p.tx = centerX + pxn * scale
            p.ty = centerY + pyn * scale
        }
    }
}

internal fun applyShapeBrightness(p: SwarmSimulation.Particle, shaped: Boolean) {
    // Particles that are part of an active shape get a brightness boost so
    // the reformed glyph / rings / router-flow read through glass cards.
    val shapeBoost = if (shaped) 1.7 else 1.0
    p.opacity = (p.baseOpacity * shapeBoost).coerceAtMost(1.0)
}
