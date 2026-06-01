package com.openburnbar.ui.hermes

internal data class HermesChatTopBarArgs(
    val conversationTitle: String,
    val isConnected: Boolean,
    val chatViewMode: ChatViewMode,
    val onBack: () -> Unit,
    val onDisconnect: () -> Unit,
    val onShowModelPicker: () -> Unit,
    val onShowConnectionSettings: () -> Unit,
    val onAgentPermissions: () -> Unit,
    val onToggleViewMode: () -> Unit,
)
