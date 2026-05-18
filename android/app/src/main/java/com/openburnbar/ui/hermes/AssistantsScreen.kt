package com.openburnbar.ui.hermes

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.AgentImportJobSnapshot
import com.openburnbar.MainActivity
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.PiService
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import kotlinx.coroutines.launch

// Android Assistants surface. Hosts up to five runtimes (Hermes / Pi /
// Codex / Claude / OpenClaw) behind a single tab. The pill renders only the
// runtimes the user has enabled in `ChatTilePreferences` (Settings → Chat
// tiles). Hermes + Pi have first-class Android chat surfaces. Codex, Claude,
// and OpenClaw use the same remote-composer and Mac-backed import contract as
// iOS so the flow is usable before native Android runtimes ship.

@Composable
fun AssistantsScreen(
    initialRuntime: AssistantRuntimeID? = null
) {
    val context = LocalContext.current
    val tilePrefs = remember { loadChatTilePreferences(context).sanitized() }
    val visibleTiles = tilePrefs.orderedVisibleTiles().ifEmpty { listOf(AssistantRuntimeID.HERMES) }

    val seedToken = initialRuntime?.takeIf { visibleTiles.contains(it) }?.token
        ?: visibleTiles.first().token
    var rawRuntime by rememberSaveable { mutableStateOf(seedToken) }
    val parsed = AssistantRuntimeID.fromToken(rawRuntime)
    val runtime = if (visibleTiles.contains(parsed)) parsed else visibleTiles.first()

    // When the route arrives with a different `initialRuntime` (e.g. user
    // taps a Pi pinned agent after the screen already saved Hermes), honor
    // the new request. Read once per identity so manual pill changes
    // survive recompositions.
    LaunchedEffect(initialRuntime) {
        val target = initialRuntime?.takeIf { visibleTiles.contains(it) }
        if (target != null && target.token != rawRuntime) {
            rawRuntime = target.token
        }
    }
    val historyStore = remember { AssistantChatHistoryStore.shared(context.applicationContext) }
    LaunchedEffect(historyStore) { historyStore.bootstrap() }
    val piService = remember { PiService().apply { bindHistoryStore(historyStore) } }
    val hermesService = remember(context) {
        HermesService(appContext = context.applicationContext)
    }

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
            AssistantRuntimeID.HERMES -> HermesView(hermesService = hermesService)
            AssistantRuntimeID.PI -> PiAssistantView(piService = piService)
            AssistantRuntimeID.CODEX,
            AssistantRuntimeID.CLAUDE,
            AssistantRuntimeID.OPEN_CLAW -> CliAgentChatView(
                runtime = runtime,
                historyStore = historyStore,
            )
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
                // Logo-only pill — names were getting truncated at this
                // width ("He rm", "Co de"), which looked worse than no
                // name at all. The provider logo is the recognizable
                // affordance; accessibility label carries the full name
                // for TalkBack.
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .weight(1f)
                        .height(36.dp)
                        .clip(RoundedCornerShape(percent = 50))
                        .background(if (isActive) activeBrush else Brush.linearGradient(listOf(Color.Transparent, Color.Transparent)))
                        .clickable { onSelect(runtime) }
                        .semantics {
                            contentDescription = runtime.displayName
                            if (isActive) selected = true
                        },
                ) {
                    com.openburnbar.ui.components.ProviderLogo(
                        runtime = runtime,
                        size = 22.dp,
                        circular = true,
                    )
                }
            }
        }
    }
}

@Composable
private fun AssistantTileBridgeView(runtime: AssistantRuntimeID) {
    val dispatcher = remember { CLIAgentMissionDispatcher() }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var message by rememberSaveable { mutableStateOf("") }
    var queued by rememberSaveable { mutableStateOf<String?>(null) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    var importStatus by rememberSaveable { mutableStateOf<String?>(null) }
    var importJobID by rememberSaveable { mutableStateOf<String?>(null) }
    var showImportSheet by rememberSaveable { mutableStateOf(false) }
    var sending by rememberSaveable { mutableStateOf(false) }
    var importing by rememberSaveable { mutableStateOf(false) }
    var clientThreadID by rememberSaveable { mutableStateOf("android-${java.util.UUID.randomUUID()}") }
    var importSnapshot by remember { mutableStateOf<AgentImportJobSnapshot?>(null) }

    LaunchedEffect(importJobID) {
        val id = importJobID ?: return@LaunchedEffect
        dispatcher.observeImportJob(id).collect { snapshot ->
            importSnapshot = snapshot
            importStatus = snapshot.progressMessage.ifBlank { "Import ${snapshot.status}" }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
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
        OutlinedTextField(
            value = message,
            onValueChange = { message = it },
            label = { Text("Message ${runtime.displayName}") },
            minLines = 3,
            maxLines = 6,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 20.dp)
        )
        Button(
            enabled = message.isNotBlank() && !sending,
            onClick = {
                val body = message
                sending = true
                error = null
                scope.launch {
                    try {
                        val requestID = dispatcher.dispatch(
                            title = "New ${runtime.displayName} chat",
                            prompt = body,
                            missionKind = "chat",
                            requestedRuntime = runtime.token,
                            approvalMode = "existing_policy",
                            commandsAllowed = false,
                            fileEditsAllowed = false,
                            clientThreadID = clientThreadID,
                            resumeAction = "new",
                        )
                        queued = requestID.take(8)
                        message = ""
                        clientThreadID = "android-${java.util.UUID.randomUUID()}"
                    } catch (t: Throwable) {
                        error = t.message ?: t::class.java.simpleName
                    } finally {
                        sending = false
                    }
                }
            },
            modifier = Modifier.padding(top = 12.dp)
        ) {
            Text(if (sending) "Queueing..." else "Start chat")
        }
        Button(
            enabled = !importing,
            onClick = { showImportSheet = true },
            modifier = Modifier.padding(top = 8.dp)
        ) {
            Text(if (importing) "Queueing import..." else "Import Mac history")
        }
        queued?.let {
            Text(
                text = "Queued on your Mac account #$it",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 10.dp)
            )
        }
        importStatus?.let {
            Text(
                text = it,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 8.dp)
            )
        }
        error?.let {
            Text(
                text = it,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 10.dp)
            )
        }
    }

    if (showImportSheet) {
        AgentImportSheet(
            importing = importing,
            snapshot = importSnapshot,
            onDismiss = { showImportSheet = false },
            onStart = { harnesses ->
                importing = true
                error = null
                importStatus = null
                importSnapshot = null
                scope.launch {
                    try {
                        val jobID = dispatcher.createImportJob(selectedHarnesses = harnesses)
                        importJobID = jobID
                        importStatus = "Import queued on your Mac account #${jobID.take(8)}"
                    } catch (t: Throwable) {
                        error = t.message ?: t::class.java.simpleName
                    } finally {
                        importing = false
                    }
                }
            },
        )
    }
}

@Composable
private fun AgentImportSheet(
    importing: Boolean,
    snapshot: AgentImportJobSnapshot?,
    onDismiss: () -> Unit,
    onStart: (List<String>) -> Unit,
) {
    val harnesses = remember {
        listOf(
            "codex" to "Codex",
            "claude" to "Claude Code",
            "openclaw" to "OpenClaw",
            "hermes" to "Hermes",
            "opencode" to "OpenCode",
            "factory" to "Factory",
            "cursor" to "Cursor",
            "aider" to "Aider",
            "cline" to "Cline",
            "kilo" to "Kilo Code",
            "roo" to "Roo Code",
            "forge" to "Forge",
            "gemini" to "Gemini CLI",
            "goose" to "Goose",
            "windsurf" to "Windsurf",
            "warp" to "Warp",
            "kimi" to "Kimi",
            "ollama" to "Ollama",
        )
    }
    var selected by rememberSaveable {
        mutableStateOf(setOf("codex", "claude", "openclaw", "hermes", "opencode"))
    }
    val scrollState = rememberScrollState()
    val progressText = snapshot?.progressMessage?.takeIf { it.isNotBlank() }
        ?: "Waiting for a trusted Mac."

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                enabled = selected.isNotEmpty() && !importing,
                onClick = { onStart(selected.toList()) },
            ) {
                Text(if (importing) "Starting..." else "Start import")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
        title = { Text("Import Mac history") },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .verticalScroll(scrollState),
            ) {
                Text(
                    text = progressText,
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (snapshot != null && !snapshot.isTerminal) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
                }
                snapshot?.let {
                    Text(
                        text = "Scanned ${it.scannedCount} · Imported ${it.importedCount} · Mirrored ${it.mirroredSessionCount}",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                    it.errorMessage?.let { message ->
                        Text(
                            text = message,
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                }
                Spacer(modifier = Modifier.height(12.dp))
                harnesses.forEach { (id, label) ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                selected = if (selected.contains(id)) selected - id else selected + id
                            }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = selected.contains(id),
                            onCheckedChange = { checked ->
                                selected = if (checked) selected + id else selected - id
                            },
                        )
                        Text(text = label, fontSize = 14.sp)
                    }
                }
            }
        },
    )
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
