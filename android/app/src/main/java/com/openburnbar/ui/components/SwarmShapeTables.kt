package com.openburnbar.ui.components

import android.content.Context
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.UIMode
import kotlin.random.Random

/**
 * Lazily-built point tables behind [SwarmSimulation].
 *
 * Each table is a SYNCHRONIZED `lazy` (the historic cache-miss path): racing
 * dereferences block and serve identical points. [prewarmShapePointTables]
 * forces them on a background thread so the frame loop never pays.
 */
internal class SwarmShapeTables(private val appContext: Context?) {

    private val dollarPoints by lazy { sampleTextPoints("$", 280f) }

    private val codePoints by lazy { sampleTextPoints("</>", 220f) }

    private val ringPoints by lazy { generateRingPoints() }

    private val routerFlowPoints by lazy { generateRouterFlowPoints() }

    private val appleSplinePoints by lazy { generateApplePoints() }

    private val cherrySplinePoints by lazy { generateCherryPoints() }

    private val bananaSplinePoints by lazy { generateBananaPoints() }

    private val cookieSplinePoints by lazy { generateCookiePoints() }

    private val cupcakeSplinePoints by lazy { generateCupcakePoints() }

    private val providerLogoPointCache by lazy {
        AgentProvider.swarmGlyphProviders.associateWith { provider ->
            logoPoints(appContext, provider, fallbackLogoPoints(provider))
        }
    }

    internal val xAiLogoPoints by lazy { generateXAILogoPoints() }

    internal val grokLogoPoints by lazy { logoPoints(appContext, AgentProvider.XAI, generateGrokLogoPoints()) }

    /**
     * Forces every shape point table this configuration can form — the
     * bitmap-sampled provider logos (one decode + getPixels scan + flood fill
     * per showcase logo), the Grok/xAI marks, and the "$"/"</>" text rasters —
     * so the work runs on the calling (background) thread instead of inside
     * the first [assignMode] on the UI frame loop. Each table is a
     * SYNCHRONIZED lazy and remains the cache-miss path: a racing dereference
     * from the UI thread blocks exactly as it did historically and serves the
     * identical points. Returns the number of points warmed.
     */
    fun prewarmShapePointTables(uiMode: UIMode): Int {
        if (uiMode == UIMode.COOKING) {
            // Cooking cycles only ever form the generated splines.
            return appleSplinePoints.size + cherrySplinePoints.size + bananaSplinePoints.size +
                cookieSplinePoints.size + cupcakeSplinePoints.size
        }
        var warmed =
            providerLogoPointCache.values.sumOf { it.size } +
                grokLogoPoints.size + xAiLogoPoints.size +
                ringPoints.size + routerFlowPoints.size
        if (appContext != null) {
            // The text rasters draw through android.graphics, which the
            // context-less JVM unit-test construction cannot host; the bitmap
            // tables above already short-circuit to generated fallbacks there.
            warmed += dollarPoints.size + codePoints.size
        }
        return warmed
    }

    internal fun providerLogoPoints(provider: AgentProvider): List<ShapePoint> {
        if (provider == AgentProvider.XAI) return xAiLogoPoints
        return providerLogoPointCache[provider] ?: logoPoints(appContext, provider, fallbackLogoPoints(provider))
    }

    /** Point table for a badge/shape mode (provider logos resolve separately). */
    internal fun pointsForMode(next: SwarmSimulation.Mode, uiMode: UIMode): List<ShapePoint> {
        if (uiMode == UIMode.COOKING) {
            return when (next) {
                SwarmSimulation.Mode.SHAPE_DOLLAR -> appleSplinePoints
                SwarmSimulation.Mode.SHAPE_CODE -> cherrySplinePoints
                SwarmSimulation.Mode.SHAPE_RINGS -> bananaSplinePoints
                SwarmSimulation.Mode.SHAPE_ROUTER_FLOW -> cookieSplinePoints
                SwarmSimulation.Mode.SHAPE_COOKING_5 -> cupcakeSplinePoints
                else -> emptyList()
            }
        }
        return when (next) {
            SwarmSimulation.Mode.SHAPE_DOLLAR -> dollarPoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
            SwarmSimulation.Mode.SHAPE_CODE -> codePoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
            SwarmSimulation.Mode.SHAPE_RINGS -> ringPoints.map { ShapePoint(it.first, it.second, null, Random.nextDouble()) }
            SwarmSimulation.Mode.SHAPE_ROUTER_FLOW -> routerFlowPoints.map { ShapePoint(it.x, it.y, it.role, it.progress) }
            else -> emptyList()
        }
    }
}
