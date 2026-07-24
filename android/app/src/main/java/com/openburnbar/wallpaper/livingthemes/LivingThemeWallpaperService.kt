package com.openburnbar.wallpaper.livingthemes

import android.content.Context
import android.content.SharedPreferences
import android.service.wallpaper.WallpaperService
import android.view.SurfaceHolder

class LivingThemeWallpaperService : WallpaperService() {
    override fun onCreateEngine(): Engine = KernelEngine(applicationContext)

    inner class KernelEngine(
        private val appContext: Context,
    ) : Engine(),
        SharedPreferences.OnSharedPreferenceChangeListener {
        private val prefs = appContext.getSharedPreferences(LivingThemePrefs.NAME, Context.MODE_PRIVATE)
        private var renderer: ShaderKernelRenderer? = null
        private var visible = false

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            prefs.registerOnSharedPreferenceChangeListener(this)
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            createRenderer(holder)
            if (visible) renderer?.start()
        }

        private fun createRenderer(holder: SurfaceHolder) {
            renderer?.release()
            renderer =
                ShaderKernelRenderer(
                    context = appContext,
                    holder = holder,
                    theme = LiveTheme.fromID(prefs.getString(LivingThemePrefs.KEY_THEME, null)),
                    maxFps = prefs.getInt(LivingThemePrefs.KEY_FPS, LivingThemePrefs.DEFAULT_FPS),
                )
        }

        override fun onVisibilityChanged(visible: Boolean) {
            this.visible = visible
            if (visible) renderer?.start() else renderer?.stop()
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            super.onSurfaceChanged(holder, format, width, height)
            if (renderer == null) createRenderer(holder)
            renderer?.resize(width, height)
            if (visible) renderer?.start()
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            renderer?.stop()
            renderer?.release()
            renderer = null
            super.onSurfaceDestroyed(holder)
        }

        override fun onSharedPreferenceChanged(sharedPreferences: SharedPreferences, key: String?) {
            when (key) {
                LivingThemePrefs.KEY_THEME ->
                    renderer?.setTheme(
                        LiveTheme.fromID(sharedPreferences.getString(LivingThemePrefs.KEY_THEME, null)),
                    )
                LivingThemePrefs.KEY_FPS ->
                    renderer?.setMaxFps(
                        sharedPreferences.getInt(LivingThemePrefs.KEY_FPS, LivingThemePrefs.DEFAULT_FPS),
                    )
            }
        }

        override fun onDestroy() {
            prefs.unregisterOnSharedPreferenceChangeListener(this)
            renderer?.release()
            renderer = null
            super.onDestroy()
        }
    }
}
