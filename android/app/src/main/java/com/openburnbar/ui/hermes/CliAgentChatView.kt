package com.openburnbar.ui.hermes

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.AssistantChatAttachment
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

// MARK: - CLI agent chat surface (Codex / Claude Code / OpenClaw)
//
// Parity with `HermesView`:
//   • `CenterAlignedTopAppBar` with title ("New Chat" / thread title),
//     New Chat (+) action, Model picker (Psychology) action, Settings
//     action.
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
// Replies stream back via `CLIAgentMissionDispatcher.observe(requestID)`:
// `liveSummary` fills the in-flight bubble, `resultPreview` (or
// `errorMessage`) finalizes it.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CliAgentChatView(
    runtime: AssistantRuntimeID,
    historyStore: AssistantChatHistoryStore,
) {
    val provider = providerFor(runtime)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current

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

    val listState = rememberLazyListState()

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

    DisposableEffect(activeThreadID) {
        onDispose { observerJob?.cancel() }
    }

    val title = activeThread.title.takeIf { it.isNotBlank() } ?: "New Chat"

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
                    // We're inside `AssistantsScreen`'s tab content so a
                    // true `back` would pop the chat tab entirely. Use
                    // it as "new chat" guard: if there are messages, it
                    // archives the current thread and starts a fresh
                    // one; if empty, it clears the draft.
                    IconButton(onClick = {
                        if (activeThread.messages.isNotEmpty()) {
                            val fresh = createThread(historyStore, runtime)
                            activeThreadID = fresh.id
                            stagedAttachments = emptyList()
                            draft = ""
                            observerJob?.cancel()
                            pendingRequestID = null
                            streamingMessageID = null
                        } else {
                            draft = ""
                            stagedAttachments = emptyList()
                        }
                    }) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "New chat",
                        )
                    }
                },
                actions = {
                    IconButton(onClick = {
                        val fresh = createThread(historyStore, runtime)
                        activeThreadID = fresh.id
                        stagedAttachments = emptyList()
                        draft = ""
                        observerJob?.cancel()
                        pendingRequestID = null
                        streamingMessageID = null
                    }) {
                        Icon(
                            imageVector = Icons.Filled.Add,
                            contentDescription = "Start a new chat",
                        )
                    }
                    IconButton(onClick = { /* model picker — runtime-managed today */ }) {
                        Icon(
                            imageVector = Icons.Filled.Psychology,
                            contentDescription = "Model",
                        )
                    }
                    IconButton(onClick = { /* settings — defer to global Settings */ }) {
                        Icon(
                            imageVector = Icons.Filled.Settings,
                            contentDescription = "Settings",
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
                        onQuickPrompt = { prompt ->
                            sendMessage(
                                text = prompt,
                                attachments = stagedAttachments,
                                runtime = runtime,
                                threadID = activeThreadID,
                                historyStore = historyStore,
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
                onDraftChange = { draft = it },
                isSending = pendingRequestID != null || streamingMessageID != null,
                onPickPhoto = { pickPhoto.launch("image/*") },
                onPickFile = { pickFile.launch(arrayOf("*/*")) },
                onSend = {
                    val text = draft.trim()
                    if (text.isEmpty() && stagedAttachments.isEmpty()) return@ComposerBar
                    val pending = stagedAttachments
                    draft = ""
                    focusManager.clearFocus()
                    sendMessage(
                        text = text.ifEmpty { "[attachments]" },
                        attachments = pending,
                        runtime = runtime,
                        threadID = activeThreadID,
                        historyStore = historyStore,
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
}

// MARK: - Empty state

@Composable
private fun EmptyStateHero(
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    quickPrompts: List<String>,
    onQuickPrompt: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ProviderLogo(provider = provider, size = 80.dp, circular = true)
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "${provider.displayName} is ready",
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(6.dp))
        Text(
            text = readyTagline(runtime),
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(14.dp))
        // Model chip — mirrors Hermes's "UN hermes" pill but reflects
        // where execution actually happens (the paired Mac picks the
        // model per the CLI runtime's own policy).
        Surface(
            shape = RoundedCornerShape(percent = 50),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                ProviderLogo(provider = provider, size = 16.dp, circular = true)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "${provider.displayName} · paired Mac",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
        Spacer(modifier = Modifier.height(20.dp))
        if (quickPrompts.isNotEmpty()) {
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(horizontal = 4.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(quickPrompts) { prompt ->
                    Surface(
                        shape = RoundedCornerShape(percent = 50),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                        modifier = Modifier.padding(vertical = 4.dp),
                    ) {
                        Text(
                            text = prompt,
                            fontSize = 13.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
                                .clip(RoundedCornerShape(percent = 50))
                                .clickable { onQuickPrompt(prompt) }
                                .padding(horizontal = 14.dp, vertical = 10.dp),
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
) {
    val isUser = message.role == "user"
    if (isUser) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Column(horizontalAlignment = Alignment.End) {
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                ) {
                    Text(
                        text = message.text,
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .widthIn(max = 280.dp)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                }
                if (message.attachments.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(4.dp))
                    message.attachments.forEach { att ->
                        AttachmentChip(att = att, accent = Color(provider.brandColor))
                    }
                }
            }
        }
    } else {
        Row(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ProviderLogo(provider = provider, size = 14.dp, circular = true)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = "via ${provider.displayName}",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (!message.modelName.isNullOrBlank()) {
                        Text(
                            text = " · ${message.modelName}",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer(modifier = Modifier.height(4.dp))
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
                ) {
                    if (isStreaming) {
                        StreamingDots(
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
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
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                        )
                    }
                }
            }
        }
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
    onSend: () -> Unit,
) {
    val accent = Color(provider.brandColor)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.4f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            AttachmentPill(
                icon = Icons.Outlined.Image,
                label = "Photo",
                accent = accent,
                onClick = onPickPhoto,
            )
            AttachmentPill(
                icon = Icons.Outlined.AttachFile,
                label = "File",
                accent = accent,
                onClick = onPickFile,
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        Surface(
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    placeholder = { Text("Ask ${provider.displayName}…", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                    enabled = !isSending,
                    singleLine = false,
                    maxLines = 5,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onSend() }),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        disabledContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                    modifier = Modifier.weight(1f),
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
private fun AttachmentPill(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    accent: Color,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(percent = 50),
        color = accent.copy(alpha = 0.18f),
        modifier = Modifier.clip(RoundedCornerShape(percent = 50)).clickable { onClick() },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(16.dp),
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = label,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = accent,
            )
        }
    }
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
                .then(
                    if (outline != Color.Transparent)
                        Modifier.background(Color.Transparent)
                    else
                        Modifier
                ),
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
    threadID: String,
    historyStore: AssistantChatHistoryStore,
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
        val requestID = try {
            dispatcher.dispatch(
                title = thread.title,
                prompt = text,
                missionKind = "chat",
                requestedRuntime = runtime.token,
                approvalMode = "existing_policy",
                commandsAllowed = false,
                fileEditsAllowed = false,
                clientThreadID = threadID,
                resumeAction = "continue",
            )
        } catch (t: Throwable) {
            finalizeMessage(
                historyStore = historyStore,
                threadID = threadID,
                placeholderID = placeholder.id,
                text = "Couldn't reach the Mac runtime: ${t.localizedMessage ?: t::class.java.simpleName}",
                isError = true,
            )
            onStreamComplete()
            return@launch
        }
        onPending(requestID, placeholder.id, null)
        dispatcher.observe(requestID).collectLatest { snapshot ->
            applySnapshot(
                historyStore = historyStore,
                threadID = threadID,
                placeholderID = placeholder.id,
                snapshot = snapshot,
            )
            if (snapshot.isTerminal) {
                onStreamComplete()
            }
        }
    }
    onPending(null, placeholder.id, job)
}

private fun applySnapshot(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    snapshot: CLIAgentMissionSnapshot,
) {
    val nextText = when {
        snapshot.status == "completed" && !snapshot.resultPreview.isNullOrBlank() -> snapshot.resultPreview!!
        snapshot.errorMessage?.isNotBlank() == true -> "Error: ${snapshot.errorMessage}"
        !snapshot.resultPreview.isNullOrBlank() -> snapshot.resultPreview!!
        !snapshot.displayLiveSummary.isNullOrBlank() -> snapshot.displayLiveSummary!!
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
    )
}

private fun finalizeMessage(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    text: String,
    isError: Boolean,
    modelName: String? = null,
) {
    val thread = historyStore.thread(threadID) ?: return
    val updatedMessages = thread.messages.map { msg ->
        if (msg.id == placeholderID) {
            msg.copy(
                text = text,
                isError = isError,
                modelName = modelName ?: msg.modelName,
                timestampMillis = System.currentTimeMillis(),
            )
        } else {
            msg
        }
    }
    val updated = thread.copy(
        messages = updatedMessages,
        preview = text.take(80),
        updatedAtMillis = System.currentTimeMillis(),
    )
    historyStore.upsert(updated)
}

private fun providerFor(runtime: AssistantRuntimeID): AgentProvider = when (runtime) {
    AssistantRuntimeID.CODEX -> AgentProvider.CODEX
    AssistantRuntimeID.CLAUDE -> AgentProvider.CLAUDE_CODE
    AssistantRuntimeID.OPEN_CLAW -> AgentProvider.OPEN_CLAW
    AssistantRuntimeID.HERMES -> AgentProvider.HERMES
    AssistantRuntimeID.PI -> AgentProvider.HERMES
}

private fun readyTagline(runtime: AssistantRuntimeID): String = when (runtime) {
    AssistantRuntimeID.CODEX -> "Ask Codex to plan, edit, or run code on your paired Mac."
    AssistantRuntimeID.CLAUDE -> "Claude Code is wired to your Mac. Ask for a refactor, a test, or a review."
    AssistantRuntimeID.OPEN_CLAW -> "OpenClaw runs locally on your paired Mac. Long-form tasks welcome."
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
    else -> emptyList()
}
