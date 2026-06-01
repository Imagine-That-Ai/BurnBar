package com.openburnbar.ui.hermes

import android.content.Context
import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.HermesSubProvider

data class HermesChatContent(
    val messages: List<com.openburnbar.data.hermes.HermesMessage>,
    val isConnected: Boolean,
    val availableModels: List<String>,
    val runtimeInfo: Map<String, String>,
    val conversationTitle: String,
    val tilePreferences: ChatTilePreferences,
    val isStreaming: Boolean = false,
    val threadId: String = "",
    val textExpansionSnippets: List<com.openburnbar.data.text.TextExpansionSnippet> = emptyList(),
)

data class HermesChatAttachmentState(
    val attachments: List<com.openburnbar.data.hermes.HermesAttachment> = emptyList(),
    val onAddAttachment: (com.openburnbar.data.hermes.HermesAttachment) -> Unit = {},
    val onRemoveAttachment: (String) -> Unit = {},
)

data class HermesChatActions(
    val onTilePreferencesChange: (ChatTilePreferences) -> Unit,
    val onBack: () -> Unit,
    val onSend: (String, String) -> Unit,
    val onAgentPermissions: () -> Unit,
    val onDisconnect: () -> Unit,
)

internal fun loadChatTilePreferences(context: Context): ChatTilePreferences {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    return ChatTilePreferences.fromJsonString(prefs.getString(ChatTilePreferences.USER_DEFAULTS_KEY, null))
}

internal fun saveChatTilePreferences(context: Context, value: ChatTilePreferences) {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    prefs.edit().putString(ChatTilePreferences.USER_DEFAULTS_KEY, value.toJsonString()).apply()
}

internal fun hermesFamilyForModel(model: String): HermesSubProvider? {
    val normalized = model.lowercase().replace(" ", "")
    HermesSubProvider.fromToken(normalized)?.let { return it }
    return when {
        "claude" in normalized || "anthropic" in normalized -> HermesSubProvider.CLAUDE
        "codex" in normalized || "openai" in normalized || normalized.startsWith("gpt-") -> HermesSubProvider.CODEX
        "zai" in normalized || "z.ai" in normalized || "glm" in normalized -> HermesSubProvider.ZAI
        "kimi" in normalized || "moonshot" in normalized -> HermesSubProvider.KIMI
        "minimax" in normalized -> HermesSubProvider.MINIMAX
        "ollama" in normalized || "llama" in normalized || "mistral" in normalized || "qwen" in normalized -> HermesSubProvider.OLLAMA
        else -> null
    }
}
