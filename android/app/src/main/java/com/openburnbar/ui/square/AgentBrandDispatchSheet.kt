package com.openburnbar.ui.square

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentDispatchTransport
import com.openburnbar.data.square.AgentIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentBrandDispatchSheet(identity: AgentIdentity, missionHost: MobileMissionConsoleHost, onDismiss: () -> Unit, onResult: (String) -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }
    var dispatching by remember { mutableStateOf(false) }
    var inlineError by remember { mutableStateOf<String?>(null) }
    val runtimeToken = rememberDispatchRuntimeToken(identity)

    DispatchSheetModal(
        sheetState = sheetState,
        onDismiss = onDismiss,
        identity = identity,
        form =
        DispatchSheetFormState(
            title = title,
            prompt = prompt,
            commandsAllowed = commandsAllowed,
            fileEditsAllowed = fileEditsAllowed,
            dispatching = dispatching,
            inlineError = inlineError,
        ),
        callbacks =
        DispatchSheetCallbacks(
            onTitleChange = { title = it },
            onPromptChange = { prompt = it },
            onCommandsAllowedChange = { commandsAllowed = it },
            onFileEditsAllowedChange = { fileEditsAllowed = it },
            onDispatch = {
                runAgentBrandDispatch(
                    scope = scope,
                    missionHost = missionHost,
                    request =
                    AgentBrandDispatchRunRequest(
                        identity = identity,
                        runtimeToken = runtimeToken,
                        title = title,
                        prompt = prompt,
                        commandsAllowed = commandsAllowed,
                        fileEditsAllowed = fileEditsAllowed,
                    ),
                    callbacks =
                    AgentBrandDispatchRunCallbacks(
                        onDispatching = { dispatching = it },
                        onInlineError = { inlineError = it },
                        onResult = onResult,
                    ),
                )
            },
        ),
    )
}

@Composable
private fun rememberDispatchRuntimeToken(identity: AgentIdentity): String? = remember(identity) {
    identity.runtimeID?.token ?: (identity.dispatchTransport as? AgentDispatchTransport.MacRelay)?.runtime
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DispatchSheetModal(
    sheetState: SheetState,
    onDismiss: () -> Unit,
    identity: AgentIdentity,
    form: DispatchSheetFormState,
    callbacks: DispatchSheetCallbacks,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = MaterialTheme.colorScheme.surface) {
        DispatchSheetBody(identity = identity, form = form, callbacks = callbacks)
    }
}

private fun runAgentBrandDispatch(
    scope: CoroutineScope,
    missionHost: MobileMissionConsoleHost,
    request: AgentBrandDispatchRunRequest,
    callbacks: AgentBrandDispatchRunCallbacks,
) {
    if (request.prompt.isBlank()) return
    if (request.runtimeToken == null) {
        callbacks.onInlineError("This agent doesn't expose a dispatch runtime.")
        return
    }
    callbacks.onDispatching(true)
    callbacks.onInlineError(null)
    scope.launch {
        val id =
            missionHost.dispatch(
                title = request.title,
                prompt = request.prompt,
                missionKind = "diligence",
                runtimeID = request.runtimeToken,
                commandsAllowed = request.commandsAllowed,
                fileEditsAllowed = request.fileEditsAllowed,
            )
        callbacks.onDispatching(false)
        if (id != null) {
            callbacks.onResult("Dispatched to ${request.identity.displayName} (mission $id).")
        } else {
            callbacks.onInlineError("Dispatch failed.")
        }
    }
}
