@file:Suppress("MagicNumber", "TooManyFunctions")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.settings.GlobalVisualSettings
import com.openburnbar.ui.settings.rememberPremiumSOTAUX
import com.openburnbar.ui.settings.rememberWebsiteBackground
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraType
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PairedMacControlsScreenContent(connectionID: String?, modifier: Modifier = Modifier) {
    val session = rememberPairedMacControlsSession(connectionID)
    PairedMacControlsScreenEffects(session.effectsBinding)
    PairedMacControlsScreenLayout(session.uiState, session.uiActions, modifier)
    PairedMacControlsSettingsSheet(
        isOpen = session.uiState.isSettingsOpen,
        usePremiumSOTAUX = session.uiState.usePremiumSOTAUX,
        useWebsiteBackground = session.uiState.useWebsiteBackground,
        onDismiss = session.uiActions.onDismissSettings,
    )
}

private data class PairedMacControlsSession(
    val uiState: PairedMacControlsUiState,
    val uiActions: PairedMacControlsUiActions,
    val effectsBinding: PairedMacControlsEffectsBinding,
)

@Composable
private fun rememberPairedMacControlsSession(connectionID: String?): PairedMacControlsSession {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val app = context.applicationContext as? BurnBarApplication
    val streams = rememberPairedMacCoordinatorStreams()
    val local = rememberPairedMacControlsLocalState()
    val premium = rememberPairedMacPremiumUi()
    val filePicker =
        rememberPairedMacFilePicker(
            scope = scope,
            activePair = streams.activePair,
            onStatusMessageChange = local.onStatusMessageChange,
            onSendingFileChange = local.onSendingFileChange,
        )
    return assemblePairedMacControlsSession(
        PairedMacControlsSessionAssembly(
            connectionID = connectionID,
            scope = scope,
            app = app,
            streams = streams,
            local = local,
            premium = premium,
            filePickerLaunch = { filePicker.launch(arrayOf("*/*")) },
        ),
    )
}

private data class PairedMacControlsSessionAssembly(
    val connectionID: String?,
    val scope: kotlinx.coroutines.CoroutineScope,
    val app: BurnBarApplication?,
    val streams: PairedMacCoordinatorStreams,
    val local: PairedMacControlsLocalState,
    val premium: PairedMacPremiumUi,
    val filePickerLaunch: () -> Unit,
)

private fun assemblePairedMacControlsSession(
    assembly: PairedMacControlsSessionAssembly,
): PairedMacControlsSession {
    val effectsBinding =
        buildPairedMacEffectsBinding(
            assembly.connectionID,
            assembly.app,
            assembly.streams,
            assembly.local,
        )
    val writeCallbacks = buildPairedMacWriteCallbacks(assembly.streams, assembly.local)
    val uiState = buildPairedMacUiState(assembly.streams, assembly.local, assembly.premium)
    val uiActions =
        buildPairedMacControlsUiActions(
            context =
            PairedMacControlsActionBuildContext(
                scope = assembly.scope,
                connectionID = assembly.connectionID,
                app = assembly.app,
                streams = assembly.streams,
                local = assembly.local,
                premium = assembly.premium,
                writeCallbacks = writeCallbacks,
            ),
            onFilePickerLaunch = assembly.filePickerLaunch,
        )
    return PairedMacControlsSession(uiState = uiState, uiActions = uiActions, effectsBinding = effectsBinding)
}

private fun buildPairedMacEffectsBinding(
    connectionID: String?,
    app: BurnBarApplication?,
    streams: PairedMacCoordinatorStreams,
    local: PairedMacControlsLocalState,
): PairedMacControlsEffectsBinding =
    PairedMacControlsEffectsBinding(
        connectionID = connectionID,
        app = app,
        coordinator = streams.coordinator,
        pendingRequestID = local.pendingRequestID,
        ack = streams.ack,
        pendingCallRequestID = local.pendingCallRequestID,
        callAck = streams.callAck,
        launchedMirrorRequestID = local.launchedMirrorRequestID,
        onCoordinatorChange = streams.onCoordinatorChange,
        onStatusMessageChange = local.onStatusMessageChange,
        onPendingRequestIDChange = local.onPendingRequestIDChange,
        onPendingCallRequestIDChange = local.onPendingCallRequestIDChange,
        onLaunchedMirrorRequestIDChange = local.onLaunchedMirrorRequestIDChange,
    )

private fun buildPairedMacWriteCallbacks(
    streams: PairedMacCoordinatorStreams,
    local: PairedMacControlsLocalState,
): PairedMacControlsWriteCallbacks =
    PairedMacControlsWriteCallbacks(
        setCoordinator = streams.onCoordinatorChange,
        setPendingRequestID = local.onPendingRequestIDChange,
        setPendingCallRequestID = local.onPendingCallRequestIDChange,
        setStatusMessage = local.onStatusMessageChange,
        setRecoveringMercury = local.onRecoveringMercuryChange,
    )

private fun buildPairedMacUiState(
    streams: PairedMacCoordinatorStreams,
    local: PairedMacControlsLocalState,
    premium: PairedMacPremiumUi,
): PairedMacControlsUiState =
    PairedMacControlsUiState(
        phase = streams.phase,
        statusMessage = local.statusMessage,
        pendingRequestID = local.pendingRequestID,
        pendingCallRequestID = local.pendingCallRequestID,
        recoveringMercury = local.recoveringMercury,
        sendingFile = local.sendingFile,
        mirrorAutoAccept = streams.mirrorAutoAccept,
        usePremiumSOTAUX = premium.usePremiumSOTAUX,
        useWebsiteBackground = premium.useWebsiteBackground,
        isSettingsOpen = local.isSettingsOpen,
        coordinator = streams.coordinator,
    )

private data class PairedMacCoordinatorStreams(
    val coordinator: MediaControlStreamCoordinator?,
    val phase: MediaControlStreamCoordinator.Phase,
    val ack: HermesRealtimeRelayMirrorAck?,
    val callAck: HermesRealtimeRelayCallAck?,
    val activePair: MediaControlStreamCoordinator.ActivePair?,
    val mirrorAutoAccept: Boolean,
    val onCoordinatorChange: (MediaControlStreamCoordinator?) -> Unit,
)

@Composable
private fun rememberPairedMacCoordinatorStreams(): PairedMacCoordinatorStreams {
    var coordinator by remember { mutableStateOf(BurnBarApplication.mediaControlCoordinator) }
    val fallbackPhase = remember { MutableStateFlow<MediaControlStreamCoordinator.Phase>(MediaControlStreamCoordinator.Phase.Idle) }
    val fallbackAck = remember { MutableStateFlow<HermesRealtimeRelayMirrorAck?>(null) }
    val fallbackPair = remember { MutableStateFlow<MediaControlStreamCoordinator.ActivePair?>(null) }
    val phase by (coordinator?.phase ?: fallbackPhase).collectAsState()
    val ack by (coordinator?.lastMirrorAck ?: fallbackAck).collectAsState()
    val fallbackCallAck = remember { MutableStateFlow<HermesRealtimeRelayCallAck?>(null) }
    val callAck by (coordinator?.lastCallAck ?: fallbackCallAck).collectAsState()
    val activePair by (coordinator?.activePair ?: fallbackPair).collectAsState()
    val fallbackPeerCapabilities = remember { MutableStateFlow<Set<String>>(emptySet()) }
    val peerCapabilities by (coordinator?.lastPeerCapabilities ?: fallbackPeerCapabilities).collectAsState()
    return PairedMacCoordinatorStreams(
        coordinator = coordinator,
        phase = phase,
        ack = ack,
        callAck = callAck,
        activePair = activePair,
        mirrorAutoAccept = peerCapabilities.contains("mirror.auto_accept"),
        onCoordinatorChange = { coordinator = it },
    )
}

private data class PairedMacControlsLocalState(
    val pendingRequestID: String?,
    val pendingCallRequestID: String?,
    val launchedMirrorRequestID: String?,
    val statusMessage: String?,
    val sendingFile: Boolean,
    val recoveringMercury: Boolean,
    val isSettingsOpen: Boolean,
    val onPendingRequestIDChange: (String?) -> Unit,
    val onPendingCallRequestIDChange: (String?) -> Unit,
    val onLaunchedMirrorRequestIDChange: (String?) -> Unit,
    val onStatusMessageChange: (String?) -> Unit,
    val onSendingFileChange: (Boolean) -> Unit,
    val onRecoveringMercuryChange: (Boolean) -> Unit,
    val onSettingsOpenChange: (Boolean) -> Unit,
)

@Composable
private fun rememberPairedMacControlsLocalState(): PairedMacControlsLocalState {
    var pendingRequestID by remember { mutableStateOf<String?>(null) }
    var pendingCallRequestID by remember { mutableStateOf<String?>(null) }
    var launchedMirrorRequestID by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var sendingFile by remember { mutableStateOf(false) }
    var recoveringMercury by remember { mutableStateOf(false) }
    var isSettingsOpen by remember { mutableStateOf(false) }
    return PairedMacControlsLocalState(
        pendingRequestID = pendingRequestID,
        pendingCallRequestID = pendingCallRequestID,
        launchedMirrorRequestID = launchedMirrorRequestID,
        statusMessage = statusMessage,
        sendingFile = sendingFile,
        recoveringMercury = recoveringMercury,
        isSettingsOpen = isSettingsOpen,
        onPendingRequestIDChange = { pendingRequestID = it },
        onPendingCallRequestIDChange = { pendingCallRequestID = it },
        onLaunchedMirrorRequestIDChange = { launchedMirrorRequestID = it },
        onStatusMessageChange = { statusMessage = it },
        onSendingFileChange = { sendingFile = it },
        onRecoveringMercuryChange = { recoveringMercury = it },
        onSettingsOpenChange = { isSettingsOpen = it },
    )
}

private data class PairedMacPremiumUi(
    val usePremiumSOTAUX: Boolean,
    val useWebsiteBackground: Boolean,
    val performPremiumHaptic: () -> Unit,
    val performSettingsHaptic: () -> Unit,
)

@Composable
private fun rememberPairedMacPremiumUi(): PairedMacPremiumUi {
    val usePremiumSOTAUXState = rememberPremiumSOTAUX()
    val usePremiumSOTAUX = usePremiumSOTAUXState.value
    val useWebsiteBackgroundState = rememberWebsiteBackground()
    val useWebsiteBackground = useWebsiteBackgroundState.value
    val haptic = LocalHapticFeedback.current
    return PairedMacPremiumUi(
        usePremiumSOTAUX = usePremiumSOTAUX,
        useWebsiteBackground = useWebsiteBackground,
        performPremiumHaptic = {
            if (usePremiumSOTAUX) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            }
        },
        performSettingsHaptic = {
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        },
    )
}

@Composable
private fun rememberPairedMacFilePicker(
    scope: kotlinx.coroutines.CoroutineScope,
    activePair: MediaControlStreamCoordinator.ActivePair?,
    onStatusMessageChange: (String?) -> Unit,
    onSendingFileChange: (Boolean) -> Unit,
) =
    rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        val picked = uri ?: return@rememberLauncherForActivityResult
        val transferService = BurnBarApplication.fileTransferService
        val pair = activePair
        if (transferService == null || pair == null) {
            onStatusMessageChange("Mercury file transfer is not ready yet. Open BurnBar on the Mac and wait for Mercury to go live.")
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            onSendingFileChange(true)
            runCatching {
                transferService.sendFile(
                    uri = picked,
                    uid = pair.uid,
                    connectionID = pair.connectionID,
                    peerDeviceID = pair.connectionID,
                )
            }.onSuccess { manifest ->
                onStatusMessageChange("Sent ${manifest.filename} to your Mac.")
            }.onFailure { error ->
                onStatusMessageChange("File send failed: ${error.localizedMessage ?: error.javaClass.simpleName}")
            }
            onSendingFileChange(false)
        }
    }

private data class PairedMacControlsActionBuildContext(
    val scope: kotlinx.coroutines.CoroutineScope,
    val connectionID: String?,
    val app: BurnBarApplication?,
    val streams: PairedMacCoordinatorStreams,
    val local: PairedMacControlsLocalState,
    val premium: PairedMacPremiumUi,
    val writeCallbacks: PairedMacControlsWriteCallbacks,
)

private fun buildPairedMacControlsUiActions(
    context: PairedMacControlsActionBuildContext,
    onFilePickerLaunch: () -> Unit,
): PairedMacControlsUiActions {
    val scope = context.scope
    val connectionID = context.connectionID
    val app = context.app
    val streams = context.streams
    val local = context.local
    val premium = context.premium
    val writeCallbacks = context.writeCallbacks
    val mirrorSnapshot = {
        PairedMacControlsMirrorRequestInput(
            app = app,
            coordinator = streams.coordinator,
            phase = streams.phase,
            connectionID = connectionID,
            activePair = streams.activePair,
            mirrorAutoAccept = streams.mirrorAutoAccept,
        )
    }
    val checkSnapshot = {
        PairedMacControlsCheckMercuryInput(
            coordinator = streams.coordinator,
            phase = streams.phase,
            connectionID = connectionID,
            activePair = streams.activePair,
            app = app,
        )
    }
    val callSnapshot = { streams.coordinator to streams.phase }
    return PairedMacControlsUiActions(
        onSettingsClick = {
            local.onSettingsOpenChange(true)
            premium.performSettingsHaptic()
        },
        onMirrorClick = {
            premium.performPremiumHaptic()
            mirrorClickAction(scope, mirrorSnapshot, writeCallbacks)()
        },
        onCheckMercuryClick = {
            premium.performPremiumHaptic()
            checkMercuryClickAction(scope, checkSnapshot, writeCallbacks)()
        },
        onSendFileClick = {
            premium.performPremiumHaptic()
            onFilePickerLaunch()
        },
        onCallMacClick = {
            premium.performPremiumHaptic()
            callMacClickAction(scope, callSnapshot, writeCallbacks)()
        },
        onDismissSettings = { local.onSettingsOpenChange(false) },
    )
}

@Composable
private fun PairedMacControlsScreenLayout(
    state: PairedMacControlsUiState,
    actions: PairedMacControlsUiActions,
    modifier: Modifier,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        if (state.useWebsiteBackground) {
            WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        } else {
            Spacer(
                modifier =
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            listOf(
                                AuroraColors.hermesMercury.copy(alpha = 0.22f),
                                MaterialTheme.colorScheme.background,
                            ),
                        ),
                    ),
            )
        }

        Column(
            modifier =
            modifier
                .fillMaxSize()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            PairedMacControlsHeaderSection(
                phase = state.phase,
                onSettingsClick = actions.onSettingsClick,
            )
            MacScreenPreviewCard(
                phase = state.phase,
                recoveringMercury = state.recoveringMercury,
                pendingRequestID = state.pendingRequestID,
                modifier = Modifier.fillMaxWidth(),
            )
            state.statusMessage?.let { message ->
                PairedMacControlsStatusBanner(message = message)
            }
            Spacer(Modifier.weight(1f))
            PairedMacControlsDockSection(state = state, actions = actions)
        }
    }
}

@Composable
internal fun PairedMacControlsScreenEffects(binding: PairedMacControlsEffectsBinding) {
    PairedMacControlsConnectionEffect(binding)
    PairedMacControlsMirrorAckEffect(binding)
    PairedMacControlsMirrorTimeoutEffect(binding)
    PairedMacControlsCallEffects(binding)
}

@Composable
private fun PairedMacControlsConnectionEffect(binding: PairedMacControlsEffectsBinding) {
    LaunchedEffect(binding.connectionID) {
        val id = binding.connectionID?.trim()?.takeIf { it.isNotBlank() } ?: return@LaunchedEffect
        if (id.startsWith("paired-mac:")) return@LaunchedEffect
        val application = binding.app ?: return@LaunchedEffect
        binding.onStatusMessageChange("Starting Mercury...")
        runCatching {
            application.ensureMediaControlStream(connectionID = id)
        }.onSuccess {
            binding.onCoordinatorChange(BurnBarApplication.mediaControlCoordinator)
            binding.onStatusMessageChange(null)
        }.onFailure { error ->
            binding.onCoordinatorChange(BurnBarApplication.mediaControlCoordinator)
            binding.onStatusMessageChange("Mercury unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}")
        }
    }
}

@Composable
private fun PairedMacControlsMirrorAckEffect(binding: PairedMacControlsEffectsBinding) {
    val context = LocalContext.current

    LaunchedEffect(binding.pendingRequestID, binding.ack) {
        val requestID = binding.pendingRequestID ?: return@LaunchedEffect
        val currentAck = binding.ack ?: return@LaunchedEffect
        if (currentAck.requestId != requestID) return@LaunchedEffect
        if (
            currentAck.decision == HermesRealtimeRelayMirrorAck.Decision.UNSUPPORTED &&
            currentAck.detail == REMOTE_UNLOCK_SESSION_REQUIRED
        ) {
            handleRemoteUnlockMirrorRetry(binding, context)
            return@LaunchedEffect
        }
        binding.onPendingRequestIDChange(null)
        binding.onStatusMessageChange(currentAck.userMessage())
        if (
            currentAck.decision == HermesRealtimeRelayMirrorAck.Decision.ACCEPTED &&
            binding.launchedMirrorRequestID != requestID
        ) {
            binding.onLaunchedMirrorRequestIDChange(requestID)
            context.startActivity(
                Intent(context, ScreenShareViewerActivity::class.java)
                    .putExtra(ScreenShareViewerActivity.EXTRA_MIRROR_REQUEST_ID, requestID)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}

private suspend fun handleRemoteUnlockMirrorRetry(
    binding: PairedMacControlsEffectsBinding,
    context: android.content.Context,
) {
    val targetCoordinator =
        binding.coordinator ?: run {
            binding.onPendingRequestIDChange(null)
            binding.onStatusMessageChange("Mercury is not ready for Remote Unlock yet.")
            return
        }
    val name = pairedMacRequesterDisplayName()
    binding.onStatusMessageChange("Confirm this Android to unlock your Mac.")
    runCatching {
        targetCoordinator.requestMirror(
            requesterDisplayName = name,
            remoteUnlockSession = buildRemoteUnlockSession(context, targetCoordinator, name),
        )
    }.onSuccess { retryRequestID ->
        binding.onPendingRequestIDChange(retryRequestID)
        binding.onStatusMessageChange("Remote Unlock request sent.")
    }.onFailure { error ->
        binding.onPendingRequestIDChange(null)
        binding.onStatusMessageChange("Remote Unlock unavailable: ${error.localizedMessage ?: error.javaClass.simpleName}")
    }
}

@Composable
private fun PairedMacControlsMirrorTimeoutEffect(binding: PairedMacControlsEffectsBinding) {
    LaunchedEffect(binding.pendingRequestID) {
        val requestID = binding.pendingRequestID ?: return@LaunchedEffect
        delay(15_000)
        if (binding.pendingRequestID == requestID) {
            binding.onPendingRequestIDChange(null)
            binding.onStatusMessageChange("No response from the Mac. Open BurnBar on the Mac, enable Local Network, then try again.")
        }
    }
}

@Composable
private fun PairedMacControlsCallEffects(binding: PairedMacControlsEffectsBinding) {
    LaunchedEffect(binding.pendingCallRequestID, binding.callAck) {
        val requestID = binding.pendingCallRequestID ?: return@LaunchedEffect
        val currentAck = binding.callAck ?: return@LaunchedEffect
        if (currentAck.requestId == requestID) {
            binding.onPendingCallRequestIDChange(null)
            binding.onStatusMessageChange(currentAck.userMessage())
        }
    }

    LaunchedEffect(binding.pendingCallRequestID) {
        val requestID = binding.pendingCallRequestID ?: return@LaunchedEffect
        delay(15_000)
        if (binding.pendingCallRequestID == requestID) {
            binding.onPendingCallRequestIDChange(null)
            binding.onStatusMessageChange("No call response from the Mac. Open BurnBar on the Mac, enable Local Network, then try again.")
        }
    }
}

@Composable
internal fun PairedMacControlsHeaderSection(
    phase: MediaControlStreamCoordinator.Phase,
    onSettingsClick: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Computer,
                contentDescription = null,
                tint = AuroraColors.hermesMercury,
                modifier = Modifier.size(30.dp),
            )
            Column {
                Text(
                    text = "My Mac",
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                )
                PairedMacControlsPhaseStatusRow(phase = phase)
            }
        }

        IconButton(
            onClick = onSettingsClick,
            modifier =
            Modifier
                .size(40.dp)
                .auroraGlass(cornerRadius = 20.dp, tintAlpha = 0.25f, shadow = AuroraShadows.subtle),
        ) {
            Icon(
                imageVector = Icons.Filled.Settings,
                contentDescription = "Mercury Customization",
                tint = Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun PairedMacControlsPhaseStatusRow(phase: MediaControlStreamCoordinator.Phase) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(6.dp)
                .background(pairedMacPhaseDotColor(phase), shape = RoundedCornerShape(999.dp)),
        )
        Text(
            text = pairedMacPhaseStatusLabel(phase),
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
internal fun PairedMacControlsStatusBanner(message: String) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .auroraGlass(cornerRadius = 14.dp, tintAlpha = 0.3f, shadow = AuroraShadows.subtle)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Refresh,
                contentDescription = null,
                tint = AuroraColors.amber,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = message,
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
internal fun PairedMacControlsDockSection(
    state: PairedMacControlsUiState,
    actions: PairedMacControlsUiActions,
) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.25f, shadow = AuroraShadows.medium)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        PairedMacControlsDockButtons(state = state, actions = actions)
    }
}

@Composable
private fun PairedMacControlsDockButtons(
    state: PairedMacControlsUiState,
    actions: PairedMacControlsUiActions,
) {
    val fileEnabled = state.coordinator != null && state.phase is MediaControlStreamCoordinator.Phase.Live && !state.sendingFile
    val mirrorEnabled = state.pendingRequestID == null && !state.recoveringMercury
    val callEnabled = state.pendingCallRequestID == null
    val scales = rememberPairedMacDockButtonScales(state.usePremiumSOTAUX)

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PairedMacControlsMirrorButton(
            enabled = mirrorEnabled,
            scale = scales.mirrorScale,
            interactionSource = scales.mirrorInteractionSource,
            mirror = PairedMacMirrorButtonState(
                recoveringMercury = state.recoveringMercury,
                pendingRequestID = state.pendingRequestID,
                mirrorAutoAccept = state.mirrorAutoAccept,
            ),
            onClick = actions.onMirrorClick,
        )

        Spacer(Modifier.width(8.dp))

        PairedMacControlsDockIconButton(
            scale = scales.checkScale,
            interactionSource = scales.checkInteractionSource,
            onClick = actions.onCheckMercuryClick,
            contentDescription = "Check Mercury",
            icon = Icons.Filled.Refresh,
        )

        Spacer(Modifier.width(8.dp))

        PairedMacControlsDockIconButton(
            scale = scales.fileScale,
            interactionSource = scales.fileInteractionSource,
            onClick = actions.onSendFileClick,
            contentDescription = if (state.sendingFile) "Sending file" else "Send File",
            icon = Icons.Filled.AttachFile,
            enabled = fileEnabled,
            enabledAlpha = if (fileEnabled) 1.0f else 0.4f,
            tintAlpha = if (fileEnabled) 0.25f else 0.1f,
        )

        Spacer(Modifier.width(8.dp))

        PairedMacControlsDockIconButton(
            scale = scales.callScale,
            interactionSource = scales.callInteractionSource,
            onClick = actions.onCallMacClick,
            contentDescription = if (state.pendingCallRequestID == null) "Call Mac" else "Calling Mac",
            icon = Icons.Filled.Phone,
            enabled = callEnabled,
            enabledAlpha = if (callEnabled) 1.0f else 0.4f,
            tintAlpha = if (callEnabled) 0.25f else 0.1f,
        )
    }
}

private data class PairedMacDockButtonScales(
    val mirrorInteractionSource: MutableInteractionSource,
    val mirrorScale: Float,
    val checkInteractionSource: MutableInteractionSource,
    val checkScale: Float,
    val fileInteractionSource: MutableInteractionSource,
    val fileScale: Float,
    val callInteractionSource: MutableInteractionSource,
    val callScale: Float,
)

@Composable
private fun rememberPairedMacDockButtonScales(usePremiumSOTAUX: Boolean): PairedMacDockButtonScales {
    val mirrorInteractionSource = remember { MutableInteractionSource() }
    val mirrorScale = rememberPairedMacButtonScale(mirrorInteractionSource, usePremiumSOTAUX, "mirror_scale")
    val checkInteractionSource = remember { MutableInteractionSource() }
    val checkScale = rememberPairedMacButtonScale(checkInteractionSource, usePremiumSOTAUX, "check_scale")
    val fileInteractionSource = remember { MutableInteractionSource() }
    val fileScale = rememberPairedMacButtonScale(fileInteractionSource, usePremiumSOTAUX, "file_scale")
    val callInteractionSource = remember { MutableInteractionSource() }
    val callScale = rememberPairedMacButtonScale(callInteractionSource, usePremiumSOTAUX, "call_scale")
    return PairedMacDockButtonScales(
        mirrorInteractionSource = mirrorInteractionSource,
        mirrorScale = mirrorScale,
        checkInteractionSource = checkInteractionSource,
        checkScale = checkScale,
        fileInteractionSource = fileInteractionSource,
        fileScale = fileScale,
        callInteractionSource = callInteractionSource,
        callScale = callScale,
    )
}

private data class PairedMacMirrorButtonState(
    val recoveringMercury: Boolean,
    val pendingRequestID: String?,
    val mirrorAutoAccept: Boolean,
)

@Composable
private fun RowScope.PairedMacControlsMirrorButton(
    enabled: Boolean,
    scale: Float,
    interactionSource: MutableInteractionSource,
    mirror: PairedMacMirrorButtonState,
    onClick: () -> Unit,
) {
    val recoveringMercury = mirror.recoveringMercury
    val pendingRequestID = mirror.pendingRequestID
    val mirrorAutoAccept = mirror.mirrorAutoAccept
    Button(
        enabled = enabled,
        onClick = onClick,
        interactionSource = interactionSource,
        colors =
        ButtonDefaults.buttonColors(
            containerColor = AuroraColors.emberDark,
            disabledContainerColor = AuroraColors.emberDark.copy(alpha = 0.35f),
        ),
        shape = RoundedCornerShape(16.dp),
        modifier =
        Modifier
            .weight(1.4f)
            .height(48.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            },
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Filled.ScreenShare,
            contentDescription = null,
            tint = Color.White,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text =
            when {
                recoveringMercury -> "Connecting..."
                pendingRequestID != null -> if (mirrorAutoAccept) "Opening..." else "Waiting..."
                else -> "Mirror"
            },
            style =
            AuroraType.body.copy(
                fontWeight = FontWeight.Bold,
                color = Color.White,
                fontSize = 13.sp,
            ),
        )
    }
}

@Composable
private fun RowScope.PairedMacControlsDockIconButton(
    scale: Float,
    interactionSource: MutableInteractionSource,
    onClick: () -> Unit,
    contentDescription: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    enabled: Boolean = true,
    enabledAlpha: Float = 1.0f,
    tintAlpha: Float = 0.25f,
) {
    Box(
        modifier =
        Modifier
            .size(48.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                alpha = enabledAlpha
            }
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .auroraGlass(cornerRadius = 16.dp, tintAlpha = tintAlpha),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = Color.White.copy(alpha = 0.85f),
            modifier = Modifier.size(20.dp),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PairedMacControlsSettingsSheet(
    isOpen: Boolean,
    usePremiumSOTAUX: Boolean,
    useWebsiteBackground: Boolean,
    onDismiss: () -> Unit,
) {
    if (!isOpen) return

    val haptic = LocalHapticFeedback.current

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
        tonalElevation = 8.dp,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        dragHandle = {
            Box(
                modifier =
                Modifier
                    .padding(vertical = 12.dp)
                    .width(36.dp)
                    .height(4.dp)
                    .background(
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                        shape = RoundedCornerShape(2.dp),
                    ),
            )
        },
    ) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(top = 8.dp, bottom = 48.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text(
                text = "CUSTOMIZATION HUB",
                color = AuroraColors.hermesMercury,
                style = AuroraType.monoSmall.copy(fontWeight = FontWeight.Bold, letterSpacing = 2.sp),
                modifier = Modifier.padding(bottom = 8.dp),
            )

            PairedMacControlsSettingsToggleRow(
                title = "Premium SOTA UX",
                subtitle = "Tactile spring scale & dynamic haptic feedback",
                checked = usePremiumSOTAUX,
                onCheckedChange = {
                    GlobalVisualSettings.setPremiumSOTAUX(it)
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                },
            )

            PairedMacControlsSettingsToggleRow(
                title = "Swarm Background",
                subtitle = "Active, token-ember swarms from burnbar.ai",
                checked = useWebsiteBackground,
                onCheckedChange = {
                    GlobalVisualSettings.setWebsiteBackground(it)
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                },
            )
        }
    }
}

@Composable
private fun PairedMacControlsSettingsToggleRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = subtitle,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                fontSize = 12.sp,
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors =
            SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = AuroraColors.hermesMercury,
            ),
        )
    }
}

@Composable
private fun rememberPairedMacButtonScale(
    interactionSource: MutableInteractionSource,
    usePremiumSOTAUX: Boolean,
    label: String,
): Float {
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) (if (usePremiumSOTAUX) 0.94f else 0.97f) else 1.0f,
        animationSpec =
        spring(
            dampingRatio = if (usePremiumSOTAUX) 0.55f else Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium,
        ),
        label = label,
    )
    return scale
}

private fun pairedMacPhaseDotColor(phase: MediaControlStreamCoordinator.Phase): Color =
    when (phase) {
        MediaControlStreamCoordinator.Phase.Live -> AuroraColors.successDark
        MediaControlStreamCoordinator.Phase.Dialing,
        is MediaControlStreamCoordinator.Phase.Reconnecting,
        -> AuroraColors.amber
        is MediaControlStreamCoordinator.Phase.Failed -> AuroraColors.errorDark
        else -> Color(0xFF4B5563)
    }

private fun pairedMacPhaseStatusLabel(phase: MediaControlStreamCoordinator.Phase): String =
    when (phase) {
        MediaControlStreamCoordinator.Phase.Live -> "Live"
        MediaControlStreamCoordinator.Phase.Dialing,
        is MediaControlStreamCoordinator.Phase.Reconnecting,
        -> "Connecting"
        is MediaControlStreamCoordinator.Phase.Failed -> "Error"
        else -> "Offline"
    }
