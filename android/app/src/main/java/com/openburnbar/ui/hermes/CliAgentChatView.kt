// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.CLIAgentRelayChatTransporting
import com.openburnbar.data.hermes.AssistantRuntimeID

// MARK: - CLI agent chat surface (Codex / Claude Code / OpenClaw)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CliAgentChatView(
    runtime: AssistantRuntimeID,
    historyStore: AssistantChatHistoryStore,
    relayChatTransport: CLIAgentRelayChatTransporting,
) {
    val state = rememberCliAgentChatState(runtime, historyStore, relayChatTransport)
    CliAgentChatScreen(state = state)
    CliAgentChatOverlays(state = state)
}

@Composable
internal fun CliAgentChatOverlays(state: CliAgentChatState) {
    if (state.showPermissionSheet) {
        com.openburnbar.ui.computeruse.AgentPermissionGrantSheet(
            runtime = state.runtime.token,
            threadId = state.activeThreadID,
            onDismiss = state.onDismissPermissionSheet,
        )
    }
    if (state.showModelPicker) {
        CliModelPickerDialog(
            runtime = state.runtime,
            catalog =
            CliModelPickerCatalog(
                options = state.modelOptions,
                isLoading = state.modelCatalogLoading,
                errorText = state.modelCatalogError,
                selectedModelID = state.selectedModelID,
            ),
            callbacks =
            CliModelPickerCallbacks(
                onDismiss = state.onDismissModelPicker,
                onRefresh = state.onRefreshModelCatalog,
                onClear = state.onClearModelSelection,
                onSelect = state.onSelectModel,
            ),
        )
    }
}
