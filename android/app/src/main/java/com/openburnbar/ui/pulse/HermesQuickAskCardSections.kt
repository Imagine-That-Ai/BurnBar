@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesMessage
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun HermesQuickAskHeader(isConnected: Boolean, onOpenHermes: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(
                text = "Hermes",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (isConnected) AuroraColors.hermesAureate else AuroraColors.warning,
            )
            Text(
                text = if (isConnected) "Live · ask about your fleet" else "Hermes offline — start it on your Mac",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = "Full chat ›",
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.hermesAureate,
            modifier = Modifier.clickable { onOpenHermes() },
        )
    }
}

@Composable
internal fun HermesQuickAskThreadPreview(recent: List<com.openburnbar.data.hermes.HermesMessage>) {
    if (recent.isEmpty()) {
        HermesQuickAskEmptyPreview()
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        recent.forEach { msg -> HermesQuickAskMessageRow(msg) }
    }
}

@Composable
private fun HermesQuickAskEmptyPreview() {
    Row(verticalAlignment = Alignment.Top) {
        Text(
            text = "✦",
            fontSize = 24.sp,
            color = AuroraColors.hermesAureate,
            modifier = Modifier.padding(end = AuroraSpacing.sm.dp),
        )
        Column {
            Text(
                text = "Ask about your burn",
                fontSize = AuroraTypography.body.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "Hermes can summarize today's spend, find your most expensive sessions, or forecast EOD usage.",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun HermesQuickAskMessageRow(msg: com.openburnbar.data.hermes.HermesMessage) {
    Row(verticalAlignment = Alignment.Top) {
        Box(modifier = Modifier.width(28.dp)) {
            if (msg.role == "user") {
                Text(
                    text = "You",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Text(text = "✦", fontSize = 14.sp, color = AuroraColors.hermesAureate)
            }
        }
        Text(
            text = msg.content,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
        )
    }
}

@Composable
internal fun HermesQuickAskInputRow(
    input: String,
    inputFocused: Boolean,
    onInputChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f))
            .border(
                width = if (inputFocused) 1.dp else 0.5.dp,
                color = if (inputFocused) AuroraColors.hermesAureate else MaterialTheme.colorScheme.outline.copy(alpha = 0.4f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        OutlinedTextField(
            value = input,
            onValueChange = onInputChange,
            modifier = Modifier.weight(1f),
            textStyle =
            LocalTextStyle.current.copy(
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurface,
            ),
            singleLine = true,
            placeholder = {
                Text(
                    text = "Ask Hermes about your burn…",
                    fontSize = AuroraTypography.body.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            colors =
            OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Color.Transparent,
                unfocusedBorderColor = Color.Transparent,
                disabledBorderColor = Color.Transparent,
            ),
        )
        Spacer(modifier = Modifier.width(8.dp))
        Icon(
            imageVector = Icons.AutoMirrored.Filled.Send,
            contentDescription = "Send",
            tint = if (input.isBlank()) MaterialTheme.colorScheme.onSurfaceVariant else AuroraColors.hermesAureate,
            modifier =
            Modifier
                .size(28.dp)
                .clickable(enabled = input.isNotBlank(), onClick = onSend),
        )
    }
}

@Composable
internal fun HermesQuickAskPromptRail(
    suggestedPrompts: List<String>,
    onPromptSelected: (String) -> Unit,
) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        items(suggestedPrompts) { prompt ->
            SuggestedPromptChip(prompt = prompt, onClick = { onPromptSelected(prompt) })
        }
    }
}

@Composable
internal fun HermesQuickAskDivider() {
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
}

@Composable
private fun SuggestedPromptChip(prompt: String, onClick: () -> Unit) {
    Text(
        text = prompt,
        fontSize = AuroraTypography.tiny.sp,
        color = AuroraColors.hermesAureate,
        modifier =
        Modifier
            .clip(CircleShape)
            .background(AuroraColors.hermesAureate.copy(alpha = 0.12f))
            .border(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.35f), CircleShape)
            .clickable { onClick() }
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}
