
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
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * Tab-order persistence tests for [GlobalVisualSettingsTabs]: the default
 * five-primary/four-secondary layout, prefs hydration (including null reads
 * falling back to the defaults), and setters writing through the shared
 * visual-settings funnel under the right keys.
 */
class GlobalVisualSettingsTabsTest {
    private val defaultPrimary = "pulse,burn,insights,streams,agents"
    private val defaultSecondary = "you,providers,devices,settings"

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0
        installAppContext(null)
        // The tabs object is a JVM-wide singleton: rehydrate the defaults so
        // earlier suites (or test ordering) can never leak a custom order in.
        val defaults = mockk<SharedPreferences>()
        every { defaults.getString(any(), any()) } answers { secondArg() }
        GlobalVisualSettingsTabs.loadFromPrefs(defaults)
    }

    @After
    fun tearDown() {
        // Restore the defaults so the singleton never leaks tab state across tests.
        val defaults = mockk<SharedPreferences>()
        every { defaults.getString(any(), any()) } answers { secondArg() }
        GlobalVisualSettingsTabs.loadFromPrefs(defaults)
        installAppContext(null)
        unmockkStatic(Log::class)
    }

    @Test
    fun `defaults describe the five primary and four secondary tabs`() {
        assertEquals(defaultPrimary, GlobalVisualSettingsTabs.primaryTabs.value)
        assertEquals(defaultSecondary, GlobalVisualSettingsTabs.secondaryTabs.value)
    }

    @Test
    fun `loadFromPrefs hydrates stored orders and null reads keep defaults`() {
        val prefs = mockk<SharedPreferences>()
        every { prefs.getString("primaryTabs", any()) } returns "agents,pulse,burn"
        every { prefs.getString("secondaryTabs", any()) } returns null

        GlobalVisualSettingsTabs.loadFromPrefs(prefs)

        assertEquals("agents,pulse,burn", GlobalVisualSettingsTabs.primaryTabs.value)
        // A null read (pref written as null) must fall back to the default order.
        assertEquals(defaultSecondary, GlobalVisualSettingsTabs.secondaryTabs.value)
    }

    @Test
    fun `setters update state and persist under their prefs keys`() {
        val editor = mockk<SharedPreferences.Editor>(relaxed = true)
        val prefs = mockk<SharedPreferences>()
        every { prefs.edit() } returns editor
        val context = mockk<Context>()
        every { context.getSharedPreferences("global_visual_settings", Context.MODE_PRIVATE) } returns prefs
        installAppContext(context)

        GlobalVisualSettingsTabs.setPrimaryTabs("burn,pulse")
        GlobalVisualSettingsTabs.setSecondaryTabs("settings,you")

        assertEquals("burn,pulse", GlobalVisualSettingsTabs.primaryTabs.value)
        assertEquals("settings,you", GlobalVisualSettingsTabs.secondaryTabs.value)
        verify(exactly = 1) { editor.putString("primaryTabs", "burn,pulse") }
        verify(exactly = 1) { editor.putString("secondaryTabs", "settings,you") }
    }

    private fun installAppContext(value: Context?) {
        val field = BurnBarApplication::class.java.getDeclaredField("appContext")
        field.isAccessible = true
        field.set(null, value)
    }
}
