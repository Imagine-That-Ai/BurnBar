@file:Suppress("MagicNumber")
// generated-by: scripts/generate-aurora-theme (design-token color/spacing tables)

package com.openburnbar.ui.theme

import android.provider.Settings
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.settings.rememberThemePalette
import com.openburnbar.ui.settings.rememberUIMode

// ── Aurora Color Tokens ──
// Light: warm botanical cream. Dark: cool slate blue (GitHub/Xcode dark lineage).
object AuroraColors {
    // ── Internal Compose States ──
    private val _ember = androidx.compose.runtime.mutableStateOf(Color(0xFFF45B69))
    val ember: Color get() = _ember.value

    private val _amber = androidx.compose.runtime.mutableStateOf(Color(0xFFF28C38))
    val amber: Color get() = _amber.value

    private val _blaze = androidx.compose.runtime.mutableStateOf(Color(0xFFE86100))
    val blaze: Color get() = _blaze.value

    private val _whimsy = androidx.compose.runtime.mutableStateOf(Color(0xFF6A5ACD))
    val whimsy: Color get() = _whimsy.value

    private val _purple = androidx.compose.runtime.mutableStateOf(Color(0xFF9080D8))
    val purple: Color get() = _purple.value

    private val _teal = androidx.compose.runtime.mutableStateOf(Color(0xFF2CCAC0))
    val teal: Color get() = _teal.value

    private val _gold = androidx.compose.runtime.mutableStateOf(Color(0xFFE0A030))
    val gold: Color get() = _gold.value

    // Dark accents
    private val _emberDark = androidx.compose.runtime.mutableStateOf(Color(0xFFFA5053))
    val emberDark: Color get() = _emberDark.value

    private val _amberDark = androidx.compose.runtime.mutableStateOf(Color(0xFFFFA800))
    val amberDark: Color get() = _amberDark.value

    private val _whimsyDark = androidx.compose.runtime.mutableStateOf(Color(0xFF8B7FE8))
    val whimsyDark: Color get() = _whimsyDark.value

    private val _purpleDark = androidx.compose.runtime.mutableStateOf(Color(0xFFA855F7))
    val purpleDark: Color get() = _purpleDark.value

    private val _tealDark = androidx.compose.runtime.mutableStateOf(Color(0xFF1A9A8C))
    val tealDark: Color get() = _tealDark.value

    private val _goldDark = androidx.compose.runtime.mutableStateOf(Color(0xFFB8942E))
    val goldDark: Color get() = _goldDark.value

    // Light surfaces
    private val _lightBackground = androidx.compose.runtime.mutableStateOf(Color(0xFFF3E8E6))
    val lightBackground: Color get() = _lightBackground.value

    private val _lightSurface = androidx.compose.runtime.mutableStateOf(Color(0xFFFAF5F2))
    val lightSurface: Color get() = _lightSurface.value

    private val _lightSurfaceElevated = androidx.compose.runtime.mutableStateOf(Color(0xFFFDF8F5))
    val lightSurfaceElevated: Color get() = _lightSurfaceElevated.value

    private val _lightBorder = androidx.compose.runtime.mutableStateOf(Color(0xFFE8BFB5))
    val lightBorder: Color get() = _lightBorder.value

    private val _lightBorderSubtle = androidx.compose.runtime.mutableStateOf(Color(0xFFF2E0DA))
    val lightBorderSubtle: Color get() = _lightBorderSubtle.value

    private val _lightTextPrimary = androidx.compose.runtime.mutableStateOf(Color(0xFF2A1816))
    val lightTextPrimary: Color get() = _lightTextPrimary.value

    private val _lightTextSecondary = androidx.compose.runtime.mutableStateOf(Color(0xFF6E4E48))
    val lightTextSecondary: Color get() = _lightTextSecondary.value

    private val _lightTextMuted = androidx.compose.runtime.mutableStateOf(Color(0xFF9A756D))
    val lightTextMuted: Color get() = _lightTextMuted.value

    // Dark surfaces
    private val _darkBackground = androidx.compose.runtime.mutableStateOf(Color(0xFF0D1117))
    val darkBackground: Color get() = _darkBackground.value

    private val _darkSurface = androidx.compose.runtime.mutableStateOf(Color(0xFF161B22))
    val darkSurface: Color get() = _darkSurface.value

    private val _darkSurfaceElevated = androidx.compose.runtime.mutableStateOf(Color(0xFF1F2630))
    val darkSurfaceElevated: Color get() = _darkSurfaceElevated.value

    private val _darkBorder = androidx.compose.runtime.mutableStateOf(Color(0xFF30363D))
    val darkBorder: Color get() = _darkBorder.value

    private val _darkBorderSubtle = androidx.compose.runtime.mutableStateOf(Color(0xFF21262D))
    val darkBorderSubtle: Color get() = _darkBorderSubtle.value

    private val _darkTextPrimary = androidx.compose.runtime.mutableStateOf(Color(0xFFE6EDF3))
    val darkTextPrimary: Color get() = _darkTextPrimary.value

    private val _darkTextSecondary = androidx.compose.runtime.mutableStateOf(Color(0xFF8B949E))
    val darkTextSecondary: Color get() = _darkTextSecondary.value

    private val _darkTextMuted = androidx.compose.runtime.mutableStateOf(Color(0xFF6E7681))
    val darkTextMuted: Color get() = _darkTextMuted.value

    // Semantic
    private val _success = androidx.compose.runtime.mutableStateOf(Color(0xFF3A7835))
    val success: Color get() = _success.value

    private val _warning = androidx.compose.runtime.mutableStateOf(Color(0xFFC47800))
    val warning: Color get() = _warning.value

    private val _error = androidx.compose.runtime.mutableStateOf(Color(0xFFD43030))
    val error: Color get() = _error.value

    private val _successDark = androidx.compose.runtime.mutableStateOf(Color(0xFF38D898))
    val successDark: Color get() = _successDark.value

    private val _warningDark = androidx.compose.runtime.mutableStateOf(Color(0xFFFFA800))
    val warningDark: Color get() = _warningDark.value

    private val _errorDark = androidx.compose.runtime.mutableStateOf(Color(0xFFFA5053))
    val errorDark: Color get() = _errorDark.value

    // Burn-specific
    val burnOrange: Color get() = ember
    val burnCoral: Color get() = blaze

    // Hermes
    private val _hermesMercury = androidx.compose.runtime.mutableStateOf(Color(0xFFAEA69C))
    val hermesMercury: Color get() = _hermesMercury.value

    private val _hermesAureate = androidx.compose.runtime.mutableStateOf(Color(0xFFB8942E))
    val hermesAureate: Color get() = _hermesAureate.value

    private val _hermesMercuryDark = androidx.compose.runtime.mutableStateOf(Color(0xFFC8BFB5))
    val hermesMercuryDark: Color get() = _hermesMercuryDark.value

    private val _hermesAureateDark = androidx.compose.runtime.mutableStateOf(Color(0xFFD4AA3C))
    val hermesAureateDark: Color get() = _hermesAureateDark.value

    // Chat bubbles
    val chatUserStroke: Color get() = whimsy
    val chatAssistantStroke: Color get() = ember

    // Adaptive color helpers
    fun ember(isDark: Boolean) = if (isDark) emberDark else ember

    fun amber(isDark: Boolean) = if (isDark) amberDark else amber

    fun whimsy(isDark: Boolean) = if (isDark) whimsyDark else whimsy

    /**
     * Completely shifts the entire color palette based on user preference and UI mode.
     */
    fun updateColorsForPalette(
        palette: String,
        isDark: Boolean,
        uiMode: UIMode = UIMode.STANDARD,
        appearance: AppAppearance = AppAppearance.AURORA,
    ) {
        if (appearance == AppAppearance.EDITORIAL) {
            // "Quiet Editorial" / paper skin — the light, ink-on-paper console
            // look. One coral accent, ochre + deep-coral + slate secondaries,
            // hairline borders. Light-locked: we set BOTH the light* and dark*
            // surface/text tokens to the paper palette so the handful of screens
            // that read AuroraColors.dark* directly off isSystemInDarkTheme()
            // still render as paper. Mirrors the shared editorial palette in
            // OpenBurnBarCore's DesignSystemTokens (and the web console).
            // ACCENTS
            _ember.value = Color(0xFFF45B69) // coral — the one accent
            _amber.value = Color(0xFF8A6200) // ochre (amber-on-paper)
            _blaze.value = Color(0xFFB3243C) // deep coral
            _whimsy.value = Color(0xFF565D68) // slate
            _purple.value = Color(0xFF565D68) // slate
            _teal.value = Color(0xFF0C7C69) // tier end-to-end
            _gold.value = Color(0xFF8A6200) // ochre

            _emberDark.value = Color(0xFFF45B69)
            _amberDark.value = Color(0xFF8A6200)
            _whimsyDark.value = Color(0xFF565D68)
            _purpleDark.value = Color(0xFF565D68)
            _tealDark.value = Color(0xFF0C7C69)
            _goldDark.value = Color(0xFF8A6200)

            // SURFACES & TEXT — paper, ink, ink-hairlines (both light + dark arms)
            val paper = Color(0xFFF6F4EF)
            val raised = Color(0xFFFFFEFB)
            val ink = Color(0xFF16140F)
            val body = Color(0xFF353027)
            val mute = Color(0xFF6E685D)
            val hairline = Color(0xFF16140F).copy(alpha = 0.12f)
            val hairlineSubtle = Color(0xFF16140F).copy(alpha = 0.08f)

            _lightBackground.value = paper
            _lightSurface.value = raised
            _lightSurfaceElevated.value = raised
            _lightBorder.value = hairline
            _lightBorderSubtle.value = hairlineSubtle
            _lightTextPrimary.value = ink
            _lightTextSecondary.value = body
            _lightTextMuted.value = mute

            _darkBackground.value = paper
            _darkSurface.value = raised
            _darkSurfaceElevated.value = raised
            _darkBorder.value = hairline
            _darkBorderSubtle.value = hairlineSubtle
            _darkTextPrimary.value = ink
            _darkTextSecondary.value = body
            _darkTextMuted.value = mute

            // HERMES & SEMANTIC — AA-legible tier identities on paper
            _hermesMercury.value = Color(0xFF9B9488)
            _hermesAureate.value = Color(0xFF353027)
            _hermesMercuryDark.value = Color(0xFF9B9488)
            _hermesAureateDark.value = Color(0xFF353027)
            _success.value = Color(0xFF0C7C69)
            _warning.value = Color(0xFF8A6200)
            _error.value = Color(0xFFB22219)
            _successDark.value = Color(0xFF0C7C69)
            _warningDark.value = Color(0xFF8A6200)
            _errorDark.value = Color(0xFFB22219)
            return
        }
        if (uiMode == UIMode.COOKING) {
            // ACCENTS
            _ember.value = Color(0xFFE74C3C) // Premium Sriracha Crimson
            _amber.value = Color(0xFFF39C12) // Warm Honey Gold
            _blaze.value = Color(0xFFE74C3C) // Premium Sriracha Crimson
            _whimsy.value = Color(0xFF9B59B6) // Fig/Plum Purple
            _purple.value = Color(0xFF9B59B6) // Fig/Plum Purple
            _teal.value = Color(0xFF2ECC71) // Soft Basil Sage
            _gold.value = Color(0xFFF39C12) // Warm Honey Gold

            _emberDark.value = Color(0xFFE74C3C) // Premium Sriracha Crimson
            _amberDark.value = Color(0xFFF39C12) // Warm Honey Gold
            _whimsyDark.value = Color(0xFF9B59B6) // Fig/Plum Purple
            _purpleDark.value = Color(0xFF9B59B6) // Fig/Plum Purple
            _tealDark.value = Color(0xFF2ECC71) // Soft Basil Sage
            _goldDark.value = Color(0xFFF39C12) // Warm Honey Gold

            // SURFACES & TEXT
            _lightBackground.value = Color(0xFFFAF6F0) // Warm Ivory
            _lightSurface.value = Color(0xFFFFFFFF) // Warm Meringue
            _lightSurfaceElevated.value = Color(0xFFFFFFFF) // Warm Meringue
            _lightBorder.value = Color(0xFFEFEBE4) // Soft Linen Outline
            _lightBorderSubtle.value = Color(0xFFEFEBE4).copy(alpha = 0.5f)
            _lightTextPrimary.value = Color(0xFF2C1D11) // Rich Coffee Text
            _lightTextSecondary.value = Color(0xFF7D6652) // Warm Chestnut/Caramel
            _lightTextMuted.value = Color(0xFF7D6652).copy(alpha = 0.7f)

            _darkBackground.value = Color(0xFF150F0A) // Rich Cacao Black
            _darkSurface.value = Color(0xFF1E1610) // Walnut Wood
            _darkSurfaceElevated.value = Color(0xFF1E1610) // Walnut Wood
            _darkBorder.value = Color(0xFF3E2718) // Deep Mahogany
            _darkBorderSubtle.value = Color(0xFF3E2718).copy(alpha = 0.5f)
            _darkTextPrimary.value = Color(0xFFF7EFE5) // Steamed Cream
            _darkTextSecondary.value = Color(0xFFCBB5A1) // Cinnamon Dust
            _darkTextMuted.value = Color(0xFFCBB5A1).copy(alpha = 0.7f)

            // HERMES & SEMANTIC
            _hermesMercury.value = Color(0xFFCBB5A1)
            _hermesAureate.value = Color(0xFFF39C12)
            _hermesMercuryDark.value = Color(0xFFCBB5A1)
            _hermesAureateDark.value = Color(0xFFF39C12)
            return
        }

        when (palette) {
            "AuroraTeal" -> {
                // ACCENTS
                _ember.value = Color(0xFF1A9A8C)
                _amber.value = Color(0xFF00C2CC)
                _blaze.value = Color(0xFF006666)
                _whimsy.value = Color(0xFF7012C9)
                _purple.value = Color(0xFF8A2BE2)
                _teal.value = Color(0xFF2CCAC0)
                _gold.value = Color(0xFF00A388)

                _emberDark.value = Color(0xFF2CCAC0)
                _amberDark.value = Color(0xFF00F5FF)
                _whimsyDark.value = Color(0xFF8A2BE2)
                _purpleDark.value = Color(0xFFA855F7)
                _tealDark.value = Color(0xFF1A9A8C)
                _goldDark.value = Color(0xFF38D898)

                // SURFACES & TEXT
                _lightBackground.value = Color(0xFFEAF5F3)
                _lightSurface.value = Color(0xFFF2FAF8)
                _lightSurfaceElevated.value = Color(0xFFF8FCFB)
                _lightBorder.value = Color(0xFFBBE5DF)
                _lightBorderSubtle.value = Color(0xFFDBF2EF)
                _lightTextPrimary.value = Color(0xFF0F2D2A)
                _lightTextSecondary.value = Color(0xFF245C56)
                _lightTextMuted.value = Color(0xFF438A81)

                _darkBackground.value = Color(0xFF0B171A)
                _darkSurface.value = Color(0xFF122226)
                _darkSurfaceElevated.value = Color(0xFF1B3137)
                _darkBorder.value = Color(0xFF23444C)
                _darkBorderSubtle.value = Color(0xFF183137)
                _darkTextPrimary.value = Color(0xFFE1F5FE)
                _darkTextSecondary.value = Color(0xFF80CBC4)
                _darkTextMuted.value = Color(0xFF4DB6AC)

                // HERMES & SEMANTIC
                _hermesMercury.value = Color(0xFF80CBC4)
                _hermesAureate.value = Color(0xFF00F5FF)
                _hermesMercuryDark.value = Color(0xFFB2DFDB)
                _hermesAureateDark.value = Color(0xFF00E6FF)
            }
            "Crimson" -> {
                // ACCENTS
                _ember.value = Color(0xFFE63946)
                _amber.value = Color(0xFFCC2E00)
                _blaze.value = Color(0xFFFA5053)
                _whimsy.value = Color(0xFF380068)
                _purple.value = Color(0xFF4A0082)
                _teal.value = Color(0xFFFF007F)
                _gold.value = Color(0xFFD62246)

                _emberDark.value = Color(0xFFFA5053)
                _amberDark.value = Color(0xFFFF4500)
                _whimsyDark.value = Color(0xFF4A0082)
                _purpleDark.value = Color(0xFF8B008B)
                _tealDark.value = Color(0xFFFF007F)
                _goldDark.value = Color(0xFFE63946)

                // SURFACES & TEXT
                _lightBackground.value = Color(0xFFF9ECEE)
                _lightSurface.value = Color(0xFFFDF5F6)
                _lightSurfaceElevated.value = Color(0xFFFFF9FA)
                _lightBorder.value = Color(0xFFE8BFC4)
                _lightBorderSubtle.value = Color(0xFFF2DCE0)
                _lightTextPrimary.value = Color(0xFF330C12)
                _lightTextSecondary.value = Color(0xFF6B222E)
                _lightTextMuted.value = Color(0xFF9A525E)

                _darkBackground.value = Color(0xFF0F0E0F)
                _darkSurface.value = Color(0xFF1A181C)
                _darkSurfaceElevated.value = Color(0xFF26222A)
                _darkBorder.value = Color(0xFF3D3035)
                _darkBorderSubtle.value = Color(0xFF2D2126)
                _darkTextPrimary.value = Color(0xFFFAECED)
                _darkTextSecondary.value = Color(0xFFF4A261)
                _darkTextMuted.value = Color(0xFFE76F51)

                // HERMES & SEMANTIC
                _hermesMercury.value = Color(0xFFE5989B)
                _hermesAureate.value = Color(0xFFFFB703)
                _hermesMercuryDark.value = Color(0xFFFCD5CE)
                _hermesAureateDark.value = Color(0xFFFFB703)
            }
            "CyberpunkViolet" -> {
                // ACCENTS
                _ember.value = Color(0xFF9400D3)
                _amber.value = Color(0xFFCC00CC)
                _blaze.value = Color(0xFFFF0080)
                _whimsy.value = Color(0xFF00B2CC)
                _purple.value = Color(0xFF7500AD)
                _teal.value = Color(0xFF00F5FF)
                _gold.value = Color(0xFFFFD700)

                _emberDark.value = Color(0xFFA855F7)
                _amberDark.value = Color(0xFFFF00FF)
                _whimsyDark.value = Color(0xFF00E6FF)
                _purpleDark.value = Color(0xFFDDA0DD)
                _tealDark.value = Color(0xFF00FFFF)
                _goldDark.value = Color(0xFFFFD700)

                // SURFACES & TEXT
                _lightBackground.value = Color(0xFFF5EFFF)
                _lightSurface.value = Color(0xFFFAF7FF)
                _lightSurfaceElevated.value = Color(0xFFFDFBFF)
                _lightBorder.value = Color(0xFFD2BFF5)
                _lightBorderSubtle.value = Color(0xFFE8DDFB)
                _lightTextPrimary.value = Color(0xFF2A085C)
                _lightTextSecondary.value = Color(0xFF561D9C)
                _lightTextMuted.value = Color(0xFF8252C4)

                _darkBackground.value = Color(0xFF07020E)
                _darkSurface.value = Color(0xFF130922)
                _darkSurfaceElevated.value = Color(0xFF1F1135)
                _darkBorder.value = Color(0xFF381F5E)
                _darkBorderSubtle.value = Color(0xFF261342)
                _darkTextPrimary.value = Color(0xFFF3E8FF)
                _darkTextSecondary.value = Color(0xFFD8B4FE)
                _darkTextMuted.value = Color(0xFFA855F7)

                // HERMES & SEMANTIC
                _hermesMercury.value = Color(0xFF00FFFF)
                _hermesAureate.value = Color(0xFFFFD700)
                _hermesMercuryDark.value = Color(0xFF80E6FF)
                _hermesAureateDark.value = Color(0xFFFFE680)
            }
            "ForestMoss" -> {
                // ACCENTS
                _ember.value = Color(0xFF228B22)
                _amber.value = Color(0xFFCC9900)
                _blaze.value = Color(0xFFD2691E)
                _whimsy.value = Color(0xFF759E75)
                _purple.value = Color(0xFF8FBC8F)
                _teal.value = Color(0xFF38D898)
                _gold.value = Color(0xFF859B30)

                _emberDark.value = Color(0xFF38D898)
                _amberDark.value = Color(0xFFFFBF00)
                _whimsyDark.value = Color(0xFF8FBC8F)
                _purpleDark.value = Color(0xFF4F7942)
                _tealDark.value = Color(0xFF38D898)
                _goldDark.value = Color(0xFF90EE90)

                // SURFACES & TEXT
                _lightBackground.value = Color(0xFFEEF5F1)
                _lightSurface.value = Color(0xFFF5F9F6)
                _lightSurfaceElevated.value = Color(0xFFFAFDFB)
                _lightBorder.value = Color(0xFFC0DABF)
                _lightBorderSubtle.value = Color(0xFFDCEDDB)
                _lightTextPrimary.value = Color(0xFF132D20)
                _lightTextSecondary.value = Color(0xFF285740)
                _lightTextMuted.value = Color(0xFF4E8367)

                _darkBackground.value = Color(0xFF090E0B)
                _darkSurface.value = Color(0xFF111A14)
                _darkSurfaceElevated.value = Color(0xFF18261E)
                _darkBorder.value = Color(0xFF263C2E)
                _darkBorderSubtle.value = Color(0xFF1B2A20)
                _darkTextPrimary.value = Color(0xFFEAF5F0)
                _darkTextSecondary.value = Color(0xFF9CCDAE)
                _darkTextMuted.value = Color(0xFF6BB286)

                // HERMES & SEMANTIC
                _hermesMercury.value = Color(0xFF9CCDAE)
                _hermesAureate.value = Color(0xFFFFA800)
                _hermesMercuryDark.value = Color(0xFFC7E6D3)
                _hermesAureateDark.value = Color(0xFFFFA800)
            }
            "SolarFlare" -> {
                // ACCENTS
                _ember.value = Color(0xFFFF8C00)
                _amber.value = Color(0xFFCC7000)
                _blaze.value = Color(0xFFFF3000)
                _whimsy.value = Color(0xFFE6DEC2)
                _purple.value = Color(0xFFFFF7DB)
                _teal.value = Color(0xFFFFA800)
                _gold.value = Color(0xFFE0A030)

                _emberDark.value = Color(0xFFFFD700)
                _amberDark.value = Color(0xFFFF8C00)
                _whimsyDark.value = Color(0xFFFFF7DB)
                _purpleDark.value = Color(0xFFFFE57F)
                _tealDark.value = Color(0xFFFFD700)
                _goldDark.value = Color(0xFFFFA500)

                // SURFACES & TEXT
                _lightBackground.value = Color(0xFFF7F1EA)
                _lightSurface.value = Color(0xFFFDFBF7)
                _lightSurfaceElevated.value = Color(0xFFFFFFFC)
                _lightBorder.value = Color(0xFFE4D5C5)
                _lightBorderSubtle.value = Color(0xFFF0E7DD)
                _lightTextPrimary.value = Color(0xFF361F0A)
                _lightTextSecondary.value = Color(0xFF6B4522)
                _lightTextMuted.value = Color(0xFF9B6E43)

                _darkBackground.value = Color(0xFF120C07)
                _darkSurface.value = Color(0xFF1E140C)
                _darkSurfaceElevated.value = Color(0xFF2C1D12)
                _darkBorder.value = Color(0xFF452D1B)
                _darkBorderSubtle.value = Color(0xFF2E1E12)
                _darkTextPrimary.value = Color(0xFFFFF6ED)
                _darkTextSecondary.value = Color(0xFFFFD1A4)
                _darkTextMuted.value = Color(0xFFFFB26B)

                // HERMES & SEMANTIC
                _hermesMercury.value = Color(0xFFFFB26B)
                _hermesAureate.value = Color(0xFFFFD700)
                _hermesMercuryDark.value = Color(0xFFFFD5B2)
                _hermesAureateDark.value = Color(0xFFFFD700)
            }
            else -> { // "System" (Standard Xcode Slate / Warm botanical cream)
                // ACCENTS
                _ember.value = Color(0xFFF45B69)
                _amber.value = Color(0xFFF28C38)
                _blaze.value = Color(0xFFE86100)
                _whimsy.value = Color(0xFF6A5ACD)
                _purple.value = Color(0xFF9080D8)
                _teal.value = Color(0xFF2CCAC0)
                _gold.value = Color(0xFFE0A030)

                _emberDark.value = Color(0xFFFA5053)
                _amberDark.value = Color(0xFFFFA800)
                _whimsyDark.value = Color(0xFF8B7FE8)
                _purpleDark.value = Color(0xFFA855F7)
                _tealDark.value = Color(0xFF1A9A8C)
                _goldDark.value = Color(0xFFB8942E)

                // SURFACES & TEXT
                _lightBackground.value = Color(0xFFF3E8E6)
                _lightSurface.value = Color(0xFFFAF5F2)
                _lightSurfaceElevated.value = Color(0xFFFDF8F5)
                _lightBorder.value = Color(0xFFE8BFB5)
                _lightBorderSubtle.value = Color(0xFFF2E0DA)
                _lightTextPrimary.value = Color(0xFF2A1816)
                _lightTextSecondary.value = Color(0xFF6E4E48)
                _lightTextMuted.value = Color(0xFF9A756D)

                _darkBackground.value = Color(0xFF0D1117)
                _darkSurface.value = Color(0xFF161B22)
                _darkSurfaceElevated.value = Color(0xFF1F2630)
                _darkBorder.value = Color(0xFF30363D)
                _darkBorderSubtle.value = Color(0xFF21262D)
                _darkTextPrimary.value = Color(0xFFE6EDF3)
                _darkTextSecondary.value = Color(0xFF8B949E)
                _darkTextMuted.value = Color(0xFF6E7681)

                // HERMES & SEMANTIC
                _hermesMercury.value = Color(0xFFAEA69C)
                _hermesAureate.value = Color(0xFFB8942E)
                _hermesMercuryDark.value = Color(0xFFC8BFB5)
                _hermesAureateDark.value = Color(0xFFD4AA3C)
            }
        }
    }
}

// ── Aurora Typography (legacy size tokens) ──
object AuroraTypography {
    val displayHero = 44
    val display = 28
    val displayLarge = 36
    val title = 20
    val headline = 16
    val heading = 16
    val body = 14
    val caption = 12
    val tiny = 11
}

// ── Aurora Type (full TextStyle constants) ──
object AuroraType {
    val displayLarge =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 36.sp,
            lineHeight = 44.sp,
            letterSpacing = (-0.3).sp,
        )
    val display =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 28.sp,
            lineHeight = 34.sp,
            letterSpacing = (-0.2).sp,
        )
    val title =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.SemiBold,
            fontSize = 20.sp,
            lineHeight = 26.sp,
        )
    val headline =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.SemiBold,
            fontSize = 16.sp,
            lineHeight = 22.sp,
        )
    val body =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Normal,
            fontSize = 14.sp,
            lineHeight = 20.sp,
        )
    val caption =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Medium,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
    val tiny =
        TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Medium,
            fontSize = 11.sp,
            lineHeight = 14.sp,
        )

    val monoLarge =
        TextStyle(
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            fontSize = 28.sp,
            lineHeight = 34.sp,
        )
    val mono =
        TextStyle(
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            fontSize = 14.sp,
            lineHeight = 20.sp,
        )
    val monoSmall =
        TextStyle(
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
    val monoTiny =
        TextStyle(
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            fontSize = 11.sp,
            lineHeight = 14.sp,
        )
}

// ── Material3 Typography wiring ──
private val AuroraMaterialTypography =
    Typography(
        displayLarge = AuroraType.displayLarge,
        displayMedium = AuroraType.display,
        displaySmall = AuroraType.title,
        headlineSmall = AuroraType.headline,
        titleLarge = AuroraType.title,
        titleMedium = AuroraType.headline,
        bodyLarge = AuroraType.body.copy(fontSize = 16.sp, lineHeight = 22.sp),
        bodyMedium = AuroraType.body,
        bodySmall = AuroraType.caption,
        labelLarge = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold),
        labelMedium = AuroraType.caption,
        labelSmall = AuroraType.tiny,
    )

// ── Aurora Spacing ──
object AuroraSpacing {
    const val xxs = 2
    const val xs = 4
    const val sm = 8
    const val md = 12
    const val lg = 16
    const val xl = 24
    const val xxl = 32
    const val xxxl = 48
}

// ── Aurora Radius ──
object AuroraRadius {
    const val sm = 6
    const val md = 10
    const val lg = 16
    const val xl = 22
    const val full = 9999
}

// ── Aurora Shadows ──
data class AuroraShadowSpec(val elevation: Dp, val spotAlpha: Float)

object AuroraShadows {
    val none = AuroraShadowSpec(0.dp, 0f)
    val subtle = AuroraShadowSpec(2.dp, 0.05f)
    val small = AuroraShadowSpec(4.dp, 0.10f)
    val medium = AuroraShadowSpec(8.dp, 0.12f)
    val cardHover = AuroraShadowSpec(12.dp, 0.18f)
    val large = AuroraShadowSpec(16.dp, 0.20f)
    val fab = AuroraShadowSpec(12.dp, 0.25f)
}

// ── Aurora Gradients ──
object AuroraGradients {
    fun auroraRibbon(isDark: Boolean): List<Color> = listOf(
        AuroraColors.ember(isDark).copy(alpha = 0.55f),
        AuroraColors.amber(isDark).copy(alpha = 0.35f),
        (if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury).copy(alpha = 0.25f),
        AuroraColors.whimsy(isDark).copy(alpha = 0.18f),
    )

    val heroCard: List<Color> get() =
        listOf(
            AuroraColors.ember.copy(alpha = 0.18f),
            AuroraColors.amber.copy(alpha = 0.08f),
            AuroraColors.blaze.copy(alpha = 0.04f),
        )

    val mercuryFoil: List<Color> get() =
        listOf(
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
            AuroraColors.hermesAureate.copy(alpha = 0.7f),
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
        )

    val mercuryGradient: List<Color> get() =
        listOf(
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
            AuroraColors.hermesAureate.copy(alpha = 0.7f),
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
        )

    val primaryGradient: List<Color> get() = listOf(AuroraColors.ember, AuroraColors.amber)

    val accentGradient: List<Color> get() = listOf(AuroraColors.whimsy, AuroraColors.ember)

    val cardGradient: List<Color> get() =
        listOf(
            AuroraColors.ember.copy(alpha = 0.06f),
            AuroraColors.amber.copy(alpha = 0.04f),
            AuroraColors.blaze.copy(alpha = 0.03f),
        )

    val whimsyGradient: List<Color> get() = listOf(AuroraColors.whimsy, AuroraColors.whimsy.copy(alpha = 0.6f))

    val piGradient: List<Color> get() = listOf(AuroraColors.whimsy, AuroraColors.whimsy.copy(alpha = 0.65f))

    val glassStroke: List<Color> get() =
        listOf(
            AuroraColors.ember.copy(alpha = 0.22f),
            AuroraColors.lightBorder.copy(alpha = 0.55f),
            AuroraColors.blaze.copy(alpha = 0.18f),
        )

    val glassSheen: List<Color> get() =
        listOf(
            AuroraColors.ember.copy(alpha = 0.08f),
            Color.Transparent,
            AuroraColors.blaze.copy(alpha = 0.06f),
        )

    fun providerRing(provider: com.openburnbar.data.models.AgentProvider): List<Color> = listOf(
        Color(provider.brandColor).copy(alpha = 0.95f),
        Color(provider.accentColor).copy(alpha = 0.65f),
        Color(provider.brandColor).copy(alpha = 0f),
        Color(provider.accentColor).copy(alpha = 0.45f),
        Color(provider.brandColor).copy(alpha = 0.95f),
    )
}

// ── Aurora Animation Specs ──
object AuroraMotion {
    data class SpringSpec(val durationMs: Int, val dampingRatio: Float)

    val auroraSpring = SpringSpec(350, 0.75f)
    val auroraSnap = SpringSpec(150, 1.0f)
    val cardHover = SpringSpec(250, 0.80f)
    val cardPress = SpringSpec(220, 0.70f)
    const val mercuryShimmerDuration = 3000L

    fun <T> auroraSpringSpec(): AnimationSpec<T> = spring(stiffness = 322f, dampingRatio = 0.75f)

    fun <T> auroraSnapSpec(): AnimationSpec<T> = tween(durationMillis = 150, easing = EaseOut)

    fun <T> cardHoverSpec(): AnimationSpec<T> = spring(stiffness = 632f, dampingRatio = 0.80f)

    fun <T> cardPressSpec(): AnimationSpec<T> = spring(stiffness = 815f, dampingRatio = 0.70f)

    fun <T> gentleSpec(): AnimationSpec<T> = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f)
}

// ── Reduce-motion CompositionLocal ──
val LocalAuroraReduceMotion = compositionLocalOf { false }

// ── Composable Theme Wrapper ──
@Composable
fun AuroraTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    // 1. Reactive color palette, UI Mode, skin, and Mode Theme states
    val palette = rememberThemePalette().value
    val uiMode = rememberUIMode().value
    val appearance = com.openburnbar.ui.settings.rememberAppearance().value

    // Editorial is a light-locked paper skin — never let it sit on a dark
    // scheme regardless of the OS setting.
    val effectiveDark = if (appearance == AppAppearance.EDITORIAL) false else darkTheme

    val modeTheme = remember(uiMode, effectiveDark) { UIModeTheme(uiMode, effectiveDark) }

    remember(palette, effectiveDark, uiMode, appearance) {
        AuroraColors.updateColorsForPalette(palette, effectiveDark, uiMode, appearance)
        true
    }

    // 2. Build the ColorScheme dynamically based on active mode theme accents and surfaces
    val colorScheme =
        if (effectiveDark) {
            darkColorScheme(
                primary = modeTheme.primaryAccent,
                secondary = modeTheme.secondaryAccent,
                tertiary = modeTheme.tertiaryAccent,
                background = modeTheme.background,
                surface = modeTheme.surface,
                surfaceVariant = modeTheme.surface,
                onPrimary = Color.White,
                onSecondary = Color.White,
                onTertiary = Color.White,
                onBackground = modeTheme.textPrimary,
                onSurface = modeTheme.textPrimary,
                onSurfaceVariant = modeTheme.textSecondary,
                outline = modeTheme.border,
                outlineVariant = modeTheme.border,
                error = AuroraColors.errorDark,
            )
        } else {
            lightColorScheme(
                primary = modeTheme.primaryAccent,
                secondary = modeTheme.secondaryAccent,
                tertiary = modeTheme.tertiaryAccent,
                background = modeTheme.background,
                surface = modeTheme.surface,
                surfaceVariant = modeTheme.surface,
                onPrimary = Color.White,
                onSecondary = Color.White,
                onTertiary = Color.White,
                onBackground = modeTheme.textPrimary,
                onSurface = modeTheme.textPrimary,
                onSurfaceVariant = modeTheme.textSecondary,
                outline = modeTheme.border,
                outlineVariant = modeTheme.border,
                error = AuroraColors.error,
            )
        }

    val context = LocalContext.current
    val reduceMotion =
        remember(context) {
            runCatching {
                Settings.Global.getFloat(
                    context.contentResolver,
                    Settings.Global.ANIMATOR_DURATION_SCALE,
                    1f,
                ) == 0f
            }.getOrDefault(false)
        }

    val cloudBadgeSelection = com.openburnbar.ui.pro.rememberLocalCloudBadgeSelection()
    CompositionLocalProvider(
        LocalAuroraReduceMotion provides reduceMotion,
        com.openburnbar.ui.pro.LocalCloudBadgeSelection provides cloudBadgeSelection,
        LocalUIMode provides uiMode,
        LocalUIModeTheme provides modeTheme,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = AuroraMaterialTypography,
            content = content,
        )
    }
}

// ── Model color helpers ──
fun colorForModel(modelName: String): Color {
    val key = modelName.lowercase()
    if (key.contains("claude") || key.contains("anthropic")) return Color(0xFFCC785C)
    if (key.contains("gpt") || key.contains("openai") || key.contains("chatgpt")) return Color(0xFF00A67E)
    if (key.contains("gemini") || key.contains("google")) return Color(0xFF4285F4)
    if (key.contains("deepseek")) return Color(0xFF6366F1)
    if (key.contains("kimi") || key.contains("moonshot")) return Color(0xFF6366F1)
    if (key.contains("minimax") || key.contains("abab")) return Color(0xFFF59E0B)
    if (key.contains("llama") || key.contains("meta")) return Color(0xFF0668E1)
    if (key.contains("mistral") || key.contains("mixtral")) return Color(0xFFFF7000)
    if (key.contains("qwen") || key.contains("qwq")) return Color(0xFF615EFF)
    if (key.contains("grok") || key.contains("xai")) return Color(0xFF1A1A1A)
    if (key.contains("cohere") || key.contains("command")) return Color(0xFF39594D)
    if (key.contains("perplexity") || key.contains("sonar")) return Color(0xFF20808D)
    if (key.contains("mlx") || key.contains("apple")) return Color(0xFFA2AAAD)
    if (key.contains("nova") || key.contains("amazon") || key.contains("bedrock")) return Color(0xFFFF9900)
    if (key.contains("alibaba") || key.contains("tongyi")) return Color(0xFFFF6A00)
    if (key.contains("ollama")) return Color(0xFF8B8589)

    val palette =
        listOf(
            0xFFD4A373, 0xFF10B981, 0xFFEC4899, 0xFFF97316,
            0xFF3B82F6, 0xFFA855F7, 0xFFEF4444, 0xFF14B8A6,
            0xFFF59E0B, 0xFF8B5CF6, 0xFF06B6D4, 0xFF84CC16,
        )
    var hash = 5381L
    key.forEach { byte -> hash = ((hash shl 5) + hash) + byte.code.toLong() }
    return Color(palette[(hash % palette.size).toInt()])
}
