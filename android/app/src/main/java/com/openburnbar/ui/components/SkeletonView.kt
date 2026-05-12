package com.openburnbar.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraRadius

/**
 * Shimmer skeleton placeholder for loading states.
 */

@Composable
fun SkeletonView(
    modifier: Modifier = Modifier,
    cornerRadius: Int = AuroraRadius.lg
) {
    val infiniteTransition = rememberInfiniteTransition()
    val shimmerOffset by infiniteTransition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        )
    )

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(cornerRadius.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        MaterialTheme.colorScheme.surface,
                        MaterialTheme.colorScheme.surfaceVariant,
                        MaterialTheme.colorScheme.surface
                    ),
                    start = Offset(shimmerOffset * 2000f - 1000f, 0f),
                    end = Offset(shimmerOffset * 2000f + 1000f, 0f)
                )
            )
    )
}

@Composable
fun SkeletonCard(
    height: Int = 120,
    modifier: Modifier = Modifier
) {
    SkeletonView(
        modifier = modifier
            .fillMaxWidth()
            .height(height.dp)
    )
}

@Composable
fun SkeletonText(
    widthFraction: Float = 0.6f,
    height: Int = 14,
    modifier: Modifier = Modifier
) {
    SkeletonView(
        modifier = modifier
            .fillMaxWidth(widthFraction)
            .height(height.dp)
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
    )
}
