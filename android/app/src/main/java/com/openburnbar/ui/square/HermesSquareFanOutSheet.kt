package com.openburnbar.ui.square

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
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
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareFanOutSheet(registry: AgentIdentityRegistry, onDispatched: (String) -> Unit, onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    val selected = remember { mutableStateListOf("claude", "codex", "hermes") }
    var dispatching by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }
    val dispatchableIdentities = registry.identities.filter { it.runtimeID != null }

    FanOutSheetModal(
        sheetState = state,
        onDismiss = onDismiss,
        dispatchableIdentities = dispatchableIdentities,
        uiState =
        FanOutSheetUiState(
            title = title,
            prompt = prompt,
            selected = selected,
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
                if (enabled) selected.add(runtime) else selected.remove(runtime)
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
    if (request.prompt.trim().isBlank() || request.selected.size < 2) return
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
