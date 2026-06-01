package com.openburnbar.ui.media

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.computeruse.RemoteUnlockSavedCredentialStore
import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockResult
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState

internal data class ScreenShareViewerActivityRelaySnapshot(
    val lastPeerHeartbeatAtMillis: Long,
    val lastRoundTripMillis: Int?,
    val lastMirrorAck: HermesRealtimeRelayMirrorAck?,
    val lastControlDenied: HermesRealtimeRelayControlDenied?,
    val lastClipboardResponse: HermesRealtimeRelayClipboardResponse?,
    val lastRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState?,
    val lastRemoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult?,
)

internal data class ScreenShareViewerActivityUiLocals(
    val savedCredentialStore: RemoteUnlockSavedCredentialStore,
    val selectedDisplayId: MutableState<String?>,
    val smartZoomContext: MutableState<ScreenShareSmartZoomContext?>,
    val savedRemoteUnlockCredentialAvailable: MutableState<Boolean>,
)

internal class ScreenShareViewerActivityUiState(
    val relay: ScreenShareViewerActivityRelaySnapshot,
    val locals: ScreenShareViewerActivityUiLocals,
) {
    val lastPeerHeartbeatAtMillis: Long get() = relay.lastPeerHeartbeatAtMillis
    val lastRoundTripMillis: Int? get() = relay.lastRoundTripMillis
    val lastMirrorAck: HermesRealtimeRelayMirrorAck? get() = relay.lastMirrorAck
    val lastControlDenied: HermesRealtimeRelayControlDenied? get() = relay.lastControlDenied
    val lastClipboardResponse: HermesRealtimeRelayClipboardResponse? get() = relay.lastClipboardResponse
    val lastRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState? get() = relay.lastRemoteUnlockState
    val lastRemoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult? get() = relay.lastRemoteUnlockResult
    val savedCredentialStore: RemoteUnlockSavedCredentialStore get() = locals.savedCredentialStore
    val selectedDisplayId: MutableState<String?> get() = locals.selectedDisplayId
    val smartZoomContext: MutableState<ScreenShareSmartZoomContext?> get() = locals.smartZoomContext
    val savedRemoteUnlockCredentialAvailable: MutableState<Boolean> get() = locals.savedRemoteUnlockCredentialAvailable

    val activeDisplayId: String
        get() = selectedDisplayId.value ?: lastMirrorAck?.selectedDisplayId ?: "main"

    val activeRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
        get() = lastRemoteUnlockState ?: lastMirrorAck?.remoteUnlockState
}

@Composable
internal fun rememberScreenShareViewerActivityUiState(activity: ScreenShareViewerActivity): ScreenShareViewerActivityUiState {
    val heartbeatFlow = BurnBarApplication.mediaControlCoordinator?.lastPeerHeartbeatAtMillis
    val lastPeerHeartbeatAtMillis by heartbeatFlow?.collectAsState()
        ?: remember { mutableStateOf(0L) }
    val roundTripFlow = BurnBarApplication.mediaControlCoordinator?.lastRoundTripMillis
    val lastRoundTripMillis by roundTripFlow?.collectAsState()
        ?: remember { mutableStateOf<Int?>(null) }
    val mirrorAckFlow = BurnBarApplication.mediaControlCoordinator?.lastMirrorAck
    val lastMirrorAck by mirrorAckFlow?.collectAsState()
        ?: remember { mutableStateOf<HermesRealtimeRelayMirrorAck?>(null) }
    val controlDeniedFlow = BurnBarApplication.mediaControlCoordinator?.lastControlDenied
    val lastControlDenied by controlDeniedFlow?.collectAsState()
        ?: remember { mutableStateOf<HermesRealtimeRelayControlDenied?>(null) }
    val clipboardResponseFlow = BurnBarApplication.mediaControlCoordinator?.lastClipboardResponse
    val lastClipboardResponse by clipboardResponseFlow?.collectAsState()
        ?: remember { mutableStateOf<HermesRealtimeRelayClipboardResponse?>(null) }
    val remoteUnlockStateFlow = BurnBarApplication.mediaControlCoordinator?.lastRemoteUnlockState
    val lastRemoteUnlockState by remoteUnlockStateFlow?.collectAsState()
        ?: remember { mutableStateOf<HermesRealtimeRelayRemoteUnlockState?>(null) }
    val remoteUnlockResultFlow = BurnBarApplication.mediaControlCoordinator?.lastRemoteUnlockResult
    val lastRemoteUnlockResult by remoteUnlockResultFlow?.collectAsState()
        ?: remember { mutableStateOf<HermesRealtimeRelayRemoteUnlockResult?>(null) }
    val savedCredentialStore = remember { RemoteUnlockSavedCredentialStore(activity) }
    val selectedDisplayId = remember { mutableStateOf<String?>(null) }
    val smartZoomContext = remember { mutableStateOf<ScreenShareSmartZoomContext?>(null) }
    val savedRemoteUnlockCredentialAvailable = remember { mutableStateOf(false) }
    return ScreenShareViewerActivityUiState(
        relay =
        ScreenShareViewerActivityRelaySnapshot(
            lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
            lastRoundTripMillis = lastRoundTripMillis,
            lastMirrorAck = lastMirrorAck,
            lastControlDenied = lastControlDenied,
            lastClipboardResponse = lastClipboardResponse,
            lastRemoteUnlockState = lastRemoteUnlockState,
            lastRemoteUnlockResult = lastRemoteUnlockResult,
        ),
        locals =
        ScreenShareViewerActivityUiLocals(
            savedCredentialStore = savedCredentialStore,
            selectedDisplayId = selectedDisplayId,
            smartZoomContext = smartZoomContext,
            savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable,
        ),
    )
}
