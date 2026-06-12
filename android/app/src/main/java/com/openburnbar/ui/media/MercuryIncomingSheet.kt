// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Compose port of iOS `MercuryIncomingSheet.swift`. Rendered full-screen
 * by `IncomingCallActivity` when a Mercury call arrives. Pulses a
 * mercury-stroked circle around the caller initial; pulse is suppressed
 * under reduce-motion.
 */
@Composable
fun MercuryIncomingSheet(pairedDeviceName: String, callerInitial: String, onAccept: () -> Unit, onDecline: () -> Unit) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val infinite = rememberInfiniteTransition(label = "mercuryIncomingPulse")
    val scale by infinite.animateFloat(
        initialValue = 1f,
        targetValue = if (reduceMotion) 1f else 1.08f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "mercuryIncomingPulseScale",
    )

    val mercuryBrush =
        Brush.linearGradient(
            listOf(
                AuroraColors.hermesMercury.copy(alpha = 0.85f),
                AuroraColors.hermesAureate.copy(alpha = 0.7f),
                AuroraColors.hermesMercury.copy(alpha = 0.85f),
            ),
        )

    Box(
        modifier = Modifier.fillMaxSize().background(Color.Black),
        contentAlignment = Alignment.Center,
    ) {
        MercuryIncomingSheetCard(
            pairedDeviceName = pairedDeviceName,
            callerInitial = callerInitial,
            pulseScale = scale,
            mercuryBrush = mercuryBrush,
            onAccept = onAccept,
            onDecline = onDecline,
        )
    }
}
