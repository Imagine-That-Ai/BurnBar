package com.openburnbar.ui.widget

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.sp
import androidx.glance.text.FontWeight
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider as GlanceColorProvider
import com.openburnbar.ui.theme.AuroraColors

/**
 * Glance can't read MaterialTheme or Compose-state colors, so widgets need
 * their own self-contained palette. We re-expose the Aurora brand constants
 * via `ColorProvider`s so each widget surface stays visually identical to
 * the in-app screens.
 */
object WidgetTheme {

    // Brand palette — light + dark surface variants the iOS widget uses.
    val ember  = AuroraColors.ember
    val amber  = AuroraColors.amber
    val blaze  = AuroraColors.blaze
    val whimsy = AuroraColors.whimsy

    val backgroundLight = Color(0xFFF3E8E6)
    val surfaceLight    = Color(0xFFFAF5F2)
    val surfaceElevated = Color(0xFFFDF8F5)
    val backgroundDark  = AuroraColors.darkBackground
    val surfaceDark     = AuroraColors.darkSurface

    val textPrimary   = AuroraColors.lightTextPrimary
    val textSecondary = AuroraColors.lightTextSecondary
    val textMuted     = AuroraColors.lightTextMuted
    val textPrimaryDark   = AuroraColors.darkTextPrimary
    val textSecondaryDark = AuroraColors.darkTextSecondary

    // Convenience ColorProvider wrappers — Glance hosts call these per-render
    // and may resolve to the light or dark variant based on the system state.
    val surface: GlanceColorProvider = GlanceColorProvider(surfaceLight)
    val background: GlanceColorProvider = GlanceColorProvider(backgroundLight)
    val text: GlanceColorProvider = GlanceColorProvider(textPrimary)
    val textSubtle: GlanceColorProvider = GlanceColorProvider(textSecondary)
    val textFaint: GlanceColorProvider = GlanceColorProvider(textMuted)
    val accentEmber: GlanceColorProvider = GlanceColorProvider(ember)
    val accentAmber: GlanceColorProvider = GlanceColorProvider(amber)

    // Glance TextStyles — rounded sans-serif at sizes matching the iOS widget.
    val display       = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold)
    val displayLarge  = TextStyle(fontSize = 32.sp, fontWeight = FontWeight.Bold)
    val title         = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Medium)
    val headline      = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium)
    val body          = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Normal)
    val caption       = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium)
    val tiny          = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium)
    val micro         = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Medium)
}
