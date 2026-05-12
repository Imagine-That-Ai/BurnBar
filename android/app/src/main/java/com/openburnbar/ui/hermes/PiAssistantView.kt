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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
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
import com.openburnbar.data.hermes.PiChatMessage
import com.openburnbar.data.hermes.PiService
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

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
            Text(
                text = if (message.content.isEmpty() && message.isStreaming) "…" else message.content,
                color = if (message.isError) AuroraColors.error else MaterialTheme.colorScheme.onSurface,
                fontSize = 14.sp
            )
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
