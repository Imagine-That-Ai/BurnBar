package com.openburnbar.ui.navigation

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.*
import com.openburnbar.ui.theme.AuroraColors

/**
 * Custom bottom navigation tray matching the iOS AuroraNavigationTray.
 * Floating pill shape with glass-like surface, accent dot under selected tab,
 * custom canvas icons, and swipe-to-switch gesture support.
 */

private val PillHeight = 50.dp
private val IconSize = 26.dp
private val TabWidth = 52.dp
private val PillSidePadding = 6.dp
private val PillBottomInset = 14.dp

@Composable
fun AuroraNavigationTray(
    destinations: List<AuroraNavDestination>,
    selectedDestination: AuroraNavDestination,
    onDestinationSelected: (AuroraNavDestination) -> Unit,
    userDisplayName: String? = null,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var isDragging by remember { mutableStateOf(false) }

    val currentIndex = destinations.indexOf(selectedDestination).coerceAtLeast(0)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp)
            .padding(bottom = PillBottomInset),
        contentAlignment = Alignment.Center
    ) {
        Row(
            modifier = Modifier
                .height(PillHeight)
                .clip(RoundedCornerShape(PillHeight))
                .background(
                    MaterialTheme.colorScheme.surface.copy(alpha = 0.72f)
                )
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            AuroraColors.ember.copy(alpha = if (isDark) 0.07f else 0.04f),
                            Color.Transparent,
                            AuroraColors.amber.copy(alpha = if (isDark) 0.05f else 0.03f)
                        ),
                        start = androidx.compose.ui.geometry.Offset(0f, 0f),
                        end = androidx.compose.ui.geometry.Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY)
                    )
                )
                .shadow(
                    elevation = 10.dp,
                    shape = RoundedCornerShape(PillHeight),
                    ambientColor = Color.Black.copy(alpha = 0.18f),
                    spotColor = Color.Black.copy(alpha = 0.18f)
                )
                .pointerInput(destinations, selectedDestination) {
                    detectHorizontalDragGestures(
                        onDragStart = { isDragging = true },
                        onDragEnd = {
                            isDragging = false
                            dragOffset = 0f
                        },
                        onDragCancel = {
                            isDragging = false
                            dragOffset = 0f
                        },
                        onHorizontalDrag = { change, dragAmount ->
                            change.consume()
                            val resistance = when {
                                currentIndex == 0 && dragAmount > 0 -> 0.30f
                                currentIndex == destinations.size - 1 && dragAmount < 0 -> 0.30f
                                else -> 0.55f
                            }
                            dragOffset += dragAmount * resistance
                        }
                    )
                },
            horizontalArrangement = Arrangement.spacedBy(0.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically
        ) {
            destinations.forEach { dest ->
                val isSelected = dest == selectedDestination
                AuroraTabItem(
                    destination = dest,
                    isSelected = isSelected,
                    userDisplayName = if (dest == AuroraNavDestination.YOU) userDisplayName else null,
                    onSelected = {
                        if (!isSelected) {
                            onDestinationSelected(dest)
                            HapticBus.tabChange(context)
                        }
                    }
                )
            }
        }
    }

    // Swipe-to-switch logic on drag end
    LaunchedEffect(isDragging, dragOffset) {
        if (!isDragging && kotlin.math.abs(dragOffset) > 36f) {
            val newIndex = when {
                dragOffset < -36f && currentIndex < destinations.size - 1 -> currentIndex + 1
                dragOffset > 36f && currentIndex > 0 -> currentIndex - 1
                else -> currentIndex
            }
            if (newIndex != currentIndex) {
                onDestinationSelected(destinations[newIndex])
                HapticBus.tabChange(context)
            }
            dragOffset = 0f
        }
    }
}

@Composable
private fun AuroraTabItem(
    destination: AuroraNavDestination,
    isSelected: Boolean,
    userDisplayName: String?,
    onSelected: () -> Unit
) {
    val dotScale by animateFloatAsState(
        targetValue = if (isSelected) 1f else 0.4f,
        animationSpec = spring(stiffness = 400f, dampingRatio = 0.72f),
        label = "dotScale"
    )
    val dotAlpha by animateFloatAsState(
        targetValue = if (isSelected) 1f else 0f,
        animationSpec = tween(200),
        label = "dotAlpha"
    )

    Box(
        modifier = Modifier
            .width(TabWidth)
            .height(PillHeight - 6.dp)
            .clip(CircleShape)
            .clickableNoRipple(onClick = onSelected),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            AuroraNavIcon(
                destination = destination,
                size = IconSize.value.toInt(),
                isSelected = isSelected,
                userDisplayName = userDisplayName
            )

            Spacer(modifier = Modifier.height(4.dp))

            // Accent dot
            Box(
                modifier = Modifier
                    .size(4.dp)
                    .graphicsLayer {
                        scaleX = dotScale
                        scaleY = dotScale
                        alpha = dotAlpha
                    }
                    .clip(CircleShape)
                    .background(destination.accent)
            )
        }
    }
}

private inline fun Modifier.clickableNoRipple(crossinline onClick: () -> Unit): Modifier =
    composed {
        clickable(
            indication = null,
            interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
            onClick = { onClick() }
        )
    }
