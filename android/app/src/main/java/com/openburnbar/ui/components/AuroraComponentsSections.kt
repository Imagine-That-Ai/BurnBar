@file:Suppress("MagicNumber", "LongParameterList")
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
                        if (isDark) {
                            Color.Black.copy(alpha = 0.32f)
                        } else {
                            Color(0xFF1C2014).copy(alpha = 0.10f)
                        },
                    ),
                    center = androidx.compose.ui.geometry.Offset(0.5f, 0.5f),
                    radius = 0.8f,
                ),
            ),
    )
}

@Composable
internal fun AuroraBackdropAnimatedLayers(
    isDark: Boolean,
    density: AuroraDensity,
    reduceMotion: Boolean,
    phase: Float,
    ribbonPhase: Float,
) {
    if (density == AuroraDensity.MINIMAL) return
    Box(modifier = Modifier.fillMaxSize()) {
        OrbLayer(
            isDark = isDark,
            phase = if (reduceMotion) 0f else phase,
            opacity = if (density == AuroraDensity.SUBTLE) 0.55f else 1f,
            modifier = Modifier.fillMaxSize(),
        )
        RibbonLayer(
            isDark = isDark,
            ribbonPhase = if (reduceMotion) 0f else ribbonPhase,
            opacity = if (density == AuroraDensity.SUBTLE) 0.35f else 0.55f,
            modifier =
            Modifier
                .fillMaxWidth()
                .height(220.dp)
                .align(androidx.compose.ui.Alignment.TopCenter),
        )
        if (density == AuroraDensity.FULL && !reduceMotion) {
            ParticleLayer(modifier = Modifier.fillMaxSize())
        }
    }
}
