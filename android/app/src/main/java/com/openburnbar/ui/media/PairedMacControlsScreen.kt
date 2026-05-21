package com.openburnbar.ui.media

import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ScreenShare
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.settings.GlobalVisualSettings
import com.openburnbar.ui.settings.rememberPremiumSOTAUX
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.settings.rememberWebsiteBackground
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairedMacControlsScreen(
    connectionID: String? = null,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val app = context.applicationContext as? BurnBarApplication
    var coordinator by remember { mutableStateOf(BurnBarApplication.mediaControlCoordinator) }
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
    var launchedMirrorRequestID by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var sendingFile by remember { mutableStateOf(false) }
    var recoveringMercury by remember { mutableStateOf(false) }
    var isSettingsOpen by remember { mutableStateOf(false) }

    // Premium settings toggles
    val usePremiumSOTAUXState = rememberPremiumSOTAUX()
    val usePremiumSOTAUX = usePremiumSOTAUXState.value
    val useWebsiteBackgroundState = rememberWebsiteBackground()
    val useWebsiteBackground = useWebsiteBackgroundState.value

    val haptic = LocalHapticFeedback.current
    fun requestedConnectionID(): String? =
        connectionID
            ?.trim()
            ?.takeIf { it.isNotBlank() && !it.startsWith("paired-mac:") }
            ?: activePair?.connectionID

    LaunchedEffect(connectionID) {
        val id = connectionID?.trim()?.takeIf { it.isNotBlank() } ?: return@LaunchedEffect
        if (id.startsWith("paired-mac:")) return@LaunchedEffect
        val application = app ?: return@LaunchedEffect
        statusMessage = "Starting Mercury..."
        runCatching {
            application.ensureMediaControlStream(connectionID = id)
        }.onSuccess {
            coordinator = BurnBarApplication.mediaControlCoordinator
            statusMessage = null
        }.onFailure { error ->
            coordinator = BurnBarApplication.mediaControlCoordinator
            statusMessage = "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}"
        }
    }

    // Interaction sources and spring scaling states for buttons
    val mirrorInteractionSource = remember { MutableInteractionSource() }
    val mirrorPressed by mirrorInteractionSource.collectIsPressedAsState()
    val mirrorScale by animateFloatAsState(
        targetValue = if (mirrorPressed) (if (usePremiumSOTAUX) 0.94f else 0.97f) else 1.0f,
        animationSpec = spring(
            dampingRatio = if (usePremiumSOTAUX) 0.55f else Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "mirror_scale"
    )

    val checkInteractionSource = remember { MutableInteractionSource() }
    val checkPressed by checkInteractionSource.collectIsPressedAsState()
    val checkScale by animateFloatAsState(
        targetValue = if (checkPressed) (if (usePremiumSOTAUX) 0.94f else 0.97f) else 1.0f,
        animationSpec = spring(
            dampingRatio = if (usePremiumSOTAUX) 0.55f else Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "check_scale"
    )

    val fileInteractionSource = remember { MutableInteractionSource() }
    val filePressed by fileInteractionSource.collectIsPressedAsState()
    val fileScale by animateFloatAsState(
        targetValue = if (filePressed) (if (usePremiumSOTAUX) 0.94f else 0.97f) else 1.0f,
        animationSpec = spring(
            dampingRatio = if (usePremiumSOTAUX) 0.55f else Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "file_scale"
    )

    val callInteractionSource = remember { MutableInteractionSource() }
    val callPressed by callInteractionSource.collectIsPressedAsState()
    val callScale by animateFloatAsState(
        targetValue = if (callPressed) (if (usePremiumSOTAUX) 0.94f else 0.97f) else 1.0f,
        animationSpec = spring(
            dampingRatio = if (usePremiumSOTAUX) 0.55f else Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "call_scale"
    )

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
            if (
                currentAck.decision == HermesRealtimeRelayMirrorAck.Decision.ACCEPTED &&
                launchedMirrorRequestID != requestID
            ) {
                launchedMirrorRequestID = requestID
                context.startActivity(
                    Intent(context, ScreenShareViewerActivity::class.java)
                        .putExtra(ScreenShareViewerActivity.EXTRA_MIRROR_REQUEST_ID, requestID)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
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

    Box(modifier = Modifier.fillMaxSize()) {
        if (useWebsiteBackground) {
            WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        } else {
            Spacer(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            listOf(
                                AuroraColors.hermesMercury.copy(alpha = 0.22f),
                                MaterialTheme.colorScheme.background,
                            )
                        )
                    )
            )
        }

        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Elegant Header Row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.Computer,
                        contentDescription = null,
                        tint = AuroraColors.hermesMercury,
                        modifier = Modifier.size(30.dp)
                    )
                    Column {
                        Text(
                            text = "My Mac",
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                        )
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            val dotColor = when (phase) {
                                MediaControlStreamCoordinator.Phase.Live -> AuroraColors.successDark
                                MediaControlStreamCoordinator.Phase.Dialing,
                                is MediaControlStreamCoordinator.Phase.Reconnecting -> AuroraColors.amber
                                is MediaControlStreamCoordinator.Phase.Failed -> AuroraColors.errorDark
                                else -> Color(0xFF4B5563)
                            }
                            Box(
                                modifier = Modifier
                                    .size(6.dp)
                                    .background(dotColor, shape = RoundedCornerShape(999.dp))
                            )
                            Text(
                                text = when (phase) {
                                    MediaControlStreamCoordinator.Phase.Live -> "Live"
                                    MediaControlStreamCoordinator.Phase.Dialing,
                                    is MediaControlStreamCoordinator.Phase.Reconnecting -> "Connecting"
                                    is MediaControlStreamCoordinator.Phase.Failed -> "Error"
                                    else -> "Offline"
                                },
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    }
                }

                // Settings Gear Icon (Glassmorphic)
                IconButton(
                    onClick = {
                        isSettingsOpen = true
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    },
                    modifier = Modifier
                        .size(40.dp)
                        .auroraGlass(cornerRadius = 20.dp, tintAlpha = 0.25f, shadow = AuroraShadows.subtle)
                ) {
                    Icon(
                        imageVector = Icons.Filled.Settings,
                        contentDescription = "Mercury Customization",
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

            // High-fidelity glassmorphic iMac/MacBook mockup preview card
            MacScreenPreviewCard(
                phase = phase,
                recoveringMercury = recoveringMercury,
                pendingRequestID = pendingRequestID,
                modifier = Modifier.fillMaxWidth()
            )

            // Status message notifications beautifully styled as a glass system banner
            statusMessage?.let { message ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .auroraGlass(cornerRadius = 14.dp, tintAlpha = 0.3f, shadow = AuroraShadows.subtle)
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Refresh,
                            contentDescription = null,
                            tint = AuroraColors.amber,
                            modifier = Modifier.size(16.dp)
                        )
                        Text(
                            text = message,
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
            }

            Spacer(Modifier.weight(1f))

            // Floating macOS-style Glass Dock
            val fileEnabled = coordinator != null && phase is MediaControlStreamCoordinator.Phase.Live && !sendingFile
            
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.25f, shadow = AuroraShadows.medium)
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Mirror Pill Button (Primary Action)
                    val mirrorEnabled = pendingRequestID == null && !recoveringMercury
                    Button(
                        enabled = mirrorEnabled,
                        onClick = {
                            if (usePremiumSOTAUX) {
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            }
                            val name = FirebaseAuth.getInstance().currentUser?.displayName
                                ?.takeIf { it.isNotBlank() }
                                ?: "Android"
                            scope.launch {
                                recoveringMercury = true
                                runCatching {
                                    val activeCoordinator = coordinator
                                    val targetCoordinator =
                                        if (activeCoordinator != null && phase is MediaControlStreamCoordinator.Phase.Live) {
                                            activeCoordinator
                                        } else {
                                            val connection = requestedConnectionID()
                                                ?: throw IllegalStateException("Open this Mac from Hermes Square so Android can target the paired Mac relay.")
                                            val application = app
                                                ?: throw IllegalStateException("BurnBar is not ready to start Mercury yet.")
                                            statusMessage = "Starting Mercury..."
                                            Log.i("BurnBar", "Ask to Mirror recovering Mercury for connectionID=$connection")
                                            application.ensureMediaControlStream(connectionID = connection)
                                            BurnBarApplication.mediaControlCoordinator
                                                ?: throw IllegalStateException("Mercury did not create a control coordinator.")
                                        }
                                    coordinator = targetCoordinator
                                    withTimeout(20_000L) {
                                        targetCoordinator.requestMirror(name)
                                    }
                                }
                                    .onSuccess { requestID ->
                                        pendingRequestID = requestID
                                        statusMessage = "Request sent. Check your Mac."
                                    }
                                    .onFailure { error ->
                                        pendingRequestID = null
                                        statusMessage = when (error) {
                                            is kotlinx.coroutines.TimeoutCancellationException ->
                                                "Mercury did not connect within 20 seconds. Open BurnBar on the Mac, then try again."
                                            else ->
                                                "Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}"
                                        }
                                        Log.w("BurnBar", "Ask to Mirror failed: ${error.message}")
                                    }
                                recoveringMercury = false
                            }
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = AuroraColors.emberDark,
                            disabledContainerColor = AuroraColors.emberDark.copy(alpha = 0.35f)
                        ),
                        shape = RoundedCornerShape(16.dp),
                        modifier = Modifier
                            .weight(1.4f)
                            .height(48.dp)
                            .graphicsLayer {
                                scaleX = mirrorScale
                                scaleY = mirrorScale
                            }
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ScreenShare,
                            contentDescription = null,
                            tint = Color.White
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = when {
                                recoveringMercury -> "Connecting..."
                                pendingRequestID != null -> "Waiting..."
                                else -> "Mirror"
                            },
                            style = AuroraType.body.copy(
                                fontWeight = FontWeight.Bold,
                                color = Color.White,
                                fontSize = 13.sp
                            )
                        )
                    }

                    Spacer(Modifier.width(8.dp))

                    // Check Mercury (Circular Button)
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .graphicsLayer {
                                scaleX = checkScale
                                scaleY = checkScale
                            }
                            .clickable(
                                interactionSource = checkInteractionSource,
                                indication = null
                            ) {
                                if (usePremiumSOTAUX) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                                statusMessage = when {
                                    coordinator == null -> "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online."
                                    phase !is MediaControlStreamCoordinator.Phase.Live -> phase.userMessage()
                                    else -> "Mercury is live. Ask to Mirror is ready."
                                }
                            }
                            .auroraGlass(cornerRadius = 16.dp, tintAlpha = 0.25f),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Refresh,
                            contentDescription = "Check Mercury",
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(20.dp)
                        )
                    }

                    Spacer(Modifier.width(8.dp))

                    // Send File (Circular Button)
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .graphicsLayer {
                                scaleX = fileScale
                                scaleY = fileScale
                                alpha = if (fileEnabled) 1.0f else 0.4f
                            }
                            .clickable(
                                enabled = fileEnabled,
                                interactionSource = fileInteractionSource,
                                indication = null
                            ) {
                                if (usePremiumSOTAUX) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                                filePicker.launch(arrayOf("*/*"))
                            }
                            .auroraGlass(cornerRadius = 16.dp, tintAlpha = if (fileEnabled) 0.25f else 0.1f),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Filled.AttachFile,
                            contentDescription = if (sendingFile) "Sending file" else "Send File",
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(20.dp)
                        )
                    }

                    Spacer(Modifier.width(8.dp))

                    // Call Mac (Circular Button)
                    val callEnabled = pendingCallRequestID == null
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .graphicsLayer {
                                scaleX = callScale
                                scaleY = callScale
                                alpha = if (callEnabled) 1.0f else 0.4f
                            }
                            .clickable(
                                enabled = callEnabled,
                                interactionSource = callInteractionSource,
                                indication = null
                            ) {
                                if (usePremiumSOTAUX) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                                val currentCoordinator = coordinator
                                val currentPhase = phase
                                if (currentCoordinator == null) {
                                    statusMessage = "Mercury is not started yet. Open BurnBar on the Mac and wait for the paired Mac tile to show online."
                                    Log.i("BurnBar", "Call Mac blocked: media coordinator is null")
                                    return@clickable
                                }
                                if (currentPhase !is MediaControlStreamCoordinator.Phase.Live) {
                                    statusMessage = currentPhase.userMessage()
                                    Log.i("BurnBar", "Call Mac blocked: phase=${currentPhase.javaClass.simpleName}")
                                    return@clickable
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
                            }
                            .auroraGlass(cornerRadius = 16.dp, tintAlpha = if (callEnabled) 0.25f else 0.1f),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Phone,
                            contentDescription = if (pendingCallRequestID == null) "Call Mac" else "Calling Mac",
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(20.dp)
                        )
                    }
                }
            }
        }
    }

    // Customization Settings Drawer (Bottom Sheet)
    if (isSettingsOpen) {
        ModalBottomSheet(
            onDismissRequest = { isSettingsOpen = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
            tonalElevation = 8.dp,
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
            dragHandle = {
                Box(
                    modifier = Modifier
                        .padding(vertical = 12.dp)
                        .width(36.dp)
                        .height(4.dp)
                        .background(
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                            shape = RoundedCornerShape(2.dp)
                        )
                )
            }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp)
                    .padding(top = 8.dp, bottom = 48.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp)
            ) {
                Text(
                    text = "CUSTOMIZATION HUB",
                    color = AuroraColors.hermesMercury,
                    style = AuroraType.monoSmall.copy(fontWeight = FontWeight.Bold, letterSpacing = 2.sp),
                    modifier = Modifier.padding(bottom = 8.dp)
                )

                // Premium SOTA UX Toggle
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Premium SOTA UX",
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Tactile spring scale & dynamic haptic feedback",
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            fontSize = 12.sp
                        )
                    }
                    Switch(
                        checked = usePremiumSOTAUX,
                        onCheckedChange = {
                            GlobalVisualSettings.setPremiumSOTAUX(it)
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = AuroraColors.hermesMercury
                        )
                    )
                }

                // Swarm Background Toggle
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Swarm Background",
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Active, token-ember swarms from burnbar.ai",
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            fontSize = 12.sp
                        )
                    }
                    Switch(
                        checked = useWebsiteBackground,
                        onCheckedChange = {
                            GlobalVisualSettings.setWebsiteBackground(it)
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = AuroraColors.hermesMercury
                        )
                    )
                }
            }
        }
    }
}

@Composable
fun MacScreenPreviewCard(
    phase: MediaControlStreamCoordinator.Phase,
    recoveringMercury: Boolean,
    pendingRequestID: String?,
    modifier: Modifier = Modifier
) {
    val isPulsing = phase is MediaControlStreamCoordinator.Phase.Dialing || 
                    phase is MediaControlStreamCoordinator.Phase.Reconnecting ||
                    recoveringMercury
    
    val cameraColor = when {
        phase is MediaControlStreamCoordinator.Phase.Live -> AuroraColors.successDark
        phase is MediaControlStreamCoordinator.Phase.Dialing || 
        phase is MediaControlStreamCoordinator.Phase.Reconnecting || 
        recoveringMercury -> AuroraColors.amber
        phase is MediaControlStreamCoordinator.Phase.Failed -> AuroraColors.errorDark
        else -> Color(0xFF4B5563) // solid dark grey for Idle/Stopped
    }

    val infiniteTransition = rememberInfiniteTransition(label = "camera_pulse")
    val cameraAlpha by infiniteTransition.animateFloat(
        initialValue = 0.4f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "camera_alpha"
    )
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.6f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse_scale"
    )

    val cameraAlphaFinal = if (isPulsing) cameraAlpha else 1.0f

    // Outer frame: simulated MacBook/iMac aspect ratio 16:10
    Box(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(1.6f)
            .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.15f, shadow = AuroraShadows.large)
            .background(Color(0xFF0D1117)) // Slate dark bezel background
            .padding(bottom = 12.dp) // Leave bezel room at bottom for branding
    ) {
        // Top camera bezel area
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 6.dp)
                .size(12.dp),
            contentAlignment = Alignment.Center
        ) {
            if (isPulsing || phase is MediaControlStreamCoordinator.Phase.Live) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = pulseScale
                            scaleY = pulseScale
                            alpha = (1.0f - pulseScale) * 0.7f
                        }
                        .background(cameraColor, shape = RoundedCornerShape(999.dp))
                )
            }
            Box(
                modifier = Modifier
                    .size(5.dp)
                    .background(cameraColor.copy(alpha = cameraAlphaFinal), shape = RoundedCornerShape(999.dp))
            )
        }

        // The real screen area inset within the bezels
        val screenWallpaper = Brush.linearGradient(
            colors = listOf(
                Color(0xFF0B0D19), // deep space dark
                Color(0xFF14132C), // cosmic indigo
                Color(0xFF28183B), // twilight violet
                Color(0xFF331D2D)  // warm ember rose
            )
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 18.dp, start = 10.dp, end = 10.dp, bottom = 4.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(screenWallpaper)
        ) {
            if (phase is MediaControlStreamCoordinator.Phase.Live) {
                // Live visual representation: concentric pulse radar waves
                val waveProgress by infiniteTransition.animateFloat(
                    initialValue = 0f,
                    targetValue = 1f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(3000, easing = LinearEasing),
                        repeatMode = RepeatMode.Restart
                    ),
                    label = "wave_progress"
                )

                Canvas(modifier = Modifier.fillMaxSize()) {
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val maxRadius = size.minDimension * 0.8f
                    for (i in 0..2) {
                        val progress = (waveProgress + i / 3f) % 1f
                        val radius = maxRadius * progress
                        val alpha = (1f - progress) * 0.35f
                        drawCircle(
                            color = AuroraColors.successDark.copy(alpha = alpha),
                            radius = radius,
                            center = center,
                            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.5.dp.toPx())
                        )
                    }
                    // Pulsing central node
                    drawCircle(
                        color = AuroraColors.successDark.copy(alpha = 0.2f),
                        radius = 16.dp.toPx() * (1f + waveProgress * 0.3f),
                        center = center
                    )
                    drawCircle(
                        color = AuroraColors.successDark,
                        radius = 6.dp.toPx(),
                        center = center
                    )
                }

                // Beautiful glowing center badge: Screen mirroring live
                Box(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .auroraGlass(cornerRadius = 14.dp, tintAlpha = 0.45f)
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .background(AuroraColors.successDark, shape = RoundedCornerShape(999.dp))
                        )
                        Text(
                            text = "MIRRORING ACTIVE",
                            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold, color = Color.White)
                        )
                    }
                }
            } else {
                // Frosted glass terminal overlay for idle/connecting/stopped states
                Box(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .fillMaxWidth(0.92f)
                        .fillMaxHeight(0.85f)
                        .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.3f)
                        .background(Color.Black.copy(alpha = 0.3f))
                ) {
                    Column(modifier = Modifier.fillMaxSize()) {
                        // Title bar
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(22.dp)
                                .background(Color.White.copy(alpha = 0.05f))
                                .padding(horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            // Traffic lights
                            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                Box(modifier = Modifier.size(6.dp).background(Color(0xFFFF5F56), shape = RoundedCornerShape(999.dp)))
                                Box(modifier = Modifier.size(6.dp).background(Color(0xFFFFBD2E), shape = RoundedCornerShape(999.dp)))
                                Box(modifier = Modifier.size(6.dp).background(Color(0xFF27C93F), shape = RoundedCornerShape(999.dp)))
                            }
                            Text(
                                text = "openburnbar — zsh",
                                style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)),
                                modifier = Modifier.fillMaxWidth(),
                                textAlign = TextAlign.Center
                            )
                        }

                        // Terminal commands & output
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            val timestamp = remember { System.currentTimeMillis() / 1000 }
                            Text(
                                text = "Last login: Wed May 20 on ttys003",
                                style = AuroraType.monoTiny.copy(color = Color.White.copy(0.35f))
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(
                                    text = "MacBook:~ admin$",
                                    style = AuroraType.monoTiny.copy(color = AuroraColors.whimsyDark)
                                )
                                Text(
                                    text = "./openburnbar --status",
                                    style = AuroraType.monoTiny.copy(color = Color.White)
                                )
                            }
                            
                            val statusLine = when {
                                phase is MediaControlStreamCoordinator.Phase.Idle -> ">> [IDLE] Waiting for connection request..."
                                phase is MediaControlStreamCoordinator.Phase.Dialing -> ">> [DIALING] Initiating Iroh secure tunnel..."
                                phase is MediaControlStreamCoordinator.Phase.Stopped -> ">> [STOPPED] Daemon inactive. Open Mac app to start."
                                phase is MediaControlStreamCoordinator.Phase.Reconnecting -> ">> [RECONNECTING] Attempting peer recovery..."
                                phase is MediaControlStreamCoordinator.Phase.Failed -> ">> [FAILED] Error: ${phase.reason}"
                                else -> ">> [READY] Standby mode."
                            }

                            Text(
                                text = statusLine,
                                style = AuroraType.monoTiny.copy(
                                    fontWeight = FontWeight.Bold,
                                    color = when {
                                        phase is MediaControlStreamCoordinator.Phase.Failed -> AuroraColors.errorDark
                                        phase is MediaControlStreamCoordinator.Phase.Dialing || phase is MediaControlStreamCoordinator.Phase.Reconnecting -> AuroraColors.amber
                                        else -> Color.White.copy(0.85f)
                                    }
                                )
                            )

                            if (recoveringMercury) {
                                Text(
                                    text = ">> [MERCURY] Bootstrapping tunnel...",
                                    style = AuroraType.monoTiny.copy(color = AuroraColors.amber, fontWeight = FontWeight.Bold)
                                )
                            }

                            if (pendingRequestID != null) {
                                Text(
                                    text = ">> [PENDING] Waiting for screen authorization...",
                                    style = AuroraType.monoTiny.copy(color = AuroraColors.amber, fontWeight = FontWeight.Bold)
                                )
                            }
                        }
                    }
                }
            }
        }

        // iMac Aluminum bottom bezel branding
        Text(
            text = "BURNBAR",
            color = Color.White.copy(alpha = 0.12f),
            style = AuroraType.monoTiny.copy(
                fontSize = 8.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 3.sp
            ),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 2.dp)
        )
    }
}

// WebsiteBackground is imported from com.openburnbar.ui.components — the
// shared swarm canvas. The previous local copy here drew a perspective grid
// that didn't fit the design language; deleted in favor of the shared swarm.

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
