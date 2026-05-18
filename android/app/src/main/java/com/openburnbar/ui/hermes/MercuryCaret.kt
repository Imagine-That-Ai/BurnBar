package com.openburnbar.ui.hermes

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

// MARK: - MercuryCaret
//
// 6×14dp metallic-platinum bar that gently fades on/off while Hermes is
// actively streaming. Mirrors iOS `MercuryCaret` from
// `AgentLens/Views/Dashboard/ProjectsView.swift`:
//
//   • Fill: `hermesAureate`.
//   • 0.55s easeInOut, repeat, autoreverses between 1.0 and 0.2 alpha.
//   • Reduce-motion: painted at full opacity, no animation.

@Composable
fun MercuryCaret(modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "mercuryCaret")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = if (reduceMotion) 1f else 0.2f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 550, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "mercuryCaretAlpha"
    )
    Box(
        modifier = modifier
            .size(width = 6.dp, height = 14.dp)
            .alpha(alpha)
            .clip(RoundedCornerShape(1.dp))
            .background(AuroraColors.hermesAureate)
    )
}
