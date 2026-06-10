@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.settings

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.compose.runtime.MutableState
import com.openburnbar.BurnBarApplication
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pure-JVM coverage for [GlobalVisualSettings] load/persist hygiene: a single
 * race-free first load, the narrowed appContext-not-ready retry, and logged
 * (instead of silently swallowed) read/write failures. `SharedPreferences` is
 * stubbed with an in-memory map; a wrong-typed value naturally throws the same
 * `ClassCastException` the real prefs implementation does.
 */
class GlobalVisualSettingsLoadTest {
    private val backing = ConcurrentHashMap<String, Any>()
    private val styleReads = AtomicInteger(0)
    private lateinit var prefs: SharedPreferences
    private lateinit var context: Context

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0

        backing.clear()
        styleReads.set(0)
        prefs = mockk()
        every { prefs.getBoolean(any(), any()) } answers {
            (backing[firstArg<String>()] ?: secondArg<Boolean>()) as Boolean
        }
        every { prefs.getString(any(), any()) } answers {
            val key = firstArg<String>()
            if (key == "backgroundStyle") styleReads.incrementAndGet()
            (backing[key] ?: secondArg<String?>()) as String?
        }
        every { prefs.edit() } returns mockk(relaxed = true)

        context = mockk(relaxed = true)
        every { context.getSharedPreferences(any(), any()) } returns prefs

        installAppContext(null)
        setLoaded(false)
        resetState("_usePremiumSOTAUX", false)
    }

    @After
    fun tearDown() {
        installAppContext(null)
        setLoaded(false)
        unmockkStatic(Log::class)
    }

    @Test
    fun `getter before appContext install keeps defaults and loads after install`() {
        backing["usePremiumSOTAUX"] = true

        // Context not ready: defaults stay, the one-shot flag is NOT burned.
        assertFalse(GlobalVisualSettings.usePremiumSOTAUX.value)
        assertFalse(isLoaded())
        assertEquals(0, styleReads.get())

        installAppContext(context)
        assertTrue(GlobalVisualSettings.usePremiumSOTAUX.value)
        assertTrue(isLoaded())
    }

    @Test
    fun `concurrent first reads load prefs exactly once`() {
        installAppContext(context)

        val threads = 8
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        repeat(threads) {
            Thread {
                start.await()
                repeat(50) {
                    GlobalVisualSettings.backgroundStyle.value
                    GlobalVisualSettings.enableSwarmSparkles.value
                    GlobalVisualSettings.providerGlyphs.value
                }
                done.countDown()
            }.start()
        }
        start.countDown()
        assertTrue(done.await(10, TimeUnit.SECONDS))
        assertEquals(1, styleReads.get())
    }

    @Test
    fun `corrupted pref logs once and stops re-reading on every access`() {
        backing["enableSwarmSparkles"] = "not-a-boolean"
        installAppContext(context)

        GlobalVisualSettings.enableSwarmSparkles.value
        assertTrue(isLoaded())
        verify(exactly = 1) { Log.w(any(), match<String> { it.contains("load failed") }, any()) }

        // The failure is terminal for this process: no full prefs re-read per getter.
        GlobalVisualSettings.backgroundStyle.value
        assertEquals(1, styleReads.get())
    }

    @Test
    fun `persist before appContext install warns instead of silently dropping`() {
        GlobalVisualSettingsTabs.setPrimaryTabs("pulse,burn")

        verify(exactly = 1) { Log.w(any(), match<String> { it.contains("dropped persist") }) }
        // In-memory state still updates so the UI stays coherent.
        assertEquals("pulse,burn", GlobalVisualSettingsTabs.primaryTabs.value)
    }

    @Test
    fun `persist after appContext install writes through the shared editor`() {
        installAppContext(context)
        val editor = mockk<SharedPreferences.Editor>(relaxed = true)
        every { prefs.edit() } returns editor

        GlobalVisualSettings.setSwarmSparkles(false)

        verify(exactly = 1) { editor.putBoolean("enableSwarmSparkles", false) }
        verify(exactly = 1) { editor.apply() }
        verify(exactly = 0) { Log.w(any(), any<String>()) }
    }

    private fun installAppContext(value: Context?) {
        val field = BurnBarApplication::class.java.getDeclaredField("appContext")
        field.isAccessible = true
        field.set(null, value)
    }

    private fun setLoaded(value: Boolean) {
        val field = GlobalVisualSettings::class.java.getDeclaredField("loaded")
        field.isAccessible = true
        field.setBoolean(GlobalVisualSettings, value)
    }

    private fun isLoaded(): Boolean {
        val field = GlobalVisualSettings::class.java.getDeclaredField("loaded")
        field.isAccessible = true
        return field.getBoolean(GlobalVisualSettings)
    }

    @Suppress("UNCHECKED_CAST")
    private fun resetState(fieldName: String, value: Any?) {
        val field = GlobalVisualSettings::class.java.getDeclaredField(fieldName)
        field.isAccessible = true
        (field.get(GlobalVisualSettings) as MutableState<Any?>).value = value
    }
}
