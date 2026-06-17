package com.openburnbar.ui.square

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.DispatchException
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.ui.pro.CloudTier
import com.openburnbar.ui.pro.FeatureUnlockSheet
import com.openburnbar.ui.pro.GatedFeature
import com.openburnbar.ui.pro.GatedFeatureCatalog
import com.openburnbar.ui.pro.GatedFeatureID
import com.openburnbar.ui.pro.WandFanOut
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareFanOutSheet(
    registry: AgentIdentityRegistry,
    currentTier: CloudTier = CloudTier.NONE,
    onDispatched: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    val selected = remember { mutableStateListOf("claude", "codex", "hermes") }
    var unlockFeature by remember { mutableStateOf<GatedFeature?>(null) }
    var dispatching by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }
    val dispatchableIdentities = registry.identities.filter { it.runtimeID != null }
    val maxParallel = WandFanOut.maxParallel(currentTier)

    LaunchedEffect(maxParallel) {
        while (selected.size > maxParallel) selected.removeAt(selected.lastIndex)
    }

    FanOutSheetModal(
        sheetState = state,
        onDismiss = onDismiss,
        dispatchableIdentities = dispatchableIdentities,
        uiState =
            FanOutSheetUiState(
                title = title,
                prompt = prompt,
                selected = selected,
                maxParallel = maxParallel,
                commandsAllowed = commandsAllowed,
                fileEditsAllowed = fileEditsAllowed,
                dispatching = dispatching,
            errorMessage = errorMessage,
        ),
        uiCallbacks =
            FanOutSheetUiCallbacks(
                onTitleChange = { title = it },
                onPromptChange = { prompt = it },
                onToggleRuntime = { runtime, enabled ->
                    if (enabled) {
                        if (selected.size >= maxParallel) {
                            unlockFeature = wandUnlockFeature(selected.size + 1)
                        } else if (!selected.contains(runtime)) {
                            selected.add(runtime)
                        }
                    } else if (selected.size > 1) {
                        selected.remove(runtime)
                    }
                },
                onCommandsAllowedChange = { commandsAllowed = it },
                onFileEditsAllowedChange = { fileEditsAllowed = it },
            onDispatch = {
                dispatchFanOutMission(
                    scope = scope,
                    request =
                    FanOutDispatchRequest(
                        title = title,
                        prompt = prompt,
                        selected = selected.toList(),
                        maxParallel = maxParallel,
                        commandsAllowed = commandsAllowed,
                        fileEditsAllowed = fileEditsAllowed,
                    ),
                    callbacks =
                    FanOutDispatchCallbacks(
                        onDispatching = { dispatching = it },
                        onError = { errorMessage = it },
                        onDispatched = onDispatched,
                        onDismiss = onDismiss,
                    ),
                )
            },
        ),
    )
    unlockFeature?.let { feature ->
        FeatureUnlockSheet(
            feature = feature,
            show = true,
            onUnlock = {},
            onDismiss = { unlockFeature = null },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FanOutSheetModal(
    sheetState: SheetState,
    onDismiss: () -> Unit,
    dispatchableIdentities: List<AgentIdentity>,
    uiState: FanOutSheetUiState,
    uiCallbacks: FanOutSheetUiCallbacks,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = MaterialTheme.colorScheme.surface) {
        FanOutSheetBody(
            dispatchableIdentities = dispatchableIdentities,
            uiState = uiState,
            uiCallbacks = uiCallbacks,
        )
    }
}

internal fun dispatchFanOutMission(scope: kotlinx.coroutines.CoroutineScope, request: FanOutDispatchRequest, callbacks: FanOutDispatchCallbacks) {
    if (request.prompt.trim().isBlank() || request.selected.isEmpty()) return
    if (request.selected.size > request.maxParallel) {
        callbacks.onError("Your current plan allows ${request.maxParallel} Wand worker${if (request.maxParallel == 1) "" else "s"}.")
        return
    }
    callbacks.onDispatching(true)
    callbacks.onError(null)
    scope.launch {
        try {
            val result =
                CLIAgentMissionDispatcher().dispatchFanOut(
                    title = request.title,
                    prompt = request.prompt,
                    missionKind = "diligence",
                    runtimeTokens = request.selected,
                    commandsAllowed = request.commandsAllowed,
                    fileEditsAllowed = request.fileEditsAllowed,
                    parallelismLimit = request.selected.size,
                )
            callbacks.onDispatched(result.groupID)
            callbacks.onDismiss()
        } catch (e: DispatchException) {
            callbacks.onError(e.message)
        } catch (e: IllegalStateException) {
            callbacks.onError(e.localizedMessage ?: "Dispatch failed.")
        } finally {
            callbacks.onDispatching(false)
        }
    }
}

private fun wandUnlockFeature(width: Int): GatedFeature {
    val requiredTier = WandFanOut.minimumTier(width)
    return GatedFeatureCatalog.feature(GatedFeatureID.THE_WAND).copy(requiredTier = requiredTier)
}
