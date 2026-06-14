
package com.openburnbar.ui.hermes

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import com.openburnbar.data.assistants.AssistantChatAttachment
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.CLIAgentChatPresentationMode
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentRelayChatTransporting
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.CliRuntimeModelOption
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.text.TextExpansionSnippet
import com.openburnbar.services.media.AgentReplyNotificationState
import com.openburnbar.ui.text.expandStaticTextSnippetDraft
import com.openburnbar.ui.text.rememberTextExpansionSnippets
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal data class CliAgentChatActions(
    val onDraftChange: (String) -> Unit,
    val onPickPhoto: () -> Unit,
    val onPickFile: () -> Unit,
    val onPresentationModeChange: (CLIAgentChatPresentationMode) -> Unit,
    val onStartFreshThread: () -> Unit,
    val onToggleViewMode: () -> Unit,
    val onShowModelPicker: () -> Unit,
    val onDismissModelPicker: () -> Unit,
    val onShowPermissionSheet: () -> Unit,
    val onDismissPermissionSheet: () -> Unit,
    val onRefreshModelCatalog: () -> Unit,
    val onClearModelSelection: () -> Unit,
    val onSelectModel: (CliRuntimeModelOption) -> Unit,
    val onRemoveAttachment: (String) -> Unit,
    val onSend: () -> Unit,
    val onQuickPrompt: (String) -> Unit,
)

internal class CliAgentChatState(
    val runtime: AssistantRuntimeID,
    val provider: AgentProvider,
    val activeThread: AssistantChatThread,
    val activeThreadID: String,
    val draft: String,
    val isSending: Boolean,
    val streamingMessageID: String?,
    val stagedAttachments: List<AssistantChatAttachment>,
    val selectedModel: CliRuntimeModelOption?,
    val presentationMode: CLIAgentChatPresentationMode,
    val chatViewMode: ChatViewMode,
    val listState: LazyListState,
    val showModelPicker: Boolean,
    val showPermissionSheet: Boolean,
    val modelOptions: List<CliRuntimeModelOption>,
    val modelCatalogLoading: Boolean,
    val modelCatalogError: String?,
    val selectedModelID: String?,
    private val actions: CliAgentChatActions,
) {
    val onDraftChange get() = actions.onDraftChange
    val onPickPhoto get() = actions.onPickPhoto
    val onPickFile get() = actions.onPickFile
    val onPresentationModeChange get() = actions.onPresentationModeChange
    val onStartFreshThread get() = actions.onStartFreshThread
    val onToggleViewMode get() = actions.onToggleViewMode
    val onShowModelPicker get() = actions.onShowModelPicker
    val onDismissModelPicker get() = actions.onDismissModelPicker
    val onShowPermissionSheet get() = actions.onShowPermissionSheet
    val onDismissPermissionSheet get() = actions.onDismissPermissionSheet
    val onRefreshModelCatalog get() = actions.onRefreshModelCatalog
    val onClearModelSelection get() = actions.onClearModelSelection
    val onSelectModel get() = actions.onSelectModel
    val onRemoveAttachment get() = actions.onRemoveAttachment
    val onSend get() = actions.onSend
    val onQuickPrompt get() = actions.onQuickPrompt
}

internal data class CliAgentChatLifecycleArgs(
    val runtime: AssistantRuntimeID,
    val context: android.content.Context,
    val activeThread: AssistantChatThread,
    val activeThreadID: String,
    val streamingMessageID: String?,
    val listState: LazyListState,
    val onObserverCancel: () -> Unit,
    val refreshModelCatalog: suspend () -> Unit,
)

internal data class CliModelCatalogRefreshParams(
    val runtime: AssistantRuntimeID,
    val relayChatTransport: CLIAgentRelayChatTransporting,
    val selectedModelID: String?,
    val context: android.content.Context,
    val onLoading: (Boolean) -> Unit,
    val onError: (String?) -> Unit,
    val onOptions: (List<CliRuntimeModelOption>) -> Unit,
    val onSelectedModelID: (String?) -> Unit,
)

private data class CliAgentThreadSlice(
    val activeThread: AssistantChatThread,
    val activeThreadID: String,
    val draft: String,
    val pendingRequestID: String?,
    val streamingMessageID: String?,
    val observerJob: Job?,
    val stagedAttachments: List<AssistantChatAttachment>,
    val showPermissionSheet: Boolean,
    val listState: LazyListState,
    val cancelObserver: () -> Unit,
    val setDraft: (String) -> Unit,
    val setStagedAttachments: (List<AssistantChatAttachment>) -> Unit,
    val setPendingRequestID: (String?) -> Unit,
    val setStreamingMessageID: (String?) -> Unit,
    val setObserverJob: (Job?) -> Unit,
    val setActiveThreadID: (String) -> Unit,
    val setShowPermissionSheet: (Boolean) -> Unit,
)

private data class CliAgentCatalogSlice(
    val modelOptions: List<CliRuntimeModelOption>,
    val modelCatalogLoading: Boolean,
    val modelCatalogError: String?,
    val selectedModelID: String?,
    val selectedModel: CliRuntimeModelOption?,
    val showModelPicker: Boolean,
    val setModelOptions: (List<CliRuntimeModelOption>) -> Unit,
    val setModelCatalogLoading: (Boolean) -> Unit,
    val setModelCatalogError: (String?) -> Unit,
    val setSelectedModelID: (String?) -> Unit,
    val setShowModelPicker: (Boolean) -> Unit,
)

private data class CliAgentPrefsSlice(
    val presentationMode: CLIAgentChatPresentationMode,
    val chatViewMode: ChatViewMode,
    val setPresentationMode: (CLIAgentChatPresentationMode) -> Unit,
    val setChatViewMode: (ChatViewMode) -> Unit,
)

@Composable
internal fun rememberCliAgentChatState(
    runtime: AssistantRuntimeID,
    historyStore: AssistantChatHistoryStore,
    relayChatTransport: CLIAgentRelayChatTransporting,
): CliAgentChatState {
    val provider = providerFor(runtime)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val textExpansionSnippets by rememberTextExpansionSnippets()
    val dispatcher = remember { CLIAgentMissionDispatcher() }
    val thread = rememberCliAgentThreadSlice(runtime, historyStore)
    val catalog = rememberCliAgentCatalogSlice(runtime, context)
    val prefs = rememberCliAgentPrefsSlice(runtime, context)
    val sendDeps =
        remember(historyStore, relayChatTransport, dispatcher, scope) {
            CliSendMessageDeps(historyStore, relayChatTransport, dispatcher, scope)
        }
    wireCliAgentChatLifecycle(runtime, context, relayChatTransport, thread, catalog)
    val launchers = rememberCliAgentAttachmentLaunchers(context, thread)
    val dispatchSend =
        rememberCliAgentSendDispatcher(runtime, thread, catalog, prefs, sendDeps)
    val actions =
        buildCliAgentChatActions(
            context = context,
            runtime = runtime,
            historyStore = historyStore,
            scope = scope,
            focusManager = focusManager,
            textExpansionSnippets = textExpansionSnippets,
            thread = thread,
            catalog = catalog,
            prefs = prefs,
            pickPhoto = launchers.pickPhoto,
            pickFile = launchers.pickFile,
            relayChatTransport = relayChatTransport,
            dispatchSend = dispatchSend,
        )
    return CliAgentChatState(
        runtime = runtime,
        provider = provider,
        activeThread = thread.activeThread,
        activeThreadID = thread.activeThreadID,
        draft = thread.draft,
        isSending = thread.pendingRequestID != null || thread.streamingMessageID != null,
        streamingMessageID = thread.streamingMessageID,
        stagedAttachments = thread.stagedAttachments,
        selectedModel = catalog.selectedModel,
        presentationMode = prefs.presentationMode,
        chatViewMode = prefs.chatViewMode,
        listState = thread.listState,
        showModelPicker = catalog.showModelPicker,
        showPermissionSheet = thread.showPermissionSheet,
        modelOptions = catalog.modelOptions,
        modelCatalogLoading = catalog.modelCatalogLoading,
        modelCatalogError = catalog.modelCatalogError,
        selectedModelID = catalog.selectedModelID,
        actions = actions,
    )
}

@Composable
private fun rememberCliAgentThreadSlice(runtime: AssistantRuntimeID, historyStore: AssistantChatHistoryStore): CliAgentThreadSlice {
    val threads by historyStore.threads.collectAsState()
    var activeThreadID by rememberSaveable(runtime) {
        mutableStateOf(
            threads.firstOrNull { it.runtime == runtime.token }?.id
                ?: createThread(historyStore, runtime).id,
        )
    }
    var activeThread by remember(threads, activeThreadID) {
        mutableStateOf(
            threads.firstOrNull { it.id == activeThreadID }
                ?: createThread(historyStore, runtime).also { activeThreadID = it.id },
        )
    }
    var draft by rememberSaveable(runtime, activeThreadID) { mutableStateOf("") }
    var pendingRequestID by remember(activeThreadID) { mutableStateOf<String?>(null) }
    var streamingMessageID by remember(activeThreadID) { mutableStateOf<String?>(null) }
    var observerJob by remember(activeThreadID) { mutableStateOf<Job?>(null) }
    var stagedAttachments by remember(activeThreadID) {
        mutableStateOf<List<AssistantChatAttachment>>(emptyList())
    }
    var showPermissionSheet by remember(activeThreadID) { mutableStateOf(false) }
    val listState = rememberLazyListState()
    return CliAgentThreadSlice(
        activeThread = activeThread,
        activeThreadID = activeThreadID,
        draft = draft,
        pendingRequestID = pendingRequestID,
        streamingMessageID = streamingMessageID,
        observerJob = observerJob,
        stagedAttachments = stagedAttachments,
        showPermissionSheet = showPermissionSheet,
        listState = listState,
        cancelObserver = { observerJob?.cancel() },
        setDraft = { draft = it },
        setStagedAttachments = { stagedAttachments = it },
        setPendingRequestID = { pendingRequestID = it },
        setStreamingMessageID = { streamingMessageID = it },
        setObserverJob = { observerJob = it },
        setActiveThreadID = { activeThreadID = it },
        setShowPermissionSheet = { showPermissionSheet = it },
    )
}

@Composable
private fun rememberCliAgentCatalogSlice(runtime: AssistantRuntimeID, context: android.content.Context): CliAgentCatalogSlice {
    var modelOptions by remember(runtime) { mutableStateOf<List<CliRuntimeModelOption>>(emptyList()) }
    var modelCatalogError by remember(runtime) { mutableStateOf<String?>(null) }
    var modelCatalogLoading by remember(runtime) { mutableStateOf(false) }
    var selectedModelID by rememberSaveable(runtime) {
        mutableStateOf(preferredCliModelID(context, runtime))
    }
    var showModelPicker by rememberSaveable(runtime) { mutableStateOf(false) }
    val selectedModel =
        remember(modelOptions, selectedModelID) {
            selectedModelID?.trim()?.takeIf { it.isNotEmpty() }?.let { selected ->
                modelOptions.firstOrNull { it.modelID.equals(selected, ignoreCase = true) }
            }
        }
    return CliAgentCatalogSlice(
        modelOptions = modelOptions,
        modelCatalogLoading = modelCatalogLoading,
        modelCatalogError = modelCatalogError,
        selectedModelID = selectedModelID,
        selectedModel = selectedModel,
        showModelPicker = showModelPicker,
        setModelOptions = { modelOptions = it },
        setModelCatalogLoading = { modelCatalogLoading = it },
        setModelCatalogError = { modelCatalogError = it },
        setSelectedModelID = { selectedModelID = it },
        setShowModelPicker = { showModelPicker = it },
    )
}

@Composable
private fun rememberCliAgentPrefsSlice(runtime: AssistantRuntimeID, context: android.content.Context): CliAgentPrefsSlice {
    var presentationMode by rememberSaveable(runtime) {
        mutableStateOf(preferredCliPresentationMode(context, runtime))
    }
    var chatViewMode by rememberSaveable(runtime) {
        mutableStateOf(
            ChatViewMode.fromKey(context.getSharedPreferences("chat", 0).getString("viewMode", null)),
        )
    }
    return CliAgentPrefsSlice(
        presentationMode = presentationMode,
        chatViewMode = chatViewMode,
        setPresentationMode = { presentationMode = it },
        setChatViewMode = { chatViewMode = it },
    )
}

@Composable
private fun wireCliAgentChatLifecycle(
    runtime: AssistantRuntimeID,
    context: android.content.Context,
    relayChatTransport: CLIAgentRelayChatTransporting,
    thread: CliAgentThreadSlice,
    catalog: CliAgentCatalogSlice,
) {
    CliAgentChatLifecycleEffects(
        args =
        CliAgentChatLifecycleArgs(
            runtime = runtime,
            context = context,
            activeThread = thread.activeThread,
            activeThreadID = thread.activeThreadID,
            streamingMessageID = thread.streamingMessageID,
            listState = thread.listState,
            onObserverCancel = thread.cancelObserver,
            refreshModelCatalog = {
                refreshCliModelCatalog(
                    params =
                    CliModelCatalogRefreshParams(
                        runtime = runtime,
                        relayChatTransport = relayChatTransport,
                        selectedModelID = catalog.selectedModelID,
                        context = context,
                        onLoading = catalog.setModelCatalogLoading,
                        onError = catalog.setModelCatalogError,
                        onOptions = catalog.setModelOptions,
                        onSelectedModelID = catalog.setSelectedModelID,
                    ),
                )
            },
        ),
    )
}

private data class CliAgentAttachmentLaunchers(val pickPhoto: () -> Unit, val pickFile: () -> Unit)

@Composable
private fun rememberCliAgentAttachmentLaunchers(context: android.content.Context, thread: CliAgentThreadSlice): CliAgentAttachmentLaunchers {
    val pickPhotoLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
            uri?.let {
                thread.setStagedAttachments(
                    thread.stagedAttachments + attachmentFor(context, it, "image/*"),
                )
            }
        }
    val pickFileLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            uri?.let {
                thread.setStagedAttachments(
                    thread.stagedAttachments + attachmentFor(context, it, "application/octet-stream"),
                )
            }
        }
    return CliAgentAttachmentLaunchers(
        pickPhoto = { pickPhotoLauncher.launch("image/*") },
        pickFile = { pickFileLauncher.launch(arrayOf("*/*")) },
    )
}

@Composable
private fun rememberCliAgentSendDispatcher(
    runtime: AssistantRuntimeID,
    thread: CliAgentThreadSlice,
    catalog: CliAgentCatalogSlice,
    prefs: CliAgentPrefsSlice,
    sendDeps: CliSendMessageDeps,
): (String, List<AssistantChatAttachment>) -> Unit = remember(runtime, thread, catalog, prefs, sendDeps) {
    { text, attachments ->
        sendCliAgentMessage(
            text = text,
            attachments = attachments,
            runtime = runtime,
            selectedModelID = catalog.selectedModel?.modelID,
            presentationMode = prefs.presentationMode,
            threadID = thread.activeThreadID,
            deps = sendDeps,
            onPending = { id, msgID, job ->
                thread.setPendingRequestID(id)
                thread.setStreamingMessageID(msgID)
                thread.setObserverJob(job)
            },
            onStreamComplete = {
                thread.setPendingRequestID(null)
                thread.setStreamingMessageID(null)
                thread.setStagedAttachments(emptyList())
            },
        )
    }
}

private fun buildCliAgentChatActions(
    context: android.content.Context,
    runtime: AssistantRuntimeID,
    historyStore: AssistantChatHistoryStore,
    scope: CoroutineScope,
    focusManager: androidx.compose.ui.focus.FocusManager,
    textExpansionSnippets: List<com.openburnbar.data.text.TextExpansionSnippet>,
    thread: CliAgentThreadSlice,
    catalog: CliAgentCatalogSlice,
    prefs: CliAgentPrefsSlice,
    pickPhoto: () -> Unit,
    pickFile: () -> Unit,
    relayChatTransport: CLIAgentRelayChatTransporting,
    dispatchSend: (String, List<AssistantChatAttachment>) -> Unit,
): CliAgentChatActions {
    val catalogActions = buildCliAgentCatalogActions(context, runtime, scope, catalog, relayChatTransport)
    val threadActions =
        buildCliAgentThreadActions(
            context = context,
            historyStore = historyStore,
            runtime = runtime,
            focusManager = focusManager,
            textExpansionSnippets = textExpansionSnippets,
            thread = thread,
            prefs = prefs,
            dispatchSend = dispatchSend,
        )
    return CliAgentChatActions(
        onDraftChange = threadActions.onDraftChange,
        onPickPhoto = pickPhoto,
        onPickFile = pickFile,
        onPresentationModeChange = threadActions.onPresentationModeChange,
        onStartFreshThread = threadActions.onStartFreshThread,
        onToggleViewMode = threadActions.onToggleViewMode,
        onShowModelPicker = catalogActions.onShowModelPicker,
        onDismissModelPicker = catalogActions.onDismissModelPicker,
        onShowPermissionSheet = threadActions.onShowPermissionSheet,
        onDismissPermissionSheet = threadActions.onDismissPermissionSheet,
        onRefreshModelCatalog = catalogActions.onRefreshModelCatalog,
        onClearModelSelection = catalogActions.onClearModelSelection,
        onSelectModel = catalogActions.onSelectModel,
        onRemoveAttachment = threadActions.onRemoveAttachment,
        onSend = threadActions.onSend,
        onQuickPrompt = threadActions.onQuickPrompt,
    )
}

private data class CliAgentCatalogActions(
    val onShowModelPicker: () -> Unit,
    val onDismissModelPicker: () -> Unit,
    val onRefreshModelCatalog: () -> Unit,
    val onClearModelSelection: () -> Unit,
    val onSelectModel: (CliRuntimeModelOption) -> Unit,
)

private fun buildCliAgentCatalogActions(
    context: android.content.Context,
    runtime: AssistantRuntimeID,
    scope: CoroutineScope,
    catalog: CliAgentCatalogSlice,
    relayChatTransport: CLIAgentRelayChatTransporting,
): CliAgentCatalogActions = CliAgentCatalogActions(
    onShowModelPicker = { catalog.setShowModelPicker(true) },
    onDismissModelPicker = { catalog.setShowModelPicker(false) },
    onRefreshModelCatalog = {
        scope.launch {
            refreshCliModelCatalog(
                params =
                CliModelCatalogRefreshParams(
                    runtime = runtime,
                    relayChatTransport = relayChatTransport,
                    selectedModelID = catalog.selectedModelID,
                    context = context,
                    onLoading = catalog.setModelCatalogLoading,
                    onError = catalog.setModelCatalogError,
                    onOptions = catalog.setModelOptions,
                    onSelectedModelID = catalog.setSelectedModelID,
                ),
            )
        }
    },
    onClearModelSelection = {
        setPreferredCliModelID(context, runtime, null)
        catalog.setSelectedModelID(null)
        catalog.setShowModelPicker(false)
    },
    onSelectModel = { option ->
        val modelID = option.modelID.trim().takeIf { it.isNotEmpty() }
        setPreferredCliModelID(context, runtime, modelID)
        catalog.setSelectedModelID(modelID)
        catalog.setShowModelPicker(false)
    },
)

private data class CliAgentThreadActions(
    val onDraftChange: (String) -> Unit,
    val onPresentationModeChange: (CLIAgentChatPresentationMode) -> Unit,
    val onStartFreshThread: () -> Unit,
    val onToggleViewMode: () -> Unit,
    val onShowPermissionSheet: () -> Unit,
    val onDismissPermissionSheet: () -> Unit,
    val onRemoveAttachment: (String) -> Unit,
    val onSend: () -> Unit,
    val onQuickPrompt: (String) -> Unit,
)

private fun buildCliAgentThreadActions(
    context: android.content.Context,
    historyStore: AssistantChatHistoryStore,
    runtime: AssistantRuntimeID,
    focusManager: androidx.compose.ui.focus.FocusManager,
    textExpansionSnippets: List<com.openburnbar.data.text.TextExpansionSnippet>,
    thread: CliAgentThreadSlice,
    prefs: CliAgentPrefsSlice,
    dispatchSend: (String, List<AssistantChatAttachment>) -> Unit,
): CliAgentThreadActions = CliAgentThreadActions(
    onDraftChange = { thread.setDraft(expandStaticTextSnippetDraft(it, textExpansionSnippets)) },
    onPresentationModeChange = { mode ->
        prefs.setPresentationMode(mode)
        setPreferredCliPresentationMode(context, runtime, mode)
    },
    onStartFreshThread = {
        thread.setStagedAttachments(emptyList())
        thread.setDraft("")
        thread.cancelObserver()
        thread.setPendingRequestID(null)
        thread.setStreamingMessageID(null)
        if (thread.activeThread.messages.isNotEmpty()) {
            thread.setActiveThreadID(createThread(historyStore, runtime).id)
        }
    },
    onToggleViewMode = {
        val next = if (prefs.chatViewMode == ChatViewMode.AGENT) ChatViewMode.CLI else ChatViewMode.AGENT
        prefs.setChatViewMode(next)
        context.getSharedPreferences("chat", 0).edit().putString("viewMode", next.key).apply()
    },
    onShowPermissionSheet = { thread.setShowPermissionSheet(true) },
    onDismissPermissionSheet = { thread.setShowPermissionSheet(false) },
    onRemoveAttachment = { id ->
        thread.setStagedAttachments(thread.stagedAttachments.filterNot { it.id == id })
    },
    onSend = {
        val text = thread.draft.trim()
        if (text.isNotEmpty() || thread.stagedAttachments.isNotEmpty()) {
            val pending = thread.stagedAttachments
            thread.setDraft("")
            focusManager.clearFocus()
            dispatchSend(text.ifEmpty { "[attachments]" }, pending)
            thread.setStagedAttachments(emptyList())
        }
    },
    onQuickPrompt = { prompt -> dispatchSend(prompt, thread.stagedAttachments) },
)

@Composable
internal fun CliAgentChatLifecycleEffects(args: CliAgentChatLifecycleArgs) {
    LaunchedEffect(args.runtime) { args.refreshModelCatalog() }
    LaunchedEffect(args.activeThread.messages.size, args.streamingMessageID) {
        if (args.activeThread.messages.isNotEmpty()) {
            args.listState.animateScrollToItem(args.activeThread.messages.lastIndex)
        }
    }
    DisposableEffect(args.runtime, args.activeThreadID) {
        AgentReplyNotificationState.setActiveChat(
            context = args.context,
            runtime = args.runtime.token,
            threadId = args.activeThreadID,
            surface = "android_cli_agent_chat",
        )
        onDispose {
            args.onObserverCancel()
            AgentReplyNotificationState.setActiveChat(
                context = args.context,
                runtime = null,
                threadId = null,
                surface = null,
            )
        }
    }
}

internal suspend fun refreshCliModelCatalog(params: CliModelCatalogRefreshParams) {
    params.onLoading(true)
    params.onError(null)
    try {
        val catalog = params.relayChatTransport.fetchModelCatalog(params.runtime)
        params.onOptions(catalog.options)
        val selected = params.selectedModelID?.trim()?.takeIf { it.isNotEmpty() }
        if (selected != null && catalog.options.none { it.modelID.equals(selected, ignoreCase = true) }) {
            setPreferredCliModelID(params.context, params.runtime, null)
            params.onSelectedModelID(null)
            params.onError(
                "Saved model '$selected' is no longer advertised by this Mac. " +
                    "Pick an available ${params.runtime.displayName} model.",
            )
        }
    } catch (t: IOException) {
        params.onOptions(emptyList())
        params.onError(t.message ?: "Could not read this Mac's ${params.runtime.displayName} model catalog.")
    } finally {
        params.onLoading(false)
    }
}

internal fun sendCliAgentMessage(
    text: String,
    attachments: List<AssistantChatAttachment>,
    runtime: AssistantRuntimeID,
    selectedModelID: String?,
    presentationMode: CLIAgentChatPresentationMode,
    threadID: String,
    deps: CliSendMessageDeps,
    onPending: (String?, String?, Job?) -> Unit,
    onStreamComplete: () -> Unit,
) {
    sendMessage(
        request =
        CliSendMessageRequest(
            text = text,
            attachments = attachments,
            runtime = runtime,
            requestedModelID = selectedModelID,
            presentationMode = presentationMode,
            threadID = threadID,
        ),
        deps = deps,
        callbacks =
        CliSendMessageCallbacks(
            onPending = onPending,
            onStreamComplete = onStreamComplete,
        ),
    )
}
