@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
private fun ColumnScope.HermesChatMessagePane(
    content: HermesChatContent,
    actions: HermesChatActions,
    local: HermesChatViewLocalState,
) {
    if (local.chatViewMode == ChatViewMode.CLI) {
        InlineAgentMirrorView(
            runtime = "hermes",
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)
        )
    } else {
        LazyColumn(
            modifier = Modifier.weight(1f),
            state = local.listState,
            contentPadding = PaddingValues(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
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
            items(content.messages) { message ->
                ChatBubble(message = message, threadId = content.threadId, viewMode = local.chatViewMode)
            }
        }
    }
}
