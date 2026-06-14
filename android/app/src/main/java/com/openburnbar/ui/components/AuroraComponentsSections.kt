// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@Composable
internal fun AuroraBackdropGradientLayer(isDark: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colors =
                    if (isDark) {
                        listOf(
                            com.openburnbar.ui.theme.AuroraColors.darkBackground,
                            com.openburnbar.ui.theme.AuroraColors.darkBackground,
                            com.openburnbar.ui.theme.AuroraColors.darkSurface,
                        )
                    } else {
                        listOf(
                            com.openburnbar.ui.theme.AuroraColors.lightBackground,
                            com.openburnbar.ui.theme.AuroraColors.lightBackground,
                            com.openburnbar.ui.theme.AuroraColors.lightSurface,
                        )
                    },
                ),
            ),
    )
}

@Composable
internal fun AuroraBackdropVignette(isDark: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors =
                    listOf(
                        Color.Transparent,
                        auroraVignetteEdgeColor(isDark),
                    ),
                    center = androidx.compose.ui.geometry.Offset(0.5f, 0.5f),
                    radius = 0.8f,
                ),
            ),
    )
}

@Composable
internal fun AuroraBackdropAnimatedLayers(isDark: Boolean, density: AuroraDensity, reduceMotion: Boolean, phase: () -> Float, ribbonPhase: () -> Float) {
    if (!auroraShowsAnimatedLayers(density)) return
    Box(modifier = Modifier.fillMaxSize()) {
        OrbLayer(
            isDark = isDark,
            phase = auroraResolvedPhase(reduceMotion, phase),
            opacity = auroraOrbLayerOpacity(density),
            modifier = Modifier.fillMaxSize(),
        )
        RibbonLayer(
            isDark = isDark,
            ribbonPhase = auroraResolvedPhase(reduceMotion, ribbonPhase),
            opacity = auroraRibbonLayerOpacity(density),
            modifier =
            Modifier
                .fillMaxWidth()
                .height(220.dp)
                .align(androidx.compose.ui.Alignment.TopCenter),
        )
        if (auroraShowsParticleLayer(density, reduceMotion)) {
            ParticleLayer(modifier = Modifier.fillMaxSize())
        }
    }
}

// ── Pure presentation policy ──
// The density/Reduce-Motion ladder, extracted so the backdrop contract is
// unit-testable without a composition.

/**
 * Phases arrive as lambdas read in layout/draw scope; this capture-less static
 * clamp keeps the Reduce Motion contract even for callers passing a live phase.
 */
internal val auroraStaticPhase: () -> Float = { 0f }

/** Vignette edge: deep black in dark mode, a faint ink tint on paper. */
internal fun auroraVignetteEdgeColor(isDark: Boolean): Color = if (isDark) {
    Color.Black.copy(alpha = 0.32f)
} else {
    Color(0xFF1C2014).copy(alpha = 0.10f)
}

/** MINIMAL renders the flat gradient only — no orbs, ribbon, or particles. */
internal fun auroraShowsAnimatedLayers(density: AuroraDensity): Boolean = density != AuroraDensity.MINIMAL

/** SUBTLE dims the orb field; FULL runs it at native opacity. */
internal fun auroraOrbLayerOpacity(density: AuroraDensity): Float = if (density == AuroraDensity.SUBTLE) 0.55f else 1f

/** The ribbon is always translucent; SUBTLE dims it further. */
internal fun auroraRibbonLayerOpacity(density: AuroraDensity): Float = if (density == AuroraDensity.SUBTLE) 0.35f else 0.55f

/** Particles are the most motion-heavy layer: FULL density only, never under Reduce Motion. */
internal fun auroraShowsParticleLayer(density: AuroraDensity, reduceMotion: Boolean): Boolean = density == AuroraDensity.FULL && !reduceMotion

/** Reduce Motion pins every drift phase to the same static 0f frame. */
internal fun auroraResolvedPhase(reduceMotion: Boolean, livePhase: () -> Float): () -> Float = if (reduceMotion) auroraStaticPhase else livePhase
