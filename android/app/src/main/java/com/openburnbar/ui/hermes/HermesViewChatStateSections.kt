// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.services.media.AgentReplyNotificationState
import com.openburnbar.ui.text.expandStaticTextSnippetDraft
import kotlinx.coroutines.launch

@Composable
internal fun rememberHermesChatViewLocalState(
    content: HermesChatContent,
    actions: HermesChatActions,
): HermesChatViewLocalState {
    val context = LocalContext.current
    var inputText by remember { mutableStateOf("") }
    var selectedModel by remember(content.tilePreferences.selectedHermesModelOverride) {
        mutableStateOf(content.tilePreferences.selectedHermesModelOverride ?: content.availableModels.firstOrNull() ?: "hermes")
    }
    var showModelPicker by remember { mutableStateOf(false) }
    var showConnectionSettings by remember { mutableStateOf(false) }
    var chatViewMode by remember(context) {
        mutableStateOf(
            ChatViewMode.fromKey(
                context.getSharedPreferences("chat", 0).getString("viewMode", null),
            ),
        )
    }
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val visibleModels =
        remember(content.availableModels, content.tilePreferences.enabledHermesSubProviders, selectedModel) {
            filterVisibleHermesModels(
                availableModels = content.availableModels,
                enabledSubProviders = content.tilePreferences.enabledHermesSubProviders,
                selectedModel = selectedModel,
            )
        }

    val sendMessage = {
        if (inputText.isNotBlank()) {
            actions.onSend(inputText.trim(), selectedModel)
            inputText = ""
            scope.launch { listState.animateScrollToItem(content.messages.size + 2) }
            focusManager.clearFocus()
        }
    }

    return HermesChatViewLocalState(
        inputText = inputText,
        selectedModel = selectedModel,
        showModelPicker = showModelPicker,
        showConnectionSettings = showConnectionSettings,
        chatViewMode = chatViewMode,
        visibleModels = visibleModels,
        listState = listState,
        focusManager = focusManager,
        scope = scope,
        setInputText = { inputText = it },
        setSelectedModel = { selectedModel = it },
        setShowModelPicker = { showModelPicker = it },
        setShowConnectionSettings = { showConnectionSettings = it },
        setChatViewMode = { mode ->
            chatViewMode = mode
            context.getSharedPreferences("chat", 0).edit().putString("viewMode", mode.key).apply()
        },
        sendMessage = sendMessage,
    )
}

@Composable
internal fun HermesChatViewLifecycleEffects(threadId: String) {
    val context = LocalContext.current
    LaunchedEffect(threadId) {
        if (threadId.isNotEmpty()) {
            com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.activeThreadId = threadId
            AgentReplyNotificationState.setActiveChat(
                context = context,
                runtime = AssistantRuntimeID.HERMES.token,
                threadId = threadId,
                surface = "android_hermes_chat",
            )
        }
    }
    DisposableEffect(threadId) {
        onDispose {
            if (com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.activeThreadId == threadId) {
                com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.activeThreadId = null
            }
            AgentReplyNotificationState.setActiveChat(
                context = context,
                runtime = null,
                threadId = null,
                surface = null,
            )
        }
    }
}

internal fun filterVisibleHermesModels(
    availableModels: List<String>,
    enabledSubProviders: Set<com.openburnbar.data.hermes.HermesSubProvider>,
    selectedModel: String,
): List<String> {
    val filtered =
        if (enabledSubProviders.isEmpty()) {
            availableModels
        } else {
            availableModels.filter { model ->
                val family = hermesFamilyForModel(model)
                family == null || enabledSubProviders.contains(family)
            }
        }
    return if (selectedModel.isNotBlank() && !filtered.contains(selectedModel)) {
        listOf(selectedModel) + filtered
    } else {
        filtered
    }
}

internal fun expandChatDraft(text: String, content: HermesChatContent): String =
    expandStaticTextSnippetDraft(text, content.textExpansionSnippets)

internal fun applyModelSelection(
    model: String,
    tilePreferences: ChatTilePreferences,
    onTilePreferencesChange: (ChatTilePreferences) -> Unit,
    setSelectedModel: (String) -> Unit,
) {
    setSelectedModel(model)
    onTilePreferencesChange(tilePreferences.setSelectedHermesModel(model))
}
