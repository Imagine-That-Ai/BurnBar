
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
 * layout (now spoken in `BurnBarTab.route` vocabulary — the legacy `agents`
 * token maps forward to `hermes` on every read), prefs hydration, the
 * `removedTabs` pref that makes removal a real state, and setters writing
 * through the shared visual-settings funnel under the right keys.
 */
class GlobalVisualSettingsTabsTest {
    private val defaultPrimary = "pulse,burn,inbox,insights,streams,hermes"
    private val defaultSecondary = "you,providers,devices,settings"

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0
        installAppContext(null)
        // The tabs object is a JVM-wide singleton: rehydrate the defaults so
        // earlier suites (or test ordering) can never leak a custom order in.
        GlobalVisualSettingsTabs.loadFromPrefs(defaultsPrefs())
    }

    @After
    fun tearDown() {
        // Restore the defaults so the singleton never leaks tab state across tests.
        GlobalVisualSettingsTabs.loadFromPrefs(defaultsPrefs())
        installAppContext(null)
        unmockkStatic(Log::class)
    }

    @Test
    fun `defaults use route vocabulary with no removals`() {
        assertEquals(defaultPrimary, GlobalVisualSettingsTabs.primaryTabs.value)
        assertEquals(defaultSecondary, GlobalVisualSettingsTabs.secondaryTabs.value)
        assertEquals("", GlobalVisualSettingsTabs.removedTabs.value)
    }

    @Test
    fun `loadFromPrefs hydrates stored orders and null reads keep defaults`() {
        val prefs = mockk<SharedPreferences>()
        every { prefs.getString("primaryTabs", any()) } returns "hermes,pulse,burn"
        every { prefs.getString("secondaryTabs", any()) } returns null
        every { prefs.getString("removedTabs", any()) } returns "inbox"

        GlobalVisualSettingsTabs.loadFromPrefs(prefs)

        assertEquals("hermes,pulse,burn", GlobalVisualSettingsTabs.primaryTabs.value)
        // A null read (pref written as null) must fall back to the default order.
        assertEquals(defaultSecondary, GlobalVisualSettingsTabs.secondaryTabs.value)
        assertEquals("inbox", GlobalVisualSettingsTabs.removedTabs.value)
    }

    @Test
    fun `the legacy agents token maps forward to hermes on load`() {
        // Installs that stored the pre-rename default (`...streams,agents`)
        // silently pushed the Assistants tab to the end of the tray, because
        // no tab has ever had the route `agents`. Reads repair the vocabulary.
        val prefs = mockk<SharedPreferences>()
        every { prefs.getString("primaryTabs", any()) } returns "pulse,burn,inbox,insights,streams,agents"
        every { prefs.getString("secondaryTabs", any()) } returns "you, agents ,settings"
        every { prefs.getString("removedTabs", any()) } returns null

        GlobalVisualSettingsTabs.loadFromPrefs(prefs)

        assertEquals("pulse,burn,inbox,insights,streams,hermes", GlobalVisualSettingsTabs.primaryTabs.value)
        assertEquals("you,hermes,settings", GlobalVisualSettingsTabs.secondaryTabs.value)
    }

    @Test
    fun `setters update state and persist under their prefs keys`() {
        val editor = installWritablePrefs()

        GlobalVisualSettingsTabs.setPrimaryTabs("burn,pulse")
        GlobalVisualSettingsTabs.setSecondaryTabs("settings,you")

        assertEquals("burn,pulse", GlobalVisualSettingsTabs.primaryTabs.value)
        assertEquals("settings,you", GlobalVisualSettingsTabs.secondaryTabs.value)
        verify(exactly = 1) { editor.putString("primaryTabs", "burn,pulse") }
        verify(exactly = 1) { editor.putString("secondaryTabs", "settings,you") }
    }

    @Test
    fun `setPrimaryTabs normalizes the legacy agents token before persisting`() {
        val editor = installWritablePrefs()

        GlobalVisualSettingsTabs.setPrimaryTabs("agents,pulse")

        assertEquals("hermes,pulse", GlobalVisualSettingsTabs.primaryTabs.value)
        verify(exactly = 1) { editor.putString("primaryTabs", "hermes,pulse") }
    }

    @Test
    fun `removed tabs persist and the add-remove helpers deduplicate`() {
        val editor = installWritablePrefs()

        GlobalVisualSettingsTabs.setRemovedTabs(listOf("inbox", "streams", "inbox"))
        assertEquals("inbox,streams", GlobalVisualSettingsTabs.removedTabs.value)
        verify(exactly = 1) { editor.putString("removedTabs", "inbox,streams") }

        GlobalVisualSettingsTabs.addRemovedTab("insights")
        assertEquals("inbox,streams,insights", GlobalVisualSettingsTabs.removedTabs.value)

        GlobalVisualSettingsTabs.clearRemovedTab("streams")
        assertEquals("inbox,insights", GlobalVisualSettingsTabs.removedTabs.value)
    }

    private fun defaultsPrefs(): SharedPreferences {
        val defaults = mockk<SharedPreferences>()
        every { defaults.getString(any(), any()) } answers { secondArg() }
        return defaults
    }

    private fun installWritablePrefs(): SharedPreferences.Editor {
        val editor = mockk<SharedPreferences.Editor>(relaxed = true)
        val prefs = mockk<SharedPreferences>()
        every { prefs.edit() } returns editor
        val context = mockk<Context>()
        every { context.getSharedPreferences("global_visual_settings", Context.MODE_PRIVATE) } returns prefs
        installAppContext(context)
        return editor
    }

    private fun installAppContext(value: Context?) {
        val field = BurnBarApplication::class.java.getDeclaredField("appContext")
        field.isAccessible = true
        field.set(null, value)
    }
}
