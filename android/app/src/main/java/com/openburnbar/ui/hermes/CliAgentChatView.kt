package com.openburnbar.ui.hermes

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.R
import com.openburnbar.data.assistants.AssistantChatAttachment
import com.openburnbar.data.assistants.AssistantChatHermesMetadata
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.AssistantChatToolCall
import com.openburnbar.data.assistants.CLIAgentChatPresentationMode
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.assistants.CLIAgentRelayChatEvent
import com.openburnbar.data.assistants.CLIAgentRelayChatTransporting
import com.openburnbar.data.assistants.CLIAgentRelayTranscriptPieceKind
import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.data.computeruse.AgentDesktopCapability
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.CliRuntimeModelOption
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.services.media.AgentReplyNotificationState
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.ProviderLogoStyle
import com.openburnbar.ui.components.ProviderLogoView
import com.openburnbar.ui.computeruse.AgentPermissionGrantSheet
import com.openburnbar.ui.text.expandStaticTextSnippetDraft
import com.openburnbar.ui.text.rememberTextExpansionSnippets
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

// MARK: - CLI agent chat surface (Codex / Claude Code / OpenClaw)
//
// Parity with `HermesView`:
//   • `CenterAlignedTopAppBar` with title ("New Chat" / thread title),
//     New Chat (+) action, Model picker (Psychology) action, and desktop
//     permission action.
//   • Empty-state hero with the *real provider logo* + ready headline
//     + model/runtime chip + quick-prompt chips.
//   • Message bubbles with provider-logo byline on assistant rows.
//   • Streaming dots while the Mac runtime executes.
//   • Working attachment pickers — `GetContent` for photos,
//     `OpenDocument` for files — wired through
//     `AssistantChatHistoryStore.AssistantChatAttachment` so the next
//     dispatch carries the URI metadata.
//   • Mercury-styled send button that honors three states (ready /
//     empty / streaming) with the correct disabled affordance.
//
// Native chat streams through the same `/v1/cli-agent/chat` encrypted
// Mac-relay contract as iOS. The mission dispatcher is reserved for the
// explicit "Mac CLI" presentation mode and relay fallback.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CliAgentChatView(
    runtime: AssistantRuntimeID,
    historyStore: AssistantChatHistoryStore,
    relayChatTransport: CLIAgentRelayChatTransporting,
) {
    val provider = providerFor(runtime)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val textExpansionSnippets by rememberTextExpansionSnippets()
    var modelOptions by remember(runtime) { mutableStateOf<List<CliRuntimeModelOption>>(emptyList()) }
    var modelCatalogError by remember(runtime) { mutableStateOf<String?>(null) }
    var modelCatalogLoading by remember(runtime) { mutableStateOf(false) }

    val dispatcher = remember { CLIAgentMissionDispatcher() }
    val threads by historyStore.threads.collectAsState()

    var activeThreadID by rememberSaveable(runtime) {
        mutableStateOf(
            threads.firstOrNull { it.runtime == runtime.token }?.id
                ?: createThread(historyStore, runtime).id
        )
    }
    val activeThread = remember(threads, activeThreadID) {
        threads.firstOrNull { it.id == activeThreadID }
            ?: createThread(historyStore, runtime).also { activeThreadID = it.id }
    }

    var draft by rememberSaveable(runtime, activeThreadID) { mutableStateOf("") }
    var pendingRequestID by remember(activeThreadID) { mutableStateOf<String?>(null) }
    var streamingMessageID by remember(activeThreadID) { mutableStateOf<String?>(null) }
    var observerJob by remember(activeThreadID) { mutableStateOf<Job?>(null) }
    var stagedAttachments by remember(activeThreadID) {
        mutableStateOf<List<AssistantChatAttachment>>(emptyList())
    }
    var selectedModelID by rememberSaveable(runtime) {
        mutableStateOf(preferredCliModelID(context, runtime))
    }
    var presentationMode by rememberSaveable(runtime) {
        mutableStateOf(preferredCliPresentationMode(context, runtime))
    }
    var showModelPicker by rememberSaveable(runtime) { mutableStateOf(false) }
    var showPermissionSheet by remember(activeThreadID) { mutableStateOf(false) }
    var chatViewMode by rememberSaveable(runtime) {
        mutableStateOf(
            ChatViewMode.fromKey(
                context.getSharedPreferences("chat", 0).getString("viewMode", null)
            )
        )
    }
    val selectedModel = remember(modelOptions, selectedModelID) {
        val selected = selectedModelID?.trim()?.takeIf { it.isNotEmpty() }
        if (selected == null) {
            null
        } else {
            modelOptions.firstOrNull { it.modelID.equals(selected, ignoreCase = true) }
        }
    }

    val listState = rememberLazyListState()

    suspend fun refreshModelCatalog() {
        modelCatalogLoading = true
        modelCatalogError = null
        try {
            val catalog = relayChatTransport.fetchModelCatalog(runtime)
            modelOptions = catalog.options
            val selected = selectedModelID?.trim()?.takeIf { it.isNotEmpty() }
            if (selected != null && catalog.options.none { it.modelID.equals(selected, ignoreCase = true) }) {
                setPreferredCliModelID(context, runtime, null)
                selectedModelID = null
                modelCatalogError = "Saved model '$selected' is no longer advertised by this Mac. Pick an available ${runtime.displayName} model."
            }
        } catch (t: Throwable) {
            modelOptions = emptyList()
            modelCatalogError = t.message ?: "Could not read this Mac's ${runtime.displayName} model catalog."
        } finally {
            modelCatalogLoading = false
        }
    }

    LaunchedEffect(runtime) {
        refreshModelCatalog()
    }

    // Photo picker — uses the Photo Picker API on Android 13+ and a
    // `GetContent` fallback on older OSes (the contract picks the right
    // one automatically when called with the `image/*` MIME type).
    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri != null) {
            stagedAttachments = stagedAttachments + attachmentFor(
                context = context,
                uri = uri,
                fallbackMime = "image/*",
            )
        }
    }

    // File picker — opens the system document picker. Returns null on
    // cancel which we silently ignore.
    val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            stagedAttachments = stagedAttachments + attachmentFor(
                context = context,
                uri = uri,
                fallbackMime = "application/octet-stream",
            )
        }
    }

    LaunchedEffect(activeThread.messages.size, streamingMessageID) {
        if (activeThread.messages.isNotEmpty()) {
            listState.animateScrollToItem(activeThread.messages.lastIndex)
        }
    }

    DisposableEffect(runtime, activeThreadID) {
        AgentReplyNotificationState.setActiveChat(
            context = context,
            runtime = runtime.token,
            threadId = activeThreadID,
            surface = "android_cli_agent_chat",
        )
        onDispose {
            observerJob?.cancel()
            AgentReplyNotificationState.setActiveChat(
                context = context,
                runtime = null,
                threadId = null,
                surface = null,
            )
        }
    }

    val title = activeThread.title.takeIf { it.isNotBlank() } ?: "New Chat"
    fun startFreshThread() {
        stagedAttachments = emptyList()
        draft = ""
        observerJob?.cancel()
        pendingRequestID = null
        streamingMessageID = null
        if (activeThread.messages.isNotEmpty()) {
            val fresh = createThread(historyStore, runtime)
            activeThreadID = fresh.id
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = title,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                },
                navigationIcon = {
                    Box(
                        modifier = Modifier
                            .padding(start = 12.dp)
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color(provider.brandColor).copy(alpha = 0.16f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        ProviderLogo(provider = provider, size = 24.dp, circular = true)
                    }
                },
                actions = {
                    IconButton(onClick = { startFreshThread() }) {
                        Icon(
                            imageVector = Icons.Filled.Add,
                            contentDescription = "Start a new chat",
                        )
                    }
                    IconButton(onClick = { showModelPicker = true }) {
                        Icon(
                            imageVector = Icons.Filled.Psychology,
                            contentDescription = "Model for ${runtime.displayName}",
                        )
                    }
                    IconButton(onClick = { showPermissionSheet = true }) {
                        Icon(
                            imageVector = Icons.Filled.Security,
                            contentDescription = "Agent permissions",
                        )
                    }
                    // View mode toggle: Agent ↔ CLI
                    IconButton(onClick = {
                        val next = if (chatViewMode == ChatViewMode.AGENT) ChatViewMode.CLI else ChatViewMode.AGENT
                        chatViewMode = next
                        context.getSharedPreferences("chat", 0).edit().putString("viewMode", next.key).apply()
                    }) {
                        Icon(
                            imageVector = if (chatViewMode == ChatViewMode.CLI) Icons.Filled.Terminal else Icons.Filled.ChatBubble,
                            contentDescription = if (chatViewMode == ChatViewMode.CLI) "Switch to Agent view" else "Switch to CLI view",
                            tint = if (chatViewMode == ChatViewMode.CLI) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent,
                ),
            )
        },
        containerColor = Color.Transparent,
    ) { innerPadding ->
        Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                if (activeThread.messages.isEmpty()) {
                    EmptyStateHero(
                        runtime = runtime,
                        provider = provider,
                        quickPrompts = quickPromptsFor(runtime),
                        selectedModel = selectedModel ?: modelOptions.firstOrNull(),
                        onQuickPrompt = onQuickPrompt@{ prompt ->
                            sendMessage(
                                text = prompt,
                                attachments = stagedAttachments,
                                runtime = runtime,
                                requestedModelID = selectedModel?.modelID,
                                presentationMode = presentationMode,
                                threadID = activeThreadID,
                                historyStore = historyStore,
                                relayChatTransport = relayChatTransport,
                                dispatcher = dispatcher,
                                scope = scope,
                                onPending = { id, msgID, job ->
                                    pendingRequestID = id
                                    streamingMessageID = msgID
                                    observerJob = job
                                },
                                onStreamComplete = {
                                    pendingRequestID = null
                                    streamingMessageID = null
                                    stagedAttachments = emptyList()
                                },
                            )
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    LazyColumn(
                        state = listState,
                        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(activeThread.messages, key = { it.id }) { message ->
                            MessageBubble(
                                message = message,
                                runtime = runtime,
                                provider = provider,
                                isStreaming = message.id == streamingMessageID && message.text.isBlank(),
                                viewMode = chatViewMode,
                            )
                        }
                    }
                }
            }

            if (stagedAttachments.isNotEmpty()) {
                StagedAttachmentRow(
                    attachments = stagedAttachments,
                    accent = Color(provider.brandColor),
                    onRemove = { id ->
                        stagedAttachments = stagedAttachments.filterNot { it.id == id }
                    },
                )
            }

            ComposerBar(
                runtime = runtime,
                provider = provider,
                draft = draft,
                onDraftChange = { draft = expandStaticTextSnippetDraft(it, textExpansionSnippets) },
                isSending = pendingRequestID != null || streamingMessageID != null,
                onPickPhoto = { pickPhoto.launch("image/*") },
                onPickFile = { pickFile.launch(arrayOf("*/*")) },
                presentationMode = presentationMode,
                onPresentationModeChange = { mode ->
                    presentationMode = mode
                    setPreferredCliPresentationMode(context, runtime, mode)
                },
                onSend = send@{
                    val text = draft.trim()
                    if (text.isEmpty() && stagedAttachments.isEmpty()) return@send
                    val pending = stagedAttachments
                    draft = ""
                    focusManager.clearFocus()
                    sendMessage(
                        text = text.ifEmpty { "[attachments]" },
                        attachments = pending,
                        runtime = runtime,
                        requestedModelID = selectedModel?.modelID,
                        presentationMode = presentationMode,
                        threadID = activeThreadID,
                        historyStore = historyStore,
                        relayChatTransport = relayChatTransport,
                        dispatcher = dispatcher,
                        scope = scope,
                        onPending = { id, msgID, job ->
                            pendingRequestID = id
                            streamingMessageID = msgID
                            observerJob = job
                        },
                        onStreamComplete = {
                            pendingRequestID = null
                            streamingMessageID = null
                            stagedAttachments = emptyList()
                        },
                    )
                    stagedAttachments = emptyList()
                },
            )
        }
    }

    if (showPermissionSheet) {
        AgentPermissionGrantSheet(
            runtime = runtime.token,
            threadId = activeThreadID,
            onDismiss = { showPermissionSheet = false },
        )
    }

    if (showModelPicker) {
        CliModelPickerDialog(
            runtime = runtime,
            options = modelOptions,
            isLoading = modelCatalogLoading,
            errorText = modelCatalogError,
            selectedModelID = selectedModelID,
            onDismiss = { showModelPicker = false },
            onRefresh = {
                scope.launch { refreshModelCatalog() }
            },
            onClear = {
                setPreferredCliModelID(context, runtime, null)
                selectedModelID = null
                showModelPicker = false
            },
            onSelect = { option ->
                val modelID = option.modelID.trim().takeIf { it.isNotEmpty() }
                setPreferredCliModelID(context, runtime, modelID)
                selectedModelID = modelID
                showModelPicker = false
            },
        )
    }
}

// MARK: - CLI model picker

@Composable
private fun CliModelPickerDialog(
    runtime: AssistantRuntimeID,
    options: List<CliRuntimeModelOption>,
    isLoading: Boolean,
    errorText: String?,
    selectedModelID: String?,
    onDismiss: () -> Unit,
    onRefresh: () -> Unit,
    onClear: () -> Unit,
    onSelect: (CliRuntimeModelOption) -> Unit,
) {
    val grouped = remember(options) { options.groupBy { it.providerName } }
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
            border = BorderStroke(1.2.dp, Brush.linearGradient(AuroraGradients.glassStroke)),
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 24.dp, horizontal = 12.dp)
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(
                        imageVector = Icons.Filled.Psychology,
                        contentDescription = null,
                        tint = AuroraColors.ember,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "${runtime.displayName} Model",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }

                Box(
                    modifier = Modifier
                        .weight(1f, fill = false)
                        .fillMaxWidth()
                ) {
                    if (options.isEmpty()) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                text = if (isLoading) {
                                    "Reading ${runtime.displayName}'s live model catalog from the paired Mac..."
                                } else {
                                    errorText ?: "${runtime.displayName} has not returned a live Mac catalog yet."
                                },
                                fontSize = 13.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                modifier = Modifier.padding(horizontal = 16.dp)
                            )
                            if (isLoading) {
                                androidx.compose.material3.CircularProgressIndicator(
                                    color = AuroraColors.ember,
                                    modifier = Modifier.size(24.dp),
                                    strokeWidth = 2.5.dp
                                )
                            } else {
                                Surface(
                                    shape = RoundedCornerShape(percent = 50),
                                    color = AuroraColors.ember.copy(alpha = 0.12f),
                                    border = BorderStroke(0.75.dp, AuroraColors.ember.copy(alpha = 0.35f)),
                                    modifier = Modifier.clip(RoundedCornerShape(percent = 50)).clickable { onRefresh() }
                                ) {
                                    Text(
                                        text = "Refresh Mac catalog",
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = AuroraColors.ember,
                                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)
                                    )
                                }
                            }
                        }
                    } else {
                        LazyColumn(
                            modifier = Modifier.heightIn(max = 420.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            grouped.forEach { (groupName, rows) ->
                                item(key = "header-$groupName") {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp)
                                    ) {
                                        if (rows.any { it.source.showsOpenBurnBarProxyBadge }) {
                                            AppLogoBadge(size = 18.dp)
                                        } else {
                                            ProviderLogoView(
                                                drawableRes = ProviderLogo.drawableForAnyIdentifier(rows.firstOrNull()?.providerID ?: groupName),
                                                size = 18.dp,
                                                style = ProviderLogoStyle.Tile,
                                            )
                                        }
                                        Spacer(modifier = Modifier.width(8.dp))
                                        Text(
                                            text = groupName.uppercase(),
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.ExtraBold,
                                            color = AuroraColors.ember,
                                            letterSpacing = 1.sp
                                        )
                                    }
                                }
                                items(rows, key = { it.modelID }) { option ->
                                    val optionID = option.modelID.trim()
                                    val selectedID = selectedModelID?.trim()
                                    CliModelPickerRow(
                                        option = option,
                                        selected = if (optionID.isEmpty()) selectedID.isNullOrEmpty() else optionID == selectedID,
                                        onClick = { onSelect(option) },
                                    )
                                }
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)
                ) {
                    TextButton(onClick = onClear) {
                        Text("Use default", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Surface(
                        shape = RoundedCornerShape(percent = 50),
                        color = AuroraColors.ember,
                        modifier = Modifier.clip(RoundedCornerShape(percent = 50)).clickable { onDismiss() }
                    ) {
                        Text(
                            text = "Done",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CliModelPickerRow(
    option: CliRuntimeModelOption,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val accent = sourceColor(option)
    val glassStrokeBrush = Brush.linearGradient(
        if (selected)
            listOf(accent, accent.copy(alpha = 0.4f))
        else
            listOf(MaterialTheme.colorScheme.outline.copy(alpha = 0.12f), MaterialTheme.colorScheme.outline.copy(alpha = 0.06f))
    )
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = if (selected) accent.copy(alpha = 0.08f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        border = BorderStroke(if (selected) 1.2.dp else 0.6.dp, glassStrokeBrush),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .clickable { onClick() }
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            CliModelLogo(option = option, size = 32.dp)
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = option.displayName,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    SourcePill(option = option)
                }
                if (option.modelID.isNotBlank()) {
                    Text(
                        text = option.modelID,
                        fontSize = 10.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    )
                }
                Text(
                    text = option.source.detailLabel,
                    fontSize = 10.sp,
                    color = accent.copy(alpha = 0.8f),
                )
            }
        }
    }
}

@Composable
private fun CliModelLogo(option: CliRuntimeModelOption, size: androidx.compose.ui.unit.Dp) {
    Box(modifier = Modifier.size(size), contentAlignment = Alignment.BottomEnd) {
        ProviderLogoView(
            drawableRes = ProviderLogo.drawableForAnyIdentifier("${option.providerID} ${option.modelID}"),
            size = size,
            style = ProviderLogoStyle.Tile,
        )
        if (option.source.showsOpenBurnBarProxyBadge) {
            AppLogoBadge(
                size = size * 0.42f,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 0.dp, bottom = 0.dp),
            )
        }
    }
}

@Composable
private fun AppLogoBadge(
    size: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.96f))
            .border(0.7.dp, Color.White.copy(alpha = 0.55f), RoundedCornerShape(size * 0.28f)),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(id = R.drawable.app_logo),
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = Modifier.size(size * 0.74f),
        )
    }
}

@Composable
private fun SourcePill(option: CliRuntimeModelOption) {
    val accent = sourceColor(option)
    Surface(
        shape = RoundedCornerShape(percent = 50),
        color = accent.copy(alpha = 0.16f),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, accent.copy(alpha = 0.36f)),
    ) {
        Text(
            text = option.source.displayLabel,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp),
        )
    }
}

private fun sourceColor(option: CliRuntimeModelOption): Color = when (option.source) {
    com.openburnbar.data.hermes.CliModelSource.DROID_STANDARD_QUOTA,
    com.openburnbar.data.hermes.CliModelSource.DROID_CORE_QUOTA -> Color(0xFFF59E0B)
    com.openburnbar.data.hermes.CliModelSource.OPENBURNBAR_PROXY -> Color(0xFF22C55E)
    com.openburnbar.data.hermes.CliModelSource.DROID_CUSTOM_MODEL -> MaterialThemeColorFallback.textSecondary
    else -> MaterialThemeColorFallback.textSecondary
}

private object MaterialThemeColorFallback {
    val textSecondary = Color(0xFF9CA3AF)
}

// MARK: - Empty state

@Composable
private fun EmptyStateHero(
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    quickPrompts: List<String>,
    selectedModel: CliRuntimeModelOption?,
    onQuickPrompt: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    Column(
        modifier = modifier.padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Surface(
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
            border = BorderStroke(1.2.dp, glassStrokeBrush),
            modifier = Modifier.padding(horizontal = 8.dp)
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    modifier = Modifier
                        .size(80.dp)
                        .background(Brush.linearGradient(AuroraGradients.providerRing(provider)), CircleShape)
                        .padding(3.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surface),
                        contentAlignment = Alignment.Center
                    ) {
                        ProviderLogo(provider = provider, size = 56.dp, circular = true)
                    }
                }
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = "${provider.displayName} is ready",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(provider.brandColor),
                )
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = readyTagline(runtime),
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(16.dp))
                Surface(
                    shape = RoundedCornerShape(percent = 50),
                    color = Color(provider.brandColor).copy(alpha = 0.08f),
                    border = BorderStroke(0.75.dp, Color(provider.brandColor).copy(alpha = 0.35f)),
                    modifier = Modifier.fillMaxWidth(0.92f),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    ) {
                        if (selectedModel != null) {
                            CliModelLogo(option = selectedModel, size = 14.dp)
                        } else {
                            ProviderLogo(provider = provider, size = 14.dp, circular = true)
                        }
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = selectedModel?.let { "${it.displayName} · ${it.source.displayLabel}" }
                            ?: "${provider.displayName} · default Mac model",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color(provider.brandColor),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(28.dp))

        if (quickPrompts.isNotEmpty()) {
            Text(
                text = "SUGGESTED PROMPTS",
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                letterSpacing = 1.sp,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(horizontal = 4.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(quickPrompts) { prompt ->
                    Surface(
                        shape = RoundedCornerShape(percent = 50),
                        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.25f),
                        border = BorderStroke(0.75.dp, Color(provider.brandColor).copy(alpha = 0.25f)),
                        modifier = Modifier.padding(vertical = 4.dp),
                    ) {
                        Text(
                            text = prompt,
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .clip(RoundedCornerShape(percent = 50))
                                .clickable { onQuickPrompt(prompt) }
                                .padding(horizontal = 14.dp, vertical = 9.dp),
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Bubble row

@Composable
private fun MessageBubble(
    message: AssistantChatMessage,
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    isStreaming: Boolean,
    viewMode: ChatViewMode = ChatViewMode.AGENT,
) {
    val isUser = message.role == "user"
    if (viewMode == ChatViewMode.CLI) {
        CLIMessageRow(message = message, isUser = isUser, isHermes = runtime == AssistantRuntimeID.HERMES)
    } else if (isUser) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Column(horizontalAlignment = Alignment.End) {
                Surface(
                    shape = RoundedCornerShape(
                        topStart = 20.dp,
                        topEnd = 20.dp,
                        bottomStart = 20.dp,
                        bottomEnd = 4.dp
                    ),
                    color = Color(provider.brandColor).copy(alpha = 0.12f),
                    border = BorderStroke(
                        width = 0.75.dp,
                        brush = Brush.linearGradient(
                            listOf(Color(provider.brandColor).copy(alpha = 0.45f), Color(provider.accentColor).copy(alpha = 0.15f))
                        )
                    ),
                ) {
                    Text(
                        text = message.text,
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .widthIn(max = 280.dp)
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                }
                if (message.attachments.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(6.dp))
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        message.attachments.forEach { att ->
                            AttachmentChip(att = att, accent = Color(provider.brandColor))
                        }
                    }
                }
            }
        }
    } else {
        Row(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(18.dp)
                            .clip(CircleShape)
                            .background(
                                Brush.linearGradient(
                                    listOf(Color(provider.brandColor), Color(provider.accentColor).copy(alpha = 0.75f))
                                )
                            )
                            .padding(1.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        ProviderLogo(provider = provider, size = 12.dp, circular = true)
                    }
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = provider.displayName,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = Color(provider.brandColor),
                    )
                    if (!message.modelName.isNullOrBlank()) {
                        Text(
                            text = " · ${message.modelName}",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        )
                    }
                }
                Spacer(modifier = Modifier.height(4.dp))
                Surface(
                    shape = RoundedCornerShape(
                        topStart = 4.dp,
                        topEnd = 20.dp,
                        bottomStart = 20.dp,
                        bottomEnd = 20.dp
                    ),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
                    border = BorderStroke(
                        width = 0.75.dp,
                        brush = Brush.linearGradient(
                            listOf(
                                Color(provider.brandColor).copy(alpha = 0.28f),
                                MaterialTheme.colorScheme.outline.copy(alpha = 0.12f)
                            )
                        )
                    ),
                ) {
                    if (isStreaming) {
                        StreamingDots(
                            modifier = Modifier.padding(horizontal = 18.dp, vertical = 14.dp),
                        )
                    } else {
                        Text(
                            text = message.text,
                            fontSize = 15.sp,
                            color = if (message.isError)
                                MaterialTheme.colorScheme.error
                            else
                                MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
                                .widthIn(max = 320.dp)
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        )
                    }
                }
                val toolCalls = message.hermes?.toolCalls.orEmpty()
                if (toolCalls.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(6.dp))
                    AssistantToolCallStrip(
                        toolCalls = toolCalls,
                        accent = Color(provider.brandColor),
                    )
                }
            }
        }
    }
}

@Composable
private fun AssistantToolCallStrip(
    toolCalls: List<AssistantChatToolCall>,
    accent: Color,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(toolCalls.reversed(), key = { it.id }) { tool ->
            val visualKind = toolCallVisualKind(tool.name)
            val isDone = tool.status == "done" || tool.status.isBlank()
            val statusColor = if (isDone) Color(0xFF22C55E) else Color(0xFFF59E0B)
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
                border = BorderStroke(
                    width = 0.8.dp,
                    brush = Brush.linearGradient(listOf(accent.copy(alpha = 0.45f), statusColor.copy(alpha = 0.25f)))
                ),
                modifier = Modifier.widthIn(max = 240.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape)
                            .background(accent.copy(alpha = 0.12f))
                            .border(0.5.dp, accent.copy(alpha = 0.35f), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = toolCallIcon(visualKind),
                            contentDescription = null,
                            tint = accent,
                            modifier = Modifier.size(12.dp),
                        )
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = tool.name,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(6.dp)
                                    .background(statusColor, CircleShape)
                            )
                            Text(
                                text = if (isDone) "completed" else tool.status,
                                fontSize = 9.sp,
                                fontWeight = FontWeight.Medium,
                                color = statusColor,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - CLI message row

@Composable
private fun CLIMessageRow(
    message: AssistantChatMessage,
    isUser: Boolean,
    isHermes: Boolean,
) {
    val toolLines = message.hermes?.toolCalls.orEmpty().map { tc ->
        "⟨${tc.name}${if (tc.status.isNotBlank() && tc.status != "done") ": ${tc.status}" else ""}⟩"
    }
    val fullText = if (toolLines.isNotEmpty()) {
        (listOf(message.text) + toolLines).filter { it.isNotBlank() }.joinToString("\n")
    } else {
        message.text
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(8.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = if (isUser) ">" else if (isHermes) "☿" else "<",
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = if (isUser) Color(0xFF22C55E) else if (isHermes) Color(0xFFD4AA3C) else Color(0xFFF45B69),
            modifier = Modifier.width(16.dp),
        )
        Text(
            text = fullText,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            color = Color(0xFFE6EDF3),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun StreamingDots(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        repeat(3) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .background(
                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        CircleShape,
                    ),
            )
        }
    }
}

// MARK: - Staged attachments

@Composable
private fun StagedAttachmentRow(
    attachments: List<AssistantChatAttachment>,
    accent: Color,
    onRemove: (String) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(attachments, key = { it.id }) { att ->
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = accent.copy(alpha = 0.18f),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                ) {
                    Icon(
                        imageVector = if (att.mimeType.startsWith("image/")) Icons.Outlined.Image else Icons.Outlined.AttachFile,
                        contentDescription = null,
                        tint = accent,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = att.displayName.take(28),
                        fontSize = 12.sp,
                        color = accent,
                        fontWeight = FontWeight.Medium,
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    IconButton(
                        onClick = { onRemove(att.id) },
                        modifier = Modifier.size(20.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Close,
                            contentDescription = "Remove attachment",
                            tint = accent,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AttachmentChip(att: AssistantChatAttachment, accent: Color) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = accent.copy(alpha = 0.16f),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            Icon(
                imageVector = if (att.mimeType.startsWith("image/")) Icons.Outlined.Image else Icons.Outlined.AttachFile,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(12.dp),
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = att.displayName.take(36),
                fontSize = 11.sp,
                color = accent,
            )
        }
    }
}

// MARK: - Composer

@Composable
private fun ComposerBar(
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    draft: String,
    onDraftChange: (String) -> Unit,
    isSending: Boolean,
    onPickPhoto: () -> Unit,
    onPickFile: () -> Unit,
    presentationMode: CLIAgentChatPresentationMode,
    onPresentationModeChange: (CLIAgentChatPresentationMode) -> Unit,
    onSend: () -> Unit,
) {
    val accent = Color(provider.brandColor)
    val toolbarBrush = Brush.linearGradient(toolbarGradientColors(runtime, accent))
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            ToolbarIconButton(
                icon = Icons.Outlined.Image,
                contentDescription = "Photo attachment",
                accent = accent,
                brush = toolbarBrush,
                enabled = !isSending,
                onClick = onPickPhoto,
            )
            Spacer(modifier = Modifier.width(8.dp))
            ToolbarIconButton(
                icon = Icons.Outlined.AttachFile,
                contentDescription = "File attachment",
                accent = accent,
                brush = toolbarBrush,
                enabled = !isSending,
                onClick = onPickFile,
            )
            Spacer(modifier = Modifier.weight(1f))
            PresentationModeToggle(
                selected = presentationMode,
                accent = accent,
                brush = toolbarBrush,
                enabled = !isSending,
                onSelect = onPresentationModeChange,
            )
        }
        Spacer(modifier = Modifier.height(10.dp))
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
            border = BorderStroke(1.dp, glassStrokeBrush),
            modifier = Modifier.fillMaxWidth(),
            tonalElevation = 8.dp
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
            ) {
                androidx.compose.foundation.text.BasicTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    enabled = !isSending,
                    textStyle = LocalTextStyle.current.copy(
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 15.sp
                    ),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onSend() }),
                    modifier = Modifier
                        .weight(1f)
                        .padding(vertical = 12.dp),
                    decorationBox = { innerTextField ->
                        Box(modifier = Modifier.fillMaxWidth()) {
                            if (draft.isEmpty()) {
                                Text(
                                    text = "Ask ${provider.displayName}…",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                    fontSize = 15.sp
                                )
                            }
                            innerTextField()
                        }
                    }
                )
                SendButton(
                    enabled = draft.isNotBlank() && !isSending,
                    accent = accent,
                    isSending = isSending,
                    onClick = onSend,
                )
            }
        }
    }
}

@Composable
private fun PresentationModeToggle(
    selected: CLIAgentChatPresentationMode,
    accent: Color,
    brush: Brush,
    enabled: Boolean,
    onSelect: (CLIAgentChatPresentationMode) -> Unit,
) {
    val shape = RoundedCornerShape(percent = 50)
    Box(
        modifier = Modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.34f), shape)
            .border(0.75.dp, brush, shape),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.padding(4.dp),
        ) {
            CLIAgentChatPresentationMode.values().forEach { mode ->
                val isSelected = mode == selected
                val icon = when (mode) {
        CLIAgentChatPresentationMode.NATIVE_CHAT -> Icons.Filled.ChatBubble
        CLIAgentChatPresentationMode.MAC_VISIBLE_CLI -> Icons.Filled.Terminal
        CLIAgentChatPresentationMode.MAC_INTERACTIVE_CLI -> Icons.Filled.Terminal
                }
                val foreground = when {
                    !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.48f)
                    isSelected -> Color.White
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                }
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(if (isSelected && enabled) brush else Brush.linearGradient(listOf(Color.Transparent, Color.Transparent)), CircleShape)
                        .border(
                            width = if (isSelected) 0.dp else 0.5.dp,
                            color = if (isSelected) Color.Transparent else MaterialTheme.colorScheme.outline.copy(alpha = 0.18f),
                            shape = CircleShape,
                        )
                        .semantics {
                            role = Role.RadioButton
                            this.selected = isSelected
                            contentDescription = "${mode.displayLabel} mode"
                            stateDescription = if (isSelected) "Selected" else "Not selected"
                        }
                        .clickable(enabled = enabled) { onSelect(mode) },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = foreground,
                        modifier = Modifier.size(21.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolbarIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    accent: Color,
    brush: Brush,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val foreground = if (enabled) accent else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.48f)
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (enabled) 0.22f else 0.08f), CircleShape)
            .border(if (enabled) 1.dp else 0.5.dp, if (enabled) brush else Brush.linearGradient(listOf(foreground, foreground)), CircleShape)
            .semantics {
                role = Role.Button
                this.contentDescription = contentDescription
            }
            .clickable(enabled = enabled) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(if (enabled) brush else Brush.linearGradient(listOf(Color.Transparent, Color.Transparent)), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (enabled) Color.White else foreground,
                modifier = Modifier.size(19.dp),
            )
        }
    }
}

private fun toolbarGradientColors(runtime: AssistantRuntimeID, accent: Color): List<Color> = when (runtime) {
    AssistantRuntimeID.HERMES -> AuroraGradients.mercuryFoil
    AssistantRuntimeID.PI -> AuroraGradients.piGradient
    AssistantRuntimeID.CODEX -> listOf(Color(0xFF1ABC9C), Color(0xFF2ECC71), Color(0xFF7EE8C4))
    AssistantRuntimeID.CLAUDE -> listOf(Color(0xFFD58A4F), Color(0xFFC76A2C), Color(0xFFF5B971))
    AssistantRuntimeID.OPEN_CLAW -> listOf(Color(0xFF6E56CF), Color(0xFF4F44C6), Color(0xFF9B8CFF))
    AssistantRuntimeID.DROID -> listOf(Color(0xFF8B5CF6), Color(0xFF6D5DF6), Color(0xFFC084FC))
    AssistantRuntimeID.FORGE -> listOf(Color(0xFFF97316), Color(0xFFEA580C), Color(0xFFFDBA74))
    AssistantRuntimeID.ANTIGRAVITY -> listOf(Color(0xFF6C63FF), Color(0xFF8F8AFF), Color(0xFFC4B5FD))
    AssistantRuntimeID.GROK -> listOf(Color(0xFF111827), Color(0xFF0EA5E9), Color(0xFF67E8F9))
    AssistantRuntimeID.CURSOR_AGENT -> listOf(Color(0xFF0F172A), Color(0xFF64748B), Color(0xFFCBD5E1))
    else -> listOf(accent, accent.copy(alpha = 0.72f), accent)
}

@Composable
private fun SendButton(
    enabled: Boolean,
    accent: Color,
    isSending: Boolean,
    onClick: () -> Unit,
) {
    // Three-state visual contract (matches the updated Hermes send
    // button): filled when ready, half-opacity while streaming, outline
    // ring with muted icon when empty — so users always understand why
    // a tap landed or didn't.
    val bg = when {
        isSending -> accent.copy(alpha = 0.35f)
        enabled -> accent
        else -> Color.Transparent
    }
    val tint = when {
        isSending -> Color.White.copy(alpha = 0.7f)
        enabled -> Color.White
        else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
    }
    val outline = if (!enabled && !isSending)
        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
    else
        Color.Transparent

    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(
                if (enabled && !isSending)
                    Brush.radialGradient(listOf(accent.copy(alpha = 0.32f), Color.Transparent))
                else
                    Brush.radialGradient(listOf(Color.Transparent, Color.Transparent)),
            ),
        contentAlignment = Alignment.Center,
    ) {
        IconButton(
            enabled = enabled,
            onClick = onClick,
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(bg)
                .border(1.dp, outline, CircleShape)
        ) {
            Icon(
                imageVector = if (isSending) Icons.Filled.HourglassEmpty else Icons.AutoMirrored.Filled.Send,
                contentDescription = when {
                    isSending -> "Waiting for response — send disabled"
                    enabled -> "Send message"
                    else -> "Type a message to enable send"
                },
                tint = tint,
            )
        }
    }
}

// MARK: - Helpers

private val CLIAgentChatPresentationMode.androidSourceSurface: String
    get() = when (this) {
        CLIAgentChatPresentationMode.NATIVE_CHAT -> "android-chat-native"
        CLIAgentChatPresentationMode.MAC_VISIBLE_CLI -> "android-chat-mac-visible-cli"
        CLIAgentChatPresentationMode.MAC_INTERACTIVE_CLI -> "android-chat-mac-interactive-cli"
    }

private val CLIAgentChatPresentationMode.deliveryMode: com.openburnbar.data.assistants.SkillRunDeliveryMode
    get() = when (this) {
        CLIAgentChatPresentationMode.NATIVE_CHAT -> com.openburnbar.data.assistants.SkillRunDeliveryMode.ACTION_ONLY
        CLIAgentChatPresentationMode.MAC_VISIBLE_CLI -> com.openburnbar.data.assistants.SkillRunDeliveryMode.FULL_STREAM
        CLIAgentChatPresentationMode.MAC_INTERACTIVE_CLI -> com.openburnbar.data.assistants.SkillRunDeliveryMode.FULL_STREAM
    }

private fun cliModelPreferenceKey(runtime: AssistantRuntimeID): String =
    "assistants.preferredModelID.${runtime.token}"

private fun cliPresentationModePreferenceKey(runtime: AssistantRuntimeID): String =
    "assistants.presentationMode.${runtime.token}"

private fun preferredCliModelID(
    context: android.content.Context,
    runtime: AssistantRuntimeID,
): String? =
    context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
        .getString(cliModelPreferenceKey(runtime), null)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

private fun preferredCliPresentationMode(
    context: android.content.Context,
    runtime: AssistantRuntimeID,
): CLIAgentChatPresentationMode =
    CLIAgentChatPresentationMode.fromWire(
        context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
            .getString(cliPresentationModePreferenceKey(runtime), null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() },
    )

private fun setPreferredCliModelID(
    context: android.content.Context,
    runtime: AssistantRuntimeID,
    modelID: String?,
) {
    val prefs = context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
    prefs.edit().apply {
        val trimmed = modelID?.trim()?.takeIf { it.isNotEmpty() }
        if (trimmed == null) remove(cliModelPreferenceKey(runtime)) else putString(cliModelPreferenceKey(runtime), trimmed)
    }.apply()
}

private fun setPreferredCliPresentationMode(
    context: android.content.Context,
    runtime: AssistantRuntimeID,
    mode: CLIAgentChatPresentationMode,
) {
    context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
        .edit()
        .putString(cliPresentationModePreferenceKey(runtime), mode.wire)
        .apply()
}

private fun attachmentFor(
    context: android.content.Context,
    uri: Uri,
    fallbackMime: String,
): AssistantChatAttachment {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri) ?: fallbackMime
    var displayName = uri.lastPathSegment ?: "attachment"
    var byteSize: Long = 0
    runCatching {
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                if (nameIdx >= 0 && !cursor.isNull(nameIdx)) displayName = cursor.getString(nameIdx)
                if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) byteSize = cursor.getLong(sizeIdx)
            }
        }
    }
    return AssistantChatAttachment(
        id = UUID.randomUUID().toString(),
        kind = if (mime.startsWith("image/")) "image" else "file",
        displayName = displayName,
        mimeType = mime,
        byteSize = byteSize,
        workspaceRelativePath = uri.toString(),
    )
}

private fun createThread(
    historyStore: AssistantChatHistoryStore,
    runtime: AssistantRuntimeID,
): AssistantChatThread {
    val now = System.currentTimeMillis()
    val thread = AssistantChatThread(
        id = "android-${runtime.token}-${UUID.randomUUID()}",
        runtime = runtime.token,
        title = "New Chat",
        preview = "",
        createdAtMillis = now,
        updatedAtMillis = now,
        messages = emptyList(),
    )
    historyStore.upsert(thread)
    return thread
}

private fun sendMessage(
    text: String,
    attachments: List<AssistantChatAttachment>,
    runtime: AssistantRuntimeID,
    requestedModelID: String?,
    presentationMode: CLIAgentChatPresentationMode,
    threadID: String,
    historyStore: AssistantChatHistoryStore,
    relayChatTransport: CLIAgentRelayChatTransporting,
    dispatcher: CLIAgentMissionDispatcher,
    scope: kotlinx.coroutines.CoroutineScope,
    onPending: (requestID: String?, streamingMessageID: String?, job: Job?) -> Unit,
    onStreamComplete: () -> Unit,
) {
    val now = System.currentTimeMillis()
    val thread = historyStore.thread(threadID) ?: return
    val userMessage = AssistantChatMessage(
        role = "user",
        text = text,
        timestampMillis = now,
        attachments = attachments,
    )
    val placeholder = AssistantChatMessage(
        role = "assistant",
        text = "",
        timestampMillis = now + 1,
        modelName = null,
    )
    val withUser = thread.copy(
        messages = thread.messages + userMessage + placeholder,
        preview = text.take(80),
        updatedAtMillis = now,
    )
    historyStore.upsert(withUser)
    onPending(null, placeholder.id, null)

    val job = scope.launch {
        if (presentationMode != CLIAgentChatPresentationMode.NATIVE_CHAT) {
            dispatchMissionFallback(
                text = text,
                runtime = runtime,
                requestedModelID = requestedModelID,
                presentationMode = presentationMode,
                threadID = threadID,
                threadTitle = thread.title,
                placeholderID = placeholder.id,
                historyStore = historyStore,
                dispatcher = dispatcher,
                onPending = onPending,
                onStreamComplete = onStreamComplete,
            )
            return@launch
        }

        try {
            relayChatTransport.stream(
                runtime = runtime,
                threadID = threadID,
                prompt = text,
                title = thread.title,
                modelID = requestedModelID,
                parentSessionID = null,
                resumeAction = "continue",
                presentationMode = presentationMode,
            ) { event ->
                applyRelayEvent(
                    historyStore = historyStore,
                    threadID = threadID,
                    placeholderID = placeholder.id,
                    event = event,
                    fallbackModelName = requestedModelID,
                )
                if (event.isTerminal) {
                    onStreamComplete()
                }
            }
            val finalThread = historyStore.thread(threadID)
            val finalMessage = finalThread?.messages?.firstOrNull { it.id == placeholder.id }
            if (finalMessage == null || finalMessage.text.isBlank()) {
                finalizeMessage(
                    historyStore = historyStore,
                    threadID = threadID,
                    placeholderID = placeholder.id,
                    text = "${runtime.displayName} finished without a visible reply.",
                    isError = false,
                    modelName = requestedModelID,
                )
            }
            onStreamComplete()
        } catch (t: Throwable) {
            if (shouldFallBackToMissionAfterRelayError(t)) {
                dispatchMissionFallback(
                    text = text,
                    runtime = runtime,
                    requestedModelID = requestedModelID,
                    presentationMode = presentationMode,
                    threadID = threadID,
                    threadTitle = thread.title,
                    placeholderID = placeholder.id,
                    historyStore = historyStore,
                    dispatcher = dispatcher,
                    onPending = onPending,
                    onStreamComplete = onStreamComplete,
                )
                return@launch
            }
            finalizeMessage(
                historyStore = historyStore,
                threadID = threadID,
                placeholderID = placeholder.id,
                text = "Couldn't reach ${runtime.displayName} on your Mac: ${t.localizedMessage ?: t::class.java.simpleName}",
                isError = true,
            )
            onStreamComplete()
        }
    }
    onPending(null, placeholder.id, job)
}

private suspend fun dispatchMissionFallback(
    text: String,
    runtime: AssistantRuntimeID,
    requestedModelID: String?,
    presentationMode: CLIAgentChatPresentationMode,
    threadID: String,
    threadTitle: String,
    placeholderID: String,
    historyStore: AssistantChatHistoryStore,
    dispatcher: CLIAgentMissionDispatcher,
    onPending: (requestID: String?, streamingMessageID: String?, job: Job?) -> Unit,
    onStreamComplete: () -> Unit,
) {
    val requestID = try {
        val grant = AgentCapabilityGrantState.optimisticGrant(runtime.token, threadID)
        dispatcher.dispatch(
            title = threadTitle,
            prompt = text,
            missionKind = "chat",
            requestedRuntime = runtime.token,
            approvalMode = "existing_policy",
            commandsAllowed = grant?.capabilities?.any {
                it == AgentDesktopCapability.SHELL.wireValue ||
                    it == AgentDesktopCapability.SHELL_UNRESTRICTED.wireValue
            } == true,
            fileEditsAllowed = grant?.capabilities?.contains(AgentDesktopCapability.WORKSPACE_WRITE.wireValue) == true,
            requestedModelID = requestedModelID?.trim()?.takeIf { it.isNotEmpty() },
            clientThreadID = threadID,
            resumeAction = "continue",
            sourceSurface = presentationMode.androidSourceSurface,
            deliveryMode = presentationMode.deliveryMode,
            presentationMode = presentationMode,
        )
    } catch (t: Throwable) {
        finalizeMessage(
            historyStore = historyStore,
            threadID = threadID,
            placeholderID = placeholderID,
            text = "Couldn't reach the Mac runtime: ${t.localizedMessage ?: t::class.java.simpleName}",
            isError = true,
        )
        onStreamComplete()
        return
    }
    onPending(requestID, placeholderID, null)
    dispatcher.observe(requestID).first { snapshot ->
        applySnapshot(
            historyStore = historyStore,
            threadID = threadID,
            placeholderID = placeholderID,
            snapshot = snapshot,
        )
        if (snapshot.isTerminal) {
            onStreamComplete()
        }
        snapshot.isTerminal
    }
}

private fun shouldFallBackToMissionAfterRelayError(error: Throwable): Boolean {
    val lower = (error.localizedMessage ?: error.message ?: "").lowercase()
    if (lower.contains("already responding") ||
        lower.contains("unsupported runtime") ||
        lower.contains("cannot send an empty")
    ) {
        return false
    }
    return true
}

private fun applyRelayEvent(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    event: CLIAgentRelayChatEvent,
    fallbackModelName: String?,
) {
    val relayText = event.text?.trim()?.takeIf { it.isNotEmpty() }
    val errorText = event.errorMessage?.trim()?.takeIf { it.isNotEmpty() }
    val visibleText = relayText ?: errorText?.let { "Error: $it" } ?: ""
    val toolCalls = mobileToolCalls(event = event)
    finalizeMessage(
        historyStore = historyStore,
        threadID = threadID,
        placeholderID = placeholderID,
        text = visibleText,
        isError = event.isError,
        modelName = event.modelID ?: fallbackModelName,
        toolCalls = toolCalls,
    )
}

private fun mobileToolCalls(event: CLIAgentRelayChatEvent): List<AssistantChatToolCall> =
    event.transcriptPieces.mapNotNull { piece ->
        when (piece.kind) {
            CLIAgentRelayTranscriptPieceKind.TOOL_USE,
            CLIAgentRelayTranscriptPieceKind.TOOL_RESULT -> AssistantChatToolCall(
                id = piece.id,
                name = piece.value.ifBlank { piece.kind.wire },
                status = piece.detail?.trim()?.takeIf { it.isNotEmpty() } ?: "done",
            )
            CLIAgentRelayTranscriptPieceKind.TEXT -> null
        }
    }

private fun applySnapshot(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    snapshot: CLIAgentMissionSnapshot,
) {
    val resultPreview = snapshot.resultPreview?.takeIf { it.isNotBlank() }
    val liveSummary = snapshot.displayLiveSummary?.takeIf { it.isNotBlank() }
    val nextText = when {
        snapshot.status == "completed" && resultPreview != null -> resultPreview
        snapshot.errorMessage?.isNotBlank() == true -> "Error: ${snapshot.errorMessage}"
        resultPreview != null -> resultPreview
        liveSummary != null -> liveSummary
        else -> snapshot.currentStepLabel
    }
    val isError = snapshot.status in setOf("failed", "agent_launch_failed", "unauthorized")
        || snapshot.errorMessage?.isNotBlank() == true
    finalizeMessage(
        historyStore = historyStore,
        threadID = threadID,
        placeholderID = placeholderID,
        text = nextText,
        isError = isError,
        modelName = snapshot.runtimeLabel,
        toolCalls = snapshotToolCalls(snapshot),
    )
}

private fun snapshotToolCalls(snapshot: CLIAgentMissionSnapshot): List<AssistantChatToolCall> =
    snapshot.events.mapNotNull { event ->
        val name = event.toolName?.takeIf { it.isNotBlank() }
            ?: event.title?.takeIf {
                event.kind == "tool_call" ||
                    event.kind == "tool_result" ||
                    event.phase == "tool_use" ||
                    event.phase == "tool_result"
            }
            ?: return@mapNotNull null
        AssistantChatToolCall(
            id = "${snapshot.id}-${event.sequence}",
            name = name,
            status = event.changedFilePath?.takeIf { it.isNotBlank() }
                ?: event.artifactPath?.takeIf { it.isNotBlank() }
                ?: "done",
        )
    }

private fun finalizeMessage(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    text: String,
    isError: Boolean,
    modelName: String? = null,
    toolCalls: List<AssistantChatToolCall> = emptyList(),
) {
    val thread = historyStore.thread(threadID) ?: return
    val updatedMessages = thread.messages.map { msg ->
        if (msg.id == placeholderID) {
            val hermesMetadata = if (toolCalls.isNotEmpty()) {
                (msg.hermes ?: AssistantChatHermesMetadata()).copy(toolCalls = toolCalls)
            } else {
                msg.hermes
            }
            val resolvedText = if (text.isEmpty() && toolCalls.isNotEmpty()) msg.text else text
            msg.copy(
                text = resolvedText,
                isError = isError,
                modelName = modelName ?: msg.modelName,
                timestampMillis = System.currentTimeMillis(),
                hermes = hermesMetadata,
            )
        } else {
            msg
        }
    }
    val resolvedPreview = updatedMessages
        .firstOrNull { it.id == placeholderID }
        ?.text
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: thread.preview
    val updated = thread.copy(
        messages = updatedMessages,
        preview = resolvedPreview.take(80),
        updatedAtMillis = System.currentTimeMillis(),
    )
    historyStore.upsert(updated)
}

private fun providerFor(runtime: AssistantRuntimeID): AgentProvider = when (runtime) {
    AssistantRuntimeID.CODEX -> AgentProvider.CODEX
    AssistantRuntimeID.CLAUDE -> AgentProvider.CLAUDE_CODE
    AssistantRuntimeID.OPEN_CLAW -> AgentProvider.OPEN_CLAW
    AssistantRuntimeID.DROID -> AgentProvider.FACTORY
    AssistantRuntimeID.FORGE -> AgentProvider.FORGE_DEV
    AssistantRuntimeID.ANTIGRAVITY -> AgentProvider.ANTIGRAVITY
    AssistantRuntimeID.GROK -> AgentProvider.XAI
    AssistantRuntimeID.CURSOR_AGENT -> AgentProvider.CURSOR
    AssistantRuntimeID.HERMES -> AgentProvider.HERMES
    AssistantRuntimeID.PI -> AgentProvider.HERMES
}

private fun readyTagline(runtime: AssistantRuntimeID): String = when (runtime) {
    AssistantRuntimeID.CODEX -> "Ask Codex to plan, edit, or run code on your paired Mac."
    AssistantRuntimeID.CLAUDE -> "Claude Code is wired to your Mac. Ask for a refactor, a test, or a review."
    AssistantRuntimeID.OPEN_CLAW -> "OpenClaw runs locally on your paired Mac. Long-form tasks welcome."
    AssistantRuntimeID.DROID -> "Droid is wired to your Mac. Ask it to inspect, plan, or work in your repo."
    AssistantRuntimeID.FORGE -> "Forge is wired to your Mac. Ask it for coding help, review, or implementation plans."
    AssistantRuntimeID.ANTIGRAVITY -> "Antigravity is wired to your Mac. Ask it to inspect, plan, or work in your repo."
    AssistantRuntimeID.GROK -> "Grok is wired to your Mac. Ask it to inspect, explain, or implement in your repo."
    AssistantRuntimeID.CURSOR_AGENT -> "Cursor Agent is wired to your Mac. Ask it to work in the current workspace."
    AssistantRuntimeID.HERMES, AssistantRuntimeID.PI -> "Ready when you are."
}

private fun quickPromptsFor(runtime: AssistantRuntimeID): List<String> = when (runtime) {
    AssistantRuntimeID.CODEX -> listOf(
        "Plan a refactor for…",
        "Write a unit test for…",
        "Explain this stack trace",
        "Generate a Bash one-liner",
    )
    AssistantRuntimeID.CLAUDE -> listOf(
        "Review my last commit",
        "Draft a PR description",
        "Find the bug in…",
        "Summarize this file",
    )
    AssistantRuntimeID.OPEN_CLAW -> listOf(
        "Sweep this repo for TODOs",
        "Migrate this to Compose",
        "Audit my dependencies",
        "Suggest a release plan",
    )
    AssistantRuntimeID.DROID -> listOf(
        "Inspect the current repo",
        "Plan the next implementation",
        "Review failing tests",
        "Explain this error",
    )
    AssistantRuntimeID.FORGE -> listOf(
        "Review my last change",
        "Draft an implementation plan",
        "Find risky code paths",
        "Summarize this module",
    )
    AssistantRuntimeID.ANTIGRAVITY -> listOf(
        "Inspect the current repo",
        "Plan an implementation",
        "Review this change",
        "Explain this error",
    )
    AssistantRuntimeID.GROK -> listOf(
        "Explain this error",
        "Review this change",
        "Plan an implementation",
        "Find risky assumptions",
    )
    AssistantRuntimeID.CURSOR_AGENT -> listOf(
        "Open this workspace",
        "Review my last change",
        "Plan the next edit",
        "Find failing tests",
    )
    else -> emptyList()
}
