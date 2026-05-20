package com.openburnbar.ui.media

import android.net.Uri
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ScreenShare
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

@Composable
fun PairedMacControlsScreen(
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val coordinator = BurnBarApplication.mediaControlCoordinator
    val fallbackPhase = remember { MutableStateFlow<MediaControlStreamCoordinator.Phase>(MediaControlStreamCoordinator.Phase.Idle) }
    val fallbackAck = remember { MutableStateFlow<HermesRealtimeRelayMirrorAck?>(null) }
    val fallbackPair = remember { MutableStateFlow<MediaControlStreamCoordinator.ActivePair?>(null) }
    val phase by (coordinator?.phase ?: fallbackPhase).collectAsState()
    val ack by (coordinator?.lastMirrorAck ?: fallbackAck).collectAsState()
    val fallbackCallAck = remember { MutableStateFlow<HermesRealtimeRelayCallAck?>(null) }
    val callAck by (coordinator?.lastCallAck ?: fallbackCallAck).collectAsState()
    val activePair by (coordinator?.activePair ?: fallbackPair).collectAsState()
    var pendingRequestID by remember { mutableStateOf<String?>(null) }
    var pendingCallRequestID by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var sendingFile by remember { mutableStateOf(false) }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        val picked = uri ?: return@rememberLauncherForActivityResult
        val transferService = BurnBarApplication.fileTransferService
        val pair = activePair
        if (transferService == null || pair == null) {
            statusMessage = "Mercury file transfer is not ready yet. Open BurnBar on the Mac and wait for Mercury to go live."
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            sendingFile = true
            runCatching {
                transferService.sendFile(
                    uri = picked,
                    uid = pair.uid,
                    connectionID = pair.connectionID,
                    peerDeviceID = pair.connectionID,
                )
            }.onSuccess { manifest ->
                statusMessage = "Sent ${manifest.filename} to your Mac."
            }.onFailure { error ->
                statusMessage = "File send failed: ${error.localizedMessage ?: error.javaClass.simpleName}"
            }
            sendingFile = false
        }
    }

    LaunchedEffect(pendingRequestID, ack) {
        val requestID = pendingRequestID ?: return@LaunchedEffect
        val currentAck = ack ?: return@LaunchedEffect
        if (currentAck.requestId == requestID) {
            pendingRequestID = null
            statusMessage = currentAck.userMessage()
        }
    }

    LaunchedEffect(pendingRequestID) {
        val requestID = pendingRequestID ?: return@LaunchedEffect
        delay(15_000)
        if (pendingRequestID == requestID) {
            pendingRequestID = null
            statusMessage = "No response from the Mac. Open BurnBar on the Mac, enable Local Network, then try again."
        }
    }

    LaunchedEffect(pendingCallRequestID, callAck) {
        val requestID = pendingCallRequestID ?: return@LaunchedEffect
        val currentAck = callAck ?: return@LaunchedEffect
        if (currentAck.requestId == requestID) {
            pendingCallRequestID = null
            statusMessage = currentAck.userMessage()
        }
    }

    LaunchedEffect(pendingCallRequestID) {
        val requestID = pendingCallRequestID ?: return@LaunchedEffect
        delay(15_000)
        if (pendingCallRequestID == requestID) {
            pendingCallRequestID = null
            statusMessage = "No call response from the Mac. Open BurnBar on the Mac, enable Local Network, then try again."
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(
                        AuroraColors.hermesMercury.copy(alpha = 0.22f),
                        MaterialTheme.colorScheme.background,
                    )
                )
            )
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.Computer,
            contentDescription = null,
            tint = AuroraColors.hermesMercury,
        )
        Text(
            text = "My Mac",
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text = phase.userMessage(),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 14.sp,
        )

        statusMessage?.let { message ->
            Surface(
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.82f),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = message,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(14.dp),
                    fontSize = 13.sp,
                )
            }
        }

        Spacer(Modifier.height(6.dp))

        Button(
            enabled = pendingRequestID == null,
            onClick = {
                val currentCoordinator = coordinator
                val currentPhase = phase
                if (currentCoordinator == null) {
                    statusMessage = "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online."
                    Log.i("BurnBar", "Ask to Mirror blocked: media coordinator is null")
                    return@Button
                }
                if (currentPhase !is MediaControlStreamCoordinator.Phase.Live) {
                    statusMessage = currentPhase.userMessage()
                    Log.i("BurnBar", "Ask to Mirror blocked: phase=${currentPhase.javaClass.simpleName}")
                    return@Button
                }
                val name = FirebaseAuth.getInstance().currentUser?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?: "Android"
                scope.launch {
                    runCatching { currentCoordinator.requestMirror(name) }
                        .onSuccess { requestID ->
                            pendingRequestID = requestID
                            statusMessage = "Request sent. Check your Mac."
                        }
                        .onFailure { error ->
                            pendingRequestID = null
                            statusMessage = "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}"
                        }
                }
            },
            colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesMercury),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.AutoMirrored.Filled.ScreenShare, contentDescription = null)
            Text(if (pendingRequestID == null) "Ask to Mirror" else "Waiting for Mac...")
        }

        OutlinedButton(
            onClick = {
                statusMessage = when {
                    coordinator == null -> "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online."
                    phase !is MediaControlStreamCoordinator.Phase.Live -> phase.userMessage()
                    else -> "Mercury is live. Ask to Mirror is ready."
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Refresh, contentDescription = null)
            Text("Check Mercury")
        }

        OutlinedButton(
            enabled = coordinator != null && phase is MediaControlStreamCoordinator.Phase.Live && !sendingFile,
            onClick = { filePicker.launch(arrayOf("*/*")) },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.AttachFile, contentDescription = null)
            Text(if (sendingFile) "Sending..." else "Send File")
        }

        OutlinedButton(
            enabled = pendingCallRequestID == null,
            onClick = {
                val currentCoordinator = coordinator
                val currentPhase = phase
                if (currentCoordinator == null) {
                    statusMessage = "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online."
                    Log.i("BurnBar", "Call Mac blocked: media coordinator is null")
                    return@OutlinedButton
                }
                if (currentPhase !is MediaControlStreamCoordinator.Phase.Live) {
                    statusMessage = currentPhase.userMessage()
                    Log.i("BurnBar", "Call Mac blocked: phase=${currentPhase.javaClass.simpleName}")
                    return@OutlinedButton
                }
                val name = FirebaseAuth.getInstance().currentUser?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?: "Android"
                scope.launch {
                    runCatching { currentCoordinator.requestCall(name) }
                        .onSuccess { requestID ->
                            pendingCallRequestID = requestID
                            statusMessage = "Call invite sent. Check your Mac."
                        }
                        .onFailure { error ->
                            pendingCallRequestID = null
                            statusMessage = "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}"
                        }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Phone, contentDescription = null)
            Text(if (pendingCallRequestID == null) "Call Mac" else "Calling Mac...")
        }
    }
}

private fun MediaControlStreamCoordinator.Phase.userMessage(): String = when (this) {
    MediaControlStreamCoordinator.Phase.Idle -> "Mercury is idle. Waiting for a paired Mac."
    MediaControlStreamCoordinator.Phase.Dialing -> "Mercury is connecting to your Mac..."
    MediaControlStreamCoordinator.Phase.Live -> "Mercury is live. You can ask the Mac to mirror."
    is MediaControlStreamCoordinator.Phase.Reconnecting -> "Mercury is reconnecting to your Mac..."
    MediaControlStreamCoordinator.Phase.Stopped -> "Mercury is stopped. Open BurnBar on the Mac."
    is MediaControlStreamCoordinator.Phase.Failed -> "Mercury unavailable: $reason"
}

private fun HermesRealtimeRelayMirrorAck.userMessage(): String = when (decision) {
    HermesRealtimeRelayMirrorAck.Decision.ACCEPTED -> detail ?: "Mac accepted. Waiting for screen frames."
    HermesRealtimeRelayMirrorAck.Decision.DENIED -> detail ?: "Mac declined the request."
    HermesRealtimeRelayMirrorAck.Decision.COOLING_DOWN -> detail ?: "Mac is cooling down."
    HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED -> detail ?: "Mac cannot mirror right now."
    HermesRealtimeRelayMirrorAck.Decision.BUSY -> detail ?: "Mac is busy."
}

private fun HermesRealtimeRelayCallAck.userMessage(): String = when (decision) {
    HermesRealtimeRelayCallAck.Decision.ACCEPTED -> detail ?: "Mac accepted the call invite."
    HermesRealtimeRelayCallAck.Decision.DENIED -> detail ?: "Mac declined the call."
    HermesRealtimeRelayCallAck.Decision.UNSUPPORTED -> detail ?: "Mac cannot receive calls right now."
    HermesRealtimeRelayCallAck.Decision.BUSY -> detail ?: "Mac is busy."
}
