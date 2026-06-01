@file:Suppress("MagicNumber", "MatchingDeclarationName")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.MainActivity
import com.openburnbar.data.assistants.AgentImportJobSnapshot
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentRelayChatTransport
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.PiService
import com.openburnbar.ui.theme.AuroraGradients
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal data class AssistantsScreenState(
    val visibleTiles: List<AssistantRuntimeID>,
    val runtime: AssistantRuntimeID,
    val rawRuntime: String,
    val setRawRuntime: (String) -> Unit,
)

@Composable
internal fun rememberAssistantsScreenState(context: Context, initialRuntime: AssistantRuntimeID?): AssistantsScreenState {
    val tilePrefs = remember { loadChatTilePreferences(context).sanitized() }
    val visibleTiles = tilePrefs.orderedVisibleTiles().ifEmpty { listOf(AssistantRuntimeID.HERMES) }
    val seedToken = initialRuntime?.takeIf { visibleTiles.contains(it) }?.token ?: visibleTiles.first().token
    var rawRuntime by rememberSaveable { mutableStateOf(seedToken) }
    val parsed = AssistantRuntimeID.fromToken(rawRuntime)
    val runtime = if (visibleTiles.contains(parsed)) parsed else visibleTiles.first()
    return AssistantsScreenState(
        visibleTiles = visibleTiles,
        runtime = runtime,
        rawRuntime = rawRuntime,
        setRawRuntime = { rawRuntime = it },
    )
}

@Composable
internal fun AssistantsScreenInitialRuntimeEffect(
    initialRuntime: AssistantRuntimeID?,
    visibleTiles: List<AssistantRuntimeID>,
    rawRuntime: String,
    onRuntimeResolved: (String) -> Unit,
) {
    LaunchedEffect(initialRuntime) {
        val target = initialRuntime?.takeIf { visibleTiles.contains(it) }
        if (target != null && target.token != rawRuntime) {
            onRuntimeResolved(target.token)
        }
    }
}

@Composable
internal fun AssistantsScreenIntentEffect(
    context: Context,
    visibleTiles: List<AssistantRuntimeID>,
    rawRuntime: String,
    onRuntimeResolved: (String) -> Unit,
) {
    val activityIntent = (context as? MainActivity)?.intent
    LaunchedEffect(activityIntent) {
        val hint =
            activityIntent?.let { intent ->
                intent.getStringExtra(MainActivity.EXTRA_ASSISTANT)?.lowercase()
                    ?: intent.data?.getQueryParameter("runtime")?.lowercase()
                    ?: intent.data?.host?.lowercase()?.takeIf { it == MainActivity.ASSISTANT_HERMES || it == MainActivity.ASSISTANT_PI }
            }
        val resolved = AssistantRuntimeID.values().firstOrNull { it.token == hint }
        if (resolved != null && visibleTiles.contains(resolved) && resolved.token != rawRuntime) {
            onRuntimeResolved(resolved.token)
        }
    }
}

@Composable
internal fun AssistantsScreenContent(
    screenState: AssistantsScreenState,
    hermesService: HermesService,
    piService: PiService,
    historyStore: AssistantChatHistoryStore,
    cliRelayChatTransport: CLIAgentRelayChatTransport,
    initialThreadId: String?,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        AssistantRuntimePill(
            visible = screenState.visibleTiles,
            selection = screenState.runtime,
            onSelect = { selected -> screenState.setRawRuntime(selected.token) },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        AssistantsRuntimeContent(
            runtime = screenState.runtime,
            hermesService = hermesService,
            piService = piService,
            historyStore = historyStore,
            cliRelayChatTransport = cliRelayChatTransport,
            initialThreadId = initialThreadId,
        )
    }
}

@Composable
private fun AssistantsRuntimeContent(
    runtime: AssistantRuntimeID,
    hermesService: HermesService,
    piService: PiService,
    historyStore: AssistantChatHistoryStore,
    cliRelayChatTransport: CLIAgentRelayChatTransport,
    initialThreadId: String?,
) {
    when (runtime) {
        AssistantRuntimeID.HERMES ->
            HermesView(hermesService = hermesService, initialThreadId = initialThreadId)
        AssistantRuntimeID.PI -> PiAssistantView(piService = piService)
        AssistantRuntimeID.CODEX,
        AssistantRuntimeID.CLAUDE,
        AssistantRuntimeID.OPEN_CLAW,
        AssistantRuntimeID.DROID,
        AssistantRuntimeID.FORGE,
        AssistantRuntimeID.ANTIGRAVITY,
        AssistantRuntimeID.GROK,
        AssistantRuntimeID.CURSOR_AGENT,
        ->
            CliAgentChatView(
                runtime = runtime,
                historyStore = historyStore,
                relayChatTransport = cliRelayChatTransport,
            )
    }
}

@Composable
fun AssistantRuntimePill(
    visible: List<AssistantRuntimeID>,
    selection: AssistantRuntimeID,
    onSelect: (AssistantRuntimeID) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        shape = RoundedCornerShape(percent = 50),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        modifier = modifier,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            visible.forEach { runtime ->
                AssistantRuntimePillItem(
                    runtime = runtime,
                    isActive = selection == runtime,
                    onSelect = onSelect,
                )
            }
        }
    }
}

@Composable
private fun RowScope.AssistantRuntimePillItem(runtime: AssistantRuntimeID, isActive: Boolean, onSelect: (AssistantRuntimeID) -> Unit) {
    val activeBrush = gradientForRuntime(runtime)
    Box(
        contentAlignment = Alignment.Center,
        modifier =
        Modifier
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

private fun gradientForRuntime(runtime: AssistantRuntimeID): Brush = when (runtime) {
    AssistantRuntimeID.HERMES -> Brush.linearGradient(AuroraGradients.mercuryGradient)
    AssistantRuntimeID.PI -> Brush.linearGradient(AuroraGradients.piGradient)
    AssistantRuntimeID.CODEX -> Brush.linearGradient(listOf(Color(0xFF1ABC9C), Color(0xFF2ECC71)))
    AssistantRuntimeID.CLAUDE -> Brush.linearGradient(listOf(Color(0xFFD58A4F), Color(0xFFC76A2C)))
    AssistantRuntimeID.OPEN_CLAW -> Brush.linearGradient(listOf(Color(0xFF6E56CF), Color(0xFF4F44C6)))
    AssistantRuntimeID.DROID -> Brush.linearGradient(listOf(Color(0xFF8B5CF6), Color(0xFF6D5DF6)))
    AssistantRuntimeID.FORGE -> Brush.linearGradient(listOf(Color(0xFFF97316), Color(0xFFEA580C)))
    AssistantRuntimeID.ANTIGRAVITY -> Brush.linearGradient(listOf(Color(0xFF6C63FF), Color(0xFF8F8AFF)))
    AssistantRuntimeID.GROK -> Brush.linearGradient(listOf(Color(0xFF111827), Color(0xFF0EA5E9)))
    AssistantRuntimeID.CURSOR_AGENT -> Brush.linearGradient(listOf(Color(0xFF0F172A), Color(0xFF64748B)))
}
private data class AssistantTileBridgeContentState(
    val message: String,
    val sending: Boolean,
    val importing: Boolean,
    val queued: String?,
    val importStatus: String?,
    val error: String?,
)

private data class AssistantTileBridgeSendRequest(
    val runtime: AssistantRuntimeID,
    val body: String,
    val clientThreadID: String,
)

private data class AssistantTileBridgeSendCallbacks(
    val onSending: (Boolean) -> Unit,
    val onError: (String?) -> Unit,
    val onQueued: (String) -> Unit,
)

private data class AssistantTileBridgeMutableFields(
    val message: MutableState<String>,
    val queued: MutableState<String?>,
    val error: MutableState<String?>,
    val importStatus: MutableState<String?>,
    val importJobID: MutableState<String?>,
    val showImportSheet: MutableState<Boolean>,
    val sending: MutableState<Boolean>,
    val importing: MutableState<Boolean>,
    val clientThreadID: MutableState<String>,
    val importSnapshot: MutableState<AgentImportJobSnapshot?>,
)

private class AssistantTileBridgeLocalState(
    private val fields: AssistantTileBridgeMutableFields,
) {
    var message by fields.message
    var queued by fields.queued
    var error by fields.error
    var importStatus by fields.importStatus
    var importJobID by fields.importJobID
    var showImportSheet by fields.showImportSheet
    var sending by fields.sending
    var importing by fields.importing
    var clientThreadID by fields.clientThreadID
    var importSnapshot by fields.importSnapshot

    fun contentState(): AssistantTileBridgeContentState =
        AssistantTileBridgeContentState(
            message = message,
            sending = sending,
            importing = importing,
            queued = queued,
            importStatus = importStatus,
            error = error,
        )

    fun applyImportSnapshot(snapshot: AgentImportJobSnapshot) {
        importSnapshot = snapshot
        importStatus = snapshot.progressMessage.ifBlank { "Import ${snapshot.status}" }
    }

    fun queueSend(scope: CoroutineScope, dispatcher: CLIAgentMissionDispatcher, runtime: AssistantRuntimeID) {
        assistantTileBridgeQueueSend(
            scope = scope,
            dispatcher = dispatcher,
            request = AssistantTileBridgeSendRequest(runtime = runtime, body = message, clientThreadID = clientThreadID),
            callbacks =
            AssistantTileBridgeSendCallbacks(
                onSending = { sending = it },
                onError = { error = it },
                onQueued = { requestID ->
                    queued = requestID.take(8)
                    message = ""
                    clientThreadID = "android-${java.util.UUID.randomUUID()}"
                },
            ),
        )
    }

    fun queueImport(scope: CoroutineScope, dispatcher: CLIAgentMissionDispatcher, harnesses: List<String>) {
        assistantTileBridgeQueueImport(
            scope = scope,
            dispatcher = dispatcher,
            harnesses = harnesses,
            onImporting = { importing = it },
            onError = { error = it },
            onImportStarted = { jobID ->
                importJobID = jobID
                importSnapshot = null
                importStatus = "Import queued on your Mac account #${jobID.take(8)}"
            },
        )
    }
}

@Composable
private fun rememberAssistantTileBridgeLocalState(): AssistantTileBridgeLocalState {
    val message = rememberSaveable { mutableStateOf("") }
    val queued = rememberSaveable { mutableStateOf<String?>(null) }
    val error = rememberSaveable { mutableStateOf<String?>(null) }
    val importStatus = rememberSaveable { mutableStateOf<String?>(null) }
    val importJobID = rememberSaveable { mutableStateOf<String?>(null) }
    val showImportSheet = rememberSaveable { mutableStateOf(false) }
    val sending = rememberSaveable { mutableStateOf(false) }
    val importing = rememberSaveable { mutableStateOf(false) }
    val clientThreadID = rememberSaveable { mutableStateOf("android-${java.util.UUID.randomUUID()}") }
    val importSnapshot = remember { mutableStateOf<AgentImportJobSnapshot?>(null) }
    return remember {
        AssistantTileBridgeLocalState(
            fields =
            AssistantTileBridgeMutableFields(
                message = message,
                queued = queued,
                error = error,
                importStatus = importStatus,
                importJobID = importJobID,
                showImportSheet = showImportSheet,
                sending = sending,
                importing = importing,
                clientThreadID = clientThreadID,
                importSnapshot = importSnapshot,
            ),
        )
    }
}

@Composable
internal fun AssistantTileBridgeView(runtime: AssistantRuntimeID) {
    val dispatcher = remember { CLIAgentMissionDispatcher() }
    val scope = rememberCoroutineScope()
    val bridgeState = rememberAssistantTileBridgeLocalState()

    AssistantTileBridgeImportObserver(
        importJobID = bridgeState.importJobID,
        dispatcher = dispatcher,
        onSnapshot = bridgeState::applyImportSnapshot,
    )
    AssistantTileBridgeContent(
        runtime = runtime,
        state = bridgeState.contentState(),
        onMessageChange = { bridgeState.message = it },
        onSend = { bridgeState.queueSend(scope, dispatcher, runtime) },
        onOpenImport = { bridgeState.showImportSheet = true },
    )
    AssistantTileBridgeImportGate(
        visible = bridgeState.showImportSheet,
        importing = bridgeState.importing,
        snapshot = bridgeState.importSnapshot,
        onDismiss = { bridgeState.showImportSheet = false },
        onStart = { bridgeState.queueImport(scope, dispatcher, it) },
    )
}

@Composable
private fun AssistantTileBridgeImportGate(
    visible: Boolean,
    importing: Boolean,
    snapshot: AgentImportJobSnapshot?,
    onDismiss: () -> Unit,
    onStart: (List<String>) -> Unit,
) {
    if (!visible) return
    AgentImportSheet(
        importing = importing,
        snapshot = snapshot,
        onDismiss = onDismiss,
        onStart = onStart,
    )
}

@Composable
private fun AssistantTileBridgeImportObserver(
    importJobID: String?,
    dispatcher: CLIAgentMissionDispatcher,
    onSnapshot: (AgentImportJobSnapshot) -> Unit,
) {
    LaunchedEffect(importJobID) {
        val id = importJobID ?: return@LaunchedEffect
        dispatcher.observeImportJob(id).collect(onSnapshot)
    }
}

private fun assistantTileBridgeQueueSend(
    scope: CoroutineScope,
    dispatcher: CLIAgentMissionDispatcher,
    request: AssistantTileBridgeSendRequest,
    callbacks: AssistantTileBridgeSendCallbacks,
) {
    callbacks.onSending(true)
    callbacks.onError(null)
    scope.launch {
        try {
            val requestID =
                dispatcher.dispatch(
                    title = "New ${request.runtime.displayName} chat",
                    prompt = request.body,
                    missionKind = "chat",
                    requestedRuntime = request.runtime.token,
                    approvalMode = "existing_policy",
                    commandsAllowed = false,
                    fileEditsAllowed = false,
                    clientThreadID = request.clientThreadID,
                    resumeAction = "new",
                )
            callbacks.onQueued(requestID)
        } catch (t: IOException) {
            callbacks.onError(t.message ?: t::class.java.simpleName)
        } finally {
            callbacks.onSending(false)
        }
    }
}

private fun assistantTileBridgeQueueImport(
    scope: CoroutineScope,
    dispatcher: CLIAgentMissionDispatcher,
    harnesses: List<String>,
    onImporting: (Boolean) -> Unit,
    onError: (String?) -> Unit,
    onImportStarted: (String) -> Unit,
) {
    onImporting(true)
    onError(null)
    scope.launch {
        try {
            val jobID = dispatcher.createImportJob(selectedHarnesses = harnesses)
            onImportStarted(jobID)
        } catch (t: IOException) {
            onError(t.message ?: t::class.java.simpleName)
        } finally {
            onImporting(false)
        }
    }
}

@Composable
private fun AssistantTileBridgeContent(
    runtime: AssistantRuntimeID,
    state: AssistantTileBridgeContentState,
    onMessageChange: (String) -> Unit,
    onSend: () -> Unit,
    onOpenImport: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        AssistantTileBridgeHero(runtime = runtime)
        OutlinedTextField(
            value = state.message,
            onValueChange = onMessageChange,
            label = { Text("Message ${runtime.displayName}") },
            minLines = 3,
            maxLines = 6,
            modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
        )
        Button(
            enabled = state.message.isNotBlank() && !state.sending,
            onClick = onSend,
            modifier = Modifier.padding(top = 12.dp),
        ) {
            Text(if (state.sending) "Queueing..." else "Start chat")
        }
        Button(
            enabled = !state.importing,
            onClick = onOpenImport,
            modifier = Modifier.padding(top = 8.dp),
        ) {
            Text(if (state.importing) "Queueing import..." else "Import Mac history")
        }
        state.queued?.let {
            Text(
                text = "Queued on your Mac account #$it",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 10.dp),
            )
        }
        state.importStatus?.let {
            Text(
                text = it,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        state.error?.let {
            Text(
                text = it,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 10.dp),
            )
        }
    }
}

@Composable
private fun AssistantTileBridgeHero(runtime: AssistantRuntimeID) {
    Box(
        modifier =
        Modifier
            .size(88.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = runtime.glyph,
            fontSize = 36.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
    Text(
        text = runtime.displayName,
        fontSize = 18.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(top = 18.dp),
    )
    Text(
        text = bridgeCopy(runtime),
        fontSize = 13.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 8.dp),
    )
}

@Composable
internal fun AgentImportSheet(importing: Boolean, snapshot: AgentImportJobSnapshot?, onDismiss: () -> Unit, onStart: (List<String>) -> Unit) {
    val harnesses = agentImportHarnesses()
    var selected by rememberSaveable {
        mutableStateOf(setOf("codex", "claude", "openclaw", "hermes", "opencode"))
    }
    val scrollState = rememberScrollState()
    val progressText = snapshot?.progressMessage?.takeIf { it.isNotBlank() } ?: "Waiting for a trusted Mac."

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
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        title = { Text("Import Mac history") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(scrollState),
            ) {
                AgentImportSheetProgress(snapshot = snapshot, progressText = progressText)
                Spacer(modifier = Modifier.height(12.dp))
                harnesses.forEach { (id, label) ->
                    AgentImportHarnessRow(
                        id = id,
                        label = label,
                        selected = selected.contains(id),
                        onToggle = { checked ->
                            selected = if (checked) selected + id else selected - id
                        },
                    )
                }
            }
        },
    )
}

@Composable
private fun AgentImportSheetProgress(snapshot: AgentImportJobSnapshot?, progressText: String) {
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
}

@Composable
private fun AgentImportHarnessRow(id: String, label: String, selected: Boolean, onToggle: (Boolean) -> Unit) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable { onToggle(!selected) }
            .padding(vertical = 4.dp)
            .semantics { contentDescription = id },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = selected, onCheckedChange = onToggle)
        Text(text = label, fontSize = 14.sp)
    }
}

private fun agentImportHarnesses(): List<Pair<String, String>> =
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

private fun bridgeCopy(runtime: AssistantRuntimeID): String = when (runtime) {
    AssistantRuntimeID.CODEX -> "Codex chat runs through OpenBurnBar on your Mac. Pair your Mac to start a session here."
    AssistantRuntimeID.CLAUDE -> "Claude Code chat runs through OpenBurnBar on your Mac. Pair your Mac to start a session here."
    AssistantRuntimeID.OPEN_CLAW -> "OpenClaw uses your Mac's local agent runtime. Pair your Mac to chat from here."
    AssistantRuntimeID.DROID -> "Droid runs through OpenBurnBar on your Mac. Pair your Mac to chat from here."
    AssistantRuntimeID.FORGE -> "Forge runs through OpenBurnBar on your Mac. Pair your Mac to chat from here."
    AssistantRuntimeID.ANTIGRAVITY -> "Antigravity runs through OpenBurnBar on your Mac. Pair your Mac to chat from here."
    AssistantRuntimeID.GROK -> "Grok runs through OpenBurnBar on your Mac. Pair your Mac to chat from here."
    AssistantRuntimeID.CURSOR_AGENT -> "Cursor Agent runs through OpenBurnBar on your Mac. Pair your Mac to chat from here."
    else -> ""
}
