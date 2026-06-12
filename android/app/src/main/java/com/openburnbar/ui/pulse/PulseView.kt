// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.theme.AuroraColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PulseView(
    dashboardStore: DashboardStore = viewModel(),
    quotaStore: QuotaStore = viewModel(),
    activityStore: ActivityStore = viewModel(),
    demoDataStore: DemoDataStore = viewModel(),
    onNavigateToBurn: (() -> Unit)? = null,
    onNavigateToHermes: (() -> Unit)? = null,
    onNavigateToStreams: (() -> Unit)? = null,
    userStore: UserStore = viewModel(),
    liveMetricsStore: PulseLiveMetricsStore = viewModel(),
) {
    val uiState = collectPulseViewUiState(dashboardStore, demoDataStore, userStore)
    PulseViewDataEffects(
        isSignedIn = uiState.isSignedIn,
        dashboardStore = dashboardStore,
        quotaStore = quotaStore,
        activityStore = activityStore,
        liveMetricsStore = liveMetricsStore,
    )
    PulseViewScaffold(
        state =
        PulseViewScaffoldState(
            isSignedIn = uiState.isSignedIn,
            photoUrl = uiState.photoUrl,
            displayName = uiState.displayName,
            isLoading = uiState.isLoading,
            error = uiState.error,
            rollups = uiState.rollups,
            onRetry = { dashboardStore.refresh() },
        ),
    ) {
        uiState.rollups?.let { rollups ->
            PulseViewContent(
                model =
                PulseContentModel(
                    rollups = rollups,
                    displayMode = uiState.displayMode,
                    timelineScope = uiState.timelineScope,
                    liveMetricsStore = liveMetricsStore,
                    quotaStore = quotaStore,
                    activityStore = activityStore,
                    demoIsSeeding = uiState.demoIsSeeding,
                    demoMessage = uiState.demoMessage,
                    demoError = uiState.demoError,
                ),
                navigation =
                PulseContentNavigation(
                    onDisplayModeChange = uiState.onDisplayModeChange,
                    onTimelineChange = uiState.onTimelineChange,
                    onLoadDemoData = {
                        demoDataStore.seed {
                            dashboardStore.refresh()
                            quotaStore.refresh()
                            activityStore.loadInitial(pageSize = 250)
                        }
                    },
                    onDismissDemoStatus = { demoDataStore.clearStatus() },
                    onNavigateToBurn = onNavigateToBurn,
                    onNavigateToHermes = onNavigateToHermes,
                    onNavigateToStreams = onNavigateToStreams,
                ),
            )
        }
    }
}

@Composable
private fun collectPulseViewUiState(
    dashboardStore: DashboardStore,
    demoDataStore: DemoDataStore,
    userStore: UserStore,
): PulseViewUiState {
    val rollups by dashboardStore.rollups.collectAsState()
    val isLoading by dashboardStore.isLoading.collectAsState()
    val error by dashboardStore.error.collectAsState()
    val demoIsSeeding by demoDataStore.isSeeding.collectAsState()
    val demoMessage by demoDataStore.message.collectAsState()
    val demoError by demoDataStore.error.collectAsState()
    val currentUser by userStore.user.collectAsState()
    var timelineScope by remember { mutableStateOf(PulseTimelineScope.DAY) }
    var displayMode by remember { mutableStateOf(UsageDisplayMode.CURRENCY) }

    return PulseViewUiState(
        isSignedIn = currentUser.isSignedIn,
        photoUrl = currentUser.photoUrl,
        displayName = currentUser.displayName,
        isLoading = isLoading,
        error = error,
        rollups = rollups,
        demoIsSeeding = demoIsSeeding,
        demoMessage = demoMessage,
        demoError = demoError,
        displayMode = displayMode,
        timelineScope = timelineScope,
        onDisplayModeChange = { displayMode = it },
        onTimelineChange = { timelineScope = it },
    )
}

private data class PulseViewUiState(
    val isSignedIn: Boolean,
    val photoUrl: String?,
    val displayName: String?,
    val isLoading: Boolean,
    val error: String?,
    val rollups: com.openburnbar.data.models.UsageRollups?,
    val demoIsSeeding: Boolean,
    val demoMessage: String?,
    val demoError: String?,
    val displayMode: UsageDisplayMode,
    val timelineScope: PulseTimelineScope,
    val onDisplayModeChange: (UsageDisplayMode) -> Unit,
    val onTimelineChange: (PulseTimelineScope) -> Unit,
)

/**
 * Up to two uppercase initials from the leading word/hyphen segments of a
 * display name, or null when nothing usable remains (then the avatar renders
 * the plain bubble). Extracted from [UserAvatarBubble] so the fallback is
 * unit-testable without a composition.
 */
internal fun avatarInitials(displayName: String?): String? =
    displayName?.split(" ", "-")
        ?.mapNotNull { it.firstOrNull()?.uppercaseChar() }
        ?.take(2)
        ?.joinToString("")
        ?.takeIf { it.isNotBlank() }

@Composable
fun UserAvatarBubble(photoUrl: String?, displayName: String?, size: Dp = 36.dp) {
    val initials = avatarInitials(displayName)

    Box(
        contentAlignment = Alignment.Center,
        modifier =
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(AuroraColors.whimsy.copy(alpha = 0.35f))
            .border(
                width = 1.dp,
                color = AuroraColors.ember.copy(alpha = 0.4f),
                shape = CircleShape,
            ),
    ) {
        if (!photoUrl.isNullOrBlank()) {
            coil.compose.AsyncImage(
                model = photoUrl,
                contentDescription = displayName,
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                modifier = Modifier.size(size).clip(CircleShape),
            )
        } else if (initials != null) {
            Text(
                text = initials,
                color = androidx.compose.ui.graphics.Color.White,
                fontSize = (size.value * 0.38f).sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}
