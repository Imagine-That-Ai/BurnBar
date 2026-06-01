package com.openburnbar.ui.hermes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.CLIAgentRelayChatTransport
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.PiService

@Composable
fun AssistantsScreen(initialRuntime: AssistantRuntimeID? = null, initialThreadId: String? = null) {
    val context = LocalContext.current
    val screenState = rememberAssistantsScreenState(context = context, initialRuntime = initialRuntime)
    AssistantsScreenIntentEffect(
        context = context,
        visibleTiles = screenState.visibleTiles,
        rawRuntime = screenState.rawRuntime,
        onRuntimeResolved = screenState.setRawRuntime,
    )
    AssistantsScreenInitialRuntimeEffect(
        initialRuntime = initialRuntime,
        visibleTiles = screenState.visibleTiles,
        rawRuntime = screenState.rawRuntime,
        onRuntimeResolved = screenState.setRawRuntime,
    )

    val historyStore = remember { AssistantChatHistoryStore.shared(context.applicationContext) }
    LaunchedEffect(historyStore) { historyStore.bootstrap() }
    val piService = remember { PiService().apply { bindHistoryStore(historyStore) } }
    val hermesService = remember(context) { HermesService(appContext = context.applicationContext) }
    val cliRelayChatTransport = remember(hermesService) { CLIAgentRelayChatTransport(hermesService) }

    AssistantsScreenContent(
        screenState = screenState,
        hermesService = hermesService,
        piService = piService,
        historyStore = historyStore,
        cliRelayChatTransport = cliRelayChatTransport,
        initialThreadId = initialThreadId,
    )
}
