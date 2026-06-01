@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.navigation

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraNavDestination
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.theme.AuroraColors

internal val AuroraTrayPillHeight = 50.dp
internal val AuroraTrayIconSize = 26.dp
internal val AuroraTrayTabWidth = 52.dp
internal val AuroraTrayPillBottomInset = 14.dp

enum class CloudIndicator { None, Free, Member }

internal data class AuroraTrayPillModel(
    val destinations: List<AuroraNavDestination>,
    val selectedDestination: AuroraNavDestination,
    val isDark: Boolean,
    val userDisplayName: String?,
    val userPhotoUrl: String?,
    val isCloudMember: Boolean,
)

internal data class AuroraTrayDragCallbacks(
    val onDragStart: () -> Unit,
    val onDragEnd: () -> Unit,
    val onDragCancel: () -> Unit,
    val onHorizontalDrag: (Float) -> Unit,
)

@Composable
internal fun AuroraTabItem(
    destination: AuroraNavDestination,
    isSelected: Boolean,
    userDisplayName: String?,
    userPhotoUrl: String?,
    cloudIndicator: CloudIndicator = CloudIndicator.None,
    onSelected: () -> Unit,
) {
    val dotScale by animateFloatAsState(
        targetValue = if (isSelected) 1f else 0.4f,
        animationSpec = spring(stiffness = 400f, dampingRatio = 0.72f),
        label = "dotScale",
    )
    val dotAlpha by animateFloatAsState(
        targetValue = if (isSelected) 1f else 0f,
        animationSpec = tween(200),
        label = "dotAlpha",
    )

    Box(
        modifier =
        Modifier
            .width(AuroraTrayTabWidth)
            .height(AuroraTrayPillHeight - 6.dp)
            .clip(CircleShape)
            .clickableNoRipple(onClick = onSelected),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box {
                AuroraNavIcon(
                    destination = destination,
                    size = AuroraTrayIconSize.value.toInt(),
                    isSelected = isSelected,
                    userDisplayName = userDisplayName,
                    userPhotoUrl = userPhotoUrl,
                )

                Box(
                    modifier =
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 6.dp, y = (-2).dp),
                ) {
                    AuroraTabCloudIndicator(cloudIndicator = cloudIndicator)
                }
            }

            Spacer(modifier = Modifier.height(4.dp))

            Box(
                modifier =
                Modifier
                    .size(4.dp)
                    .graphicsLayer {
                        scaleX = dotScale
                        scaleY = dotScale
                        alpha = dotAlpha
                    }
                    .clip(CircleShape)
                    .background(destination.accent),
            )
        }
    }
}

@Composable
private fun AuroraTabCloudIndicator(cloudIndicator: CloudIndicator) {
    when (cloudIndicator) {
        CloudIndicator.None -> {}
        CloudIndicator.Free ->
            com.openburnbar.ui.pro.ProBadgeDot(
                pulse = com.openburnbar.ui.pro.ProBadgePulse.Breathing,
                diameter = 7.dp,
            )
        CloudIndicator.Member ->
            com.openburnbar.ui.pro.CloudBadge(
                size = com.openburnbar.ui.pro.CloudBadgeSize.Small,
                modifier =
                Modifier.graphicsLayer {
                    scaleX = 0.55f
                    scaleY = 0.55f
                },
            )
    }
}

internal inline fun Modifier.clickableNoRipple(crossinline onClick: () -> Unit): Modifier = composed {
    clickable(
        indication = null,
        interactionSource = remember { MutableInteractionSource() },
        onClick = { onClick() },
    )
}

private fun Modifier.auroraTrayPillChrome(isDark: Boolean): Modifier =
    this
        .height(AuroraTrayPillHeight)
        .clip(RoundedCornerShape(AuroraTrayPillHeight))
        .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.72f))
        .background(
            Brush.linearGradient(
                colors =
                listOf(
                    AuroraColors.ember.copy(alpha = if (isDark) 0.07f else 0.04f),
                    Color.Transparent,
                    AuroraColors.amber.copy(alpha = if (isDark) 0.05f else 0.03f),
                ),
                start = androidx.compose.ui.geometry.Offset(0f, 0f),
                end = androidx.compose.ui.geometry.Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
            ),
        )
        .shadow(
            elevation = 10.dp,
            shape = RoundedCornerShape(AuroraTrayPillHeight),
            ambientColor = Color.Black.copy(alpha = 0.18f),
            spotColor = Color.Black.copy(alpha = 0.18f),
        )

private fun Modifier.auroraTrayPillDragGesture(
    destinations: List<AuroraNavDestination>,
    selectedDestination: AuroraNavDestination,
    dragCallbacks: AuroraTrayDragCallbacks,
): Modifier =
    pointerInput(destinations, selectedDestination) {
        detectHorizontalDragGestures(
            onDragStart = { dragCallbacks.onDragStart() },
            onDragEnd = { dragCallbacks.onDragEnd() },
            onDragCancel = { dragCallbacks.onDragCancel() },
            onHorizontalDrag = { change, dragAmount ->
                change.consume()
                dragCallbacks.onHorizontalDrag(dragAmount)
            },
        )
    }

@Composable
internal fun AuroraTraySwipeNavigationEffect(
    isDragging: Boolean,
    dragOffset: Float,
    currentIndex: Int,
    destinations: List<AuroraNavDestination>,
    onDestinationSelected: (AuroraNavDestination) -> Unit,
    onResetDragOffset: () -> Unit,
) {
    val context = LocalContext.current
    LaunchedEffect(isDragging, dragOffset) {
        if (!isDragging && kotlin.math.abs(dragOffset) > 36f) {
            val newIndex =
                when {
                    dragOffset < -36f && currentIndex < destinations.size - 1 -> currentIndex + 1
                    dragOffset > 36f && currentIndex > 0 -> currentIndex - 1
                    else -> currentIndex
                }
            if (newIndex != currentIndex) {
                onDestinationSelected(destinations[newIndex])
                HapticBus.tabChange(context)
            }
            onResetDragOffset()
        }
    }
}

@Composable
internal fun AuroraNavigationTrayPill(
    model: AuroraTrayPillModel,
    onDestinationSelected: (AuroraNavDestination) -> Unit,
    dragCallbacks: AuroraTrayDragCallbacks,
) {
    val context = LocalContext.current
    Row(
        modifier =
        Modifier
            .auroraTrayPillChrome(model.isDark)
            .auroraTrayPillDragGesture(model.destinations, model.selectedDestination, dragCallbacks),
        horizontalArrangement = Arrangement.spacedBy(0.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        model.destinations.forEach { dest ->
            val isSelected = dest == model.selectedDestination
            AuroraTabItem(
                destination = dest,
                isSelected = isSelected,
                userDisplayName = if (dest == AuroraNavDestination.YOU) model.userDisplayName else null,
                userPhotoUrl = if (dest == AuroraNavDestination.YOU) model.userPhotoUrl else null,
                cloudIndicator =
                if (dest == AuroraNavDestination.YOU) {
                    if (model.isCloudMember) CloudIndicator.Member else CloudIndicator.Free
                } else {
                    CloudIndicator.None
                },
                onSelected = {
                    if (!isSelected) {
                        onDestinationSelected(dest)
                        HapticBus.tabChange(context)
                    }
                },
            )
        }
    }
}
