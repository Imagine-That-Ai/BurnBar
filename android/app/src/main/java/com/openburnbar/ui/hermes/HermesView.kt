@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.ui.computeruse.AgentPermissionGrantSheet
import com.openburnbar.ui.text.rememberTextExpansionSnippets

@Composable
fun HermesView(hermesService: HermesService = remember { HermesService() }, initialThreadId: String? = null) {
    val context = LocalContext.current
    val textExpansionSnippets by rememberTextExpansionSnippets()
    val ui = rememberHermesViewUiState(hermesService, initialThreadId)
    val messages by hermesService.messages.collectAsState()
    val isConnected by hermesService.isConnected.collectAsState()
    val isStreaming by hermesService.isStreaming.collectAsState()
    val availableModels by hermesService.availableModels.collectAsState()
    val runtimeInfo by hermesService.runtimeInfo.collectAsState()

    HermesViewRoute(
        ui = ui,
        hermesService = hermesService,
        connection =
        HermesViewConnectionState(
            messages = messages,
            isConnected = isConnected,
            isStreaming = isStreaming,
            availableModels = availableModels,
            runtimeInfo = runtimeInfo,
            textExpansionSnippets = textExpansionSnippets,
        ),
        context = context,
    )

    ui.permissionThreadID?.let { threadID ->
        AgentPermissionGrantSheet(
            runtime = AssistantRuntimeID.HERMES.token,
            threadId = threadID,
            onDismiss = { ui.setPermissionThreadID(null) },
        )
    }
}
