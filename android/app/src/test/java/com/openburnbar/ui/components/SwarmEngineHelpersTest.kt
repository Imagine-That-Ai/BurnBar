// UI unit-test fixture literals (sizes, colors, pixel values); extraction adds noise without reuse.

package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.UIMode
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM coverage for the helpers extracted from the old SwarmBackground god
 * file: cooking/spline geometry, particle coloring, logo bitmap sampling over
 * raw ARGB pixels, the physics integrators, and formation layout math.
 */
class SwarmEngineHelpersTest {
    private fun particle(x: Double = 50.0, y: Double = 50.0, tx: Double? = null, ty: Double? = null, role: String? = null, isGlyph: Boolean = false) =
        SwarmSimulation.Particle(
            x = x,
            y = y,
            vx = 0.0,
            vy = 0.0,
            size = 2.0,
            isGlyph = isGlyph,
            glyph = "",
            colorIndex = 0.5,
            baseOpacity = 0.5,
            opacity = 0.5,
            tx = tx,
            ty = ty,
            role = role,
        )

    private fun config(motionSpeedMultiplier: Double = 1.0, isRewinding: Boolean = false) = SwarmStepConfig(
        stepScale = 1.0,
        swarmNoise = 0.1,
        swarmDragStep = 0.9,
        morphNoise = 0.05,
        morphDragStep = 0.8,
        morphAttract = 0.5,
        maxSpeedGlyph = 1.0,
        maxSpeedPixel = 2.0,
        isRewinding = isRewinding,
        motionSpeedMultiplier = motionSpeedMultiplier,
    )

    private fun assertFinite(points: List<ShapePoint>) {
        assertTrue(points.isNotEmpty())
        assertTrue(points.all { it.x.isFinite() && it.y.isFinite() })
    }

    @Test
    fun cookingShapesProduceFiniteOutlines() {
        listOf(
            generateApplePoints(),
            generateCherryPoints(),
            generateBananaPoints(),
            generateCookiePoints(),
            generateCupcakePoints(),
        ).forEach(::assertFinite)
    }

    @Test
    fun splinesCoverClosedOpenAndDegenerateInputs() {
        val square = listOf(0.0 to 0.0, 1.0 to 0.0, 1.0 to 1.0, 0.0 to 1.0)
        val closed = generateSpline(square, stepsPerSegment = 4, colorStart = Color.Red, colorEnd = Color.Blue)
        val open = generateSpline(square, stepsPerSegment = 4, colorStart = Color.Red, isClosed = false)
        assertFinite(closed)
        assertFinite(open)
        assertTrue(generateSpline(emptyList(), stepsPerSegment = 4, colorStart = Color.Red).isEmpty())
        assertEquals(16, splinePoints(square, stepsPerSegment = 4, role = "ring").size)
        assertTrue(splinePoints(square.take(2), stepsPerSegment = 4, role = "ring").isEmpty())
        assertEquals(80 + 130 + 180, generateRingPoints().size)
        val route = generateRouterFlowPoints()
        assertEquals(setOf("gateway", "target-1", "target-2", "target-3", "path-1", "path-2", "path-3"), route.map { it.role }.toSet())
    }

    @Test
    fun providerAndPaletteColorsCoverEveryRole() {
        for (role in listOf("logo-flame-outer", "logo-flame-spark", "logo-flame-inner")) {
            assertTrue(providerLogoColor(AgentProvider.CLAUDE_CODE, role, 0.5f, isDark = true).alpha <= 1f)
            assertTrue(providerLogoColor(AgentProvider.XAI, role, 0.9f, isDark = true).alpha <= 1f)
            assertTrue(providerLogoColor(AgentProvider.XAI, role, 0.2f, isDark = false).alpha > 0f)
        }
        assertEquals(Color(0xFFD6DBE5), contrastAdjustedSourceLogoColor(Color.Black))
        assertNotEquals(Color(0xFF303030), contrastAdjustedSourceLogoColor(Color(0xFF303030)))
        assertEquals(Color.White, contrastAdjustedSourceLogoColor(Color.White))

        assertNull(parseRoleAndProvider(null))
        assertNull(parseRoleAndProvider("no-separator"))
        assertNull(parseRoleAndProvider("trailing:"))
        assertNull(parseRoleAndProvider("logo:not-a-provider"))
        assertEquals("logo-flame-inner" to AgentProvider.XAI, parseRoleAndProvider("logo-flame-inner:${AgentProvider.XAI.key}"))

        assertEquals(COOKING_SWARM_COLORS.first().copy(alpha = 0.75f), cookingSwarmColor(0.0, 0.5f))
        assertEquals(COOKING_SWARM_COLORS.last().copy(alpha = 1f), cookingSwarmColor(1.0, 0.9f))

        for (name in listOf("Aurora", "AuroraTeal", "Crimson", "SunsetCrimson", "System")) {
            assertNotEquals(swarmPaletteFor(name, isDark = true), swarmPaletteFor(name, isDark = false))
        }
        val palette = swarmPaletteFor("System", isDark = true)
        val roles = listOf("gateway", "path-1", "target-2", "path-3", "unknown")
        assertEquals(roles.size, roles.map { routerFlowColor(it, palette, Color.Green, 0.4f) }.toSet().size)
        val embers = listOf(0.0, 0.2, 0.5, 0.9).map { emberIndexColor(it, palette, 0.5f) }
        assertEquals(listOf(palette.whimsy, palette.ember, palette.amber, palette.blaze).map { it.copy(alpha = 0.5f) }, embers)
        assertEquals(Color.Red, blend(Color.Red, Color.Blue, -1f))
        assertTrue(relativeLuminance(Color.White) > relativeLuminance(Color.Black))
    }

    @Test
    fun logoBitmapSamplingFindsTheForegroundInsideAnOpaqueBackground() {
        val width = 40
        val height = 40
        val background = 0xFFFFFFFF.toInt()
        val pixels = IntArray(width * height) { background }
        for (y in 10 until 30) {
            for (x in 12 until 28) {
                pixels[y * width + x] =
                    when {
                        x < 16 -> 0xFF101010.toInt() // dark: outer
                        x > 24 -> 0xFFF0F040.toInt() // bright and saturated: spark
                        else -> 0xFFD04010.toInt() // mid: inner
                    }
            }
        }

        val inferred = inferredOpaqueBackgroundColor(pixels, width, height)
        assertNotNull(inferred)
        val mask = connectedBackgroundMask(pixels, width, height, inferred)
        assertNotNull(mask)
        assertNull(connectedBackgroundMask(pixels, width, height, null))

        val bounds = foregroundBoundingBox(pixels, width, height, mask, inferred)
        assertEquals(LogoBitmapBounds(12, 10, 27, 29), bounds)
        val points = sampleForegroundPoints(pixels, width, requireNotNull(bounds), mask, inferred, maxPoints = 40)
        assertTrue(points.isNotEmpty())
        assertTrue(points.all { abs(it.x) <= 1.0 && abs(it.y) <= 1.0 })
        assertEquals(setOf("logo-flame-outer", "logo-flame-inner", "logo-flame-spark"), points.mapNotNull { it.role }.toSet())

        // Background-only and transparent images have no foreground.
        assertNull(foregroundBoundingBox(IntArray(16) { background }, 4, 4, null, inferred))
        assertNull(inferredOpaqueBackgroundColor(IntArray(16), 4, 4))
    }

    @Test
    fun foregroundPixelClassificationHonorsAlphaMaskAndBackground() {
        val white = Color.White
        assertFalse(isLogoForegroundPixel(0x00000000, 0, null, white))
        assertTrue(isLogoForegroundPixel(0xFF000000.toInt(), 0, booleanArrayOf(false), white))
        assertFalse(isLogoForegroundPixel(0xFF000000.toInt(), 0, booleanArrayOf(true), white))
        assertTrue(isLogoForegroundPixel(0xFF000000.toInt(), 5, booleanArrayOf(true), white))
        assertTrue(isLogoForegroundPixel(0xFF808080.toInt(), 0, null, null))
        assertFalse(isLogoForegroundPixel(0xFFFFFFFF.toInt(), 0, null, white))
        assertFalse(isLogoForegroundPixel(0xFFF4F4F4.toInt(), 0, null, Color(0xFFE0E0E0)))
        assertTrue(isLogoForegroundPixel(0xFFD04010.toInt(), 0, null, white))

        assertTrue(isBackgroundLikePixel(0x10FFFFFF, Color.Black))
        assertTrue(isBackgroundLikePixel(0xFFFFFFFF.toInt(), white))
        assertTrue(isBackgroundLikePixel(0xFFF4F4F4.toInt(), Color(0xFFE0E0E0)))
        assertFalse(isBackgroundLikePixel(0xFFD04010.toInt(), white))
    }

    @Test
    fun integratorsApplyMotionSpeedAndClampToBounds() {
        val calm = particle().also { it.vx = 10.0 }
        stepSwarmParticle(calm, SwarmStepForces(1.0, 1.0, 0.0, 0.0), config(motionSpeedMultiplier = 0.5), 100.0, 100.0)
        assertTrue(kotlin.math.hypot(calm.vx, calm.vy) <= 2.0 * 0.5 + 1e-9)

        val glyph = particle(isGlyph = true).also { it.vy = 10.0 }
        stepSwarmParticle(glyph, SwarmStepForces(0.0, 0.0, 0.0, 0.0), config(), 100.0, 100.0)
        assertTrue(kotlin.math.hypot(glyph.vx, glyph.vy) <= 1.0 + 1e-9)

        val attracted = particle(tx = 90.0, ty = 50.0)
        stepMorphedParticle(attracted, SwarmStepForces(0.0, 0.0, 0.0, 0.0), config(), 100.0, 100.0)
        assertTrue(attracted.vx > 0)
        val rewinding = particle(tx = 90.0, ty = 50.0)
        stepMorphedParticle(rewinding, SwarmStepForces(0.0, 0.0, 0.0, 0.0), config(isRewinding = true), 100.0, 100.0)
        assertTrue(rewinding.vx < 0)
        val untargeted = particle()
        stepMorphedParticle(untargeted, SwarmStepForces(1.0, 0.0, 0.0, 0.0), config(), 100.0, 100.0)
        assertTrue(untargeted.vx > 0)

        val edge = particle(x = -1.0, y = 101.0)
        wrapParticleInBounds(edge, 100.0, 100.0)
        assertEquals(100.0, edge.x, 0.0)
        assertEquals(0.0, edge.y, 0.0)

        assertEquals(0.0 to 0.0, pointerPushVector(particle(), null, null, 1.0))
        assertEquals(0.0 to 0.0, pointerPushVector(particle(), 500.0, 500.0, 1.0))
        assertTrue(pointerPushVector(particle(), 40.0, 50.0, 1.0).first > 0)
        val (nx, ny) = flowFieldNoise(10.0, 20.0, 0.5)
        assertTrue(nx in -1.0..1.0 && ny in -1.0..1.0)
    }

    @Test
    fun routerFlowRetargetsEveryRoleAndScalesPathProgress() {
        val gateway = particle(role = "gateway")
        retargetRouterFlowParticle(gateway, 1200.0, 800.0, flowTime = 1.0, isEnergetic = true, stepScale = 1.0)
        assertNotNull(gateway.tx)
        for (role in listOf("target-1", "target-2", "target-3")) {
            val target = particle(role = role)
            retargetRouterFlowParticle(target, 600.0, 800.0, flowTime = 1.0, isEnergetic = false, stepScale = 1.0)
            assertNotNull(target.ty)
        }
        val fast = particle(role = "path-1")
        val slow = particle(role = "path-3")
        retargetRouterFlowParticle(fast, 600.0, 800.0, flowTime = 0.0, isEnergetic = true, stepScale = 1.0)
        retargetRouterFlowParticle(slow, 600.0, 800.0, flowTime = 0.0, isEnergetic = true, stepScale = 1.0, motionSpeedMultiplier = 0.5)
        assertEquals(fast.flowProgress / 2.0, slow.flowProgress, 1e-12)
        val wrapped = particle(role = "path-2").also { it.flowProgress = 0.999 }
        retargetRouterFlowParticle(wrapped, 600.0, 800.0, flowTime = 0.0, isEnergetic = true, stepScale = 1.0)
        assertEquals(0.0, wrapped.flowProgress, 0.0)
        val unassigned = particle()
        retargetRouterFlowParticle(unassigned, 600.0, 800.0, flowTime = 0.0, isEnergetic = true, stepScale = 1.0)
        assertNull(unassigned.tx)
    }

    @Test
    fun formationLayoutAndSettleMath() {
        val modes = SwarmSimulation.Mode.entries
        for (mode in modes) {
            val wide = shapeLayoutFor(mode, 1400.0, 900.0)
            val phone = shapeLayoutFor(mode, 400.0, 800.0)
            assertTrue(wide.scale > 0 && phone.scale > 0)
        }
        assertTrue(defaultModes(UIMode.COOKING, false, emptyList(), 0).contains(SwarmSimulation.Mode.SHAPE_COOKING_5))
        assertTrue(defaultModes(UIMode.STANDARD, true, listOf(AgentProvider.XAI), 1).isNotEmpty())
        assertTrue(defaultModes(UIMode.STANDARD, false, AgentProvider.swarmGlyphProviders, 2).isNotEmpty())

        assertEquals(0, spreadPointIndex(0, 3, 10))
        assertEquals(9, spreadPointIndex(2, 3, 10))
        assertEquals(1, spreadPointIndex(4, 5, 3))

        val particles = MutableList(4) { particle() }
        assignShapeTargets(particles, listOf(ShapePoint(0.1, 0.1, "a", 0.0), ShapePoint(-0.1, 0.1, "b", 0.5)), ShapeLayout(50.0, 50.0, 10.0))
        assertEquals(2, particles.count { it.tx != null })

        val settled = List(10) { particle(tx = 50.0, ty = 50.0) }
        val scattered = List(10) { particle(x = 0.0, y = 0.0, tx = 500.0, ty = 500.0) }
        assertTrue(formationIsSettled(settled, Size(1000f, 1000f), 1.0, 0.8))
        assertFalse(formationIsSettled(scattered, Size(1000f, 1000f), 0.35, 0.8))
        assertTrue(formationIsSettled(listOf(particle()), Size(1000f, 1000f), 1.0, 0.8))

        val group = (0 until 10).toList()
        val target = LogoPointTarget(listOf(ShapePoint(0.0, 0.0, null, 0.0), ShapePoint(0.5, 0.5, "logo-flame-spark", 1.0)), 10.0, 10.0, 5.0)
        val logoParticles = MutableList(10) { particle(isGlyph = true) }
        distributeAvatarAndTextGroup(group, target, target, "claude", logoParticles)
        assertTrue(logoParticles.all { !it.isGlyph && it.role?.endsWith(":claude") == true })
        assertEquals(listOf(AgentProvider.XAI), normalizeProviderGlyphs(listOf(AgentProvider.XAI, AgentProvider.CLAUDE_CODE), setOf(AgentProvider.XAI)))
    }

    @Test
    fun autoCyclingGateHoldsTheCurrentFormation() {
        var now = 0L
        val simulation = SwarmSimulation(particleCount = 120, pace = SwarmPace.ENERGETIC, clockNanos = { now })
        simulation.ensureBounds(Size(800f, 600f))
        simulation.isAutoCyclingEnabled = false
        simulation.motionSpeedMultiplier = 10.0
        assertEquals(2.5, simulation.motionSpeedMultiplier, 0.0)
        val before = simulation.particles.map { it.role }
        repeat(20) {
            now += 2_000_000_000L
            simulation.advance(now, null, 1.0)
        }
        assertEquals(before, simulation.particles.map { it.role })
    }
}
