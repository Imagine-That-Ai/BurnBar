package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.PiPendingPrompt
import com.openburnbar.data.hermes.PiChatMessage
import com.openburnbar.data.hermes.PiService
import com.openburnbar.data.hermes.PiToolCall
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import kotlinx.coroutines.delay

// Plan 2 — Android Pi assistant pane. Minimal but functional sibling of
// `HermesView` so users can chat with the Pi gateway from the Assistants
// surface. Tool cards and library import are deferred to a follow-up wave.

@Composable
fun PiAssistantView(piService: PiService) {
    val messages by piService.messages.collectAsState()
    val isStreaming by piService.isStreaming.collectAsState()
    val isReachable by piService.isReachable.collectAsState()
    val errorText by piService.runtimeErrorText.collectAsState()

    var input by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    LaunchedEffect(Unit) { piService.refreshRuntime() }

    // Pending-prompt consumer — picks up prompts stashed by the
    // "Ask Pi" widget chip via `MainActivity.stashPendingPromptFromIntent`
    // or by a `burnbar://pi?prompt=…` deep link. Non-blank values
    // auto-send once the composer surface is ready; an empty slot is
    // ignored (chip with no prompt just lands the user on this screen
    // with the composer ready).
    LaunchedEffect(Unit) {
        val pending = PiPendingPrompt.pending
        if (!pending.isNullOrBlank()) {
            PiPendingPrompt.pending = null
            delay(250)
            piService.send(pending.trim())
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        if (!isReachable) {
            Text(
                text = errorText ?: "Pi gateway not reached yet.",
                color = AuroraColors.warning,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)
            )
        }
        LazyColumn(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            state = listState,
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(messages, key = { it.id }) { msg ->
                PiMessageBubble(msg)
            }
        }
        PiComposer(
            value = input,
            isStreaming = isStreaming,
            onChange = { input = it },
            onSend = {
                val text = input
                if (text.isNotBlank()) {
                    piService.send(text)
                    input = ""
                }
            }
        )
    }
}

@Composable
private fun PiMessageBubble(message: PiChatMessage) {
    val isUser = message.role == "user"
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (isUser) Alignment.End else Alignment.Start
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
        ) {
            Column(
                modifier = Modifier
                    .background(
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                        shape = RoundedCornerShape(14.dp)
                    )
                    .border(
                        width = 0.7.dp,
                        brush = Brush.linearGradient(AuroraGradients.piGradient),
                        shape = RoundedCornerShape(14.dp)
                    )
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                if (!isUser) {
                    Text(
                        text = "π via Pi",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = AuroraColors.whimsy
                    )
                }
                val shouldShowText =
                    message.content.isNotEmpty() || message.toolCalls.isEmpty() || message.isStreaming
                if (shouldShowText) {
                    Text(
                        text = if (message.content.isEmpty() && message.isStreaming) "…" else message.content,
                        color = if (message.isError) AuroraColors.error else MaterialTheme.colorScheme.onSurface,
                        fontSize = 14.sp
                    )
                }
            }
        }
        if (!isUser && message.toolCalls.isNotEmpty()) {
            Spacer(modifier = Modifier.height(6.dp))
            PiToolCallStrip(message.toolCalls)
        }
    }
}

@Composable
private fun PiToolCallStrip(toolCalls: List<PiToolCall>) {
    // Most-recent on the left, matching the iOS pill row.
    val reversed = remember(toolCalls) { toolCalls.reversed() }
    LazyRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        items(reversed, key = { it.id }) { tool -> PiToolCallPill(tool) }
    }
}

@Composable
private fun PiToolCallPill(tool: PiToolCall) {
    Surface(
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.75f),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .widthIn(max = 240.dp)
            .border(
                width = 0.75.dp,
                brush = Brush.linearGradient(AuroraGradients.piGradient),
                shape = RoundedCornerShape(12.dp)
            )
    ) {
        Column(modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = piToolIcon(tool.name),
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = AuroraColors.whimsy
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = tool.name,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraColors.whimsy
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = tool.status,
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            val detail = tool.detail?.trim().orEmpty()
            if (detail.isNotEmpty()) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = detail,
                    fontSize = 10.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private fun piToolIcon(name: String): ImageVector {
    val n = name.lowercase()
    return when {
        n.contains("search") || n.contains("grep") || n.contains("find") -> Icons.Filled.Search
        n.contains("terminal") || n.contains("bash") || n.contains("exec") || n.contains("run") -> Icons.Filled.Terminal
        n.contains("edit") || n.contains("write") || n.contains("patch") -> Icons.Filled.Edit
        else -> Icons.Filled.Code
    }
}

@Composable
private fun PiComposer(
    value: String,
    isStreaming: Boolean,
    onChange: (String) -> Unit,
    onSend: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            placeholder = { Text("Ask Pi…", fontSize = 14.sp) },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { onSend() }),
            singleLine = false,
            modifier = Modifier.weight(1f)
        )
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(Brush.linearGradient(AuroraGradients.piGradient)),
            contentAlignment = Alignment.Center
        ) {
            IconButton(
                onClick = onSend,
                enabled = !isStreaming && value.isNotBlank()
            ) {
                Icon(
                    imageVector = Icons.Filled.Send,
                    contentDescription = "Send",
                    tint = Color.Black
                )
            }
        }
    }
}
