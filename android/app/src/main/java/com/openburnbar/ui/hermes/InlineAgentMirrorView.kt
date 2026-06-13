package com.openburnbar.ui.hermes

import android.content.Context
import android.util.Log
import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.computeruse.AndroidAppCheckAttestationReader
import com.openburnbar.data.computeruse.ControlSealSessionEstablisher
import com.openburnbar.data.computeruse.InMemoryPhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentTerminalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.ui.components.liquidGlassSurface
import com.openburnbar.ui.media.SurfaceCallback
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val INLINE_MIRROR_DEFAULT_ASPECT_WIDTH = 16f
private const val INLINE_MIRROR_DEFAULT_ASPECT_HEIGHT = 9f
private const val INLINE_MIRROR_STATUS_DOT_SIZE_DP = 6
private val INLINE_MIRROR_LIVE_STATUS_COLOR = Color(0xFF4CAF50)

enum class InlineMirrorPhase {
    IDLE,
    CONNECTING,
    ASKING_MIRROR,
    WAITING_FOR_APPROVAL,
    WAITING_FOR_FRAMES,
    LIVE,
    ERROR
}

@Composable
fun InlineAgentMirrorView(
    runtime: String = "hermes",
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    val coordinator = remember { BurnBarApplication.mediaControlCoordinator }

    var phase by remember { mutableStateOf(InlineMirrorPhase.CONNECTING) }
    var statusMessage by remember { mutableStateOf("Connecting to Mac...") }
    var requestID by remember { mutableStateOf<String?>(null) }
    var mirrorSessionID by remember { mutableStateOf<String?>(null) }
    var phoneControlSender by remember { mutableStateOf<PhoneControlSender?>(null) }

    val pipeline = remember {
        VideoReceivePipeline(
            onLongTermReferenceTokenDecoded = { token ->
                requestID?.let { reqId ->
                    coordinator?.sendLongTermReferenceAcknowledgement(token = token, requestID = reqId)
                }
            },
        )
    }

    val stats by pipeline.stats.collectAsState()
    val aspectRatio = inlineMirrorAspectRatio(stats)

    var retryTrigger by remember { mutableStateOf(0) }
    val stateCallbacks = InlineMirrorStateCallbacks({ phase = it }, { statusMessage = it }, { requestID = it }, { mirrorSessionID = it }, { phoneControlSender = it })

    InlineMirrorConnectionLifecycle(
        coordinator = coordinator,
        runtime = runtime,
        retryTrigger = retryTrigger,
        coroutineScope = coroutineScope,
        pipeline = pipeline,
        callbacks = stateCallbacks,
    )
    InlineMirrorAckCollector(
        context = context,
        coordinator = coordinator,
        requestID = requestID,
        callbacks = stateCallbacks,
    )
    InlineMirrorPipelinePhaseEffect(pipeline = pipeline, callbacks = stateCallbacks)
    InlineMirrorDisposeEffect(
        coordinator = coordinator,
        pipeline = pipeline,
        coroutineScope = coroutineScope,
        requestID = requestID,
        mirrorSessionID = mirrorSessionID,
    )

    val uiState = InlineMirrorUiState(phase, statusMessage, aspectRatio, phoneControlSender != null)
    val handlers = InlineMirrorHandlers(
        onSendKey = { key, modifiers -> sendInlineMirrorKey(coroutineScope, phoneControlSender, key, modifiers) },
        onRetry = { retryTrigger++ },
    )
    InlineMirrorContent(uiState, pipeline, coroutineScope, handlers, modifier)
}

private fun inlineMirrorAspectRatio(stats: VideoReceivePipeline.Stats): Float =
    if (stats.widthPx > 0 && stats.heightPx > 0) {
        stats.widthPx.toFloat() / stats.heightPx.toFloat()
    } else {
        INLINE_MIRROR_DEFAULT_ASPECT_WIDTH / INLINE_MIRROR_DEFAULT_ASPECT_HEIGHT
    }

private data class InlineMirrorStateCallbacks(
    val onPhaseChange: (InlineMirrorPhase) -> Unit,
    val onStatusMessageChange: (String) -> Unit,
    val onRequestIDChange: (String?) -> Unit,
    val onMirrorSessionIDChange: (String?) -> Unit,
    val onPhoneControlSenderChange: (PhoneControlSender?) -> Unit,
)

private data class InlineMirrorUiState(
    val phase: InlineMirrorPhase,
    val statusMessage: String,
    val aspectRatio: Float,
    val phoneControlEnabled: Boolean,
)

private data class InlineMirrorHandlers(
    val onSendKey: (String, List<String>) -> Unit,
    val onRetry: () -> Unit,
)

private fun sendInlineMirrorKey(
    coroutineScope: CoroutineScope,
    phoneControlSender: PhoneControlSender?,
    key: String,
    modifiers: List<String> = emptyList(),
) {
    val sender = phoneControlSender ?: return
    coroutineScope.launch(Dispatchers.IO) {
        runCatching {
            sender.send(
                PhoneControlIntent(
                    kind = PhoneControlIntentKind.SHORTCUT,
                    key = key,
                    modifiers = modifiers,
                ),
            )
        }.onFailure { e ->
            Log.e("InlineMirror", "Failed to send shortcut key=$key error=${e.message}")
        }
    }
}

@Composable
private fun InlineMirrorConnectionLifecycle(
    coordinator: MediaControlStreamCoordinator?,
    runtime: String,
    retryTrigger: Int,
    coroutineScope: CoroutineScope,
    pipeline: VideoReceivePipeline,
    callbacks: InlineMirrorStateCallbacks,
) {
    LaunchedEffect(coordinator, retryTrigger) {
        if (coordinator == null) {
            callbacks.onPhaseChange(InlineMirrorPhase.ERROR)
            callbacks.onStatusMessageChange("No relay connection. Make sure your phone is paired.")
            return@LaunchedEffect
        }
        callbacks.onPhaseChange(InlineMirrorPhase.CONNECTING)
        callbacks.onStatusMessageChange("Connecting to Mac...")
        coroutineScope.launch {
            runCatching {
                requestInlineMirror(coordinator, runtime, pipeline, callbacks)
            }.onFailure { e ->
                Log.e("InlineMirror", "Failed to start mirror request: ${e.message}", e)
                callbacks.onPhaseChange(InlineMirrorPhase.ERROR)
                callbacks.onStatusMessageChange(e.message ?: "Connection error")
            }
        }
    }
}

private suspend fun requestInlineMirror(
    coordinator: MediaControlStreamCoordinator,
    runtime: String,
    pipeline: VideoReceivePipeline,
    callbacks: InlineMirrorStateCallbacks,
) {
    val responsive = withContext(Dispatchers.IO) {
        coordinator.ensureResponsive(
            freshnessIntervalMillis = 5000,
            probeTimeoutMillis = 10000,
        )
    }
    if (!responsive) {
        callbacks.onPhaseChange(InlineMirrorPhase.ERROR)
        callbacks.onStatusMessageChange("Mac is unresponsive. Make sure BurnBar is running on your Mac.")
        return
    }
    coordinator.mirrorFrameHandler = { frame -> pipeline.ingest(frame) }
    coordinator.mirrorFrameV2Handler = { frameV2 -> pipeline.ingest(frameV2) }
    callbacks.onPhaseChange(InlineMirrorPhase.ASKING_MIRROR)
    callbacks.onStatusMessageChange("Asking Mac to share terminal...")
    val reqId = withContext(Dispatchers.IO) {
        val displayName = FirebaseAuth.getInstance().currentUser?.displayName
            ?.takeIf { it.isNotBlank() } ?: "Android"
        coordinator.requestMirror(
            requesterDisplayName = displayName,
            agentTerminal = HermesRealtimeRelayAgentTerminalRequest(
                runtimeId = runtime,
                interactive = true,
            ),
        )
    }
    callbacks.onRequestIDChange(reqId)
    callbacks.onPhaseChange(InlineMirrorPhase.WAITING_FOR_APPROVAL)
    callbacks.onStatusMessageChange("Accept the request on your Mac...")
}

@Composable
private fun InlineMirrorAckCollector(
    context: Context,
    coordinator: MediaControlStreamCoordinator?,
    requestID: String?,
    callbacks: InlineMirrorStateCallbacks,
) {
    LaunchedEffect(coordinator, requestID) {
        if (coordinator == null || requestID == null) return@LaunchedEffect
        coordinator.lastMirrorAck.collectLatest { ack ->
            if (ack == null || ack.requestId != requestID) return@collectLatest
            val presentation = inlineMirrorAckPresentation(ack.decision, ack.detail)
            callbacks.onPhaseChange(presentation.phase)
            callbacks.onStatusMessageChange(presentation.statusMessage)
            if (ack.decision == HermesRealtimeRelayMirrorAck.Decision.ACCEPTED) {
                callbacks.onMirrorSessionIDChange(ack.sessionId)
                runCatching {
                    val sender = inlineMirrorPhoneControlSender(context, coordinator)
                    callbacks.onPhoneControlSenderChange(sender)
                    // RR-7b: publish the live sender so the Agent Watch surface can sign + transmit approvals.
                    com.openburnbar.BurnBarApplication.activePhoneControlSender = sender
                }.onFailure { e ->
                    Log.e("InlineMirror", "Failed to setup phone control sender: ${e.message}", e)
                }
            }
        }
    }
}

private fun inlineMirrorPhoneControlSender(
    context: Context,
    coordinator: MediaControlStreamCoordinator,
): PhoneControlSender? {
    val activePair = coordinator.activePair.value ?: return null
    val keyStore = PhoneControlSigningKeyStore(context)
    val identity = keyStore.signingIdentity()
    val peerNodeId = keyStore.peerNodeId(identity)
    val baseSink: suspend (HermesRealtimeRelayFrame) -> Unit = { frame -> coordinator.send(frame) }
    val sealSession = ControlSealSessionEstablisher.activeSession(activePair.connectionID)
    return PhoneControlSender(
        uid = activePair.uid,
        connectionId = activePair.connectionID,
        peerNodeId = peerNodeId,
        signingIdentityProvider = { identity },
        counterStore = InMemoryPhoneControlCounterStore(),
        attestationDigestProvider = {
            AndroidAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        },
        // RR-7c: fail-closed attestation gate under the strict ramp (mirror iOS).
        attestationEnforcer = { AndroidAppCheckAttestationReader.ensureAttestationDigestOrThrow() },
        frameSink = sealSession
            ?.let { ControlSealSessionEstablisher.sealingFrameSink(baseSink, it) }
            ?: baseSink,
    )
}

@Composable
private fun InlineMirrorPipelinePhaseEffect(
    pipeline: VideoReceivePipeline,
    callbacks: InlineMirrorStateCallbacks,
) {
    LaunchedEffect(pipeline) {
        pipeline.phase.collectLatest { p ->
            if (p is VideoReceivePipeline.Phase.Running) {
                callbacks.onPhaseChange(InlineMirrorPhase.LIVE)
                callbacks.onStatusMessageChange("Live")
            } else if (p is VideoReceivePipeline.Phase.Failed) {
                callbacks.onPhaseChange(InlineMirrorPhase.ERROR)
                callbacks.onStatusMessageChange(p.reason)
            }
        }
    }
}

@Composable
private fun InlineMirrorDisposeEffect(
    coordinator: MediaControlStreamCoordinator?,
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
    requestID: String?,
    mirrorSessionID: String?,
) {
    DisposableEffect(Unit) {
        onDispose {
            coroutineScope.launch {
                pipeline.stop()
                if (coordinator != null) {
                    coordinator.mirrorFrameHandler = null
                    coordinator.mirrorFrameV2Handler = null
                    if (requestID != null) {
                        runCatching {
                            withContext(Dispatchers.IO) {
                                coordinator.stopMirror(
                                    requestID = requestID,
                                    sessionID = mirrorSessionID,
                                    reason = "inline_closed",
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun InlineMirrorContent(
    uiState: InlineMirrorUiState,
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
    handlers: InlineMirrorHandlers,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black)
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (uiState.phase == InlineMirrorPhase.LIVE) {
            InlineMirrorLiveContent(
                uiState = uiState,
                pipeline = pipeline,
                coroutineScope = coroutineScope,
                onSendKey = handlers.onSendKey,
            )
        } else {
            InlineMirrorPlaceholder(
                phase = uiState.phase,
                statusMessage = uiState.statusMessage,
                onRetry = handlers.onRetry,
            )
        }
    }
}

@Composable
private fun InlineMirrorLiveContent(
    uiState: InlineMirrorUiState,
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
    onSendKey: (String, List<String>) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        InlineMirrorSurface(
            aspectRatio = uiState.aspectRatio,
            pipeline = pipeline,
            coroutineScope = coroutineScope,
        )
        if (uiState.phoneControlEnabled) {
            InlineMirrorControlsRow(onSendKey = onSendKey)
        }
        InlineMirrorPanicBanner()
    }
}

@Composable
private fun InlineMirrorSurface(
    aspectRatio: Float,
    pipeline: VideoReceivePipeline,
    coroutineScope: CoroutineScope,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(aspectRatio),
    ) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                }
            },
        )
        InlineMirrorLiveStatusChip(modifier = Modifier.align(Alignment.TopEnd))
    }
}

@Composable
private fun InlineMirrorLiveStatusChip(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .padding(8.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(Color.Black.copy(alpha = 0.6f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(INLINE_MIRROR_STATUS_DOT_SIZE_DP.dp)
                .clip(CircleShape)
                .background(INLINE_MIRROR_LIVE_STATUS_COLOR),
        )
        Spacer(modifier = Modifier.width(INLINE_MIRROR_STATUS_DOT_SIZE_DP.dp))
        Text(
            text = "LIVE",
            color = Color.White,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun InlineMirrorControlsRow(onSendKey: (String, List<String>) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .liquidGlassSurface(
                shape = RoundedCornerShape(12.dp),
                wash = Color.Black.copy(alpha = 0.35f),
                isDark = true,
            )
            .padding(vertical = 8.dp, horizontal = 6.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TerminalButton(label = "esc", onClick = { onSendKey("escape", emptyList()) })
        TerminalButton(label = "tab", onClick = { onSendKey("tab", emptyList()) })
        TerminalButton(label = "⌃C", onClick = { onSendKey("c", listOf("control")) })
        TerminalButton(label = "←", onClick = { onSendKey("left", emptyList()) })
        TerminalButton(label = "↑", onClick = { onSendKey("up", emptyList()) })
        TerminalButton(label = "↓", onClick = { onSendKey("down", emptyList()) })
        TerminalButton(label = "→", onClick = { onSendKey("right", emptyList()) })
        TerminalButton(label = "⏎", onClick = { onSendKey("return", emptyList()) })
    }
}

@Composable
private fun InlineMirrorPanicBanner() {
    Text(
        text = "Hold ⌃⌥⌘. on Mac to abort session",
        color = Color.White.copy(alpha = 0.5f),
        fontSize = 10.sp,
        modifier = Modifier.padding(bottom = 6.dp, top = 2.dp),
    )
}

@Composable
private fun InlineMirrorPlaceholder(
    phase: InlineMirrorPhase,
    statusMessage: String,
    onRetry: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Terminal,
            contentDescription = "Terminal View",
            tint = AuroraColors.ember,
            modifier = Modifier.size(48.dp),
        )
        Spacer(modifier = Modifier.height(16.dp))
        if (phase == InlineMirrorPhase.ERROR) {
            InlineMirrorErrorStatus(statusMessage = statusMessage, onRetry = onRetry)
        } else {
            InlineMirrorLoadingStatus(statusMessage = statusMessage)
        }
    }
}

@Composable
private fun InlineMirrorErrorStatus(statusMessage: String, onRetry: () -> Unit) {
    Text(
        text = statusMessage,
        color = MaterialTheme.colorScheme.error,
        fontSize = 14.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
    Spacer(modifier = Modifier.height(16.dp))
    Button(
        onClick = onRetry,
        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
    ) {
        Icon(Icons.Filled.Refresh, contentDescription = "Retry")
        Spacer(modifier = Modifier.width(8.dp))
        Text("Retry Connection")
    }
}

@Composable
private fun InlineMirrorLoadingStatus(statusMessage: String) {
    CircularProgressIndicator(
        color = AuroraColors.ember,
        modifier = Modifier.size(24.dp),
    )
    Spacer(modifier = Modifier.height(12.dp))
    Text(
        text = statusMessage,
        color = Color.White.copy(alpha = 0.7f),
        fontSize = 14.sp,
        fontWeight = FontWeight.Normal,
    )
}

@Composable
private fun TerminalButton(
    label: String,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .border(0.5.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(4.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = label,
            color = Color.White,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium
        )
    }
}

/** Phase + status line for one mirror-request ack. Pure so it is unit-testable. */
internal data class InlineMirrorAckPresentation(
    val phase: InlineMirrorPhase,
    val statusMessage: String,
)

/**
 * Maps the Mac's mirror-request decision onto the inline mirror phase and the
 * status line under the canvas. Any non-accepted decision is terminal for the
 * attempt; the Mac's own `detail` copy wins when present.
 */
internal fun inlineMirrorAckPresentation(
    decision: HermesRealtimeRelayMirrorAck.Decision,
    detail: String?,
): InlineMirrorAckPresentation = when (decision) {
    HermesRealtimeRelayMirrorAck.Decision.ACCEPTED ->
        InlineMirrorAckPresentation(InlineMirrorPhase.WAITING_FOR_FRAMES, "Mac accepted request. Starting stream...")
    HermesRealtimeRelayMirrorAck.Decision.DENIED ->
        InlineMirrorAckPresentation(InlineMirrorPhase.ERROR, detail ?: "Request denied by Mac.")
    HermesRealtimeRelayMirrorAck.Decision.BUSY ->
        InlineMirrorAckPresentation(InlineMirrorPhase.ERROR, detail ?: "Mac is busy.")
    HermesRealtimeRelayMirrorAck.Decision.COOLING_DOWN ->
        InlineMirrorAckPresentation(InlineMirrorPhase.ERROR, detail ?: "Mac is cooling down.")
    HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED ->
        InlineMirrorAckPresentation(InlineMirrorPhase.ERROR, detail ?: "Mac cannot mirror right now.")
}
