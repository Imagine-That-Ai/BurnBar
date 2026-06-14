package com.openburnbar.ui.pro

import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.spring
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors

// ── Pro Theme (Android) ──
//
// Compose mirror of `OpenBurnBarMobile/Theme/ProTheme.swift`. Defines the
// "luxury island in utilitarian sea" Pro vocabulary: obsidian + mercury foil
// + serif display, deliberately distinct from the AuroraTheme utilitarian
// shell. Composes existing `AuroraColors.hermesMercury` / `hermesAureate`
// — only the obsidian palette is net-new.
//
// Android cannot purchase yet (no Play Billing). These primitives render
// the same posters and moments as iOS; CTAs deep-link to the iOS App Store
// or the website pricing page.

object ProPalette {
    val obsidian = Color(red = 0.040f, green = 0.040f, blue = 0.052f)
    val obsidianElevated = Color(red = 0.070f, green = 0.070f, blue = 0.085f)
    val mercury = AuroraColors.hermesMercuryDark
    val aureate = AuroraColors.hermesAureateDark
    val emberPop = AuroraColors.ember

    // / Foil edge — gradient stroke colors for borders.
    val aureateStrokeStops: List<Color> =
        listOf(
            aureate.copy(alpha = 0.95f),
            mercury.copy(alpha = 0.98f),
            aureate.copy(alpha = 0.95f),
        )

    // / Darkened aurora ribbon descending from top of posters.
    val darkAuroraRibbonStops: List<Color> =
        listOf(
            emberPop.copy(alpha = 0.32f),
            AuroraColors.amber.copy(alpha = 0.18f),
            mercury.copy(alpha = 0.14f),
            Color.Transparent,
        )
}

object ProTypography {
    val displaySerif =
        TextStyle(
            fontFamily = FontFamily.Serif,
            fontWeight = FontWeight.Black,
            fontSize = 40.sp,
            lineHeight = 48.sp,
            letterSpacing = (-0.4).sp,
        )
    val titleSerif =
        TextStyle(
            fontFamily = FontFamily.Serif,
            fontWeight = FontWeight.Bold,
            fontSize = 26.sp,
            lineHeight = 32.sp,
            letterSpacing = (-0.2).sp,
        )
    val headlineSerif =
        TextStyle(
            fontFamily = FontFamily.Serif,
            fontWeight = FontWeight.SemiBold,
            fontSize = 18.sp,
            lineHeight = 24.sp,
        )
    val priceMono =
        TextStyle(
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            fontSize = 20.sp,
            lineHeight = 26.sp,
        )
}

object ProMotion {
    const val SPECULAR_DURATION_MS = 2800
    const val MERCURY_SHIMMER_DURATION_MS = 3000L
    const val BREATHING_DURATION_MS = 2400

    fun <T> posterSettleSpec(): AnimationSpec<T> = spring(stiffness = 240f, dampingRatio = 0.78f)
}

object ProLayout {
    const val CARD_RADIUS_DP = 18
    const val BAND_RADIUS_DP = 14
    const val FOIL_STROKE_DP = 1.0f
    const val CREST_LARGE_DP = 48
    const val CREST_MEDIUM_DP = 36
    const val CREST_SMALL_DP = 24
    const val BADGE_DOT_DP = 6
}
