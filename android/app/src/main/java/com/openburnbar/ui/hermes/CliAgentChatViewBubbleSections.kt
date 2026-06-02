@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatToolCall
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.CliRuntimeModelOption
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.AuroraGradients

// MARK: - Empty state

@Composable
internal fun EmptyStateHero(
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    quickPrompts: List<String>,
    selectedModel: CliRuntimeModelOption?,
    onQuickPrompt: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        EmptyStateHeroCard(runtime = runtime, provider = provider, selectedModel = selectedModel)
        Spacer(modifier = Modifier.height(28.dp))
        EmptyStateQuickPrompts(quickPrompts = quickPrompts, provider = provider, onQuickPrompt = onQuickPrompt)
    }
}

@Composable
internal fun EmptyStateHeroCard(
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    selectedModel: CliRuntimeModelOption?,
) {
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        border = BorderStroke(1.2.dp, glassStrokeBrush),
        modifier = Modifier.padding(horizontal = 8.dp),
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            EmptyStateProviderAvatar(provider = provider)
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
            EmptyStateModelBadge(provider = provider, selectedModel = selectedModel)
        }
    }
}

@Composable
private fun EmptyStateProviderAvatar(provider: AgentProvider) {
    Box(
        modifier =
        Modifier
            .size(80.dp)
            .background(Brush.linearGradient(AuroraGradients.providerRing(provider)), CircleShape)
            .padding(3.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.Center,
        ) {
            ProviderLogo(provider = provider, size = 56.dp, circular = true)
        }
    }
}

@Composable
private fun EmptyStateModelBadge(provider: AgentProvider, selectedModel: CliRuntimeModelOption?) {
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
                text =
                selectedModel?.let { "${it.displayName} · ${it.source.displayLabel}" }
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

@Composable
internal fun EmptyStateQuickPrompts(
    quickPrompts: List<String>,
    provider: AgentProvider,
    onQuickPrompt: (String) -> Unit,
) {
    if (quickPrompts.isEmpty()) return
    Text(
        text = "SUGGESTED PROMPTS",
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        letterSpacing = 1.sp,
        modifier = Modifier.padding(bottom = 8.dp),
    )
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 4.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(quickPrompts) { prompt ->
            EmptyStateQuickPromptChip(prompt = prompt, provider = provider, onQuickPrompt = onQuickPrompt)
        }
    }
}

@Composable
private fun EmptyStateQuickPromptChip(prompt: String, provider: AgentProvider, onQuickPrompt: (String) -> Unit) {
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
            modifier =
            Modifier
                .clip(RoundedCornerShape(percent = 50))
                .clickable { onQuickPrompt(prompt) }
                .padding(horizontal = 14.dp, vertical = 9.dp),
        )
    }
}

// MARK: - Bubble row

@Composable
internal fun MessageBubble(
    message: AssistantChatMessage,
    runtime: AssistantRuntimeID,
    provider: AgentProvider,
    isStreaming: Boolean,
    viewMode: ChatViewMode = ChatViewMode.AGENT,
) {
    val isUser = message.role == "user"
    when {
        viewMode == ChatViewMode.CLI ->
            CLIMessageRow(message = message, isUser = isUser, isHermes = runtime == AssistantRuntimeID.HERMES)
        isUser -> UserMessageBubble(message = message, provider = provider)
        else -> AgentMessageBubble(message = message, provider = provider, isStreaming = isStreaming)
    }
}

@Composable
internal fun UserMessageBubble(message: AssistantChatMessage, provider: AgentProvider) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Column(horizontalAlignment = Alignment.End) {
                Surface(
                    shape =
                    RoundedCornerShape(
                        topStart = 20.dp,
                        topEnd = 20.dp,
                        bottomStart = 20.dp,
                        bottomEnd = 4.dp,
                    ),
                    color = Color(provider.brandColor).copy(alpha = 0.12f),
                    border =
                    BorderStroke(
                        width = 0.75.dp,
                        brush =
                        Brush.linearGradient(
                            listOf(Color(provider.brandColor).copy(alpha = 0.45f), Color(provider.accentColor).copy(alpha = 0.15f)),
                        ),
                    ),
                ) {
                    Text(
                        text = message.text,
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier =
                        Modifier
                            .widthIn(max = 280.dp)
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                }
                if (message.attachments.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(6.dp))
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        message.attachments.forEach { att ->
                            AttachmentChip(att = att, accent = Color(provider.brandColor))
                        }
                    }
                }
            }
        }
}

@Composable
internal fun AgentMessageBubble(message: AssistantChatMessage, provider: AgentProvider, isStreaming: Boolean) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            AgentMessageBubbleHeader(message = message, provider = provider)
            Spacer(modifier = Modifier.height(4.dp))
            AgentMessageBubbleBody(message = message, provider = provider, isStreaming = isStreaming)
            val toolCalls = message.hermes?.toolCalls.orEmpty()
            if (toolCalls.isNotEmpty()) {
                Spacer(modifier = Modifier.height(6.dp))
                AssistantToolCallStrip(toolCalls = toolCalls, accent = Color(provider.brandColor))
            }
        }
    }
}

@Composable
private fun AgentMessageBubbleHeader(message: AssistantChatMessage, provider: AgentProvider) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier =
            Modifier
                .size(18.dp)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        listOf(Color(provider.brandColor), Color(provider.accentColor).copy(alpha = 0.75f)),
                    ),
                )
                .padding(1.dp),
            contentAlignment = Alignment.Center,
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
}

@Composable
private fun AgentMessageBubbleBody(message: AssistantChatMessage, provider: AgentProvider, isStreaming: Boolean) {
    Surface(
        shape = RoundedCornerShape(topStart = 4.dp, topEnd = 20.dp, bottomStart = 20.dp, bottomEnd = 20.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        border =
        BorderStroke(
            width = 0.75.dp,
            brush =
            Brush.linearGradient(
                listOf(
                    Color(provider.brandColor).copy(alpha = 0.28f),
                    MaterialTheme.colorScheme.outline.copy(alpha = 0.12f),
                ),
            ),
        ),
    ) {
        val displayText =
            when {
                message.text.isBlank() && isStreaming -> "…"
                isStreaming -> message.text + "▍"
                else -> message.text
            }
        if (!message.isError) {
            HermesRichBubble(
                text = displayText,
                isStreaming = isStreaming,
                baseSize = 15f,
                baseColor = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.widthIn(max = 320.dp).padding(horizontal = 16.dp, vertical = 12.dp),
            )
        } else {
            Text(
                text = displayText,
                fontSize = 15.sp,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.widthIn(max = 320.dp).padding(horizontal = 16.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
internal fun AssistantToolCallStrip(toolCalls: List<AssistantChatToolCall>, accent: Color) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(toolCalls.reversed(), key = { it.id }) { tool ->
            AssistantToolCallChip(tool = tool, accent = accent)
        }
    }
}

@Composable
private fun AssistantToolCallChip(tool: AssistantChatToolCall, accent: Color) {
    val isDone = tool.status == "done" || tool.status.isBlank()
    val statusColor = if (isDone) Color(0xFF22C55E) else Color(0xFFF59E0B)
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
        border =
        BorderStroke(
            width = 0.8.dp,
            brush = Brush.linearGradient(listOf(accent.copy(alpha = 0.45f), statusColor.copy(alpha = 0.25f))),
        ),
        modifier = Modifier.widthIn(max = 240.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            AssistantToolCallIcon(tool = tool, accent = accent)
            AssistantToolCallLabels(tool = tool, isDone = isDone, statusColor = statusColor)
        }
    }
}

@Composable
private fun AssistantToolCallIcon(tool: AssistantChatToolCall, accent: Color) {
    Box(
        modifier =
        Modifier
            .size(24.dp)
            .clip(CircleShape)
            .background(accent.copy(alpha = 0.12f))
            .border(0.5.dp, accent.copy(alpha = 0.35f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = toolCallIcon(toolCallVisualKind(tool.name)),
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(12.dp),
        )
    }
}

@Composable
private fun RowScope.AssistantToolCallLabels(tool: AssistantChatToolCall, isDone: Boolean, statusColor: Color) {
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
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(modifier = Modifier.size(6.dp).background(statusColor, CircleShape))
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
