package com.openburnbar.ui.insights

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Insights-specific theme tokens extending the existing Aurora theme.
 * Maps DESIGN.md's six canvas themes (Aurora, Ember, Mercury, Whimsy, Mono, Print)
 * to Material 3 color schemes and accent palettes used by widget renderers.
 */

object InsightsColors {
    // ── Accent palettes per theme (from DESIGN.md) ──

    val auroraAccents = listOf(AuroraColors.ember, AuroraColors.amber, AuroraColors.purple, AuroraColors.teal, AuroraColors.gold)
    val emberAccents = listOf(AuroraColors.ember, AuroraColors.amber, AuroraColors.blaze, Color(0xFFE87060), Color(0xFFF0C040))
    val mercuryAccents = AuroraGradients.mercuryGradient + listOf(AuroraColors.hermesAureate, Color(0xFFAEA69C))
    val whimsyAccents = listOf(AuroraColors.whimsy, Color(0xFF8B7FE8), Color(0xFF6A5ACD), Color(0xFFB8942E), Color(0xFFE87060))
    val monoAccents = listOf(Color(0xFFE6EDF3), Color(0xFF8B949E), Color(0xFF6E7681), Color(0xFFD0D7DE), Color(0xFFF0F6FC))
    val printAccents = listOf(Color(0xFF1C2014), Color(0xFF4A5442), Color(0xFF7A8572), Color(0xFFC5CEB6), Color(0xFF3A7835))

    fun accentsFor(theme: InsightTheme): List<Color> = when (theme) {
        InsightTheme.AURORA -> auroraAccents
        InsightTheme.EMBER -> emberAccents
        InsightTheme.MERCURY -> mercuryAccents
        InsightTheme.WHIMSY -> whimsyAccents
        InsightTheme.MONO -> monoAccents
        InsightTheme.PRINT -> printAccents
    }

    // ── Chart colors (Vico line/area/bar fill) ──

    val chartLinePrimary = AuroraColors.ember
    val chartLineSecondary = AuroraColors.purple
    val chartLineTertiary = AuroraColors.teal
    val chartLineQuaternary = AuroraColors.gold
    val chartLineQuinary = AuroraColors.whimsy

    val chartFillPrimary = AuroraColors.ember.copy(alpha = 0.25f)
    val chartFillSecondary = AuroraColors.purple.copy(alpha = 0.25f)
    val chartFillTertiary = AuroraColors.teal.copy(alpha = 0.25f)

    // ── KPI accent ──
    val kpiPositive = AuroraColors.success
    val kpiNegative = Color(0xFFF45B69) // ember for negative
    val kpiNeutral = AuroraColors.amber

    // ── Heatmap palettes ──
    val heatmapEmber = listOf(Color(0xFF2D1B0E), Color(0xFFE87060), Color(0xFFF0C040))
    val heatmapMercury = listOf(Color(0xFF1A1A2E), Color(0xFFAEA69C), Color(0xFFD4AA3C))
    val heatmapWhimsy = listOf(Color(0xFF1A103C), Color(0xFF8B7FE8), Color(0xFFD4AA3C))
    val heatmapMono = listOf(Color(0xFF0D1117), Color(0xFF8B949E), Color(0xFFE6EDF3))

    // ── Freshness indicators ──
    val freshnessFresh = Color(0xFF38D898)
    val freshnessStale = Color(0xFF9A9088)
    val freshnessComputing = Color(0xFFF0C040)
    val freshnessError = Color(0xFFF45B69)
    val freshnessLocked = Color(0xFF6E7681)

    // ── Canvas surface colors ──
    val canvasSurfaceDark = Color(0xFF171510)
    val canvasSurfaceLight = Color(0xFFF4F6EE)
    val canvasBorderDark = Color(0xFF302C22)
    val canvasBorderLight = Color(0xFFC5CEB6)
}

object InsightsSpacing {
    val widgetPadding = AuroraSpacing.sm // 8dp
    val widgetGap = AuroraSpacing.md // 12dp
    val cardRadius = 16 // dp (lg from DESIGN.md)
    val chartHeight = 180 // dp
    val sparklineHeight = 24 // dp
}
