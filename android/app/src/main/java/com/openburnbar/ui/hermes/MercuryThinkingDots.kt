package com.openburnbar.ui.hermes

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.compositionLocalWithComputedDefaultOf

// MARK: - MercuryThinkingDots
//
// Three 6dp circles painted with the mercury gradient that pool and
// separate like liquid metal while Hermes is thinking. Replaces a
// spinner. Mirrors iOS `MercuryPoolDots` in
// `AgentLens/Views/Dashboard/ProjectsView.swift`:
//
//   scale start:  [1.0, 0.8, 1.0]
//   scale target: [1.4, 1.0, 0.8]
//   opacity start:  [0.55, 1.0, 0.6]
//   opacity target: [1.0, 0.55, 1.0]
//   1.8s easeInOut, repeat, autoreverses
//
// When reduce-motion is on we paint the start frame synchronously.

@Composable
fun MercuryThinkingDots(modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "mercuryPool")
    val t by transition.animateFloat(
        initialValue = 0f,
        targetValue = if (reduceMotion) 0f else 1f,
        animationSpec = infiniteRepeatable(
            animation = keyframes {
                durationMillis = 1800
                0f at 0
                1f at 1800
            },
            repeatMode = RepeatMode.Reverse
        ),
        label = "mercuryPoolPhase"
    )

    val startScale = floatArrayOf(1.0f, 0.8f, 1.0f)
    val targetScale = floatArrayOf(1.4f, 1.0f, 0.8f)
    val startAlpha = floatArrayOf(0.55f, 1.0f, 0.6f)
    val targetAlpha = floatArrayOf(1.0f, 0.55f, 1.0f)

    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        for (i in 0..2) {
            val scale = startScale[i] + (targetScale[i] - startScale[i]) * t
            val alpha = startAlpha[i] + (targetAlpha[i] - startAlpha[i]) * t
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .scale(scale)
                    .alpha(alpha)
                    .clip(CircleShape)
                    .background(Brush.linearGradient(colors = AuroraGradients.mercuryGradient))
            )
        }
    }
}
