// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.ActivityStore

@Composable
fun StreamsView(
    activityStore: ActivityStore = viewModel(),
    hermesPendingPrompt: MutableState<String?>? = null,
    isCloudMember: Boolean = false,
    onOpenCloudStore: () -> Unit = {},
) {
    val usages by activityStore.usages.collectAsState()
    val projects by activityStore.projects.collectAsState()
    val isLoading by activityStore.isLoading.collectAsState()
    val error by activityStore.error.collectAsState()
    val selectedSegment by activityStore.selectedSegment.collectAsState()
    val hasMore by activityStore.hasMore.collectAsState()
    val cloudSearchHits by activityStore.cloudSearchHits.collectAsState()

    var searchQuery by remember { mutableStateOf("") }
    val snackbarHostState = remember { SnackbarHostState() }
    val cloudDialog = rememberStreamsCloudDialogState(activityStore)

    StreamsViewInitialEffects(activityStore, searchQuery, selectedSegment)

    StreamsViewScaffold(
        snackbarHostState = snackbarHostState,
        state =
        StreamsViewContentState(
            selectedSegment = selectedSegment,
            searchQuery = searchQuery,
            usages = usages,
            projects = projects,
            cloudSearchHits = cloudSearchHits,
            isLoading = isLoading,
            error = error,
            isCloudMember = isCloudMember,
            isDark = androidx.compose.foundation.isSystemInDarkTheme(),
        ),
        callbacks =
        StreamsViewContentCallbacks(
            onSelectSegment = activityStore::setSegment,
            onSearchChange = { searchQuery = it },
            onOpenCloudStore = onOpenCloudStore,
            onCloudHitSelected = cloudDialog::onHitSelected,
            onAskHermes = { prompt -> hermesPendingPrompt?.value = prompt },
            onLoadNext = {
                if (hasMore && !isLoading) activityStore.loadNext()
            },
        ),
        cloudDialogState = cloudDialog,
        activityStore = activityStore,
        hermesPendingPrompt = hermesPendingPrompt,
    )
}
