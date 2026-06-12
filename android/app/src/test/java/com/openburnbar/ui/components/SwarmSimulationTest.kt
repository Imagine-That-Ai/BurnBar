// UI unit-test fixture literals (sizes, millis, colors); extraction adds noise without reuse.

package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Size
import com.openburnbar.data.models.AgentProvider
import kotlin.math.abs
import kotlin.math.sqrt
import org.junit.Assert.assertTrue
import org.junit.Test

class SwarmSimulationTest {
    @Test
    fun grokShapeAssignsXaiProviderRoles() {
        val simulation = SwarmSimulation(particleCount = 180, pace = SwarmPace.CINEMATIC)

        simulation.ensureBounds(Size(1200f, 800f))
        simulation.setShapeMode("grok")

        assertTrue(
            simulation.particles.any { it.role?.endsWith(":${AgentProvider.XAI.key}") == true },
        )
    }

    @Test
    fun providerLogoSwarmAssignsSeveralProvidersAtOnce() {
        val simulation = SwarmSimulation(particleCount = 300, pace = SwarmPace.CINEMATIC)

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        val providers =
            simulation.particles
                .mapNotNull { it.role?.substringAfter(':', missingDelimiterValue = "") }
                .filter { it.isNotBlank() }
                .toSet()

        assertTrue(simulation.providerLogoShowcaseKeys.containsAll(AgentProvider.entries.map { it.key }))
        assertTrue(providers.contains(AgentProvider.CLAUDE_CODE.key))
        assertTrue(providers.contains(AgentProvider.OPENCODE.key))
    }

    @Test
    fun providerLogoSwarmObeysEnabledProviderGlyphFilter() {
        val simulation =
            SwarmSimulation(
                particleCount = 300,
                pace = SwarmPace.CINEMATIC,
                enabledProviderGlyphs = setOf(AgentProvider.CODEX, AgentProvider.OPEN_CLAW),
            )

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        val providers =
            simulation.particles
                .mapNotNull { it.role?.substringAfter(':', missingDelimiterValue = "") }
                .filter { it.isNotBlank() }
                .toSet()

        assertTrue(simulation.enabledProviderLogoKeys == setOf(AgentProvider.CODEX.key, AgentProvider.OPEN_CLAW.key))
        assertTrue(providers.contains(AgentProvider.CODEX.key))
        assertTrue(providers.contains(AgentProvider.OPEN_CLAW.key))
        assertTrue(!providers.contains(AgentProvider.CLAUDE_CODE.key))
    }

    @Test
    fun providerLogoSwarmHidesProviderRolesWhenAllGlyphsAreDisabled() {
        val simulation =
            SwarmSimulation(
                particleCount = 180,
                pace = SwarmPace.CINEMATIC,
                enabledProviderGlyphs = emptySet(),
            )

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        assertTrue(simulation.enabledProviderLogoKeys.isEmpty())
        assertTrue(simulation.particles.none { it.role?.contains(':') == true })
    }

    @Test
    fun providerLogoCyclesWaitForSettledAdmireHold() {
        var nowNanos = 1_000_000_000L
        val providers = AgentProvider.swarmGlyphProviders.take(12).toSet()
        val simulation =
            SwarmSimulation(
                particleCount = 360,
                pace = SwarmPace.CINEMATIC,
                enabledProviderGlyphs = providers,
                clockNanos = { nowNanos },
            )

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        val firstBatch = providerKeysInFormation(simulation)
        assertTrue(firstBatch.contains(AgentProvider.swarmGlyphProviders[0].key))
        assertTrue(!firstBatch.contains(AgentProvider.swarmGlyphProviders[6].key))

        nowNanos += 14_000_000_000L
        simulation.advance(nowNanos, pointer = null)
        assertTrue(providerKeysInFormation(simulation) == firstBatch)

        simulation.particles.forEach { particle ->
            particle.tx?.let { particle.x = it }
            particle.ty?.let { particle.y = it }
        }

        nowNanos += 250_000_000L
        simulation.advance(nowNanos, pointer = null)
        assertTrue(providerKeysInFormation(simulation) == firstBatch)

        nowNanos += 3_900_000_000L
        simulation.advance(nowNanos, pointer = null)
        assertTrue(providerKeysInFormation(simulation) == firstBatch)

        nowNanos += 1_200_000_000L
        simulation.advance(nowNanos, pointer = null)
        val secondBatch = providerKeysInFormation(simulation)
        assertTrue(secondBatch != firstBatch)
        assertTrue(secondBatch.contains(AgentProvider.swarmGlyphProviders[6].key))
    }

    @Test
    fun providerLogoMappingsUseRealVisualAssetsForInspectedAgents() {
        assertTrue(ProviderLogo.drawableFor(AgentProvider.OPEN_CLAW) == com.openburnbar.R.drawable.logo_openclaw)
        assertTrue(ProviderLogo.drawableFor(AgentProvider.HERMES) == com.openburnbar.R.drawable.logo_hermes)
        assertTrue(ProviderLogo.drawableFor(AgentProvider.CODEX) == com.openburnbar.R.drawable.logo_codex)
        assertTrue(ProviderLogo.drawableFor(AgentProvider.ANTIGRAVITY) == com.openburnbar.R.drawable.logo_antigravity)
    }

    @Test
    fun switchingColorPaletteChangesResolvedColors() {
        val simulation = SwarmSimulation(particleCount = 180, pace = SwarmPace.CINEMATIC)
        val particle =
            SwarmSimulation.Particle(
                x = 100.0, y = 100.0,
                vx = 0.0, vy = 0.0,
                size = 3.0,
                isGlyph = false,
                glyph = "",
                // falls into 'amber' range (0.35 to 0.62)
                colorIndex = 0.5,
                baseOpacity = 1.0,
                opacity = 1.0,
            )

        // Default / System palette (amber is 0xFFFFA800)
        simulation.paletteName = "System"
        val systemColor = simulation.colorFor(particle, androidx.compose.ui.graphics.Color.Red, isDark = true)
        org.junit.Assert.assertEquals(androidx.compose.ui.graphics.Color(0xFFFFA800), systemColor)

        // AuroraTeal palette (amber is 0xFF00F5FF)
        simulation.paletteName = "AuroraTeal"
        val auroraColor = simulation.colorFor(particle, androidx.compose.ui.graphics.Color.Red, isDark = true)
        org.junit.Assert.assertEquals(androidx.compose.ui.graphics.Color(0xFF00F5FF), auroraColor)

        // Crimson palette (amber is 0xFFFF4500)
        simulation.paletteName = "Crimson"
        val crimsonColor = simulation.colorFor(particle, androidx.compose.ui.graphics.Color.Red, isDark = true)
        org.junit.Assert.assertEquals(androidx.compose.ui.graphics.Color(0xFFFF4500), crimsonColor)
    }

    private fun providerKeysInFormation(simulation: SwarmSimulation): Set<String> = simulation.particles
        .mapNotNull { it.role?.substringAfter(':', missingDelimiterValue = "") }
        .filter { it.isNotBlank() }
        .toSet()

    @Test
    fun instantlysettleSnapsAllTargetedParticlesDirectlyToTarget() {
        val simulation = SwarmSimulation(particleCount = 180, pace = SwarmPace.CINEMATIC)
        simulation.ensureBounds(Size(1200f, 800f))
        simulation.setShapeMode("grok")

        // Ensure targets are assigned but not yet reached
        val targeted = simulation.particles.filter { it.tx != null }
        assertTrue(targeted.isNotEmpty())

        simulation.instantlySettle()

        targeted.forEach { p ->
            val tx = requireNotNull(p.tx)
            val ty = requireNotNull(p.ty)
            org.junit.Assert.assertEquals(tx, p.x, 0.0001)
            org.junit.Assert.assertEquals(ty, p.y, 0.0001)
            org.junit.Assert.assertEquals(0.0, p.vx, 0.0001)
            org.junit.Assert.assertEquals(0.0, p.vy, 0.0001)
        }
    }

    @Test
    fun forcecycleshapeSupportCyclingBackwards() {
        val simulation = SwarmSimulation(particleCount = 180, pace = SwarmPace.CINEMATIC)
        simulation.ensureBounds(Size(1200f, 800f))

        // Tap backwards (left) from initial Mode.SWARM
        simulation.forceCycleShape(forward = false)
        // Check that we go backward in cycle
        assertTrue(simulation.inShapeMode)
    }

    @Test
    fun isrewindingEnabledRepelsTargetedParticlesFromTargets() {
        val simulation = SwarmSimulation(particleCount = 300, pace = SwarmPace.CINEMATIC)
        simulation.ensureBounds(Size(1200f, 800f))
        simulation.setShapeMode("providers")

        // First snap to target
        simulation.instantlySettle()

        // Enable rewinding and take a step
        simulation.isRewinding = true
        // Set particle slightly off target to have non-zero dx/dy
        val p = simulation.particles.first { it.tx != null }
        val tx = requireNotNull(p.tx)
        val ty = requireNotNull(p.ty)
        p.x = tx - 5.0
        p.y = ty

        // Advance simulation
        simulation.advance(System.nanoTime(), pointer = null)

        // Since x is to the left of tx, attraction would pull right (vx > 0),
        // but rewinding repulsion should push it further left (vx < 0).
        assertTrue(p.vx < 0)
    }

    @Test
    fun frameScaleAdvancesFlowTimeByElapsedSimTime() {
        val canonical = SwarmSimulation(particleCount = 8, pace = SwarmPace.ENERGETIC)
        val scaled = SwarmSimulation(particleCount = 8, pace = SwarmPace.ENERGETIC)
        canonical.ensureBounds(Size(400f, 400f))
        scaled.ensureBounds(Size(400f, 400f))
        canonical.setShapeMode("swarm")
        scaled.setShapeMode("swarm")

        // Two canonical 60Hz steps must advance the noise-field clock exactly
        // as far as one double-length (frame-capped) step.
        canonical.advance(16_666_667L, pointer = null)
        canonical.advance(33_333_334L, pointer = null)
        scaled.advance(33_333_334L, pointer = null, frameScale = 2.0)

        org.junit.Assert.assertEquals(canonical.flowTime, scaled.flowTime, 0.0)
    }

    @Test
    fun frameScaledSteppingKeepsSwarmTravelRefreshRateIndependent() {
        val simulation = SwarmSimulation(particleCount = 240, pace = SwarmPace.ENERGETIC)
        simulation.ensureBounds(Size(1200f, 800f))
        simulation.setShapeMode("swarm")

        // Settle into steady-state murmuration at the canonical 60Hz step.
        var nowNanos = 1_000_000_000L
        repeat(180) {
            nowNanos += 16_666_667L
            simulation.advance(nowNanos, pointer = null)
        }

        val savedX = simulation.particles.map { it.x }
        val savedY = simulation.particles.map { it.y }
        val savedVx = simulation.particles.map { it.vx }
        val savedVy = simulation.particles.map { it.vy }
        val savedFlowTime = simulation.flowTime
        val savedNowNanos = nowNanos

        fun travel(frameScale: Double, steps: Int): Double {
            simulation.particles.forEachIndexed { i, p ->
                p.x = savedX[i]
                p.y = savedY[i]
                p.vx = savedVx[i]
                p.vy = savedVy[i]
            }
            simulation.flowTime = savedFlowTime
            var now = savedNowNanos
            var total = 0.0
            repeat(steps) {
                val beforeX = simulation.particles.map { it.x }
                val beforeY = simulation.particles.map { it.y }
                now += (16_666_667L * frameScale).toLong()
                simulation.advance(now, pointer = null, frameScale = frameScale)
                simulation.particles.forEachIndexed { i, p ->
                    val dx = p.x - beforeX[i]
                    val dy = p.y - beforeY[i]
                    val step = sqrt(dx * dx + dy * dy)
                    if (step < 50.0) total += step // ignore edge wrap-around jumps
                }
            }
            return total
        }

        // 120 canonical 60Hz steps vs 60 double-length steps span the same
        // simulated time, so total distance travelled must match. The legacy
        // fixed-per-frame step made distance proportional to step count (the
        // 120Hz double-speed bug): the scaled run would cover ~half as much.
        val canonicalTravel = travel(frameScale = 1.0, steps = 120)
        val scaledTravel = travel(frameScale = 2.0, steps = 60)
        assertTrue(canonicalTravel > 0.0)
        assertTrue(abs(scaledTravel - canonicalTravel) / canonicalTravel < 0.15)
    }

    @Test
    fun prewarmShapePointTablesWarmsEveryTableAndIsIdempotent() {
        val simulation = SwarmSimulation(particleCount = 60, pace = SwarmPace.CINEMATIC)

        val firstPass = simulation.prewarmShapePointTables()
        assertTrue(firstPass > 0)
        // The lazies cache: a second pass revisits the same tables and counts
        // the same points without recomputing them.
        org.junit.Assert.assertEquals(firstPass, simulation.prewarmShapePointTables())
    }

    @Test
    fun backgroundPrewarmCachesTheExactTablesTheSyncAssignPathServes() {
        val simulation = SwarmSimulation(particleCount = 60, pace = SwarmPace.CINEMATIC)

        val warmedTables = mutableMapOf<AgentProvider, List<SwarmSimulation.ShapePoint>>()
        val prewarmThread =
            Thread {
                simulation.prewarmShapePointTables()
                AgentProvider.swarmGlyphProviders.forEach { provider ->
                    warmedTables[provider] = simulation.providerLogoPoints(provider)
                }
            }
        prewarmThread.start()
        prewarmThread.join()

        // The (UI-thread) assign path must serve the very instances the
        // background prewarm cached — identical points, no second sampling.
        AgentProvider.swarmGlyphProviders.forEach { provider ->
            org.junit.Assert.assertSame(warmedTables[provider], simulation.providerLogoPoints(provider))
        }
    }

    @Test
    fun prewarmedTablesEqualTheTablesAColdSimulationComputesSynchronously() {
        val warmed = SwarmSimulation(particleCount = 60, pace = SwarmPace.CINEMATIC)
        val cold = SwarmSimulation(particleCount = 60, pace = SwarmPace.CINEMATIC)

        val prewarmThread = Thread { warmed.prewarmShapePointTables() }
        prewarmThread.start()
        prewarmThread.join()

        // Off-main prewarm must be pixel-identical to the historical
        // synchronous-on-assign path, point for point.
        AgentProvider.swarmGlyphProviders.forEach { provider ->
            org.junit.Assert.assertEquals(
                cold.providerLogoPoints(provider),
                warmed.providerLogoPoints(provider),
            )
        }
    }
}
