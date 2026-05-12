package com.openburnbar.ui.chartstudio

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Floating action button that's visible whenever Chart Studio is in
 * `Minimized` mode. Tapping restores Studio; dragging repositions the FAB
 * (position persisted via [ChartStudioPresenter.setFabOffset]).
 *
 * Mirrors iOS `ChartStudioFloatingButton` — 56dp aureate-gradient capsule
 * with a breathing glow when minimized state is fresh.
 */
@Composable
fun ChartStudioFab(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val offset by ChartStudioPresenter.fabOffset.collectAsState()
    val reduce = LocalAuroraReduceMotion.current

    val transition = rememberInfiniteTransition(label = "fab-pulse")
    val pulse by transition.animateFloat(
        initialValue = 0.85f,
        targetValue = 1.05f,
        animationSpec = infiniteRepeatable(
            animation = tween(1600, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "fab-pulse-scale"
    )
    val scale = if (reduce) 1f else pulse

    val density = LocalDensity.current

    Box(
        modifier = modifier
            .graphicsLayer {
                translationX = offset.x
                translationY = offset.y
                scaleX = scale
                scaleY = scale
            }
            .size(56.dp)
            .clip(CircleShape)
            .background(
                Brush.radialGradient(
                    colors = listOf(
                        AuroraColors.amber,
                        AuroraColors.ember,
                        AuroraColors.blaze.copy(alpha = 0.85f)
                    )
                )
            )
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.30f),
                shape = CircleShape
            )
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragEnd = { HapticBus.light(context) },
                    onDrag = { change, drag ->
                        change.consume()
                        ChartStudioPresenter.setFabOffset(
                            Offset(offset.x + drag.x, offset.y + drag.y),
                            context
                        )
                    }
                )
            }
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val tap = event.changes.singleOrNull()
                        if (tap != null && tap.changedToUp()) {
                            HapticBus.medium(context)
                            ChartStudioPresenter.restore()
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = Icons.Filled.AutoAwesome,
            contentDescription = "Chart Studio",
            tint = Color.White,
            modifier = Modifier.size(26.dp)
        )
    }
}

// Compose's pointer-event extensions on PointerInputChange.changedToUp() live in
// `androidx.compose.ui.input.pointer` — but the import keeps the call concise.
private fun androidx.compose.ui.input.pointer.PointerInputChange.changedToUp(): Boolean =
    pressed.not() && previousPressed
