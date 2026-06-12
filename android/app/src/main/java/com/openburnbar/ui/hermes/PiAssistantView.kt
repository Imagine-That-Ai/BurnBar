// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.hermes.PiService

// Plan 2 — Android Pi assistant pane. Minimal but functional sibling of
// `HermesView` so users can chat with the Pi gateway from the Assistants
// surface. Tool cards and library import are deferred to a follow-up wave.

@Composable
fun PiAssistantView(piService: PiService) {
    val context = LocalContext.current
    val messages by piService.messages.collectAsState()
    val isStreaming by piService.isStreaming.collectAsState()
    val isReachable by piService.isReachable.collectAsState()
    val errorText by piService.runtimeErrorText.collectAsState()
    val currentThreadID by piService.currentThreadID.collectAsState()

    var input by remember { mutableStateOf("") }
    var permissionThreadID by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()

    PiAssistantLifecycleEffects(
        piService = piService,
        context = context,
        currentThreadID = currentThreadID,
    )

    PiAssistantScreen(
        state =
        PiAssistantScreenState(
            messages = messages,
            isStreaming = isStreaming,
            isReachable = isReachable,
            errorText = errorText,
            listState = listState,
            input = input,
        ),
        callbacks =
        PiAssistantScreenCallbacks(
            onInputChange = { input = it },
            onSend = {
                val text = input
                if (text.isNotBlank()) {
                    piService.send(text)
                    input = ""
                }
            },
            onShowPermissions = { permissionThreadID = piService.ensureDesktopGrantThreadID() },
        ),
    )

    PiAssistantPermissionOverlay(
        permissionThreadID = permissionThreadID,
        onDismiss = { permissionThreadID = null },
    )
}
