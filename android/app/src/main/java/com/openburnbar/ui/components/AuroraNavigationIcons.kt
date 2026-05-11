package com.openburnbar.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

/**
 * Five tab icons for the OpenBurnBar bottom navigation tray.
 * Selected state uses accent gradient; unselected uses muted mercury.
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
    userDisplayName: String? = null
) {
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.88f else if (isSelected) 1.06f else 1f,
        animationSpec = spring(stiffness = 400f, dampingRatio = 0.7f),
        label = "iconScale"
    )

    val tint = if (isSelected) {
        Brush.linearGradient(destination.gradientColors)
    } else {
        SolidColor(AuroraColors.hermesMercury.copy(alpha = 0.78f))
    }

    Box(
        modifier = Modifier
            .size(size.dp),
        contentAlignment = Alignment.Center
    ) {
        when (destination) {
            AuroraNavDestination.PULSE -> Icon(
                imageVector = Icons.AutoMirrored.Filled.ShowChart,
                contentDescription = "Pulse",
                modifier = Modifier.size(size.dp),
                tint = if (isSelected) destination.accent else AuroraColors.hermesMercury.copy(alpha = 0.78f)
            )
            AuroraNavDestination.BURN -> Icon(
                imageVector = Icons.Filled.LocalFireDepartment,
                contentDescription = "Burn",
                modifier = Modifier.size(size.dp),
                tint = if (isSelected) destination.accent else AuroraColors.hermesMercury.copy(alpha = 0.78f)
            )
            AuroraNavDestination.STREAMS -> Icon(
                imageVector = Icons.Filled.Tv,
                contentDescription = "Streams",
                modifier = Modifier.size(size.dp),
                tint = if (isSelected) destination.accent else AuroraColors.hermesMercury.copy(alpha = 0.78f)
            )
            AuroraNavDestination.HERMES -> {
                // Hermes robot head — simple circle with antenna
                Box(contentAlignment = Alignment.Center, modifier = Modifier.size(size.dp)) {
                    Box(
                        modifier = Modifier
                            .size((size * 0.7).dp)
                            .clip(CircleShape)
                            .background(
                                if (isSelected) destination.accent.copy(alpha = 0.2f)
                                else AuroraColors.hermesMercury.copy(alpha = 0.15f)
                            )
                    )
                    Text(
                        text = "H",
                        fontSize = (size * 0.45).sp,
                        fontWeight = FontWeight.Bold,
                        color = if (isSelected) destination.accent else AuroraColors.hermesMercury.copy(alpha = 0.78f)
                    )
                }
            }
            AuroraNavDestination.YOU -> {
                val initials = userDisplayName?.split(" ")?.map { it.firstOrNull()?.uppercase() ?: "" }?.take(2)?.joinToString("")
                    ?: userDisplayName?.firstOrNull()?.uppercase()
                    ?: "?"
                Box(contentAlignment = Alignment.Center, modifier = Modifier.size(size.dp)) {
                    if (isSelected) {
                        Box(
                            modifier = Modifier
                                .size((size * 0.8).dp)
                                .clip(CircleShape)
                                .background(destination.accent.copy(alpha = 0.2f))
                        )
                    }
                    if (initials != null && initials != "?") {
                        Text(
                            text = initials,
                            fontSize = (size * 0.4).sp,
                            fontWeight = FontWeight.Bold,
                            color = if (isSelected) destination.accent else AuroraColors.hermesMercury.copy(alpha = 0.78f)
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Filled.Person,
                            contentDescription = "You",
                            modifier = Modifier.size((size * 0.65).dp),
                            tint = if (isSelected) destination.accent else AuroraColors.hermesMercury.copy(alpha = 0.78f)
                        )
                    }
                }
            }
        }
    }
}
