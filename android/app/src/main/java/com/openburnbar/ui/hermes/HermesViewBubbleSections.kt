// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesMessage
import com.openburnbar.data.hermes.ToolCall
import com.openburnbar.ui.components.BreathingDot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import java.io.IOException
import org.json.JSONObject

@Composable
fun ChatBubble(
    message: HermesMessage,
    viewMode: ChatViewMode = ChatViewMode.AGENT,
    permissionItem: com.openburnbar.data.computeruse.SystemPermissionItem? = null,
) {
    if (viewMode == ChatViewMode.CLI) {
        HermesCLIMessageRow(message = message, isUser = message.role == "user")
        return
    }

    val permissionState = rememberChatBubblePermissionState(matchingItem = permissionItem)
    ChatBubbleAgentLayout(message = message, permissionState = permissionState)
    ChatBubblePermissionSheet(permissionState = permissionState)
}

private data class ChatBubblePermissionState(
    val matchingItem: com.openburnbar.data.computeruse.SystemPermissionItem?,
    val presentedItem: com.openburnbar.data.computeruse.SystemPermissionItem?,
    val setPresentedItem: (com.openburnbar.data.computeruse.SystemPermissionItem?) -> Unit,
)

@Composable
private fun rememberChatBubblePermissionState(matchingItem: com.openburnbar.data.computeruse.SystemPermissionItem?): ChatBubblePermissionState {
    var presentedPermissionItem by remember {
        mutableStateOf<com.openburnbar.data.computeruse.SystemPermissionItem?>(null)
    }
    return ChatBubblePermissionState(
        matchingItem = matchingItem,
        presentedItem = presentedPermissionItem,
        setPresentedItem = { presentedPermissionItem = it },
    )
}

/**
 * Pending system-permission items for [threadId], keyed by originating tool call.
 * First occurrence wins so lookups keep the previous first-match-in-inbox-order
 * semantics; items without an originating tool call never matched a bubble and
 * are skipped.
 */
internal fun systemPermissionItemsByToolCallId(
    itemsByThread: Map<String, Map<String, com.openburnbar.data.computeruse.SystemPermissionItem>>,
    threadId: String,
): Map<String, com.openburnbar.data.computeruse.SystemPermissionItem> {
    val threadItems = itemsByThread[threadId]?.values ?: return emptyMap()
    return buildMap {
        threadItems.forEach { item ->
            val toolCallId = item.originatingToolCallId ?: return@forEach
            if (toolCallId !in this) put(toolCallId, item)
        }
    }
}

/** A message owns an item when the originating tool call is the message itself or one of its tool calls. */
internal fun matchingSystemPermissionItem(
    inboxByToolCallId: Map<String, com.openburnbar.data.computeruse.SystemPermissionItem>,
    message: HermesMessage,
): com.openburnbar.data.computeruse.SystemPermissionItem? = inboxByToolCallId[message.id]
    ?: message.toolCalls.firstNotNullOfOrNull { tc -> inboxByToolCallId[tc.id] }

@Composable
private fun ChatBubbleAgentLayout(message: HermesMessage, permissionState: ChatBubblePermissionState) {
    val isUser = message.role == "user"
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (isUser) Alignment.End else Alignment.Start,
    ) {
        if (!isUser) {
            ChatBubbleAgentHeader(message = message)
        }
        ChatBubbleAgentSurface(message = message, isUser = isUser, permissionState = permissionState)
        Spacer(modifier = Modifier.height(if (isUser) AuroraSpacing.XXS.dp else AuroraSpacing.SM.dp))
    }
}

@Composable
private fun ChatBubbleAgentHeader(message: HermesMessage) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(start = AuroraSpacing.MD.dp + 4.dp, bottom = AuroraSpacing.XXS.dp),
    ) {
        BreathingDot(
            color = if (message.isStreaming) AuroraColors.success else AuroraColors.hermesMercury,
            size = 6,
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
        Text(
            text = "via Hermes · ${message.modelName}",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f),
        )
    }
}

@Composable
private fun ChatBubbleAgentSurface(message: HermesMessage, isUser: Boolean, permissionState: ChatBubblePermissionState) {
    Surface(
        shape =
        RoundedCornerShape(
            topStart = 18.dp,
            topEnd = 18.dp,
            bottomStart = if (isUser) 18.dp else 4.dp,
            bottomEnd = if (isUser) 4.dp else 18.dp,
        ),
        color =
        if (isUser) {
            AuroraColors.hermesMercury.copy(alpha = 0.12f)
        } else {
            MaterialTheme.colorScheme.surface.copy(alpha = 0.35f)
        },
        border =
        BorderStroke(
            width = 0.75.dp,
            brush =
            Brush.linearGradient(
                if (isUser) {
                    listOf(AuroraColors.hermesMercury.copy(alpha = 0.45f), AuroraColors.hermesAureate.copy(alpha = 0.15f))
                } else {
                    listOf(AuroraColors.hermesMercury.copy(alpha = 0.28f), MaterialTheme.colorScheme.outline.copy(alpha = 0.12f))
                },
            ),
        ),
        modifier = Modifier.widthIn(max = 320.dp),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            ChatBubbleMessageBody(message = message, isUser = isUser)
            ChatBubbleMetadata(message = message, permissionState = permissionState)
        }
    }
}

@Composable
private fun ChatBubbleMessageBody(message: HermesMessage, isUser: Boolean) {
    val displayText = chatBubbleDisplayText(message)
    if (!isUser && !message.isError) {
        HermesRichBubble(
            text = displayText,
            isStreaming = message.isStreaming,
            baseSize = 15f,
            baseColor = MaterialTheme.colorScheme.onSurface,
        )
    } else {
        Text(
            text = displayText,
            fontSize = 15.sp,
            color = if (message.isError) AuroraColors.error else MaterialTheme.colorScheme.onSurface,
            lineHeight = 20.sp,
        )
    }
}

private fun chatBubbleDisplayText(message: HermesMessage): String = when {
    message.content.isEmpty() && message.isStreaming -> "…"
    message.isStreaming -> message.content + "▍"
    else -> message.content
}

@Composable
private fun ChatBubbleMetadata(message: HermesMessage, permissionState: ChatBubblePermissionState) {
    if (message.toolCalls.isNotEmpty()) {
        Spacer(modifier = Modifier.height(8.dp))
        ChatBubbleToolCallStrip(toolCalls = message.toolCalls)
    }
    if (message.tokensPerSecond != null) {
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "${"%.1f".format(message.tokensPerSecond)} t/s",
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        )
    }
    permissionState.matchingItem?.let { item ->
        Spacer(modifier = Modifier.height(8.dp))
        com.openburnbar.ui.computeruse.SystemPermissionInlinePill(
            item = item,
            onTap = { permissionState.setPresentedItem(item) },
        )
    }
}

@Composable
private fun ChatBubbleToolCallStrip(toolCalls: List<ToolCall>) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(toolCalls) { tc -> ChatBubbleToolCallPill(tc = tc) }
    }
}

@Composable
private fun ChatBubbleToolCallPill(tc: ToolCall) {
    val visualKind = toolCallVisualKind(tc.name)
    val isDone = tc.result?.trim()?.isNotEmpty() == true
    val statusColor = if (isDone) Color(0xFF22C55E) else Color(0xFFF59E0B)
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
        border =
        BorderStroke(
            width = 0.8.dp,
            brush = Brush.linearGradient(
                listOf(AuroraColors.hermesMercury.copy(alpha = 0.45f), statusColor.copy(alpha = 0.25f)),
            ),
        ),
        modifier = Modifier.widthIn(max = 240.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            ChatBubbleToolCallIcon(visualKind = visualKind)
            ChatBubbleToolCallLabels(tc = tc, isDone = isDone, statusColor = statusColor)
        }
    }
}

@Composable
private fun ChatBubbleToolCallIcon(visualKind: ToolCallVisualKind) {
    Box(
        modifier =
        Modifier
            .size(24.dp)
            .clip(CircleShape)
            .background(AuroraColors.hermesMercury.copy(alpha = 0.12f))
            .border(0.5.dp, AuroraColors.hermesMercury.copy(alpha = 0.35f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = toolCallIcon(visualKind),
            contentDescription = null,
            tint = AuroraColors.hermesMercury,
            modifier = Modifier.size(12.dp),
        )
    }
}

@Composable
private fun ChatBubbleToolCallLabels(tc: ToolCall, isDone: Boolean, statusColor: Color) {
    Column {
        Text(
            text = tc.name,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        ChatBubbleToolCallStatusRow(isDone = isDone, statusColor = statusColor)
    }
}

@Composable
private fun ChatBubbleToolCallStatusRow(isDone: Boolean, statusColor: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(6.dp)
                .background(statusColor, CircleShape),
        )
        Text(
            text = if (isDone) "completed" else "running",
            fontSize = 9.sp,
            fontWeight = FontWeight.Medium,
            color = statusColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ChatBubblePermissionSheet(permissionState: ChatBubblePermissionState) {
    permissionState.presentedItem?.let { item ->
        val context = LocalContext.current
        com.openburnbar.ui.computeruse.SystemPermissionGrantBottomSheet(
            item = item,
            onDismiss = { permissionState.setPresentedItem(null) },
            sendPermissionRequest = { request ->
                try {
                    val controller =
                        com.openburnbar.BurnBarApplication.agentCapabilityGrantController
                            ?: com.openburnbar.data.computeruse.AgentCapabilityGrantController(
                                context.applicationContext,
                            ).also {
                                com.openburnbar.BurnBarApplication.agentCapabilityGrantController = it
                            }
                    controller.sendSystemPermissionRequest(request)
                    Result.success(Unit)
                } catch (t: IOException) {
                    Result.failure(t)
                }
            },
        )
    }
}

@Composable
private fun HermesCLIMessageRow(message: HermesMessage, isUser: Boolean) {
    val toolLines =
        message.toolCalls.map { tc ->
            val detail = summarizeHermesToolDetail(tc)?.takeIf { it.isNotBlank() }
            "⟨${tc.name}${if (detail != null) ": $detail" else ""}⟩"
        }
    val fullText =
        if (toolLines.isNotEmpty()) {
            (listOf(message.content) + toolLines).filter { it.isNotBlank() }.joinToString("\n")
        } else {
            message.content
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
            text = if (isUser) ">" else "☿",
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = if (isUser) Color(0xFF22C55E) else Color(0xFFD4AA3C),
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

fun summarizeHermesToolDetail(tc: ToolCall): String? {
    val result = tc.result?.trim().orEmpty()
    if (result.isNotEmpty()) return result.take(200)
    return summarizeHermesToolDetailFromArguments(tc.arguments.trim())
}

private fun summarizeHermesToolDetailFromArguments(args: String): String? {
    if (args.isEmpty()) return null
    val preferredKeys = listOf("path", "file_path", "command", "pattern", "query", "url", "prompt")
    runCatching {
        val obj = JSONObject(args)
        preferredKeys.firstNotNullOfOrNull { key ->
            obj.optString(key).takeIf { it.isNotEmpty() }?.take(200)
        }?.let { return it }
        val keys = obj.keys()
        while (keys.hasNext()) {
            val value = obj.optString(keys.next())
            if (value.isNotEmpty()) return value.take(200)
        }
    }
    return preferredKeys.firstNotNullOfOrNull { key ->
        val pattern = "\"$key\"\\s*:\\s*\"([^\"]+)\"".toRegex()
        pattern.find(args)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }?.take(200)
    }
}
