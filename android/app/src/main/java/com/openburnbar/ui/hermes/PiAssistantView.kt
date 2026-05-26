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
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.LocalTextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.PiPendingPrompt
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.PiChatMessage
import com.openburnbar.data.hermes.PiService
import com.openburnbar.data.hermes.PiToolCall
import com.openburnbar.ui.computeruse.AgentPermissionGrantSheet
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
    var permissionThreadID by remember { mutableStateOf<String?>(null) }
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
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Pi",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f)
            )
            IconButton(onClick = { permissionThreadID = piService.ensureDesktopGrantThreadID() }) {
                Icon(Icons.Filled.Security, contentDescription = "Agent permissions")
            }
        }
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

    permissionThreadID?.let { threadID ->
        AgentPermissionGrantSheet(
            runtime = AssistantRuntimeID.PI.token,
            threadId = threadID,
            onDismiss = { permissionThreadID = null },
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
            horizontalArrangement = if (isUser) Arrangement.End as androidx.compose.foundation.layout.Arrangement.Horizontal else Arrangement.Start as androidx.compose.foundation.layout.Arrangement.Horizontal
        ) {
            if (isUser) {
                Surface(
                    shape = RoundedCornerShape(
                        topStart = 20.dp,
                        topEnd = 20.dp,
                        bottomStart = 20.dp,
                        bottomEnd = 4.dp
                    ),
                    color = AuroraColors.whimsy.copy(alpha = 0.12f),
                    border = BorderStroke(
                        width = 0.75.dp,
                        brush = Brush.linearGradient(
                            listOf(AuroraColors.whimsy.copy(alpha = 0.45f), AuroraColors.purple.copy(alpha = 0.15f))
                        )
                    ),
                    modifier = Modifier.widthIn(max = 300.dp)
                ) {
                    Text(
                        text = message.content,
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)
                    )
                }
            } else {
                Column {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(18.dp)
                                .clip(CircleShape)
                                .background(Brush.linearGradient(AuroraGradients.piGradient))
                                .padding(1.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text("π", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Color.White)
                        }
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = "Pi",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = AuroraColors.whimsy,
                        )
                    }
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
                                    AuroraColors.whimsy.copy(alpha = 0.28f),
                                    MaterialTheme.colorScheme.outline.copy(alpha = 0.12f)
                                )
                            )
                        ),
                        modifier = Modifier.widthIn(max = 320.dp)
                    ) {
                        Text(
                            text = if (message.content.isEmpty() && message.isStreaming) "…" else message.content,
                            fontSize = 15.sp,
                            color = if (message.isError) AuroraColors.error else MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)
                        )
                    }
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
    val accent = AuroraColors.whimsy
    val isDone = tool.status == "done" || tool.status.isBlank()
    val statusColor = if (isDone) Color(0xFF22C55E) else Color(0xFFF59E0B)
    val visualKind = toolCallVisualKind(tool.name)
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

@Composable
private fun PiComposer(
    value: String,
    isStreaming: Boolean,
    onChange: (String) -> Unit,
    onSend: () -> Unit
) {
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    val accent = AuroraColors.whimsy
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border = BorderStroke(1.dp, glassStrokeBrush),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        tonalElevation = 8.dp
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp)
        ) {
            androidx.compose.foundation.text.BasicTextField(
                value = value,
                onValueChange = onChange,
                enabled = !isStreaming,
                textStyle = LocalTextStyle.current.copy(
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 15.sp
                ),
                cursorBrush = SolidColor(accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = 12.dp),
                decorationBox = { innerTextField ->
                    Box(modifier = Modifier.fillMaxWidth()) {
                        if (value.isEmpty()) {
                            Text(
                                text = "Ask Pi…",
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                fontSize = 15.sp
                            )
                        }
                        innerTextField()
                    }
                }
            )

            Spacer(modifier = Modifier.width(8.dp))

            val canSend = value.isNotBlank() && !isStreaming
            val sendBg = when {
                canSend -> accent
                isStreaming -> accent.copy(alpha = 0.35f)
                else -> Color.Transparent
            }
            val sendTint = when {
                canSend -> Color.White
                isStreaming -> Color.White.copy(alpha = 0.7f)
                else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
            }
            val outline = if (!canSend && !isStreaming)
                MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
            else
                Color.Transparent
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(
                        if (canSend)
                            Brush.radialGradient(listOf(accent.copy(alpha = 0.32f), Color.Transparent))
                        else
                            SolidColor(Color.Transparent)
                    ),
                contentAlignment = Alignment.Center
            ) {
                IconButton(
                    onClick = onSend,
                    enabled = canSend,
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(sendBg)
                        .border(1.dp, outline, CircleShape)
                ) {
                    Icon(
                        imageVector = if (isStreaming) Icons.Filled.HourglassEmpty else Icons.AutoMirrored.Filled.Send,
                        contentDescription = when {
                            canSend -> "Send message"
                            isStreaming -> "Waiting for response — send disabled"
                            else -> "Type a message to enable send"
                        },
                        tint = sendTint
                    )
                }
            }
        }
    }
}
