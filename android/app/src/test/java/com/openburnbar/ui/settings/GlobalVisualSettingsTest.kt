
package com.openburnbar.ui.settings

import android.content.Context
import android.util.Log
import androidx.compose.runtime.MutableState
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.models.AgentProvider
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Style/glyph coherence tests for the [GlobalVisualSettings] singleton: the
 * legacy `useWebsiteBackground` flag must stay derived from the style enum,
 * the legacy boolean setter must map onto the enum without losing the
 * constellation choice, and provider-glyph sets are always normalized to the
 * swarm showcase. Load/persist hygiene lives in [GlobalVisualSettingsLoadTest].
 */
class GlobalVisualSettingsTest {
    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0
        // No app context: setters update in-memory state and drop the persist.
        installAppContext(null)
        setLoaded(true)
        resetStyle(BackgroundStyle.AURORA)
    }

    @After
    fun tearDown() {
        resetStyle(BackgroundStyle.AURORA)
        setProviderGlyphsState(AgentProvider.swarmGlyphProviders.toSet())
        setLoaded(false)
        unmockkStatic(Log::class)
    }

    @Test
    fun `background style keeps the legacy website background flag in sync`() {
        GlobalVisualSettings.setBackgroundStyle(BackgroundStyle.SWARM)
        assertEquals(BackgroundStyle.SWARM, GlobalVisualSettings.backgroundStyle.value)
        assertTrue(GlobalVisualSettings.useWebsiteBackground.value)

        GlobalVisualSettings.setBackgroundStyle(BackgroundStyle.AURORA)
        assertFalse(GlobalVisualSettings.useWebsiteBackground.value)

        GlobalVisualSettings.setBackgroundStyle(BackgroundStyle.DOT_CONSTELLATION)
        assertTrue(GlobalVisualSettings.useWebsiteBackground.value)
    }

    @Test
    fun `legacy boolean toggle maps onto the style enum`() {
        GlobalVisualSettings.setBackgroundStyle(BackgroundStyle.AURORA)
        GlobalVisualSettings.setWebsiteBackground(true)
        // From a non-backdrop style, "on" selects the swarm default.
        assertEquals(BackgroundStyle.SWARM, GlobalVisualSettings.backgroundStyle.value)

        GlobalVisualSettings.setWebsiteBackground(false)
        assertEquals(BackgroundStyle.AURORA, GlobalVisualSettings.backgroundStyle.value)
    }

    @Test
    fun `toggling the legacy boolean on preserves a constellation choice`() {
        GlobalVisualSettings.setBackgroundStyle(BackgroundStyle.DOT_CONSTELLATION)
        // Already on a custom backdrop: "on" must NOT stomp it back to SWARM.
        GlobalVisualSettings.setWebsiteBackground(true)
        assertEquals(BackgroundStyle.DOT_CONSTELLATION, GlobalVisualSettings.backgroundStyle.value)
    }

    @Test
    fun `provider glyphs are normalized to the swarm showcase`() {
        val showcase = AgentProvider.swarmGlyphProviders.toSet()
        GlobalVisualSettings.setProviderGlyphs(showcase + AgentProvider.entries.toSet())
        // Anything outside the showcase is dropped, never persisted.
        assertEquals(showcase, GlobalVisualSettings.providerGlyphs.value)

        GlobalVisualSettings.setProviderGlyphs(emptySet())
        assertEquals(emptySet<AgentProvider>(), GlobalVisualSettings.providerGlyphs.value)
    }

    @Test
    fun `background style keys round trip through fromKey`() {
        for (style in BackgroundStyle.entries) {
            assertEquals(style, BackgroundStyle.fromKey(style.key))
        }
        assertEquals(null, BackgroundStyle.fromKey("unknown"))
        assertEquals(null, BackgroundStyle.fromKey(""))
        assertEquals(null, BackgroundStyle.fromKey(null))
        // The two dark, content-behind backdrops are exactly swarm + constellation.
        assertEquals(
            setOf(BackgroundStyle.SWARM, BackgroundStyle.DOT_CONSTELLATION),
            BackgroundStyle.entries.filter { it.usesCustomBackdrop }.toSet(),
        )
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

    private fun resetStyle(style: BackgroundStyle) {
        val styleField = GlobalVisualSettings::class.java.getDeclaredField("_backgroundStyle")
        styleField.isAccessible = true
        (styleField.get(GlobalVisualSettings) as? MutableState<Any?>)?.value = style
        val legacyField = GlobalVisualSettings::class.java.getDeclaredField("_useWebsiteBackground")
        legacyField.isAccessible = true
        (legacyField.get(GlobalVisualSettings) as? MutableState<Any?>)?.value = style.usesCustomBackdrop
    }

    private fun setProviderGlyphsState(value: Set<AgentProvider>) {
        val field = GlobalVisualSettings::class.java.getDeclaredField("_providerGlyphs")
        field.isAccessible = true
        (field.get(GlobalVisualSettings) as? MutableState<Any?>)?.value = value
    }
}
