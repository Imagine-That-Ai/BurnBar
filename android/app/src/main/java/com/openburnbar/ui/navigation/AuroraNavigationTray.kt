// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.navigation

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraNavDestination

/**
 * Custom bottom navigation tray matching the iOS AuroraNavigationTray.
 * Floating pill shape with glass-like surface, accent dot under selected tab,
 * custom canvas icons, and swipe-to-switch gesture support.
 */

@Composable
fun AuroraNavigationTray(
    destinations: List<AuroraNavDestination>,
    selectedDestination: AuroraNavDestination,
    onDestinationSelected: (AuroraNavDestination) -> Unit,
    userDisplayName: String? = null,
    userPhotoUrl: String? = null,
    isCloudMember: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val isDark = isSystemInDarkTheme()
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var isDragging by remember { mutableStateOf(false) }
    val currentIndex = destinations.indexOf(selectedDestination).coerceAtLeast(0)

    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(bottom = AuroraTrayPillBottomInset),
        contentAlignment = Alignment.Center,
    ) {
        AuroraNavigationTrayPill(
            model =
            AuroraTrayPillModel(
                destinations = destinations,
                selectedDestination = selectedDestination,
                isDark = isDark,
                userDisplayName = userDisplayName,
                userPhotoUrl = userPhotoUrl,
                isCloudMember = isCloudMember,
            ),
            onDestinationSelected = onDestinationSelected,
            dragCallbacks =
            AuroraTrayDragCallbacks(
                onDragStart = { isDragging = true },
                onDragEnd = {
                    isDragging = false
                    dragOffset = 0f
                },
                onDragCancel = {
                    isDragging = false
                    dragOffset = 0f
                },
                onHorizontalDrag = { dragAmount ->
                    val resistance =
                        when {
                            currentIndex == 0 && dragAmount > 0 -> 0.30f
                            currentIndex == destinations.size - 1 && dragAmount < 0 -> 0.30f
                            else -> 0.55f
                        }
                    dragOffset += dragAmount * resistance
                },
            ),
        )
    }

    AuroraTraySwipeNavigationEffect(
        isDragging = isDragging,
        dragOffset = dragOffset,
        currentIndex = currentIndex,
        destinations = destinations,
        onDestinationSelected = onDestinationSelected,
        onResetDragOffset = { dragOffset = 0f },
    )
}
