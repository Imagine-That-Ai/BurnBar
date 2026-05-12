package com.openburnbar.ui.pulse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesMessage
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.*
import kotlinx.coroutines.launch

@Composable
fun HermesQuickAskCard(
    service: HermesService,
    suggestedPrompts: List<String>,
    onOpenHermes: () -> Unit
) {
    val isConnected by service.isConnected.collectAsState()
    val messages by service.messages.collectAsState()
    var input by remember { mutableStateOf("") }
    var inputFocused by remember { mutableStateOf(false) }

    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl
    ) {
        Column() {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "Hermes",
                        fontSize = AuroraTypography.caption.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (isConnected) AuroraColors.hermesAureate else AuroraColors.warning
                    )
                    Text(
                        text = if (isConnected) "Live · ask about your fleet" else "Hermes offline — start it on your Mac",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    text = "Full chat ›",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraColors.hermesAureate,
                    modifier = Modifier.clickable { onOpenHermes() }
                )
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

            // Thread preview
            val recent = messages.takeLast(3)
            if (recent.isEmpty()) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        text = "✦",
                        fontSize = 24.sp,
                        color = AuroraColors.hermesAureate,
                        modifier = Modifier.padding(end = AuroraSpacing.sm.dp)
                    )
                    Column {
                        Text(
                            text = "Ask about your burn",
                            fontSize = AuroraTypography.body.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            text = "Hermes can summarize today's spend, find your most expensive sessions, or forecast EOD usage.",
                            fontSize = AuroraTypography.tiny.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    recent.forEach { msg ->
                        Row(verticalAlignment = Alignment.Top) {
                            Box(modifier = Modifier.width(28.dp)) {
                                if (msg.role == "user") {
                                    Text(
                                        text = "You",
                                        fontSize = AuroraTypography.tiny.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                } else {
                                    Text(
                                        text = "✦",
                                        fontSize = 14.sp,
                                        color = AuroraColors.hermesAureate
                                    )
                                }
                            }
                            Text(
                                text = msg.content,
                                fontSize = AuroraTypography.tiny.sp,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 2
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

            androidx.compose.material3.Divider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))

            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

            // Input row
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f))
                    .border(
                        width = if (inputFocused) 1.dp else 0.5.dp,
                        color = if (inputFocused) AuroraColors.hermesAureate else MaterialTheme.colorScheme.outline.copy(alpha = 0.4f),
                        shape = RoundedCornerShape(12.dp)
                    )
                    .padding(horizontal = 10.dp, vertical = 8.dp)
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    modifier = Modifier.weight(1f),
                    textStyle = LocalTextStyle.current.copy(
                        fontSize = AuroraTypography.body.sp,
                        color = MaterialTheme.colorScheme.onSurface
                    ),
                    singleLine = true,
                    placeholder = {
                        Text(
                            text = "Ask Hermes about your burn…",
                            fontSize = AuroraTypography.body.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color.Transparent,
                        unfocusedBorderColor = Color.Transparent,
                        disabledBorderColor = Color.Transparent
                    )
                )
                Spacer(modifier = Modifier.width(8.dp))
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.Send,
                    contentDescription = "Send",
                    tint = if (input.isBlank()) MaterialTheme.colorScheme.onSurfaceVariant else AuroraColors.hermesAureate,
                    modifier = Modifier
                        .size(28.dp)
                        .clickable(enabled = input.isNotBlank()) {
                            service.sendMessage(input.trim())
                            input = ""
                        }
                )
            }

            // Prompt rail
            if (input.isEmpty() && suggestedPrompts.isNotEmpty()) {
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(suggestedPrompts) { prompt ->
                        SuggestedPromptChip(
                            prompt = prompt,
                            onClick = {
                                service.sendMessage(prompt)
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SuggestedPromptChip(
    prompt: String,
    onClick: () -> Unit
) {
    Text(
        text = prompt,
        fontSize = AuroraTypography.tiny.sp,
        color = AuroraColors.hermesAureate,
        modifier = Modifier
            .clip(CircleShape)
            .background(AuroraColors.hermesAureate.copy(alpha = 0.12f))
            .border(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.35f), CircleShape)
            .clickable { onClick() }
            .padding(horizontal = 10.dp, vertical = 6.dp)
    )
}
