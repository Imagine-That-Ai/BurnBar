package com.openburnbar.ui.settings

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.TextExpansionSnippetEntity
import com.openburnbar.data.text.TextExpansionTrigger
import com.openburnbar.data.text.TextExpansionSyncManager
import com.openburnbar.data.text.TextExpansionSyncWorker
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

private const val TEXT_EXPANSION_STATUS_TOAST_MS = 2_500L
private const val TEXT_EXPANSION_SANDBOX_SUCCESS_MS = 1_500L
private const val TEXT_EXPANSION_TRIGGER_SPACE_SUFFIX_LEN = 3

internal data class TextExpansionColorTokens(
    val surfaceColor: Color,
    val surfaceElevatedColor: Color,
    val borderSubtleColor: Color,
    val textPrimaryColor: Color,
    val textSecondaryColor: Color,
    val textMutedColor: Color,
    val successColor: Color,
    val errorColor: Color,
    val backgroundCol: Color,
)

internal data class TextExpansionEditorDraft(
    val editing: TextExpansionSnippetEntity?,
    val title: String,
    val trigger: String,
    val body: String,
    val enabled: Boolean,
)

internal data class TextExpansionSandboxState(
    val text: String,
    val success: Boolean,
)

internal data class TextExpansionSettingsCallbacks(
    val onTitleChange: (String) -> Unit,
    val onTriggerChange: (String) -> Unit,
    val onBodyChange: (String) -> Unit,
    val onEnabledChange: (Boolean) -> Unit,
    val onSearchQueryChange: (String) -> Unit,
    val onSandboxTextChange: (String) -> Unit,
    val onCloudSyncChange: (Boolean) -> Unit,
    val loadDraft: (TextExpansionSnippetEntity?) -> Unit,
    val saveSnippet: () -> Unit,
    val deleteSnippet: () -> Unit,
    val syncNow: () -> Unit,
    val toggleSnippetEnabled: (TextExpansionSnippetEntity) -> Unit,
    val openKeyboardSettings: () -> Unit,
)

internal data class TextExpansionStatusSnapshot(
    val message: String?,
    val isError: Boolean,
)

internal class TextExpansionSettingsState(
    val colors: TextExpansionColorTokens,
    val snippets: List<TextExpansionSnippetEntity>,
    val filteredSnippets: List<TextExpansionSnippetEntity>,
    val editor: TextExpansionEditorDraft,
    val searchQuery: String,
    val sandbox: TextExpansionSandboxState,
    val cloudSyncEnabled: Boolean,
    val statusSnapshot: TextExpansionStatusSnapshot,
    val callbacks: TextExpansionSettingsCallbacks,
) {
    val editing get() = editor.editing
    val title get() = editor.title
    val trigger get() = editor.trigger
    val body get() = editor.body
    val enabled get() = editor.enabled
    val sandboxText get() = sandbox.text
    val sandboxSuccess get() = sandbox.success
    val status get() = statusSnapshot.message
    val statusIsError get() = statusSnapshot.isError
    val onTitleChange get() = callbacks.onTitleChange
    val onTriggerChange get() = callbacks.onTriggerChange
    val onBodyChange get() = callbacks.onBodyChange
    val onEnabledChange get() = callbacks.onEnabledChange
    val onSearchQueryChange get() = callbacks.onSearchQueryChange
    val onSandboxTextChange get() = callbacks.onSandboxTextChange
    val onCloudSyncChange get() = callbacks.onCloudSyncChange
    val loadDraft get() = callbacks.loadDraft
    val saveSnippet get() = callbacks.saveSnippet
    val deleteSnippet get() = callbacks.deleteSnippet
    val syncNow get() = callbacks.syncNow
    val toggleSnippetEnabled get() = callbacks.toggleSnippetEnabled
    val openKeyboardSettings get() = callbacks.openKeyboardSettings
}

private suspend fun textExpansionReload(context: Context): List<TextExpansionSnippetEntity> =
    withContext(Dispatchers.IO) { AppDatabase.getDatabase(context).textExpansionDao().getAllActive() }

private fun textExpansionFilterSnippets(
    snippets: List<TextExpansionSnippetEntity>,
    searchQuery: String,
): List<TextExpansionSnippetEntity> {
    if (searchQuery.isBlank()) return snippets
    val query = searchQuery.trim().lowercase()
    return snippets.filter {
        it.title.lowercase().contains(query) ||
            it.trigger.lowercase().contains(query) ||
            it.body.lowercase().contains(query)
    }
}

private fun textExpansionColorTokens(isDark: Boolean): TextExpansionColorTokens {
    return TextExpansionColorTokens(
        surfaceColor = if (isDark) AuroraColors.darkSurface else AuroraColors.lightSurface,
        surfaceElevatedColor = if (isDark) AuroraColors.darkSurfaceElevated else AuroraColors.lightSurfaceElevated,
        borderSubtleColor = if (isDark) AuroraColors.darkBorderSubtle else AuroraColors.lightBorderSubtle,
        textPrimaryColor = if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary,
        textSecondaryColor = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary,
        textMutedColor = if (isDark) AuroraColors.darkTextMuted else AuroraColors.lightTextMuted,
        successColor = if (isDark) AuroraColors.successDark else AuroraColors.success,
        errorColor = if (isDark) AuroraColors.errorDark else AuroraColors.error,
        backgroundCol = if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground,
    )
}

private class TextExpansionRuntimeState(
    val snippetData: TextExpansionSnippetData,
    val editor: TextExpansionEditorBundle,
    val mutation: TextExpansionSnippetMutationContext,
)

private class TextExpansionEditorBundle(
    val draft: TextExpansionDraftFields,
    val sandbox: TextExpansionSandboxFields,
    val status: TextExpansionStatusHolder,
)

private class TextExpansionSnippetData(
    val snippets: List<TextExpansionSnippetEntity>,
    val searchQuery: String,
    val cloudSyncEnabled: Boolean,
    val filteredSnippets: List<TextExpansionSnippetEntity>,
    val onSearchQueryChange: (String) -> Unit,
    val onCloudSyncChange: (Boolean) -> Unit,
    val reload: suspend () -> Unit,
)

@Composable
private fun rememberTextExpansionSnippetData(context: Context): TextExpansionSnippetData {
    var snippets by remember { mutableStateOf<List<TextExpansionSnippetEntity>>(emptyList()) }
    var searchQuery by remember { mutableStateOf("") }
    val prefs = remember(context) {
        context.getSharedPreferences("text_expansion_settings", Context.MODE_PRIVATE)
    }
    var cloudSyncEnabled by remember { mutableStateOf(prefs.getBoolean("cloud_sync_enabled", true)) }

    suspend fun reload() { snippets = textExpansionReload(context) }
    LaunchedEffect(Unit) { reload() }

    val filteredSnippets = remember(snippets, searchQuery) { textExpansionFilterSnippets(snippets, searchQuery) }

    return TextExpansionSnippetData(
        snippets = snippets,
        searchQuery = searchQuery,
        cloudSyncEnabled = cloudSyncEnabled,
        filteredSnippets = filteredSnippets,
        onSearchQueryChange = { searchQuery = it },
        onCloudSyncChange = { checked ->
            cloudSyncEnabled = checked
            prefs.edit().putBoolean("cloud_sync_enabled", checked).apply()
            if (checked) TextExpansionSyncWorker.enqueueImmediate(context)
        },
        reload = ::reload,
    )
}

private class TextExpansionStatusHolder(
    val status: String?,
    val statusIsError: Boolean,
    val showToast: (String, Boolean) -> Unit,
    val clearStatus: () -> Unit,
)

@Composable
private fun rememberTextExpansionStatusHolder(): TextExpansionStatusHolder {
    var status by remember { mutableStateOf<String?>(null) }
    var statusIsError by remember { mutableStateOf(false) }

    fun showToast(message: String, isError: Boolean = false) {
        status = message
        statusIsError = isError
    }

    LaunchedEffect(status) {
        if (status != null) {
            delay(TEXT_EXPANSION_STATUS_TOAST_MS)
            status = null
        }
    }

    return TextExpansionStatusHolder(
        status = status,
        statusIsError = statusIsError,
        showToast = ::showToast,
        clearStatus = { status = null },
    )
}

private data class TextExpansionDraftValues(
    val editing: TextExpansionSnippetEntity?,
    val title: String,
    val trigger: String,
    val body: String,
    val enabled: Boolean,
)

private data class TextExpansionDraftCallbacks(
    val onTitleChange: (String) -> Unit,
    val onTriggerChange: (String) -> Unit,
    val onBodyChange: (String) -> Unit,
    val onEnabledChange: (Boolean) -> Unit,
    val loadDraft: (TextExpansionSnippetEntity?) -> Unit,
)

private class TextExpansionDraftFields(
    val values: TextExpansionDraftValues,
    val callbacks: TextExpansionDraftCallbacks,
) {
    val editing get() = values.editing
    val title get() = values.title
    val trigger get() = values.trigger
    val body get() = values.body
    val enabled get() = values.enabled
    val onTitleChange get() = callbacks.onTitleChange
    val onTriggerChange get() = callbacks.onTriggerChange
    val onBodyChange get() = callbacks.onBodyChange
    val onEnabledChange get() = callbacks.onEnabledChange
    val loadDraft get() = callbacks.loadDraft
}

@Composable
private fun rememberTextExpansionDraftFields(status: TextExpansionStatusHolder): TextExpansionDraftFields {
    var editing by remember { mutableStateOf<TextExpansionSnippetEntity?>(null) }
    var title by remember { mutableStateOf("") }
    var trigger by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var enabled by remember { mutableStateOf(true) }

    fun loadDraft(snippet: TextExpansionSnippetEntity?) {
        editing = snippet
        if (snippet == null) {
            title = ""
            trigger = ""
            body = ""
            enabled = true
        } else {
            title = snippet.title
            trigger = snippet.trigger
            body = snippet.body
            enabled = snippet.isEnabled
        }
        status.clearStatus()
    }

    return TextExpansionDraftFields(
        values = TextExpansionDraftValues(editing, title, trigger, body, enabled),
        callbacks = TextExpansionDraftCallbacks(
            onTitleChange = { title = it },
            onTriggerChange = { trigger = it },
            onBodyChange = { body = it },
            onEnabledChange = { enabled = it },
            loadDraft = ::loadDraft,
        ),
    )
}

private class TextExpansionSandboxFields(
    val sandboxText: String,
    val sandboxSuccess: Boolean,
    val onSandboxTextChange: (String) -> Unit,
)

@Composable
private fun rememberTextExpansionSandboxFields(
    trigger: String,
    body: String,
    snippets: List<TextExpansionSnippetEntity>,
    scope: CoroutineScope,
): TextExpansionSandboxFields {
    var sandboxText by remember { mutableStateOf("") }
    var sandboxSuccess by remember { mutableStateOf(false) }

    fun handleSandboxInput(newVal: String) = textExpansionApplySandboxInput(
        newVal = newVal,
        trigger = trigger,
        body = body,
        snippets = snippets,
        setSandboxText = { sandboxText = it },
        pulseSuccess = {
            scope.launch {
                sandboxSuccess = true
                delay(TEXT_EXPANSION_SANDBOX_SUCCESS_MS)
                sandboxSuccess = false
            }
        },
    )

    return TextExpansionSandboxFields(
        sandboxText = sandboxText,
        sandboxSuccess = sandboxSuccess,
        onSandboxTextChange = { newVal ->
            sandboxText = newVal
            handleSandboxInput(newVal)
        },
    )
}

@Composable
private fun rememberTextExpansionEditorFields(
    snippets: List<TextExpansionSnippetEntity>,
    scope: CoroutineScope,
): TextExpansionEditorBundle {
    val status = rememberTextExpansionStatusHolder()
    val draft = rememberTextExpansionDraftFields(status)
    val sandbox = rememberTextExpansionSandboxFields(draft.trigger, draft.body, snippets, scope)

    return TextExpansionEditorBundle(
        draft = draft,
        sandbox = sandbox,
        status = status,
    )
}

@Composable
private fun rememberTextExpansionRuntimeState(context: Context): TextExpansionRuntimeState {
    val scope = rememberCoroutineScope()
    val snippetData = rememberTextExpansionSnippetData(context)
    val editor = rememberTextExpansionEditorFields(snippetData.snippets, scope)
    val mutation = TextExpansionSnippetMutationContext(
        scope = scope,
        context = context,
        cloudSyncEnabled = snippetData.cloudSyncEnabled,
        showToast = editor.status.showToast,
        loadDraft = editor.draft.loadDraft,
    ) { scope.launch { snippetData.reload() } }

    return TextExpansionRuntimeState(
        snippetData = snippetData,
        editor = editor,
        mutation = mutation,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun rememberTextExpansionSettingsState(): TextExpansionSettingsState {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val runtime = rememberTextExpansionRuntimeState(context)
    val snippetData = runtime.snippetData
    val draft = runtime.editor.draft
    val sandbox = runtime.editor.sandbox
    val status = runtime.editor.status

    return TextExpansionSettingsState(
        colors = textExpansionColorTokens(isDark),
        snippets = snippetData.snippets,
        filteredSnippets = snippetData.filteredSnippets,
        editor = TextExpansionEditorDraft(
            draft.editing,
            draft.title,
            draft.trigger,
            draft.body,
            draft.enabled,
        ),
        searchQuery = snippetData.searchQuery,
        sandbox = TextExpansionSandboxState(sandbox.sandboxText, sandbox.sandboxSuccess),
        cloudSyncEnabled = snippetData.cloudSyncEnabled,
        statusSnapshot = TextExpansionStatusSnapshot(status.status, status.statusIsError),
        callbacks = textExpansionSettingsCallbacks(
            mutation = runtime.mutation,
            fields = TextExpansionEditorFieldCallbacks(
                onTitleChange = draft.onTitleChange,
                onTriggerChange = draft.onTriggerChange,
                onBodyChange = draft.onBodyChange,
                onEnabledChange = draft.onEnabledChange,
                onSearchQueryChange = snippetData.onSearchQueryChange,
                onSandboxTextChange = sandbox.onSandboxTextChange,
                onCloudSyncChange = snippetData.onCloudSyncChange,
            ),
            editorInput = {
                TextExpansionSaveSnippetInput(
                    draft.trigger,
                    draft.title,
                    draft.body,
                    draft.enabled,
                    draft.editing,
                    snippetData.snippets,
                )
            },
        ),
    )
}

private data class TextExpansionSnippetMutationContext(
    val scope: CoroutineScope,
    val context: Context,
    val cloudSyncEnabled: Boolean,
    val showToast: (String, Boolean) -> Unit,
    val loadDraft: (TextExpansionSnippetEntity?) -> Unit,
    val reload: () -> Unit,
)

private fun textExpansionApplySandboxInput(
    newVal: String,
    trigger: String,
    body: String,
    snippets: List<TextExpansionSnippetEntity>,
    setSandboxText: (String) -> Unit,
    pulseSuccess: () -> Unit,
) {
    val activeTrigger = trigger.replace("&&", "").trim()
    if (activeTrigger.isNotEmpty() && newVal.endsWith("&&$activeTrigger ")) {
        setSandboxText(
            newVal.substring(0, newVal.length - (activeTrigger.length + TEXT_EXPANSION_TRIGGER_SPACE_SUFFIX_LEN)) +
                body.trim(),
        )
        pulseSuccess()
        return
    }
    for (snippet in snippets) {
        val token = "&&${snippet.trigger}"
        if (newVal.endsWith("$token ")) {
            setSandboxText(newVal.substring(0, newVal.length - (token.length + 1)) + snippet.body.trim())
            pulseSuccess()
            break
        }
    }
}

private data class TextExpansionEditorFieldCallbacks(
    val onTitleChange: (String) -> Unit,
    val onTriggerChange: (String) -> Unit,
    val onBodyChange: (String) -> Unit,
    val onEnabledChange: (Boolean) -> Unit,
    val onSearchQueryChange: (String) -> Unit,
    val onSandboxTextChange: (String) -> Unit,
    val onCloudSyncChange: (Boolean) -> Unit,
)

private fun textExpansionSettingsCallbacks(
    mutation: TextExpansionSnippetMutationContext,
    fields: TextExpansionEditorFieldCallbacks,
    editorInput: () -> TextExpansionSaveSnippetInput,
): TextExpansionSettingsCallbacks = TextExpansionSettingsCallbacks(
    onTitleChange = fields.onTitleChange,
    onTriggerChange = fields.onTriggerChange,
    onBodyChange = fields.onBodyChange,
    onEnabledChange = fields.onEnabledChange,
    onSearchQueryChange = fields.onSearchQueryChange,
    onSandboxTextChange = fields.onSandboxTextChange,
    onCloudSyncChange = fields.onCloudSyncChange,
    loadDraft = mutation.loadDraft,
    saveSnippet = { textExpansionSaveSnippet(mutation, editorInput()) },
    deleteSnippet = { textExpansionDeleteSnippet(mutation, editorInput().editing) },
    syncNow = { textExpansionSyncNow(mutation) },
    toggleSnippetEnabled = { snippet -> textExpansionToggleSnippet(mutation, snippet) },
    openKeyboardSettings = {
        mutation.context.startActivity(
            Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    },
)

private data class TextExpansionSaveSnippetInput(
    val trigger: String,
    val title: String,
    val body: String,
    val enabled: Boolean,
    val editing: TextExpansionSnippetEntity?,
    val snippets: List<TextExpansionSnippetEntity>,
)

private fun textExpansionSaveSnippet(
    mutation: TextExpansionSnippetMutationContext,
    input: TextExpansionSaveSnippetInput,
) {
    mutation.scope.launch {
        val validationError = TextExpansionTrigger.validationError(input.trigger)
        val canonicalTrigger = TextExpansionTrigger.canonicalName(input.trigger)
        val duplicateTrigger =
            validationError == null &&
                input.snippets.any { it.id != input.editing?.id && it.trigger == canonicalTrigger }
        if (snippetSaveBlocked(validationError, duplicateTrigger, input.title, input.body, input.trigger)) {
            return@launch
        }
        val now = System.currentTimeMillis()
        val entity = TextExpansionSnippetEntity(
            id = input.editing?.id ?: UUID.randomUUID().toString(),
            title = input.title.trim(),
            trigger = canonicalTrigger,
            body = input.body.trim(),
            mode = "static",
            isEnabled = input.enabled,
            scopeJson = input.editing?.scopeJson ?: "{}",
            revision = (input.editing?.revision ?: 0) + 1,
            createdAtMillis = input.editing?.createdAtMillis ?: now,
            updatedAtMillis = now,
            sourceDeviceID = input.editing?.sourceDeviceID,
        )
        withContext(Dispatchers.IO) { AppDatabase.getDatabase(mutation.context).textExpansionDao().upsert(entity) }
        mutation.showToast("Saved &&${entity.trigger}", false)
        if (mutation.cloudSyncEnabled) TextExpansionSyncWorker.enqueueImmediate(mutation.context)
        mutation.loadDraft(entity)
        mutation.reload()
    }
}

private fun textExpansionDeleteSnippet(
    mutation: TextExpansionSnippetMutationContext,
    editing: TextExpansionSnippetEntity?,
) {
    mutation.scope.launch {
        val target = editing ?: return@launch
        withContext(Dispatchers.IO) { AppDatabase.getDatabase(mutation.context).textExpansionDao().softDelete(target.id) }
        mutation.showToast("Deleted &&${target.trigger}", false)
        if (mutation.cloudSyncEnabled) TextExpansionSyncWorker.enqueueImmediate(mutation.context)
        mutation.loadDraft(null)
        mutation.reload()
    }
}

private fun textExpansionSyncNow(mutation: TextExpansionSnippetMutationContext) {
    mutation.scope.launch {
        mutation.showToast("Syncing...", false)
        val result = withContext(Dispatchers.IO) { TextExpansionSyncManager(mutation.context).sync() }
        if (result.isSuccess) {
            mutation.showToast("Sync complete", false)
            mutation.reload()
        } else {
            mutation.showToast(result.exceptionOrNull()?.message ?: "Sync failed", true)
        }
    }
}

private fun textExpansionToggleSnippet(
    mutation: TextExpansionSnippetMutationContext,
    snippet: TextExpansionSnippetEntity,
) {
    mutation.scope.launch {
        val updated = snippet.copy(
            isEnabled = !snippet.isEnabled,
            revision = snippet.revision + 1,
            updatedAtMillis = System.currentTimeMillis(),
        )
        withContext(Dispatchers.IO) { AppDatabase.getDatabase(mutation.context).textExpansionDao().upsert(updated) }
        val label = if (updated.isEnabled) "Enabled" else "Disabled"
        mutation.showToast("$label &&${updated.trigger}", false)
        mutation.reload()
    }
}

private fun snippetSaveBlocked(
    validationError: String?,
    duplicateTrigger: Boolean,
    title: String,
    body: String,
    trigger: String,
): Boolean =
    validationError != null ||
        duplicateTrigger ||
        title.isBlank() ||
        body.isBlank() ||
        trigger.isBlank()
