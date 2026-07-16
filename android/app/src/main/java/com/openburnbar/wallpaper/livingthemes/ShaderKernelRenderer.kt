package com.openburnbar.wallpaper.livingthemes

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.FileNotFoundException
import kotlin.math.max
import org.json.JSONArray
import org.json.JSONObject

/**
 * GLES3 wallpaper renderer with one GL thread/context per surface lifetime.
 *
 * Visibility pauses frame callbacks without destroying GL. Surface teardown
 * owns final EGL cleanup; preference changes rebuild only the shader program.
 */
class ShaderKernelRenderer(
    private val context: Context,
    private val nativeWindow: Any,
    theme: LiveTheme,
    maxFps: Int,
) {
    @Volatile
    private var running = false

    @Volatile
    private var released = false

    @Volatile
    private var requestedTheme = theme

    @Volatile
    private var requestedMaxFps = maxFps.coerceIn(5, 60)

    @Volatile
    private var width = 1

    @Volatile
    private var height = 1

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var initialized = false
    private var frameScheduled = false

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var uniforms = UniformLocations()
    private var parameterDefaults: List<UniformDefault> = emptyList()
    private var activeTimeSec = 0f
    private var lastFrameNs = 0L

    private data class UniformDefault(val location: Int, val values: FloatArray)

    private data class UniformLocations(
        val resolution: Int = -1,
        val time: Int = -1,
        val pointer: Int = -1,
        val pointerActive: Int = -1,
        val background: Int = -1,
        val accent0: Int = -1,
        val accent1: Int = -1,
        val accent2: Int = -1,
        val accent3: Int = -1,
        val ink: Int = -1,
        val intensity: Int = -1,
        val theme: Int = -1,
        val hasSimulation: Int = -1,
        val scroll: Int = -1,
        val scrollVelocity: Int = -1,
        val glyphActive: Int = -1,
        val glyphPhase: Int = -1,
        val glyphRect: Int = -1,
        val impulseCount: Int = -1,
    )

    private val frameRunnable =
        object : Runnable {
            override fun run() {
                frameScheduled = false
                if (!running || released || !initialized) return
                drawFrame()
                scheduleFrame()
            }
        }

    @Synchronized
    fun start() {
        if (released || running) return
        running = true
        ensureThread()
        handler?.post {
            if (!initialized) initialized = initGl()
            if (!initialized || !running || released) return@post
            lastFrameNs = System.nanoTime()
            drawFrame()
            scheduleFrame()
        }
    }

    fun stop() {
        running = false
        handler?.removeCallbacks(frameRunnable)
        frameScheduled = false
    }

    fun resize(w: Int, h: Int) {
        width = max(1, w)
        height = max(1, h)
        handler?.post {
            if (initialized) {
                GLES30.glViewport(0, 0, width, height)
                if (running) drawFrame()
            }
        }
    }

    fun setTheme(theme: LiveTheme) {
        requestedTheme = theme
        handler?.post {
            if (!initialized || released) return@post
            val nextProgram = buildProgramOrFallback(loadFragSource(theme), theme.id)
            if (nextProgram == 0) return@post
            if (program != 0) GLES30.glDeleteProgram(program)
            program = nextProgram
            uniforms = loadUniformLocations()
            parameterDefaults = loadParameterDefaults(theme)
            activeTimeSec = 0f
            lastFrameNs = System.nanoTime()
            if (running) drawFrame()
        }
    }

    fun setMaxFps(fps: Int) {
        requestedMaxFps = fps.coerceIn(5, 60)
        if (running) {
            handler?.removeCallbacks(frameRunnable)
            frameScheduled = false
            handler?.post { scheduleFrame() }
        }
    }

    @Synchronized
    fun release(onReleased: (() -> Unit)? = null) {
        if (released) return
        released = true
        running = false
        val localHandler = handler
        val localThread = thread
        localHandler?.removeCallbacksAndMessages(null)
        if (localHandler == null) {
            onReleased?.invoke()
            localThread?.quitSafely()
        } else {
            localHandler.post {
                destroyGl()
                onReleased?.invoke()
                localThread?.quitSafely()
            }
        }
        handler = null
        thread = null
    }

    private fun ensureThread() {
        if (thread != null) return
        val nextThread = HandlerThread("it-wallpaper-gl").also { it.start() }
        thread = nextThread
        handler = Handler(nextThread.looper)
    }

    private fun scheduleFrame() {
        if (!running || released || !initialized || frameScheduled) return
        frameScheduled = true
        val intervalMs = (1000L / requestedMaxFps).coerceAtLeast(16L)
        handler?.postDelayed(frameRunnable, intervalMs)
    }

    private fun initGl(): Boolean {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return failEgl("eglGetDisplay")

        val versions = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, versions, 0, versions, 1)) {
            return failEgl("eglInitialize")
        }

        val attribList =
            intArrayOf(
                EGL14.EGL_SURFACE_TYPE,
                EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE,
                8,
                EGL14.EGL_GREEN_SIZE,
                8,
                EGL14.EGL_BLUE_SIZE,
                8,
                EGL14.EGL_ALPHA_SIZE,
                8,
                EGL14.EGL_RENDERABLE_TYPE,
                EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_NONE,
            )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        if (!EGL14.eglChooseConfig(
                eglDisplay,
                attribList,
                0,
                configs,
                0,
                configs.size,
                count,
                0,
            ) ||
            count[0] == 0
        ) {
            return failEgl("eglChooseConfig")
        }
        val config = configs[0] ?: return failEgl("eglChooseConfig(null)")

        eglContext =
            EGL14.eglCreateContext(
                eglDisplay,
                config,
                EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE),
                0,
            )
        if (eglContext == EGL14.EGL_NO_CONTEXT) return failEgl("eglCreateContext")

        eglSurface =
            EGL14.eglCreateWindowSurface(
                eglDisplay,
                config,
                nativeWindow,
                intArrayOf(EGL14.EGL_NONE),
                0,
            )
        if (eglSurface == EGL14.EGL_NO_SURFACE) return failEgl("eglCreateWindowSurface")
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            return failEgl("eglMakeCurrent")
        }

        program = buildProgramOrFallback(loadFragSource(requestedTheme), requestedTheme.id)
        if (program == 0) {
            destroyGl()
            return false
        }
        uniforms = loadUniformLocations()
        parameterDefaults = loadParameterDefaults(requestedTheme)
        GLES30.glViewport(0, 0, width, height)
        return true
    }

    private fun failEgl(operation: String): Boolean {
        Log.e(TAG, "$operation failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        destroyGl()
        return false
    }

    private fun destroyGl() {
        if (program != 0) {
            GLES30.glDeleteProgram(program)
            program = 0
        }
        uniforms = UniformLocations()
        parameterDefaults = emptyList()
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(
                eglDisplay,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT,
            )
            if (eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, eglSurface)
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(eglDisplay, eglContext)
            }
            EGL14.eglTerminate(eglDisplay)
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        initialized = false
    }

    private fun drawFrame() {
        if (!running || program == 0 || eglDisplay == EGL14.EGL_NO_DISPLAY) return
        val now = System.nanoTime()
        if (lastFrameNs != 0L) {
            val deltaSec = ((now - lastFrameNs) / 1_000_000_000.0).toFloat()
            activeTimeSec += deltaSec.coerceIn(0f, 0.1f)
        }
        lastFrameNs = now

        GLES30.glClearColor(0.02f, 0.02f, 0.05f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        GLES30.glUseProgram(program)

        set2f(uniforms.resolution, width.toFloat(), height.toFloat())
        set1f(uniforms.time, activeTimeSec)
        set2f(uniforms.pointer, 0.5f, 0.5f)
        set1f(uniforms.pointerActive, 0f)
        set3f(uniforms.background, 0.02f, 0.03f, 0.08f)
        set3f(uniforms.accent0, 0.51f, 0.56f, 1f)
        set3f(uniforms.accent1, 0.47f, 0.86f, 0.91f)
        set3f(uniforms.accent2, 0.7f, 0.45f, 0.95f)
        set3f(uniforms.accent3, 0.95f, 0.45f, 0.65f)
        set3f(uniforms.ink, 0.9f, 0.92f, 0.98f)
        set1f(uniforms.intensity, 1f)
        set1f(uniforms.theme, 0f)
        set1f(uniforms.hasSimulation, 0f)
        set2f(uniforms.scroll, 0f, 0f)
        set1f(uniforms.scrollVelocity, 0f)
        set1f(uniforms.glyphActive, 0f)
        set1f(uniforms.glyphPhase, 0f)
        set4f(uniforms.glyphRect, 0f, 0f, 0f, 0f)
        set1i(uniforms.impulseCount, 0)
        applyParameterDefaults()

        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
        if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
            Log.e(TAG, "eglSwapBuffers failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
    }

    private fun set1f(location: Int, value: Float) {
        if (location >= 0) GLES30.glUniform1f(location, value)
    }

    private fun set1i(location: Int, value: Int) {
        if (location >= 0) GLES30.glUniform1i(location, value)
    }

    private fun set2f(location: Int, x: Float, y: Float) {
        if (location >= 0) GLES30.glUniform2f(location, x, y)
    }

    private fun set3f(location: Int, x: Float, y: Float, z: Float) {
        if (location >= 0) GLES30.glUniform3f(location, x, y, z)
    }

    private fun set4f(location: Int, x: Float, y: Float, z: Float, w: Float) {
        if (location >= 0) GLES30.glUniform4f(location, x, y, z, w)
    }

    private fun loadUniformLocations(): UniformLocations = UniformLocations(
        resolution = GLES30.glGetUniformLocation(program, "uResolution"),
        time = GLES30.glGetUniformLocation(program, "uTime"),
        pointer = GLES30.glGetUniformLocation(program, "uPointer"),
        pointerActive = GLES30.glGetUniformLocation(program, "uPointerActive"),
        background = GLES30.glGetUniformLocation(program, "uBg"),
        accent0 = GLES30.glGetUniformLocation(program, "uAccent0"),
        accent1 = GLES30.glGetUniformLocation(program, "uAccent1"),
        accent2 = GLES30.glGetUniformLocation(program, "uAccent2"),
        accent3 = GLES30.glGetUniformLocation(program, "uAccent3"),
        ink = GLES30.glGetUniformLocation(program, "uInk"),
        intensity = GLES30.glGetUniformLocation(program, "uIntensity"),
        theme = GLES30.glGetUniformLocation(program, "uTheme"),
        hasSimulation = GLES30.glGetUniformLocation(program, "uHasSim"),
        scroll = GLES30.glGetUniformLocation(program, "uScroll"),
        scrollVelocity = GLES30.glGetUniformLocation(program, "uScrollVel"),
        glyphActive = GLES30.glGetUniformLocation(program, "uGlyphActive"),
        glyphPhase = GLES30.glGetUniformLocation(program, "uGlyphPhase"),
        glyphRect = GLES30.glGetUniformLocation(program, "uGlyphRect"),
        impulseCount = GLES30.glGetUniformLocation(program, "uImpulseCount"),
    )

    private fun applyParameterDefaults() {
        for (parameter in parameterDefaults) {
            val values = parameter.values
            if (parameter.location < 0) continue
            when {
                values.size == 1 -> GLES30.glUniform1f(parameter.location, values[0])
                values.size == 2 -> GLES30.glUniform2f(parameter.location, values[0], values[1])
                values.size == 3 -> GLES30.glUniform3f(parameter.location, values[0], values[1], values[2])
                values.size % 3 == 0 -> GLES30.glUniform3fv(
                    parameter.location,
                    values.size / 3,
                    values,
                    0,
                )
            }
        }
    }

    /** Read the extracted createShaderKernel defaults for native GLES. */
    private fun loadParameterDefaults(theme: LiveTheme): List<UniformDefault> {
        val path = "living-themes/kernels/${theme.assetID}.manifest.json"
        return try {
            val root = context.assets.open(path).bufferedReader().use { JSONObject(it.readText()) }
            val params = root.optJSONArray("params") ?: return emptyList()
            buildList {
                for (index in 0 until params.length()) {
                    val param = params.optJSONObject(index) ?: continue
                    val name = param.optString("name")
                    if (name.isBlank()) continue
                    val values = param.optJSONArray("default")?.toFloatList()
                        ?: listOf(param.optDouble("default", 0.0).toFloat())
                    val location = GLES30.glGetUniformLocation(program, name)
                    add(UniformDefault(location, values.toFloatArray()))
                }
            }
        } catch (_: FileNotFoundException) {
            emptyList()
        } catch (error: Exception) {
            Log.w(TAG, "No parameter manifest for ${theme.id}", error)
            emptyList()
        }
    }

    private fun loadFragSource(theme: LiveTheme): String {
        val candidates =
            listOf(
                "living-themes/kernels/${theme.assetID}.frag",
                "living-themes/kernels/${theme.assetID.replace('-', '_')}.frag",
            )
        for (path in candidates) {
            try {
                val source = context.assets.open(path).bufferedReader().use { it.readText() }
                if (source.isNotBlank()) return source
            } catch (_: Exception) {
                // Try the next generated filename before falling back.
            }
        }
        Log.e(TAG, "Shader asset missing for ${theme.id}; using fallback")
        return FALLBACK_DISPLAY
    }

    private fun buildProgramOrFallback(fragmentSource: String, label: String): Int {
        val requested = buildProgram(fragmentSource, label)
        if (requested != 0) return requested
        Log.e(TAG, "Falling back after shader failure: $label")
        return buildProgram(FALLBACK_DISPLAY, "fallback")
    }

    private fun buildProgram(fragmentSource: String, label: String): Int {
        val vertexShader = compile(GLES30.GL_VERTEX_SHADER, VERTEX_SHADER, "$label:vertex")
        if (vertexShader == 0) return 0
        val fragmentShader =
            compile(GLES30.GL_FRAGMENT_SHADER, fragmentSource, "$label:fragment")
        if (fragmentShader == 0) {
            GLES30.glDeleteShader(vertexShader)
            return 0
        }

        val linkedProgram = GLES30.glCreateProgram()
        GLES30.glAttachShader(linkedProgram, vertexShader)
        GLES30.glAttachShader(linkedProgram, fragmentShader)
        GLES30.glLinkProgram(linkedProgram)
        GLES30.glDeleteShader(vertexShader)
        GLES30.glDeleteShader(fragmentShader)

        val status = IntArray(1)
        GLES30.glGetProgramiv(linkedProgram, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == GLES30.GL_TRUE) {
            Log.i(TAG, "Shader program ready: $label")
            return linkedProgram
        }

        Log.e(TAG, "Program link failed ($label): ${GLES30.glGetProgramInfoLog(linkedProgram)}")
        GLES30.glDeleteProgram(linkedProgram)
        return 0
    }

    private fun compile(type: Int, source: String, label: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == GLES30.GL_TRUE) return shader

        Log.e(TAG, "Shader compile failed ($label): ${GLES30.glGetShaderInfoLog(shader)}")
        GLES30.glDeleteShader(shader)
        return 0
    }

    companion object {
        private const val TAG = "BurnBarLivingThemes"
        private const val EGL_OPENGL_ES3_BIT_KHR = 0x0040

        private val VERTEX_SHADER =
            """
            #version 300 es
            void main() {
              vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
              gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
            }
            """.trimIndent()

        private val FALLBACK_DISPLAY =
            """
            #version 300 es
            precision highp float;
            out vec4 fragColor;
            uniform vec2 uResolution;
            uniform float uTime;
            void main() {
              vec2 uv = gl_FragCoord.xy / max(uResolution, vec2(1.0));
              vec2 p = uv * 2.0 - 1.0;
              float n = sin(p.x * 3.0 + uTime * 0.15) * cos(p.y * 2.5 - uTime * 0.1);
              vec3 c = mix(vec3(0.05, 0.06, 0.12), vec3(0.35, 0.55, 1.0), 0.5 + 0.5 * n);
              fragColor = vec4(c, 1.0);
            }
            """.trimIndent()
    }
}

private fun JSONArray.toFloatList(): List<Float> = buildList {
    for (index in 0 until length()) add(optDouble(index, 0.0).toFloat())
}
