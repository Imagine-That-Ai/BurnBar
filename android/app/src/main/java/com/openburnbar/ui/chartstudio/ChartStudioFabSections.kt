// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.components.liquidGlassCircleButton
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

@Composable
internal fun ChartStudioFabContent(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val offset by ChartStudioPresenter.fabOffset.collectAsState()
    val reduce = LocalAuroraReduceMotion.current
    val scale = chartStudioFabPulseScale(reduceMotion = reduce)

    ChartStudioFabSurface(
        modifier = modifier,
        offset = offset,
        scale = scale,
        onDrag = { drag ->
            ChartStudioPresenter.setFabOffset(
                Offset(offset.x + drag.x, offset.y + drag.y),
                context,
            )
        },
        onDragEnd = { HapticBus.light(context) },
        onTap = {
            HapticBus.medium(context)
            ChartStudioPresenter.restore()
        },
    )
}

@Composable
private fun chartStudioFabPulseScale(reduceMotion: Boolean): Float {
    if (reduceMotion) return 1f
    val transition = rememberInfiniteTransition(label = "fab-pulse")
    val pulse by transition.animateFloat(
        initialValue = 0.85f,
        targetValue = 1.05f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1600, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "fab-pulse-scale",
    )
    return pulse
}

@Composable
private fun ChartStudioFabSurface(modifier: Modifier, offset: Offset, scale: Float, onDrag: (Offset) -> Unit, onDragEnd: () -> Unit, onTap: () -> Unit) {
    Box(
        modifier =
        modifier
            .graphicsLayer {
                translationX = offset.x
                translationY = offset.y
                scaleX = scale
                scaleY = scale
            }
            .liquidGlassCircleButton(diameter = 56.dp, tint = AuroraColors.ember)
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.30f),
                shape = CircleShape,
            )
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragEnd = { onDragEnd() },
                    onDrag = { change, drag ->
                        change.consume()
                        onDrag(drag)
                    },
                )
            }
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val tap = event.changes.singleOrNull()
                        if (tap != null && tap.changedToUp()) {
                            onTap()
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.AutoAwesome,
            contentDescription = "Chart Studio",
            tint = AuroraColors.ember,
            modifier = Modifier.size(26.dp),
        )
    }
}

private fun androidx.compose.ui.input.pointer.PointerInputChange.changedToUp(): Boolean = pressed.not() && previousPressed
