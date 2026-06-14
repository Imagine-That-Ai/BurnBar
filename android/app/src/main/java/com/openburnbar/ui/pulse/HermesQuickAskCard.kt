// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun HermesQuickAskCard(service: HermesService, suggestedPrompts: List<String>, onOpenHermes: () -> Unit) {
    val isConnected by service.isConnected.collectAsState()
    val messages by service.messages.collectAsState()
    var input by remember { mutableStateOf("") }
    var inputFocused by remember { mutableStateOf(false) }

    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
        cornerRadius = AuroraRadius.XL,
    ) {
        Column {
            HermesQuickAskHeader(isConnected = isConnected, onOpenHermes = onOpenHermes)
            Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
            HermesQuickAskThreadPreview(recent = messages.takeLast(3))
            Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
            HermesQuickAskDivider()
            Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
            HermesQuickAskInputRow(
                input = input,
                inputFocused = inputFocused,
                onInputChange = { input = it },
                onSend = {
                    service.sendMessage(input.trim())
                    input = ""
                },
            )
            if (input.isEmpty() && suggestedPrompts.isNotEmpty()) {
                Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
                HermesQuickAskPromptRail(
                    suggestedPrompts = suggestedPrompts,
                    onPromptSelected = { service.sendMessage(it) },
                )
            }
        }
    }
}
