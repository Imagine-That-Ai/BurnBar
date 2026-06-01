@file:Suppress("MagicNumber")
// Live wallpaper canvas uses literal geometry and animation timing constants.

package com.openburnbar.wallpaper

import android.content.SharedPreferences
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.view.MotionEvent
import android.view.SurfaceHolder
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.ui.components.SwarmPace
import com.openburnbar.ui.components.SwarmSimulation
import kotlin.math.max
import kotlin.math.min

private object BurnBarWallpaperConstants {
    const val FRAME_INTERVAL_CINEMATIC_MS = 33L
    const val FRAME_INTERVAL_ENERGETIC_MS = 16L
    const val GLYPH_TEXT_SIZE_SP = 20f
    const val MIN_PARTICLE_DRAW_RADIUS = 0.5f
    const val DEFAULT_EMBER_COLOR_ARGB = 0xFFFF6B35.toInt()
    const val MAX_PROVIDER_COLOR_WEIGHTS = 5
    const val FULL_OPACITY_ALPHA = 255
    const val RGB_COLOR_MASK = 0x00FFFFFF
    const val ALPHA_CHANNEL_SHIFT_BITS = 24
}

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
    val argb: Int,
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
        private val globalPrefs by lazy {
            getSharedPreferences("global_visual_settings", android.content.Context.MODE_PRIVATE)
        }
        private val preferenceListener =
            SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                if (key == "pace" || key == "shape" || key == BurnBarWallpaperGlyphSettings.key) {
                    updateSettings()
                }
            }
        private val globalPreferenceListener =
            SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                if (key == "appThemePalette") {
                    updatePalette()
                }
            }

        // Render loop
        private val handler = Handler(Looper.getMainLooper())
        private var visible = false
        private var frameIntervalMs = BurnBarWallpaperConstants.FRAME_INTERVAL_CINEMATIC_MS
        private var lastFrameNanos = System.nanoTime()

        // Paint objects (reused per frame to avoid allocation)
        private val particlePaint =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.FILL
            }
        private val glyphPaint =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = BurnBarWallpaperConstants.GLYPH_TEXT_SIZE_SP
                typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
                style = Paint.Style.FILL
            }
        private val backgroundPaint =
            Paint().apply {
                color = BACKGROUND_COLOR
                style = Paint.Style.FILL
            }

        // Canvas background
        private val vignetteCenter = Paint(Paint.ANTI_ALIAS_FLAG)

        private val drawRunnable =
            object : Runnable {
                override fun run() {
                    drawFrame()
                    if (visible) {
                        handler.postDelayed(this, frameIntervalMs)
                    }
                }
            }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            simulation =
                SwarmSimulation(
                    particleCount = WALLPAPER_PARTICLE_COUNT,
                    pace = SwarmPace.CINEMATIC, // Default, updated via settings
                    context = applicationContext,
                )
            wallpaperPrefs.registerOnSharedPreferenceChangeListener(preferenceListener)
            globalPrefs.registerOnSharedPreferenceChangeListener(globalPreferenceListener)
            // Bind snapshot store so the StateFlow hydrates from disk.
            BurnBarWidgetSnapshotStore.bind(applicationContext)
            updateSettings()
            updatePalette()
            refreshProviderColors()
            // Enable touch events for tap-to-cycle
            setTouchEventsEnabled(true)
        }

        private fun updateSettings() {
            val pacePref = wallpaperPrefs.getString("pace", "cinematic") ?: "cinematic"
            val shapePref = wallpaperPrefs.getString("shape", "all") ?: "all"
            val providerGlyphs = BurnBarWallpaperGlyphSettings.read(wallpaperPrefs)

            simulation.setPace(if (pacePref == "energetic") SwarmPace.ENERGETIC else SwarmPace.CINEMATIC)
            simulation.setEnabledProviderGlyphs(providerGlyphs)

            // Adjust framerate based on pace to save battery if cinematic
            frameIntervalMs =
                if (pacePref == "energetic") {
                    BurnBarWallpaperConstants.FRAME_INTERVAL_ENERGETIC_MS
                } else {
                    BurnBarWallpaperConstants.FRAME_INTERVAL_CINEMATIC_MS
                }

            simulation.setShapeMode(shapePref)
        }

        private fun updatePalette() {
            val paletteName = globalPrefs.getString("appThemePalette", "System") ?: "System"
            simulation.paletteName = paletteName
        }

        override fun onVisibilityChanged(visible: Boolean) {
            this.visible = visible
            if (visible) {
                updateSettings()
                updatePalette()
                refreshProviderColors()
                handler.removeCallbacks(drawRunnable)
                handler.post(drawRunnable)
            } else {
                handler.removeCallbacks(drawRunnable)
            }
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
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
            globalPrefs.unregisterOnSharedPreferenceChangeListener(globalPreferenceListener)
            super.onDestroy()
        }

        override fun onTouchEvent(event: MotionEvent?) {
            super.onTouchEvent(event)
            if (event?.action == MotionEvent.ACTION_DOWN) {
                simulation.forceCycleShape()
            }
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
                    0f,
                    0f,
                    canvas.width.toFloat(),
                    canvas.height.toFloat(),
                    backgroundPaint,
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
                        canvas.drawCircle(
                            p.x.toFloat(),
                            p.y.toFloat(),
                            max(BurnBarWallpaperConstants.MIN_PARTICLE_DRAW_RADIUS, p.size.toFloat()),
                            particlePaint,
                        )
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
                return simulation.colorFor(p, Color(BurnBarWallpaperConstants.DEFAULT_EMBER_COLOR_ARGB), isDark = true).toArgb()
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

            // Fallback: use simulation's colorFor which correctly respects the selected palette!
            return simulation.colorFor(p, Color(BurnBarWallpaperConstants.DEFAULT_EMBER_COLOR_ARGB), isDark = true).toArgb()
        }

        private fun applyOpacity(argb: Int, opacity: Double): Int {
            val alpha = (min(1.0, max(0.0, opacity)) * BurnBarWallpaperConstants.FULL_OPACITY_ALPHA).toInt()
            return argb and BurnBarWallpaperConstants.RGB_COLOR_MASK or
                (alpha shl BurnBarWallpaperConstants.ALPHA_CHANNEL_SHIFT_BITS)
        }

        // MARK: - Provider Data

        /**
         * Reads the latest widget snapshot and builds provider color weights.
         * This is lightweight — just reads the current StateFlow value.
         */
        private fun refreshProviderColors() {
            val snapshot =
                BurnBarWidgetSnapshotStore.snapshot.value
                    ?: return

            val providers = snapshot.topProviders.take(BurnBarWallpaperConstants.MAX_PROVIDER_COLOR_WEIGHTS)
            val tokens = snapshot.topProviderTokens.take(BurnBarWallpaperConstants.MAX_PROVIDER_COLOR_WEIGHTS)
            val totalTokens = tokens.sum().coerceAtLeast(1)

            providerWeights =
                providers.zip(tokens).mapNotNull { pair ->
                    val name = pair.first
                    val tokenCount = pair.second
                    val agent = AgentProvider.fromKey(name) ?: return@mapNotNull null
                    ProviderColorWeight(
                        provider = agent,
                        weight = tokenCount.toDouble() / totalTokens.toDouble(),
                        argb = agent.brandColor.toInt(),
                    )
                }
        }
    }
}
