package com.openburnbar.ui.hermes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.openburnbar.data.hermes.HermesService

@Composable
fun HermesSettingsView(service: HermesService, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    val connections by service.connections.collectAsState()
    val selectedConnection by service.selectedConnection.collectAsState()
    val modelOptions by service.modelOptions.collectAsState()
    val selectedModelID by service.selectedModelID.collectAsState()
    val favoriteModelIDs by service.favoriteModelIDs.collectAsState()
    val isReachable by service.isReachable.collectAsState()
    val runtimeErrorText by service.runtimeErrorText.collectAsState()
    val isLoadingRuntime by service.isLoadingRuntime.collectAsState()

    var dialogState by remember { mutableStateOf(HermesSettingsDialogState()) }

    val uiState =
        HermesSettingsUiState(
            connections = connections,
            selectedConnection = selectedConnection,
            modelOptions = modelOptions,
            selectedModelID = selectedModelID,
            favoriteModelIDs = favoriteModelIDs,
            isReachable = isReachable,
            runtimeErrorText = runtimeErrorText,
            isLoadingRuntime = isLoadingRuntime,
        )

    val callbacks =
        HermesSettingsCallbacks(
            onDismiss = onDismiss,
            onSelectConnection = service::selectConnection,
            onRequestDeleteConnection = { connection ->
                dialogState = dialogState.copy(deleteTarget = connection)
            },
            onRequestAddDirect = {
                dialogState = dialogState.copy(showAddDirect = true)
            },
            onSelectModel = service::selectModel,
            onToggleFavoriteModel = service::toggleFavoriteModel,
            onDialogStateChange = { dialogState = it },
            onAddDirectConnection = service::addDirectConnection,
        )

    HermesSettingsBody(uiState = uiState, callbacks = callbacks, modifier = modifier)
    HermesSettingsDialogs(dialogState = dialogState, callbacks = callbacks)
}
