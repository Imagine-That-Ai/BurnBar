package com.openburnbar.ui.hermes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.hermes.HermesAttachment
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.ui.navigation.HermesPendingPrompt

internal data class HermesViewUiState(
    val showConversationList: Boolean,
    val showSessionsLibrary: Boolean,
    val showSetupWizard: Boolean,
    val showHermesSettings: Boolean,
    val permissionThreadID: String?,
    val conversationTitle: String,
    val tilePrefs: com.openburnbar.data.hermes.ChatTilePreferences,
    val stagedAttachments: List<HermesAttachment>,
    val setShowConversationList: (Boolean) -> Unit,
    val setShowSessionsLibrary: (Boolean) -> Unit,
    val setShowSetupWizard: (Boolean) -> Unit,
    val setShowHermesSettings: (Boolean) -> Unit,
    val setPermissionThreadID: (String?) -> Unit,
    val setConversationTitle: (String) -> Unit,
    val setTilePrefs: (com.openburnbar.data.hermes.ChatTilePreferences) -> Unit,
    val setStagedAttachments: (List<HermesAttachment>) -> Unit,
)

@Composable
internal fun rememberHermesViewUiState(
    hermesService: HermesService,
    initialThreadId: String?,
): HermesViewUiState {
    val context = LocalContext.current
    var showConversationList by remember { mutableStateOf(true) }
    var showSessionsLibrary by remember { mutableStateOf(false) }
    var showSetupWizard by remember { mutableStateOf(false) }
    var showHermesSettings by remember { mutableStateOf(false) }
    var permissionThreadID by remember { mutableStateOf<String?>(null) }
    var conversationTitle by remember { mutableStateOf("New Chat") }
    var tilePrefs by remember { mutableStateOf(loadChatTilePreferences(context).sanitized()) }
    var stagedAttachments by remember { mutableStateOf<List<HermesAttachment>>(emptyList()) }

    HermesViewBootstrapEffects(hermesService = hermesService, tilePrefs = tilePrefs) { showSetupWizard = true }
    HermesViewInitialThreadEffects(
        hermesService = hermesService,
        initialThreadId = initialThreadId,
        onOpenThread = { title ->
            showConversationList = false
            conversationTitle = title
        },
    )
    HermesViewTilePrefsEffects(hermesService = hermesService, tilePrefs = tilePrefs)
    HermesViewPendingPromptEffects(showConversationList = showConversationList, hermesService = hermesService)

    return HermesViewUiState(
        showConversationList = showConversationList,
        showSessionsLibrary = showSessionsLibrary,
        showSetupWizard = showSetupWizard,
        showHermesSettings = showHermesSettings,
        permissionThreadID = permissionThreadID,
        conversationTitle = conversationTitle,
        tilePrefs = tilePrefs,
        stagedAttachments = stagedAttachments,
        setShowConversationList = { showConversationList = it },
        setShowSessionsLibrary = { showSessionsLibrary = it },
        setShowSetupWizard = { showSetupWizard = it },
        setShowHermesSettings = { showHermesSettings = it },
        setPermissionThreadID = { permissionThreadID = it },
        setConversationTitle = { conversationTitle = it },
        setTilePrefs = { tilePrefs = it },
        setStagedAttachments = { stagedAttachments = it },
    )
}

@Composable
private fun HermesViewBootstrapEffects(hermesService: HermesService, tilePrefs: com.openburnbar.data.hermes.ChatTilePreferences, onShowSetupWizard: () -> Unit) {
    val context = LocalContext.current
    val onboarding = remember(context) { com.openburnbar.data.hermes.HermesOnboardingState(context.applicationContext) }
    val historyStore =
        remember(context) {
            com.openburnbar.data.assistants.AssistantChatHistoryStore.shared(context.applicationContext)
        }

    LaunchedEffect(Unit) {
        hermesService.bindHistoryStore(historyStore)
        historyStore.bootstrap()
        hermesService.setChatTilePreferences(tilePrefs)
        hermesService.connect()
        if (onboarding.shouldAutoPresentSetupWizard()) {
            onShowSetupWizard()
        }
    }
}

@Composable
private fun HermesViewInitialThreadEffects(
    hermesService: HermesService,
    initialThreadId: String?,
    onOpenThread: (String) -> Unit,
) {
    val context = LocalContext.current
    val historyStore =
        remember(context) {
            com.openburnbar.data.assistants.AssistantChatHistoryStore.shared(context.applicationContext)
        }

    LaunchedEffect(initialThreadId) {
        if (!initialThreadId.isNullOrBlank()) {
            val cleanThreadId = initialThreadId.removePrefix("hermes:")
            hermesService.bindHistoryStore(historyStore)
            historyStore.bootstrap()
            hermesService.loadThread(cleanThreadId)
            val title = historyStore.thread(cleanThreadId)?.title ?: "New Chat"
            onOpenThread(title)
        }
    }
}

@Composable
private fun HermesViewTilePrefsEffects(hermesService: HermesService, tilePrefs: com.openburnbar.data.hermes.ChatTilePreferences) {
    LaunchedEffect(tilePrefs) {
        hermesService.setChatTilePreferences(tilePrefs)
    }
}

@Composable
private fun HermesViewPendingPromptEffects(showConversationList: Boolean, hermesService: HermesService) {
    LaunchedEffect(showConversationList) {
        if (!showConversationList) {
            val pending = HermesPendingPrompt.pending
            if (!pending.isNullOrBlank()) {
                kotlinx.coroutines.delay(HermesPendingPromptDispatchDelayMs)
                hermesService.sendMessage(pending.trim())
                HermesPendingPrompt.pending = null
            }
        }
    }
}

private const val HermesPendingPromptDispatchDelayMs = 300L
