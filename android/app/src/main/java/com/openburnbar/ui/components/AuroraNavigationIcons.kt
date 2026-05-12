package com.openburnbar.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.aurora.BurnGlyph
import com.openburnbar.ui.components.aurora.HermesGlyph
import com.openburnbar.ui.components.aurora.PulseGlyph
import com.openburnbar.ui.components.aurora.StreamsGlyph
import com.openburnbar.ui.components.aurora.YouGlyph
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

/**
 * Five tab icons for the OpenBurnBar bottom navigation tray. Each branch
 * delegates to a custom Compose Canvas glyph in `components/aurora/` that
 * mirrors the iOS `AuroraNavigationIcons` Path/Canvas drawings (heartbeat,
 * living-fire flame, vintage CRT TV with SMPTE bars, robot face with antenna
 * heart, avatar + rotating halo).
 */
enum class AuroraNavDestination(val label: String) {
    PULSE("Pulse"),
    BURN("Burn"),
    STREAMS("Streams"),
    HERMES("Hermes"),
    YOU("You");

    val accent: Color
        get() = when (this) {
            PULSE -> AuroraColors.ember
            BURN -> AuroraColors.amber
            STREAMS -> AuroraColors.whimsy
            HERMES -> AuroraColors.hermesAureate
            YOU -> AuroraColors.blaze
        }

    val gradientColors: List<Color>
        get() = when (this) {
            PULSE -> listOf(AuroraColors.ember, AuroraColors.amber)
            BURN -> listOf(AuroraColors.amber, AuroraColors.blaze)
            STREAMS -> listOf(AuroraColors.whimsy, AuroraColors.whimsy.copy(alpha = 0.55f))
            HERMES -> AuroraGradients.mercuryGradient
            YOU -> listOf(AuroraColors.blaze, AuroraColors.ember)
        }
}

@Composable
fun AuroraNavIcon(
    destination: AuroraNavDestination,
    size: Int = 26,
    isSelected: Boolean,
    isPressed: Boolean = false,
    userDisplayName: String? = null,
    userPhotoUrl: String? = null
) {
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.88f else if (isSelected) 1.06f else 1f,
        animationSpec = spring(stiffness = 400f, dampingRatio = 0.7f),
        label = "iconScale"
    )

    Box(
        modifier = Modifier
            .size(size.dp)
            .graphicsLayer { scaleX = scale; scaleY = scale },
        contentAlignment = Alignment.Center
    ) {
        when (destination) {
            AuroraNavDestination.PULSE   -> PulseGlyph(size = size.dp, isSelected = isSelected)
            AuroraNavDestination.BURN    -> BurnGlyph(size = size.dp, isSelected = isSelected)
            AuroraNavDestination.STREAMS -> StreamsGlyph(size = size.dp, isSelected = isSelected)
            AuroraNavDestination.HERMES  -> HermesGlyph(size = size.dp, isSelected = isSelected)
            AuroraNavDestination.YOU     -> {
                val initials = userDisplayName
                    ?.split(" ", "-")
                    ?.mapNotNull { it.firstOrNull()?.uppercaseChar() }
                    ?.take(2)
                    ?.joinToString("")
                    ?.takeIf { it.isNotBlank() }
                YouGlyph(
                    size = size.dp,
                    isSelected = isSelected,
                    photoUrl = userPhotoUrl,
                    initials = initials
                )
            }
        }
    }
}
