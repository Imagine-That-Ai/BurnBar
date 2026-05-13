package com.openburnbar.ui.hermes

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
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
import com.openburnbar.MainActivity
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.PiService
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

// Android Assistants surface. Hosts up to five runtimes (Hermes / Pi /
// Codex / Claude / OpenClaw) behind a single tab. The pill renders only the
// runtimes the user has enabled in `ChatTilePreferences` (Settings → Chat
// tiles). Hermes + Pi have first-class Android chat surfaces; the rest
// surface a `AssistantTileBridgeView` placeholder pointing the user at the
// macOS host until a native Android runtime ships.

@Composable
fun AssistantsScreen() {
    val context = LocalContext.current
    val tilePrefs = remember { loadChatTilePreferences(context).sanitized() }
    val visibleTiles = tilePrefs.orderedVisibleTiles().ifEmpty { listOf(AssistantRuntimeID.HERMES) }

    var rawRuntime by rememberSaveable { mutableStateOf(visibleTiles.first().token) }
    val parsed = AssistantRuntimeID.fromToken(rawRuntime)
    val runtime = if (visibleTiles.contains(parsed)) parsed else visibleTiles.first()
    val piService = remember { PiService() }

    // Honor the runtime hint carried by the launch / new intent — widget
    // chips and `burnbar://pi` deep links both surface it here. Read once
    // per intent identity so manual pill changes survive recompositions.
    val activityIntent = (context as? MainActivity)?.intent
    LaunchedEffect(activityIntent) {
        val hint = activityIntent?.let { intent ->
            intent.getStringExtra(MainActivity.EXTRA_ASSISTANT)?.lowercase()
                ?: intent.data?.getQueryParameter("runtime")?.lowercase()
                ?: intent.data?.host?.lowercase()?.takeIf { it == MainActivity.ASSISTANT_HERMES || it == MainActivity.ASSISTANT_PI }
        }
        val resolved = AssistantRuntimeID.values().firstOrNull { it.token == hint }
        if (resolved != null && visibleTiles.contains(resolved) && resolved.token != rawRuntime) {
            rawRuntime = resolved.token
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        AssistantRuntimePill(
            visible = visibleTiles,
            selection = runtime,
            onSelect = { selected -> rawRuntime = selected.token },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
        )

        when (runtime) {
            AssistantRuntimeID.HERMES -> HermesView()
            AssistantRuntimeID.PI -> PiAssistantView(piService = piService)
            AssistantRuntimeID.CODEX,
            AssistantRuntimeID.CLAUDE,
            AssistantRuntimeID.OPEN_CLAW -> AssistantTileBridgeView(runtime = runtime)
        }
    }
}

@Composable
fun AssistantRuntimePill(
    visible: List<AssistantRuntimeID>,
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
            visible.forEach { runtime ->
                val isActive = selection == runtime
                val activeBrush = gradientForRuntime(runtime)
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
                        color = if (isActive) foregroundForRuntime(runtime) else MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }
    }
}

@Composable
private fun AssistantTileBridgeView(runtime: AssistantRuntimeID) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(88.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = runtime.glyph,
                fontSize = 36.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
        Text(
            text = runtime.displayName,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(top = 18.dp)
        )
        Text(
            text = bridgeCopy(runtime),
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp)
        )
    }
}

private fun bridgeCopy(runtime: AssistantRuntimeID): String = when (runtime) {
    AssistantRuntimeID.CODEX -> "Codex chat runs through OpenBurnBar on your Mac. Pair your Mac to start a session here."
    AssistantRuntimeID.CLAUDE -> "Claude Code chat runs through OpenBurnBar on your Mac. Pair your Mac to start a session here."
    AssistantRuntimeID.OPEN_CLAW -> "OpenClaw uses your Mac's local agent runtime. Pair your Mac to chat from here."
    else -> ""
}

private fun gradientForRuntime(runtime: AssistantRuntimeID): Brush = when (runtime) {
    AssistantRuntimeID.HERMES -> Brush.linearGradient(AuroraGradients.mercuryGradient)
    AssistantRuntimeID.PI -> Brush.linearGradient(AuroraGradients.piGradient)
    AssistantRuntimeID.CODEX -> Brush.linearGradient(listOf(Color(0xFF1ABC9C), Color(0xFF2ECC71)))
    AssistantRuntimeID.CLAUDE -> Brush.linearGradient(listOf(Color(0xFFD58A4F), Color(0xFFC76A2C)))
    AssistantRuntimeID.OPEN_CLAW -> Brush.linearGradient(listOf(Color(0xFF6E56CF), Color(0xFF4F44C6)))
}

private fun foregroundForRuntime(runtime: AssistantRuntimeID): Color = when (runtime) {
    AssistantRuntimeID.HERMES -> Color(0xFF151210)
    else -> Color.White
}

private fun loadChatTilePreferences(context: Context): ChatTilePreferences {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    val raw = prefs.getString(ChatTilePreferences.USER_DEFAULTS_KEY, null)
    return ChatTilePreferences.fromJsonString(raw)
}
