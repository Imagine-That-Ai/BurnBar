package com.openburnbar.ui.hermes

import android.util.Log
import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.*
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
import com.openburnbar.data.computeruse.InMemoryPhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentTerminalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.ui.media.SurfaceCallback
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
                    coordinator?.sendLongTermReferenceAcknowledgement(
                        token = token,
                        requestID = reqId
                    )
                }
            }
        )
    }

    val stats by pipeline.stats.collectAsState()
    val aspectRatio = if (stats.widthPx > 0 && stats.heightPx > 0) {
        stats.widthPx.toFloat() / stats.heightPx.toFloat()
    } else {
        16f / 9f
    }

    // Helper function to send control inputs
    fun sendKey(key: String, modifiers: List<String> = emptyList()) {
        val sender = phoneControlSender ?: return
        coroutineScope.launch(Dispatchers.IO) {
            runCatching {
                sender.send(
                    PhoneControlIntent(
                        kind = PhoneControlIntentKind.SHORTCUT,
                        key = key,
                        modifiers = modifiers
                    )
                )
            }.onFailure { e ->
                Log.e("InlineMirror", "Failed to send shortcut key=$key error=${e.message}")
            }
        }
    }

    // Trigger retry
    var retryTrigger by remember { mutableStateOf(0) }

    // Mirror connection lifecycle
    LaunchedEffect(coordinator, retryTrigger) {
        if (coordinator == null) {
            phase = InlineMirrorPhase.ERROR
            statusMessage = "No relay connection. Make sure your phone is paired."
            return@LaunchedEffect
        }

        phase = InlineMirrorPhase.CONNECTING
        statusMessage = "Connecting to Mac..."

        coroutineScope.launch {
            try {
                // 1. Ensure stream is responsive
                val responsive = withContext(Dispatchers.IO) {
                    coordinator.ensureResponsive(
                        freshnessIntervalMillis = 5000,
                        probeTimeoutMillis = 10000
                    )
                }

                if (!responsive) {
                    phase = InlineMirrorPhase.ERROR
                    statusMessage = "Mac is unresponsive. Make sure BurnBar is running on your Mac."
                    return@launch
                }

                // 2. Set up mirror frame handlers
                coordinator.mirrorFrameHandler = { frame ->
                    pipeline.ingest(frame)
                }
                coordinator.mirrorFrameV2Handler = { frameV2 ->
                    pipeline.ingest(frameV2)
                }

                phase = InlineMirrorPhase.ASKING_MIRROR
                statusMessage = "Asking Mac to share terminal..."

                // 3. Send mirror request with runtime agent terminal info
                val reqId = withContext(Dispatchers.IO) {
                    val displayName = FirebaseAuth.getInstance().currentUser?.displayName
                        ?.takeIf { it.isNotBlank() } ?: "Android"
                    
                    val agentTerminal = HermesRealtimeRelayAgentTerminalRequest(
                        runtimeId = runtime,
                        interactive = true
                    )
                    
                    coordinator.requestMirror(
                        requesterDisplayName = displayName,
                        agentTerminal = agentTerminal
                    )
                }

                requestID = reqId
                phase = InlineMirrorPhase.WAITING_FOR_APPROVAL
                statusMessage = "Accept the request on your Mac..."

            } catch (e: Exception) {
                Log.e("InlineMirror", "Failed to start mirror request: ${e.message}", e)
                phase = InlineMirrorPhase.ERROR
                statusMessage = e.message ?: "Connection error"
            }
        }
    }

    // Collect ACK and setup input sender
    LaunchedEffect(coordinator, requestID) {
        if (coordinator == null || requestID == null) return@LaunchedEffect
        coordinator.lastMirrorAck.collectLatest { ack ->
            if (ack != null && ack.requestId == requestID) {
                val presentation = inlineMirrorAckPresentation(ack.decision, ack.detail)
                phase = presentation.phase
                statusMessage = presentation.statusMessage
                if (ack.decision == HermesRealtimeRelayMirrorAck.Decision.ACCEPTED) {
                    mirrorSessionID = ack.sessionId

                    // Setup PhoneControlSender for interactive keyboard commands
                    try {
                        val activePair = coordinator.activePair.value
                        if (activePair != null) {
                            val keyStore = PhoneControlSigningKeyStore(context)
                            val identity = keyStore.signingIdentity()
                            val peerNodeId = keyStore.peerNodeId(identity)
                            phoneControlSender = PhoneControlSender(
                                uid = activePair.uid,
                                connectionId = activePair.connectionID,
                                peerNodeId = peerNodeId,
                                signingIdentityProvider = { identity },
                                counterStore = InMemoryPhoneControlCounterStore(),
                                frameSink = { frame -> coordinator.send(frame) }
                            )
                        }
                    } catch (e: Exception) {
                        Log.e("InlineMirror", "Failed to setup phone control sender: ${e.message}", e)
                    }
                }
            }
        }
    }

    // Listen to pipeline running phase
    LaunchedEffect(pipeline) {
        pipeline.phase.collectLatest { p ->
            if (p is VideoReceivePipeline.Phase.Running) {
                phase = InlineMirrorPhase.LIVE
                statusMessage = "Live"
            } else if (p is VideoReceivePipeline.Phase.Failed) {
                phase = InlineMirrorPhase.ERROR
                statusMessage = p.reason
            }
        }
    }

    // Clean up on dispose
    DisposableEffect(Unit) {
        onDispose {
            coroutineScope.launch {
                pipeline.stop()
                val currentReqID = requestID
                val currentSessionID = mirrorSessionID
                if (coordinator != null) {
                    coordinator.mirrorFrameHandler = null
                    coordinator.mirrorFrameV2Handler = null
                    if (currentReqID != null) {
                        runCatching {
                            withContext(Dispatchers.IO) {
                                coordinator.stopMirror(
                                    requestID = currentReqID,
                                    sessionID = currentSessionID,
                                    reason = "inline_closed"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black)
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp)),
        contentAlignment = Alignment.Center
    ) {
        if (phase == InlineMirrorPhase.LIVE) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Live Stream Surface
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(aspectRatio)
                ) {
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { ctx ->
                            SurfaceView(ctx).apply {
                                holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                            }
                        }
                    )

                    // Overlay live status chip
                    Row(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(8.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color.Black.copy(alpha = 0.6f))
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(Color(0xFF4CAF50))
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = "LIVE",
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }

                // Control buttons row at the bottom if controller is active
                if (phoneControlSender != null) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(Color(0xFF1E1E1E))
                            .padding(vertical = 8.dp, horizontal = 6.dp),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TerminalButton(label = "esc", onClick = { sendKey("escape") })
                        TerminalButton(label = "tab", onClick = { sendKey("tab") })
                        TerminalButton(label = "⌃C", onClick = { sendKey("c", listOf("control")) })
                        TerminalButton(label = "←", onClick = { sendKey("left") })
                        TerminalButton(label = "↑", onClick = { sendKey("up") })
                        TerminalButton(label = "↓", onClick = { sendKey("down") })
                        TerminalButton(label = "→", onClick = { sendKey("right") })
                        TerminalButton(label = "⏎", onClick = { sendKey("return") })
                    }
                }

                // Security panic banner
                Text(
                    text = "Hold ⌃⌥⌘. on Mac to abort session",
                    color = Color.White.copy(alpha = 0.5f),
                    fontSize = 10.sp,
                    modifier = Modifier.padding(bottom = 6.dp, top = 2.dp)
                )
            }
        } else {
            // Placeholder Connection / Status View
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.Terminal,
                    contentDescription = "Terminal View",
                    tint = AuroraColors.ember,
                    modifier = Modifier.size(48.dp)
                )
                Spacer(modifier = Modifier.height(16.dp))
                if (phase == InlineMirrorPhase.ERROR) {
                    Text(
                        text = statusMessage,
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Button(
                        onClick = { retryTrigger++ },
                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember)
                    ) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Retry")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Retry Connection")
                    }
                } else {
                    CircularProgressIndicator(
                        color = AuroraColors.ember,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = statusMessage,
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Normal
                    )
                }
            }
        }
    }
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
