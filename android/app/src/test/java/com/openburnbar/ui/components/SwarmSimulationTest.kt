package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Size
import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.assertTrue
import org.junit.Test

class SwarmSimulationTest {
    @Test
    fun `grok shape assigns xai provider roles`() {
        val simulation = SwarmSimulation(particleCount = 180, pace = SwarmPace.CINEMATIC)

        simulation.ensureBounds(Size(1200f, 800f))
        simulation.setShapeMode("grok")

        assertTrue(
            simulation.particles.any { it.role?.endsWith(":${AgentProvider.XAI.key}") == true }
        )
    }

    @Test
    fun `provider logo swarm assigns several providers at once`() {
        val simulation = SwarmSimulation(particleCount = 300, pace = SwarmPace.CINEMATIC)

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        val providers = simulation.particles
            .mapNotNull { it.role?.substringAfter(':', missingDelimiterValue = "") }
            .filter { it.isNotBlank() }
            .toSet()

        assertTrue(simulation.providerLogoShowcaseKeys.containsAll(AgentProvider.entries.map { it.key }))
        assertTrue(providers.contains(AgentProvider.CLAUDE_CODE.key))
        assertTrue(providers.contains(AgentProvider.OPENCODE.key))
    }

    @Test
    fun `provider logo swarm obeys enabled provider glyph filter`() {
        val simulation = SwarmSimulation(
            particleCount = 300,
            pace = SwarmPace.CINEMATIC,
            enabledProviderGlyphs = setOf(AgentProvider.CODEX, AgentProvider.OPEN_CLAW)
        )

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        val providers = simulation.particles
            .mapNotNull { it.role?.substringAfter(':', missingDelimiterValue = "") }
            .filter { it.isNotBlank() }
            .toSet()

        assertTrue(simulation.enabledProviderLogoKeys == setOf(AgentProvider.CODEX.key, AgentProvider.OPEN_CLAW.key))
        assertTrue(providers.contains(AgentProvider.CODEX.key))
        assertTrue(providers.contains(AgentProvider.OPEN_CLAW.key))
        assertTrue(!providers.contains(AgentProvider.CLAUDE_CODE.key))
    }

    @Test
    fun `provider logo swarm hides provider roles when all glyphs are disabled`() {
        val simulation = SwarmSimulation(
            particleCount = 180,
            pace = SwarmPace.CINEMATIC,
            enabledProviderGlyphs = emptySet()
        )

        simulation.ensureBounds(Size(1400f, 900f))
        simulation.setShapeMode("providers")

        assertTrue(simulation.enabledProviderLogoKeys.isEmpty())
        assertTrue(simulation.particles.none { it.role?.contains(':') == true })
    }

    @Test
    fun `provider logo cycles wait for settled admire hold`() {
        var nowNanos = 1_000_000_000L
        val providers = AgentProvider.swarmGlyphProviders.take(12).toSet()
        val simulation = SwarmSimulation(
            particleCount = 360,
            pace = SwarmPace.CINEMATIC,
            enabledProviderGlyphs = providers,
            clockNanos = { nowNanos }
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

        nowNanos += 400_000_000L
        simulation.advance(nowNanos, pointer = null)
        val secondBatch = providerKeysInFormation(simulation)
        assertTrue(secondBatch != firstBatch)
        assertTrue(secondBatch.contains(AgentProvider.swarmGlyphProviders[6].key))
    }

    @Test
    fun `provider logo mappings use real visual assets for inspected agents`() {
        assertTrue(ProviderLogo.drawableFor(AgentProvider.OPEN_CLAW) == com.openburnbar.R.drawable.open_claw_logo)
        assertTrue(ProviderLogo.drawableFor(AgentProvider.HERMES) == com.openburnbar.R.drawable.hermes_logo)
        assertTrue(ProviderLogo.drawableFor(AgentProvider.CODEX) == com.openburnbar.R.drawable.codex_logo)
        assertTrue(ProviderLogo.drawableFor(AgentProvider.ANTIGRAVITY) == com.openburnbar.R.drawable.antigravity_logo)
    }

    private fun providerKeysInFormation(simulation: SwarmSimulation): Set<String> =
        simulation.particles
            .mapNotNull { it.role?.substringAfter(':', missingDelimiterValue = "") }
            .filter { it.isNotBlank() }
            .toSet()
}
