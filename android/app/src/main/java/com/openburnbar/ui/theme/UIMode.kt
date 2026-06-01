package com.openburnbar.ui.theme

import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * App-wide visual persona. Adapts colors, typography scale, spacing,
 * and animations to match standard or finger-friendly cooking modes.
 */
enum class UIMode(val key: String, val displayName: String, val description: String, val iconName: String) {
    STANDARD("standard", "Standard", "The classic Aurora experience", "sparkles"),
    COOKING("cooking", "Cooking", "Big, bright, and finger-friendly", "cooking"),
    ;

    companion object {
        fun fromKey(key: String?): UIMode = entries.find { it.key == key } ?: STANDARD
    }
}

/**
 * Mode-specific design token overrides. Computes adapted values for each persona
 * to guarantee state-of-the-art visual harmony.
 */
class UIModeTheme(val mode: UIMode, val isDark: Boolean) {
    val primaryAccent: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.emberDark else AuroraColors.ember
                UIMode.COOKING -> Color(0xFFE74C3C) // Premium Sriracha Crimson
            }

    val secondaryAccent: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
                UIMode.COOKING -> Color(0xFFF39C12) // Warm Honey Gold
            }

    val tertiaryAccent: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.emberDark else AuroraColors.blaze
                UIMode.COOKING -> Color(0xFF2ECC71) // Soft Basil Sage
            }

    val quaternaryAccent: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.whimsyDark else AuroraColors.whimsy
                UIMode.COOKING -> Color(0xFF9B59B6) // Elegant Fig/Plum Purple
            }

    val background: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground
                UIMode.COOKING -> if (isDark) Color(0xFF150F0A) else Color(0xFFFAF6F0) // Rich Cacao Black / Warm Ivory
            }

    val surface: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.darkSurface else AuroraColors.lightSurface
                UIMode.COOKING -> if (isDark) Color(0xFF1E1610) else Color(0xFFFFFFFF) // Walnut / Warm Meringue
            }

    val textPrimary: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary
                UIMode.COOKING -> if (isDark) Color(0xFFF7EFE5) else Color(0xFF2C1D11) // Steamed Cream / Rich Coffee
            }

    val textSecondary: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary
                UIMode.COOKING -> if (isDark) Color(0xFFCBB5A1) else Color(0xFF7D6652) // Cinnamon / Warm Chestnut
            }

    val border: Color
        get() =
            when (mode) {
                UIMode.STANDARD -> if (isDark) AuroraColors.darkBorder else AuroraColors.lightBorder
                UIMode.COOKING -> if (isDark) Color(0xFF3E2718) else Color(0xFFEFEBE4) // Deep Mahogany / Soft Linen Outline
            }

    val spacingScale: Float
        get() =
            when (mode) {
                UIMode.STANDARD -> 1.0f
                UIMode.COOKING -> 1.2f // Subtle 1.2x scale for spacing rather than global density balloon
            }

    val extraRadius: Dp
        get() =
            when (mode) {
                UIMode.STANDARD -> 0.dp
                UIMode.COOKING -> 4.dp
            }

    val ambientAnimationsEnabled: Boolean
        get() =
            when (mode) {
                UIMode.STANDARD -> true
                UIMode.COOKING -> false
            }
}

/**
 * CompositionLocal keys to distribute mode states reactively throughout the UI.
 */
val LocalUIMode = compositionLocalOf { UIMode.STANDARD }
val LocalUIModeTheme = compositionLocalOf<UIModeTheme> { error("No UIModeTheme provided") }
