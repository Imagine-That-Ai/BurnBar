package com.openburnbar.ui.hermes

import com.openburnbar.data.hermes.HermesMessage
import com.openburnbar.data.text.TextExpansionSnippet

internal data class HermesViewConnectionState(
    val messages: List<HermesMessage>,
    val isConnected: Boolean,
    val isStreaming: Boolean,
    val availableModels: List<String>,
    val runtimeInfo: Map<String, String>,
    val textExpansionSnippets: List<TextExpansionSnippet>,
)
