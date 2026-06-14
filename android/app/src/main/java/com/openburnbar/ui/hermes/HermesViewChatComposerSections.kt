// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

@Composable
internal fun HermesChatComposer(content: HermesChatContent, attachments: HermesChatAttachmentState, local: HermesChatViewLocalState) {
    Surface(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        shape = RoundedCornerShape(28.dp),
        border = BorderStroke(1.dp, Brush.linearGradient(AuroraGradients.glassStroke)),
        tonalElevation = 8.dp,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            HermesAttachmentTray(
                attachments = attachments.attachments,
                onAddAttachment = attachments.onAddAttachment,
                onRemoveAttachment = attachments.onRemoveAttachment,
                modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 4.dp),
            )
            HermesChatComposerInputRow(content = content, local = local)
        }
    }
}

@Composable
private fun HermesChatComposerInputRow(content: HermesChatContent, local: HermesChatViewLocalState) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HermesChatComposerTextField(content = content, local = local)
        Spacer(modifier = Modifier.width(8.dp))
        HermesChatSendButton(content = content, local = local)
    }
}

@Composable
private fun RowScope.HermesChatComposerTextField(content: HermesChatContent, local: HermesChatViewLocalState) {
    androidx.compose.foundation.text.BasicTextField(
        value = local.inputText,
        onValueChange = { local.setInputText(expandChatDraft(it, content)) },
        enabled = !content.isStreaming,
        textStyle =
        LocalTextStyle.current.copy(
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 15.sp,
        ),
        cursorBrush = SolidColor(AuroraColors.hermesMercury),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { local.sendMessage() }),
        modifier =
        Modifier
            .weight(1f)
            .padding(vertical = 12.dp),
        decorationBox = { innerTextField ->
            Box(modifier = Modifier.fillMaxWidth()) {
                if (local.inputText.isEmpty()) {
                    Text(
                        text = "Ask Hermes...",
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        fontSize = 15.sp,
                    )
                }
                innerTextField()
            }
        },
    )
}

@Composable
private fun HermesChatSendButton(content: HermesChatContent, local: HermesChatViewLocalState) {
    val canSend = local.inputText.isNotBlank() && !content.isStreaming
    val sendBg =
        when {
            canSend -> AuroraColors.hermesMercury
            content.isStreaming -> AuroraColors.hermesMercury.copy(alpha = 0.35f)
            else -> Color.Transparent
        }
    val sendTint =
        when {
            canSend -> Color.White
            content.isStreaming -> Color.White.copy(alpha = 0.7f)
            else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
        }
    val outline =
        if (!canSend && !content.isStreaming) {
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
                if (canSend) {
                    Brush.radialGradient(listOf(AuroraColors.hermesMercury.copy(alpha = 0.32f), Color.Transparent))
                } else {
                    SolidColor(Color.Transparent)
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        IconButton(
            onClick = local.sendMessage,
            enabled = canSend,
            modifier =
            Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(sendBg)
                .border(1.dp, outline, CircleShape),
        ) {
            Icon(
                imageVector = if (content.isStreaming) Icons.Filled.HourglassEmpty else Icons.AutoMirrored.Filled.Send,
                contentDescription =
                when {
                    canSend -> "Send message"
                    content.isStreaming -> "Waiting for response — send disabled"
                    else -> "Type a message to enable send"
                },
                tint = sendTint,
            )
        }
    }
}
