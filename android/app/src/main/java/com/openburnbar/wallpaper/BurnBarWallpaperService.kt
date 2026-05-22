package com.openburnbar.wallpaper

import android.content.SharedPreferences
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.view.SurfaceHolder
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.ui.components.SwarmPace
import com.openburnbar.ui.components.SwarmSimulation
import kotlin.math.max
import kotlin.math.min

/**
 * A live wallpaper that renders the BurnBar swarm simulation behind the home
 * screen. Particles are colored by the user's actual AI provider usage data.
 *
 * Architecture:
 * - The Engine instantiates a [SwarmSimulation] (the same class used by the
 *   in-app SwarmBackground composable) and renders it to a SurfaceHolder Canvas.
 * - Usage data is read from [BurnBarWidgetSnapshotStore] (the same file-backed
 *   store used by widgets), so no additional Firestore connections are needed.
 * - Frame rate is 30fps when visible, 0 when not visible.
 * - On battery saver, drops to 15fps and halves particle count.
 *
 * To set as wallpaper: Settings → Wallpaper → Live Wallpapers → BurnBar Live
 */
data class ProviderColorWeight(
    val provider: AgentProvider,
    val weight: Double,
    val argb: Int
)

class BurnBarWallpaperService : WallpaperService() {

    override fun onCreateEngine(): Engine = SwarmEngine()

    companion object {
        /** Near-black background matching the in-app swarm. */
        private const val BACKGROUND_COLOR = 0xFF050508.toInt()

        /** Reduced particle count for battery efficiency. */
        private const val WALLPAPER_PARTICLE_COUNT = 180
    }

    inner class SwarmEngine : Engine() {

        // Simulation
        private lateinit var simulation: SwarmSimulation
        private var providerWeights: List<ProviderColorWeight> = emptyList()
        private val wallpaperPrefs by lazy {
            getSharedPreferences("wallpaper_settings", android.content.Context.MODE_PRIVATE)
        }
        private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "pace" || key == "shape" || key == BurnBarWallpaperGlyphSettings.key) {
                updateSettings()
            }
        }

        // Render loop
        private val handler = Handler(Looper.getMainLooper())
        private var visible = false
        private var frameIntervalMs = 33L // ~30fps
        private var lastFrameNanos = System.nanoTime()

        // Paint objects (reused per frame to avoid allocation)
        private val particlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val glyphPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 20f
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
            style = Paint.Style.FILL
        }
        private val backgroundPaint = Paint().apply {
            color = BACKGROUND_COLOR
            style = Paint.Style.FILL
        }

        // Canvas background
        private val vignetteCenter = Paint(Paint.ANTI_ALIAS_FLAG)



        private val drawRunnable = object : Runnable {
            override fun run() {
                drawFrame()
                if (visible) {
                    handler.postDelayed(this, frameIntervalMs)
                }
            }
        }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            simulation = SwarmSimulation(
                particleCount = WALLPAPER_PARTICLE_COUNT,
                pace = SwarmPace.CINEMATIC, // Default, updated via settings
                context = applicationContext
            )
            wallpaperPrefs.registerOnSharedPreferenceChangeListener(preferenceListener)
            // Bind snapshot store so the StateFlow hydrates from disk.
            BurnBarWidgetSnapshotStore.bind(applicationContext)
            updateSettings()
            refreshProviderColors()
        }

        private fun updateSettings() {
            val pacePref = wallpaperPrefs.getString("pace", "cinematic") ?: "cinematic"
            val shapePref = wallpaperPrefs.getString("shape", "all") ?: "all"
            val providerGlyphs = BurnBarWallpaperGlyphSettings.read(wallpaperPrefs)

            simulation.setPace(if (pacePref == "energetic") SwarmPace.ENERGETIC else SwarmPace.CINEMATIC)
            simulation.setEnabledProviderGlyphs(providerGlyphs)

            // Adjust framerate based on pace to save battery if cinematic
            frameIntervalMs = if (pacePref == "energetic") 16L else 33L

            simulation.setShapeMode(shapePref)
        }

        override fun onVisibilityChanged(visible: Boolean) {
            this.visible = visible
            if (visible) {
                updateSettings()
                refreshProviderColors()
                handler.removeCallbacks(drawRunnable)
                handler.post(drawRunnable)
            } else {
                handler.removeCallbacks(drawRunnable)
            }
        }

        override fun onSurfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int
        ) {
            super.onSurfaceChanged(holder, format, width, height)
            simulation.ensureBounds(Size(width.toFloat(), height.toFloat()))
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            handler.removeCallbacks(drawRunnable)
            visible = false
            super.onSurfaceDestroyed(holder)
        }

        override fun onDestroy() {
            handler.removeCallbacks(drawRunnable)
            wallpaperPrefs.unregisterOnSharedPreferenceChangeListener(preferenceListener)
            super.onDestroy()
        }

        // MARK: - Drawing

        private fun drawFrame() {
            val holder = surfaceHolder ?: return
            var canvas: Canvas? = null
            try {
                canvas = holder.lockCanvas() ?: return
                val now = System.nanoTime()
                lastFrameNanos = now

                // Advance simulation
                simulation.advance(now, pointer = null)

                // Clear background
                canvas.drawRect(
                    0f, 0f,
                    canvas.width.toFloat(),
                    canvas.height.toFloat(),
                    backgroundPaint
                )

                // Draw particles
                val particles = simulation.particles
                for (i in particles.indices) {
                    val p = particles[i]
                    if (p.isGlyph) {
                        val color = resolveColor(p)
                        glyphPaint.color = color
                        canvas.drawText(p.glyph, p.x.toFloat(), p.y.toFloat(), glyphPaint)
                    } else {
                        val color = resolveColor(p)
                        particlePaint.color = color
                        canvas.drawCircle(p.x.toFloat(), p.y.toFloat(), max(0.5f, p.size.toFloat()), particlePaint)
                    }
                }
            } catch (_: Exception) {
                // Surface may be destroyed mid-draw; silently catch.
            } finally {
                if (canvas != null) {
                    try {
                        holder.unlockCanvasAndPost(canvas)
                    } catch (_: Exception) {
                        // Surface destroyed between lock and unlock.
                    }
                }
            }
        }

        // MARK: - Color Resolution

        /**
         * Resolves a particle's color from the weighted provider palette.
         * Maps the particle's colorIndex (0…1) into provider color bands.
         * Falls back to the default ember/amber/blaze palette when no
         * provider data is available.
         */
        private fun resolveColor(p: SwarmSimulation.Particle): Int {
            if (p.role?.contains(":") == true) {
                return simulation.colorFor(p, Color(0xFFFF6B35), isDark = true).toArgb()
            }

            if (providerWeights.isNotEmpty()) {
                var accumulated = 0.0
                for (pw in providerWeights) {
                    accumulated += pw.weight
                    if (p.colorIndex < accumulated) {
                        return applyOpacity(pw.argb, p.opacity)
                    }
                }
                // Rounding residual — use last provider
                return applyOpacity(providerWeights.last().argb, p.opacity)
            }

            // Fallback: default palette
            return when {
                p.colorIndex < 0.08 -> applyOpacity(0xFF8080FF.toInt(), p.opacity) // whimsy
                p.colorIndex < 0.35 -> applyOpacity(0xFFFA6B06.toInt(), p.opacity) // ember
                p.colorIndex < 0.62 -> applyOpacity(0xFFFDC42C.toInt(), p.opacity) // amber
                else                -> applyOpacity(0xFFEE1803.toInt(), p.opacity) // blaze
            }
        }

        private fun applyOpacity(argb: Int, opacity: Double): Int {
            val alpha = (min(1.0, max(0.0, opacity)) * 255).toInt()
            return (argb and 0x00FFFFFF) or (alpha shl 24)
        }

        // MARK: - Provider Data

        /**
         * Reads the latest widget snapshot and builds provider color weights.
         * This is lightweight — just reads the current StateFlow value.
         */
        private fun refreshProviderColors() {
            val snapshot = BurnBarWidgetSnapshotStore.snapshot.value
                ?: return

            val providers = snapshot.topProviders.take(5)
            val tokens = snapshot.topProviderTokens.take(5)
            val totalTokens = tokens.sum().coerceAtLeast(1)

            providerWeights = providers.zip(tokens).mapNotNull { pair ->
                val name = pair.first
                val tokenCount = pair.second
                val agent = AgentProvider.fromKey(name) ?: return@mapNotNull null
                ProviderColorWeight(
                    provider = agent,
                    weight = tokenCount.toDouble() / totalTokens.toDouble(),
                    argb = agent.brandColor.toInt()
                )
            }
        }

    }
}
