package com.openburnbar.ui.chartstudio

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.ChartStudioMode
import com.openburnbar.data.stores.ChartStudioPresenter
import com.openburnbar.ui.theme.AuroraColors

@Composable
fun ChartStudioFloatingButton(
    presenter: ChartStudioPresenter = viewModel()
) {
    val mode by presenter.mode.collectAsState()
    val savedOffsetX by presenter.fabOffsetX.collectAsState()
    val savedOffsetY by presenter.fabOffsetY.collectAsState()

    var offsetX by remember { mutableFloatStateOf(savedOffsetX) }
    var offsetY by remember { mutableFloatStateOf(savedOffsetY) }

    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val pulse by infiniteTransition.animateFloat(
        initialValue = 28f,
        targetValue = 38f,
        animationSpec = infiniteRepeatable(
            animation = tween(1600, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse"
    )

    val density = LocalDensity.current
    val screenWidth = with(density) { LocalConfiguration.current.screenWidthDp.dp.toPx() }
    val screenHeight = with(density) { LocalConfiguration.current.screenHeightDp.dp.toPx() }

    AnimatedVisibility(
        visible = mode == ChartStudioMode.MINIMIZED,
        enter = scaleIn(initialScale = 0.6f) + fadeIn(),
        exit = scaleOut(targetScale = 0.6f) + fadeOut()
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
            val baseX = screenWidth - 72f
            val baseY = screenHeight - 200f
            val fabSize = 56f

            IconButton(
                onClick = { presenter.restore() },
                modifier = Modifier
                    .offset {
                        androidx.compose.ui.unit.IntOffset(
                            (baseX + offsetX - fabSize).toInt(),
                            (baseY + offsetY - fabSize).toInt()
                        )
                    }
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(
                        Brush.radialGradient(
                            colors = listOf(
                                AuroraColors.hermesAureate.copy(alpha = 0.55f),
                                AuroraColors.hermesAureate.copy(alpha = 0f)
                            ),
                            radius = pulse
                        )
                    )
                    .border(
                        1.dp,
                        Brush.linearGradient(listOf(AuroraColors.hermesMercury, AuroraColors.hermesAureate)),
                        CircleShape
                    )
                    .pointerInput(Unit) {
                        detectDragGestures { change, dragAmount ->
                            change.consume()
                            val newX = offsetX + dragAmount.x
                            val newY = offsetY + dragAmount.y
                            // Clamp to screen bounds
                            offsetX = newX.coerceIn(-baseX + fabSize, baseX - fabSize)
                            offsetY = newY.coerceIn(-baseY + fabSize + 100f, baseY - fabSize - 100f)
                        }
                    }
            ) {
                Icon(
                    Icons.Filled.AutoGraph,
                    contentDescription = "Restore Chart Studio",
                    tint = AuroraColors.hermesAureate
                )
            }
        }
    }
}
