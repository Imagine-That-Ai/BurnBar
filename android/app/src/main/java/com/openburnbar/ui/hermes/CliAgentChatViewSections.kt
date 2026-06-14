// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.AssistantChatAttachment
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.CLIAgentChatPresentationMode
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CliAgentChatScreen(state: CliAgentChatState) {
    val title = state.activeThread.title.takeIf { it.isNotBlank() } ?: "New Chat"
    Scaffold(
        topBar = {
            CliAgentChatTopBar(
                args =
                CliAgentChatTopBarArgs(
                    title = title,
                    provider = state.provider,
                    chatViewMode = state.chatViewMode,
                    onStartFreshThread = state.onStartFreshThread,
                    onShowModelPicker = state.onShowModelPicker,
                    onShowPermissionSheet = state.onShowPermissionSheet,
                    onToggleViewMode = state.onToggleViewMode,
                ),
            )
        },
        containerColor = Color.Transparent,
    ) { innerPadding ->
        CliAgentChatBody(state = state, innerPadding = innerPadding)
    }
}

internal data class CliAgentChatTopBarArgs(
    val title: String,
    val provider: AgentProvider,
    val chatViewMode: ChatViewMode,
    val onStartFreshThread: () -> Unit,
    val onShowModelPicker: () -> Unit,
    val onShowPermissionSheet: () -> Unit,
    val onToggleViewMode: () -> Unit,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CliAgentChatTopBar(args: CliAgentChatTopBarArgs) {
    CenterAlignedTopAppBar(
        title = {
            Text(
                text = args.title,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
        },
        navigationIcon = {
            Box(
                modifier =
                Modifier
                    .padding(start = 12.dp)
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(Color(args.provider.brandColor).copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) {
                ProviderLogo(provider = args.provider, size = 24.dp, circular = true)
            }
        },
        actions = {
            IconButton(onClick = args.onStartFreshThread) {
                Icon(imageVector = Icons.Filled.Add, contentDescription = "Start a new chat")
            }
            IconButton(onClick = args.onShowModelPicker) {
                Icon(imageVector = Icons.Filled.Psychology, contentDescription = "Model picker")
            }
            IconButton(onClick = args.onShowPermissionSheet) {
                Icon(imageVector = Icons.Filled.Security, contentDescription = "Agent permissions")
            }
            IconButton(onClick = args.onToggleViewMode) {
                Icon(
                    imageVector = if (args.chatViewMode == ChatViewMode.CLI) Icons.Filled.Terminal else Icons.Filled.ChatBubble,
                    contentDescription = if (args.chatViewMode == ChatViewMode.CLI) "Switch to Agent view" else "Switch to CLI view",
                    tint = if (args.chatViewMode == ChatViewMode.CLI) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color.Transparent),
    )
}

@Composable
internal fun CliAgentChatBody(state: CliAgentChatState, innerPadding: PaddingValues) {
    Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
        CliAgentChatMessagePane(state = state)
        if (state.stagedAttachments.isNotEmpty()) {
            StagedAttachmentRow(
                attachments = state.stagedAttachments,
                accent = Color(state.provider.brandColor),
                onRemove = state.onRemoveAttachment,
            )
        }
        ComposerBar(
            state =
            ComposerBarState(
                runtime = state.runtime,
                provider = state.provider,
                draft = state.draft,
                isSending = state.isSending,
                presentationMode = state.presentationMode,
            ),
            callbacks =
            ComposerBarCallbacks(
                onDraftChange = state.onDraftChange,
                onPickPhoto = state.onPickPhoto,
                onPickFile = state.onPickFile,
                onPresentationModeChange = state.onPresentationModeChange,
                onSend = state.onSend,
            ),
        )
    }
}

@Composable
internal fun ColumnScope.CliAgentChatMessagePane(state: CliAgentChatState) {
    Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
        if (state.chatViewMode == ChatViewMode.CLI) {
            InlineAgentMirrorView(
                runtime = state.runtime.token,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            )
        } else if (state.activeThread.messages.isEmpty()) {
            EmptyStateHero(
                runtime = state.runtime,
                provider = state.provider,
                quickPrompts = quickPromptsFor(state.runtime),
                selectedModel = state.selectedModel ?: state.modelOptions.firstOrNull(),
                onQuickPrompt = state.onQuickPrompt,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            LazyColumn(
                state = state.listState,
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(state.activeThread.messages, key = { it.id }) { message ->
                    MessageBubble(
                        message = message,
                        runtime = state.runtime,
                        provider = state.provider,
                        isStreaming = message.id == state.streamingMessageID && message.text.isBlank(),
                        viewMode = state.chatViewMode,
                    )
                }
            }
        }
    }
}

// MARK: - CLI message row

@Composable
internal fun CLIMessageRow(message: AssistantChatMessage, isUser: Boolean, isHermes: Boolean) {
    val toolLines =
        message.hermes?.toolCalls.orEmpty().map { tc ->
            "⟨${tc.name}${if (tc.status.isNotBlank() && tc.status != "done") ": ${tc.status}" else ""}⟩"
        }
    val fullText =
        if (toolLines.isNotEmpty()) {
            (listOf(message.text) + toolLines).filter { it.isNotBlank() }.joinToString("\n")
        } else {
            message.text
        }
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(8.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text =
            if (isUser) {
                ">"
            } else if (isHermes) {
                "☿"
            } else {
                "<"
            },
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color =
            if (isUser) {
                Color(0xFF22C55E)
            } else if (isHermes) {
                Color(0xFFD4AA3C)
            } else {
                Color(0xFFF45B69)
            },
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
internal fun StreamingDots(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        repeat(3) {
            Box(
                modifier =
                Modifier
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
internal fun StagedAttachmentRow(attachments: List<AssistantChatAttachment>, accent: Color, onRemove: (String) -> Unit) {
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
internal fun AttachmentChip(att: AssistantChatAttachment, accent: Color) {
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

internal data class ComposerBarState(
    val runtime: AssistantRuntimeID,
    val provider: AgentProvider,
    val draft: String,
    val isSending: Boolean,
    val presentationMode: CLIAgentChatPresentationMode,
)

internal data class ComposerBarCallbacks(
    val onDraftChange: (String) -> Unit,
    val onPickPhoto: () -> Unit,
    val onPickFile: () -> Unit,
    val onPresentationModeChange: (CLIAgentChatPresentationMode) -> Unit,
    val onSend: () -> Unit,
)

@Composable
internal fun ComposerBar(state: ComposerBarState, callbacks: ComposerBarCallbacks) {
    val accent = Color(state.provider.brandColor)
    val toolbarBrush = Brush.linearGradient(toolbarGradientColors(state.runtime))
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        ComposerToolbarRow(state = state, callbacks = callbacks, accent = accent, toolbarBrush = toolbarBrush)
        Spacer(modifier = Modifier.height(10.dp))
        ComposerInputRow(
            state =
            ComposerInputRowState(
                draft = state.draft,
                provider = state.provider,
                accent = accent,
                glassStrokeBrush = glassStrokeBrush,
                isSending = state.isSending,
            ),
            callbacks =
            ComposerInputRowCallbacks(
                onDraftChange = callbacks.onDraftChange,
                onSend = callbacks.onSend,
            ),
        )
    }
}

@Composable
private fun ComposerToolbarRow(state: ComposerBarState, callbacks: ComposerBarCallbacks, accent: Color, toolbarBrush: Brush) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        ToolbarIconButton(
            icon = Icons.Outlined.Image,
            contentDescription = "Photo attachment",
            accent = accent,
            brush = toolbarBrush,
            enabled = !state.isSending,
            onClick = callbacks.onPickPhoto,
        )
        Spacer(modifier = Modifier.width(8.dp))
        ToolbarIconButton(
            icon = Icons.Outlined.AttachFile,
            contentDescription = "File attachment",
            accent = accent,
            brush = toolbarBrush,
            enabled = !state.isSending,
            onClick = callbacks.onPickFile,
        )
        Spacer(modifier = Modifier.weight(1f))
        PresentationModeToggle(
            selected = state.presentationMode,
            brush = toolbarBrush,
            enabled = !state.isSending,
            onSelect = callbacks.onPresentationModeChange,
        )
    }
}

internal data class ComposerInputRowState(
    val draft: String,
    val provider: AgentProvider,
    val accent: Color,
    val glassStrokeBrush: Brush,
    val isSending: Boolean,
)

internal data class ComposerInputRowCallbacks(
    val onDraftChange: (String) -> Unit,
    val onSend: () -> Unit,
)

@Composable
internal fun ComposerInputRow(state: ComposerInputRowState, callbacks: ComposerInputRowCallbacks) {
    val draft = state.draft
    val provider = state.provider
    val accent = state.accent
    val glassStrokeBrush = state.glassStrokeBrush
    val isSending = state.isSending
    val onDraftChange = callbacks.onDraftChange
    val onSend = callbacks.onSend
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border = BorderStroke(1.dp, glassStrokeBrush),
        modifier = Modifier.fillMaxWidth(),
        tonalElevation = 8.dp,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
        ) {
            androidx.compose.foundation.text.BasicTextField(
                value = draft,
                onValueChange = onDraftChange,
                enabled = !isSending,
                textStyle =
                LocalTextStyle.current.copy(
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 15.sp,
                ),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                modifier =
                Modifier
                    .weight(1f)
                    .padding(vertical = 12.dp),
                decorationBox = { innerTextField ->
                    Box(modifier = Modifier.fillMaxWidth()) {
                        if (draft.isEmpty()) {
                            Text(
                                text = "Ask ${provider.displayName}…",
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                fontSize = 15.sp,
                            )
                        }
                        innerTextField()
                    }
                },
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

@Composable
private fun PresentationModeToggleOption(
    mode: CLIAgentChatPresentationMode,
    isSelected: Boolean,
    brush: Brush,
    enabled: Boolean,
    onSelect: (CLIAgentChatPresentationMode) -> Unit,
) {
    val icon =
        when (mode) {
            CLIAgentChatPresentationMode.NATIVE_CHAT -> Icons.Filled.ChatBubble
            CLIAgentChatPresentationMode.MAC_VISIBLE_CLI -> Icons.Filled.Terminal
            CLIAgentChatPresentationMode.MAC_INTERACTIVE_CLI -> Icons.Filled.Terminal
        }
    val foreground =
        when {
            !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.48f)
            isSelected -> Color.White
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        }
    Box(
        modifier =
        Modifier
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

@Composable
internal fun PresentationModeToggle(selected: CLIAgentChatPresentationMode, brush: Brush, enabled: Boolean, onSelect: (CLIAgentChatPresentationMode) -> Unit) {
    val shape = RoundedCornerShape(percent = 50)
    Box(
        modifier =
        Modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.34f), shape)
            .border(0.75.dp, brush, shape),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.padding(4.dp),
        ) {
            CLIAgentChatPresentationMode.values().forEach { mode ->
                PresentationModeToggleOption(
                    mode = mode,
                    isSelected = mode == selected,
                    brush = brush,
                    enabled = enabled,
                    onSelect = onSelect,
                )
            }
        }
    }
}

@Composable
internal fun ToolbarIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    accent: Color,
    brush: Brush,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val foreground = if (enabled) accent else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.48f)
    Box(
        modifier =
        Modifier
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
            modifier =
            Modifier
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

internal fun toolbarGradientColors(runtime: AssistantRuntimeID): List<Color> = when (runtime) {
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
}

@Composable
internal fun SendButton(enabled: Boolean, accent: Color, isSending: Boolean, onClick: () -> Unit) {
    // Three-state visual contract (matches the updated Hermes send
    // button): filled when ready, half-opacity while streaming, outline
    // ring with muted icon when empty — so users always understand why
    // a tap landed or didn't.
    val bg =
        when {
            isSending -> accent.copy(alpha = 0.35f)
            enabled -> accent
            else -> Color.Transparent
        }
    val tint =
        when {
            isSending -> Color.White.copy(alpha = 0.7f)
            enabled -> Color.White
            else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
        }
    val outline =
        if (!enabled && !isSending) {
            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
        } else {
            Color.Transparent
        }

    Box(
        modifier =
        Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(
                if (enabled && !isSending) {
                    Brush.radialGradient(listOf(accent.copy(alpha = 0.32f), Color.Transparent))
                } else {
                    Brush.radialGradient(listOf(Color.Transparent, Color.Transparent))
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        IconButton(
            enabled = enabled,
            onClick = onClick,
            modifier =
            Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(bg)
                .border(1.dp, outline, CircleShape),
        ) {
            Icon(
                imageVector = if (isSending) Icons.Filled.HourglassEmpty else Icons.AutoMirrored.Filled.Send,
                contentDescription =
                when {
                    isSending -> "Waiting for response — send disabled"
                    enabled -> "Send message"
                    else -> "Type a message to enable send"
                },
                tint = tint,
            )
        }
    }
}
