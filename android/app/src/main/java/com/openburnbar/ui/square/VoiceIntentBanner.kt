package com.openburnbar.ui.square

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

// MARK: - Voice Intent Banner (Android parity, Hermes Square §6.7)
//
// Top-banner overlay that surfaces a resolved `AndroidVoiceIntent` for
// ~4.5s, then auto-dismisses. Mirrors the iOS `VoiceIntentBanner`.

@Composable
internal fun VoiceIntentBannerView(
    intent: AndroidVoiceIntent,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    LaunchedEffect(intent) {
        delay(4_500)
        onDismiss()
    }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        tonalElevation = 1.dp,
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onDismiss)
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            Text(
                intent.displayLabel,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.height(2.dp))
            val sub = when (intent) {
                is AndroidVoiceIntent.OpenAgent -> intent.agentURI
                is AndroidVoiceIntent.Search -> "“${intent.query}”"
                is AndroidVoiceIntent.DispatchMission ->
                    if (intent.runtimeHint != null) "→ ${intent.runtimeHint}: ${intent.prompt}"
                    else intent.prompt
                is AndroidVoiceIntent.SendMessageToCurrentThread -> intent.text
                AndroidVoiceIntent.AmbientBriefing -> "Asking Hermes for the brief…"
                is AndroidVoiceIntent.FallbackToHermes -> intent.text.ifBlank { "Heard nothing — try again." }
            }
            Text(
                sub,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}
