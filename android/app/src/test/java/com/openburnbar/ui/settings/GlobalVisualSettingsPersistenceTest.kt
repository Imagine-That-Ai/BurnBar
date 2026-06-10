@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.settings

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.openburnbar.BurnBarApplication
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Funnel tests for [GlobalVisualSettingsPersistence]: every write goes through
 * one guarded path that (1) drops-and-warns before the app context exists,
 * (2) routes each typed helper to the right editor call, and (3) survives a
 * real write failure by logging instead of crashing the caller.
 */
class GlobalVisualSettingsPersistenceTest {
    private lateinit var editor: SharedPreferences.Editor
    private lateinit var prefs: SharedPreferences
    private lateinit var context: Context

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0

        editor = mockk(relaxed = true)
        prefs = mockk()
        every { prefs.edit() } returns editor
        context = mockk()
        every { context.getSharedPreferences("global_visual_settings", Context.MODE_PRIVATE) } returns prefs
        installAppContext(null)
    }

    @After
    fun tearDown() {
        installAppContext(null)
        unmockkStatic(Log::class)
    }

    @Test
    fun `not ready before the app context is installed`() {
        assertFalse(GlobalVisualSettingsPersistence.isReady)
        installAppContext(context)
        assertTrue(GlobalVisualSettingsPersistence.isReady)
    }

    @Test
    fun `writes before the app context are dropped with a warning not a crash`() {
        GlobalVisualSettingsPersistence.persistBoolean("enableSwarmSparkles", true)

        verify(exactly = 1) { Log.w(any(), match<String> { it.contains("dropped persist") && it.contains("enableSwarmSparkles") }) }
        verify(exactly = 0) { editor.putBoolean(any(), any()) }
    }

    @Test
    fun `typed helpers route to the matching editor write and apply`() {
        installAppContext(context)

        GlobalVisualSettingsPersistence.persistString("primaryTabs", "pulse,burn")
        GlobalVisualSettingsPersistence.persistBoolean("usePremiumSOTAUX", true)
        GlobalVisualSettingsPersistence.persistThemePalette("Crimson")

        verify(exactly = 1) { editor.putString("primaryTabs", "pulse,burn") }
        verify(exactly = 1) { editor.putBoolean("usePremiumSOTAUX", true) }
        verify(exactly = 1) { editor.putString("appThemePalette", "Crimson") }
        verify(exactly = 3) { editor.apply() }
        verify(exactly = 0) { Log.w(any(), any<String>()) }
    }

    @Test
    fun `a real write failure logs the key instead of throwing`() {
        installAppContext(context)
        every { prefs.edit() } throws IllegalStateException("disk full")

        // Must not propagate — the in-memory Compose state already updated.
        GlobalVisualSettingsPersistence.persistString("backgroundStyle", "swarm")

        verify(exactly = 1) { Log.w(any(), match<String> { it.contains("persist of backgroundStyle failed") }, any()) }
    }

    private fun installAppContext(value: Context?) {
        val field = BurnBarApplication::class.java.getDeclaredField("appContext")
        field.isAccessible = true
        field.set(null, value)
    }
}
