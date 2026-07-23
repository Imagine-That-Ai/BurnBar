package com.openburnbar.wallpaper.livingthemes

import android.content.Context
import android.graphics.Outline
import android.graphics.SurfaceTexture
import android.util.AttributeSet
import android.view.TextureView
import android.view.View
import android.view.ViewOutlineProvider

/**
 * Exact in-app preview for the system wallpaper renderer.
 *
 * The picker owns only one animated preview. Catalog tiles remain static, while
 * this surface runs the same GLES program, uniforms, frame cap, and lifecycle
 * behavior as [LivingThemeWallpaperService].
 */
class LivingThemePreviewView
@JvmOverloads
constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : TextureView(context, attrs),
    TextureView.SurfaceTextureListener {
    private var renderer: ShaderKernelRenderer? = null
    private var theme = LiveTheme.CONSTELLATION
    private var maxFps = LivingThemePrefs.DEFAULT_FPS
    private var surfaceReady = false

    init {
        surfaceTextureListener = this
        isOpaque = true
        outlineProvider =
            object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    val radius = 24f * resources.displayMetrics.density
                    outline.setRoundRect(0, 0, view.width, view.height, radius)
                }
            }
        clipToOutline = true
    }

    fun update(theme: LiveTheme, maxFps: Int) {
        val resolvedFps = maxFps.coerceIn(5, 60)
        if (this.theme != theme) {
            this.theme = theme
            renderer?.setTheme(theme)
        }
        if (this.maxFps != resolvedFps) {
            this.maxFps = resolvedFps
            renderer?.setMaxFps(resolvedFps)
        }
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        surfaceReady = true
        renderer =
            ShaderKernelRenderer(
                context = context.applicationContext,
                nativeWindow = surface,
                theme = theme,
                maxFps = maxFps,
            ).also {
                it.resize(width.coerceAtLeast(1), height.coerceAtLeast(1))
                if (isShown) it.start()
            }
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        renderer?.resize(width, height)
        if (isShown) renderer?.start()
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        surfaceReady = false
        renderer?.release { surface.release() }
        renderer = null
        return false
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    override fun onVisibilityChanged(changedView: android.view.View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility)
        if (!surfaceReady) return
        if (visibility == VISIBLE) renderer?.start() else renderer?.stop()
    }
}
