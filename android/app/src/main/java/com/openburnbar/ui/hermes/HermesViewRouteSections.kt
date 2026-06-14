package com.openburnbar.ui.hermes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.openburnbar.data.hermes.HermesAttachmentLimits
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.clearMessages
import com.openburnbar.data.hermes.loadThread

@Composable
internal fun HermesViewRoute(ui: HermesViewUiState, hermesService: HermesService, connection: HermesViewConnectionState, context: android.content.Context) {
    when {
        ui.showSetupWizard ->
            HermesSetupWizard(
                onComplete = { ui.setShowSetupWizard(false) },
                onOpenConnections = {
                    ui.setShowSetupWizard(false)
                    ui.setShowHermesSettings(true)
                },
                onDismiss = { ui.setShowSetupWizard(false) },
            )
        ui.showHermesSettings ->
            HermesSettingsView(
                service = hermesService,
                onDismiss = { ui.setShowHermesSettings(false) },
            )
        ui.showSessionsLibrary ->
            HermesSessionsScreen(
                service = hermesService,
                onBack = { ui.setShowSessionsLibrary(false) },
                onImported = { imported ->
                    hermesService.loadThread(imported)
                    ui.setShowSessionsLibrary(false)
                    ui.setShowConversationList(false)
                    ui.setConversationTitle("Imported session")
                },
            )
        ui.showConversationList ->
            ConversationListView(
                isConnected = connection.isConnected,
                onStartChat = { title ->
                    ui.setConversationTitle(title)
                    ui.setShowConversationList(false)
                    hermesService.clearMessages()
                    ui.setStagedAttachments(emptyList())
                },
                onOpenLibrary = { ui.setShowSessionsLibrary(true) },
                onOpenSetup = { ui.setShowHermesSettings(true) },
            )
        else ->
            HermesViewActiveChatRoute(
                ui = ui,
                hermesService = hermesService,
                connection = connection,
                context = context,
            )
    }
}

@Composable
private fun HermesViewActiveChatRoute(
    ui: HermesViewUiState,
    hermesService: HermesService,
    connection: HermesViewConnectionState,
    context: android.content.Context,
) {
    val currentThreadID by hermesService.currentThreadID.collectAsState()
    ChatView(
        content =
        HermesChatContent(
            messages = connection.messages,
            isConnected = connection.isConnected,
            isStreaming = connection.isStreaming,
            availableModels = connection.availableModels,
            runtimeInfo = connection.runtimeInfo,
            conversationTitle = ui.conversationTitle,
            tilePreferences = ui.tilePrefs,
            threadId = currentThreadID.orEmpty(),
            textExpansionSnippets = connection.textExpansionSnippets,
        ),
        attachments =
        HermesChatAttachmentState(
            attachments = ui.stagedAttachments,
            onAddAttachment = { attachment ->
                ui.setStagedAttachments(
                    (ui.stagedAttachments + attachment).take(HermesAttachmentLimits.MAX_ATTACHMENTS),
                )
            },
            onRemoveAttachment = { id ->
                ui.setStagedAttachments(ui.stagedAttachments.filterNot { it.id == id })
            },
        ),
        actions =
        HermesChatActions(
            onTilePreferencesChange = { next ->
                val sanitized = next.sanitized()
                ui.setTilePrefs(sanitized)
                saveChatTilePreferences(context, sanitized)
            },
            onBack = { ui.setShowConversationList(true) },
            onSend = { msg, model ->
                hermesService.sendMessage(msg, model, ui.stagedAttachments)
                ui.setStagedAttachments(emptyList())
            },
            onAgentPermissions = {
                ui.setPermissionThreadID(hermesService.ensureDesktopGrantThreadID())
            },
            onDisconnect = { hermesService.disconnect() },
        ),
    )
}
