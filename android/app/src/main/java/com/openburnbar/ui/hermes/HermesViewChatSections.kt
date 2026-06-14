// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openburnbar.data.hermes.HermesMessage
import com.openburnbar.ui.theme.AuroraSpacing

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatView(content: HermesChatContent, attachments: HermesChatAttachmentState = HermesChatAttachmentState(), actions: HermesChatActions) {
    val local = rememberHermesChatViewLocalState(content = content, actions = actions)
    HermesChatViewLifecycleEffects(threadId = content.threadId)

    Scaffold(
        topBar = {
            HermesChatTopBar(
                args =
                HermesChatTopBarArgs(
                    conversationTitle = content.conversationTitle,
                    isConnected = content.isConnected,
                    chatViewMode = local.chatViewMode,
                    onBack = actions.onBack,
                    onDisconnect = actions.onDisconnect,
                    onShowModelPicker = { local.setShowModelPicker(true) },
                    onShowConnectionSettings = { local.setShowConnectionSettings(true) },
                    onAgentPermissions = actions.onAgentPermissions,
                    onToggleViewMode = {
                        local.setChatViewMode(
                            if (local.chatViewMode == ChatViewMode.AGENT) ChatViewMode.CLI else ChatViewMode.AGENT,
                        )
                    },
                ),
            )
        },
        containerColor = Color.Transparent,
    ) { innerPadding ->
        HermesChatBody(
            content = content,
            attachments = attachments,
            actions = actions,
            local = local,
            innerPadding = innerPadding,
        )
    }

    if (local.showModelPicker) {
        HermesChatModelPickerDialog(
            visibleModels = local.visibleModels,
            selectedModel = local.selectedModel,
            tilePreferences = content.tilePreferences,
            onTilePreferencesChange = actions.onTilePreferencesChange,
            onSelectModel = local.setSelectedModel,
            onDismiss = { local.setShowModelPicker(false) },
        )
    }

    if (local.showConnectionSettings) {
        HermesChatConnectionDialog(
            isConnected = content.isConnected,
            runtimeInfo = content.runtimeInfo,
            onDismiss = { local.setShowConnectionSettings(false) },
        )
    }
}

@Composable
private fun HermesChatBody(
    content: HermesChatContent,
    attachments: HermesChatAttachmentState,
    actions: HermesChatActions,
    local: HermesChatViewLocalState,
    innerPadding: PaddingValues,
) {
    Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
        HermesChatMessagePane(content = content, actions = actions, local = local)
        HermesChatComposer(content = content, attachments = attachments, local = local)
    }
}

@Composable
private fun ColumnScope.HermesChatMessagePane(content: HermesChatContent, actions: HermesChatActions, local: HermesChatViewLocalState) {
    if (local.chatViewMode == ChatViewMode.CLI) {
        InlineAgentMirrorView(
            runtime = "hermes",
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
        )
    } else {
        // Collected once for the whole transcript (not per bubble) so an inbox change only
        // recomposes bubbles whose matched item actually changed.
        val permissionItems by com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.store.items
            .collectAsState()
        val inboxByToolCallId =
            remember(permissionItems, content.threadId) {
                systemPermissionItemsByToolCallId(permissionItems, content.threadId)
            }
        LazyColumn(
            modifier = Modifier.weight(1f),
            state = local.listState,
            contentPadding = PaddingValues(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        ) {
            item {
                WelcomeBlock(
                    runtimeInfo = content.runtimeInfo,
                    selectedModel = local.selectedModel,
                    availableModels = local.visibleModels,
                    onModelSelect = { model ->
                        applyModelSelection(
                            model = model,
                            tilePreferences = content.tilePreferences,
                            onTilePreferencesChange = actions.onTilePreferencesChange,
                            setSelectedModel = local.setSelectedModel,
                        )
                    },
                    onTriggerPrompt = { prompt -> actions.onSend(prompt, local.selectedModel) },
                )
            }
            itemsIndexed(content.messages, key = { index, message -> hermesChatMessageKey(index, message) }) { _, message ->
                ChatBubble(
                    message = message,
                    viewMode = local.chatViewMode,
                    permissionItem = matchingSystemPermissionItem(inboxByToolCallId, message),
                )
            }
        }
    }
}

// LazyColumn keys must be unique and stable across list mutations (retry truncates and
// re-appends; stale streaming rows are dropped mid-list). Legacy messages may carry an
// empty id, so fall back to positional identity for those instead of crashing on
// duplicate keys.
internal fun hermesChatMessageKey(index: Int, message: HermesMessage): Any = message.id.ifEmpty { "hermes-msg-$index" }
