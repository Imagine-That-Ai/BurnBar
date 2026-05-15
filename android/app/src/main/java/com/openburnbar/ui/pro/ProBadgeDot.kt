package com.openburnbar.ui.pro

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.semantics.invisibleToUser
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — the whisper. 6dp foil dot that breathes for free users.
 * Lives on persistent surfaces (You-tab icon corner, FAB) so the presence
 * of Pro is never invisible without being intrusive.
 */
@Composable
fun ProBadgeDot(
    modifier: Modifier = Modifier,
    pulse: ProBadgePulse = ProBadgePulse.Breathing,
    diameter: Dp = ProLayout.badgeDotDp.dp
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val breathing = if (pulse == ProBadgePulse.Breathing && !reduceMotion) {
        rememberInfiniteTransition(label = "proBadgeBreath").animateFloat(
            initialValue = 0.6f,
            targetValue = 1.0f,
            animationSpec = infiniteRepeatable(
                animation = tween(ProMotion.breathingDurationMs, easing = LinearEasing),
                repeatMode = RepeatMode.Reverse
            ),
            label = "proBadgeBreathPhase"
        ).value
    } else 1.0f

    Box(
        modifier = modifier
            .size(diameter)
            .clip(CircleShape)
            .background(
                brush = Brush.linearGradient(AuroraGradients.mercuryGradient),
                shape = CircleShape
            )
            .border(0.7.dp, ProPalette.aureate.copy(alpha = 0.95f), CircleShape)
            .alpha(breathing)
            .semantics(mergeDescendants = true) { invisibleToUser() }
    )
}

enum class ProBadgePulse {
    Breathing,
    Still
}
