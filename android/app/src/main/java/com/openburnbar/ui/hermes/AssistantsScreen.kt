package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.height
import com.openburnbar.MainActivity
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.PiService
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

// Plan 2 — Android Assistants surface. Hosts the Hermes and Pi runtimes
// behind a single tab. A pill at the top lets the user flip between them
// while preserving the existing `HermesView` flow.

@Composable
fun AssistantsScreen() {
    var rawRuntime by rememberSaveable { mutableStateOf(AssistantRuntimeID.HERMES.token) }
    val runtime = AssistantRuntimeID.fromToken(rawRuntime)
    val piService = remember { PiService() }
    val context = LocalContext.current

    // Honor the runtime hint carried by the launch / new intent — widget
    // chips and `burnbar://pi` deep links both surface it here. Read once
    // per intent identity so manual pill changes survive recompositions.
    val activityIntent = (context as? MainActivity)?.intent
    LaunchedEffect(activityIntent) {
        val hint = activityIntent?.let { intent ->
            intent.getStringExtra(MainActivity.EXTRA_ASSISTANT)?.lowercase()
                ?: intent.data?.getQueryParameter("runtime")?.lowercase()
                ?: intent.data?.host?.lowercase()?.takeIf {
                    it == MainActivity.ASSISTANT_HERMES || it == MainActivity.ASSISTANT_PI
                }
        }
        val resolved = AssistantRuntimeID.values().firstOrNull { it.token == hint }
        if (resolved != null && resolved.token != rawRuntime) {
            rawRuntime = resolved.token
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        AssistantRuntimePill(
            selection = runtime,
            onSelect = { selected -> rawRuntime = selected.token },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
        )

        when (runtime) {
            AssistantRuntimeID.HERMES -> HermesView()
            AssistantRuntimeID.PI     -> PiAssistantView(piService = piService)
        }
    }
}

@Composable
fun AssistantRuntimePill(
    selection: AssistantRuntimeID,
    onSelect: (AssistantRuntimeID) -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(percent = 50),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        modifier = modifier
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            AssistantRuntimeID.values().forEach { runtime ->
                val isActive = selection == runtime
                val activeBrush = when (runtime) {
                    AssistantRuntimeID.HERMES -> Brush.linearGradient(AuroraGradients.mercuryGradient)
                    AssistantRuntimeID.PI     -> Brush.linearGradient(AuroraGradients.piGradient)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(36.dp)
                        .clip(RoundedCornerShape(percent = 50))
                        .background(if (isActive) activeBrush else Brush.linearGradient(listOf(Color.Transparent, Color.Transparent)))
                        .clickable { onSelect(runtime) },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "${runtime.glyph}  ${runtime.displayName}",
                        color = if (isActive) Color.Black else MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }
    }
}
