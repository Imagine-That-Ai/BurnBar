// UI unit-test fixture literals (sizes, millis, colors); extraction adds noise without reuse.

package com.openburnbar.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UIModeThemeTest {
    @Test
    fun uimodeFromKeyMatchesCorrectly() {
        assertEquals(UIMode.STANDARD, UIMode.fromKey("standard"))
        assertEquals(UIMode.COOKING, UIMode.fromKey("cooking"))
        // Fallback for null or unknown keys
        assertEquals(UIMode.STANDARD, UIMode.fromKey(null))
        assertEquals(UIMode.STANDARD, UIMode.fromKey("invalid_key"))
    }

    @Test
    fun uimodethemePropertiesForStandardModeLight() {
        val theme = UIModeTheme(UIMode.STANDARD, isDark = false)
        assertEquals(UIMode.STANDARD, theme.mode)
        assertFalse(theme.isDark)

        // Verifying standard typography/spacing defaults
        assertEquals(1.0f, theme.spacingScale, 0.001f)
        assertEquals(0.dp, theme.extraRadius)
        assertTrue(theme.ambientAnimationsEnabled)
    }

    @Test
    fun uimodethemePropertiesForStandardModeDark() {
        val theme = UIModeTheme(UIMode.STANDARD, isDark = true)
        assertEquals(UIMode.STANDARD, theme.mode)
        assertTrue(theme.isDark)

        assertEquals(1.0f, theme.spacingScale, 0.001f)
        assertEquals(0.dp, theme.extraRadius)
        assertTrue(theme.ambientAnimationsEnabled)
    }

    @Test
    fun uimodethemePropertiesForCookingModeLight() {
        val theme = UIModeTheme(UIMode.COOKING, isDark = false)
        assertEquals(UIMode.COOKING, theme.mode)
        assertFalse(theme.isDark)

        // Verifying dynamic cooking mode defaults
        assertEquals(1.2f, theme.spacingScale, 0.001f)
        assertEquals(4.dp, theme.extraRadius)
        assertFalse(theme.ambientAnimationsEnabled)

        // Accents
        assertEquals(Color(0xFFE74C3C), theme.primaryAccent) // Premium Sriracha Crimson
        assertEquals(Color(0xFFF39C12), theme.secondaryAccent) // Warm Honey Gold
        assertEquals(Color(0xFF2ECC71), theme.tertiaryAccent) // Soft Basil Sage
        assertEquals(Color(0xFF9B59B6), theme.quaternaryAccent) // Elegant Fig/Plum Purple

        // Surfaces & Text
        assertEquals(Color(0xFFFAF6F0), theme.background) // Warm Ivory
        assertEquals(Color(0xFFFFFFFF), theme.surface) // Warm Meringue
        assertEquals(Color(0xFF2C1D11), theme.textPrimary) // Rich Coffee
        assertEquals(Color(0xFF7D6652), theme.textSecondary) // Warm Chestnut/Caramel
        assertEquals(Color(0xFFEFEBE4), theme.border) // Soft Linen
    }

    @Test
    fun uimodethemePropertiesForCookingModeDark() {
        val theme = UIModeTheme(UIMode.COOKING, isDark = true)
        assertEquals(UIMode.COOKING, theme.mode)
        assertTrue(theme.isDark)

        // Verifying dynamic cooking mode defaults
        assertEquals(1.2f, theme.spacingScale, 0.001f)
        assertEquals(4.dp, theme.extraRadius)
        assertFalse(theme.ambientAnimationsEnabled)

        // Accents
        assertEquals(Color(0xFFE74C3C), theme.primaryAccent) // Premium Sriracha Crimson
        assertEquals(Color(0xFFF39C12), theme.secondaryAccent) // Warm Honey Gold
        assertEquals(Color(0xFF2ECC71), theme.tertiaryAccent) // Soft Basil Sage
        assertEquals(Color(0xFF9B59B6), theme.quaternaryAccent) // Elegant Fig/Plum Purple

        // Surfaces & Text
        assertEquals(Color(0xFF150F0A), theme.background) // Rich Cacao Black
        assertEquals(Color(0xFF1E1610), theme.surface) // Walnut Wood
        assertEquals(Color(0xFFF7EFE5), theme.textPrimary) // Steamed Cream
        assertEquals(Color(0xFFCBB5A1), theme.textSecondary) // Cinnamon Dust
        assertEquals(Color(0xFF3E2718), theme.border) // Deep Mahogany
    }
}
