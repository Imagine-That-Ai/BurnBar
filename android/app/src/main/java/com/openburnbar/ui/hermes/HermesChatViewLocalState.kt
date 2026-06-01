package com.openburnbar.ui.hermes

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.ui.focus.FocusManager
import kotlinx.coroutines.CoroutineScope

internal data class HermesChatViewLocalState(
    val inputText: String,
    val selectedModel: String,
    val showModelPicker: Boolean,
    val showConnectionSettings: Boolean,
    val chatViewMode: ChatViewMode,
    val visibleModels: List<String>,
    val listState: LazyListState,
    val focusManager: FocusManager,
    val scope: CoroutineScope,
    val setInputText: (String) -> Unit,
    val setSelectedModel: (String) -> Unit,
    val setShowModelPicker: (Boolean) -> Unit,
    val setShowConnectionSettings: (Boolean) -> Unit,
    val setChatViewMode: (ChatViewMode) -> Unit,
    val sendMessage: () -> Unit,
)
