// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import com.openburnbar.BurnBarApplication
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockResult

@Composable
internal fun ScreenShareViewerActivityContent(activity: ScreenShareViewerActivity) {
    val ui = rememberScreenShareViewerActivityUiState(activity)
    ScreenShareViewerActivityFocusContextEffect(ui)
    ScreenShareViewerActivityMirrorAckEffect(activity, ui)
    ScreenShareViewerActivityControlDeniedEffect(activity, ui)
    ScreenShareViewerActivityClipboardEffect(activity, ui)
    ScreenShareViewerActivityRemoteUnlockResultEffect(activity, ui)
    ScreenShareViewerActivityRoundTripEffect(activity, ui)
    ScreenShareViewerActivitySavedCredentialEffect(activity, ui)
    ScreenShareViewerScreen(
        pipeline = activity.pipeline,
        options = activity.screenShareViewerScreenOptions(ui),
    )
}

@Composable
private fun ScreenShareViewerActivityFocusContextEffect(ui: ScreenShareViewerActivityUiState) {
    DisposableEffect(Unit) {
        val coordinator = BurnBarApplication.mediaControlCoordinator
        coordinator?.focusContextHandler = { relayContext ->
            ui.smartZoomContext.value = ScreenShareSmartZoomContext.from(relayContext)
        }
        onDispose {
            coordinator?.focusContextHandler = null
        }
    }
}

@Composable
private fun ScreenShareViewerActivityMirrorAckEffect(
    activity: ScreenShareViewerActivity,
    ui: ScreenShareViewerActivityUiState,
) {
    LaunchedEffect(ui.lastMirrorAck) {
        ui.lastMirrorAck?.let { ack -> activity.applyMirrorAck(ack, ui.selectedDisplayId) }
    }
}

@Composable
private fun ScreenShareViewerActivityControlDeniedEffect(
    activity: ScreenShareViewerActivity,
    ui: ScreenShareViewerActivityUiState,
) {
    LaunchedEffect(ui.lastControlDenied) {
        ui.lastControlDenied?.let { denied -> activity.applyControlDenied(denied) }
    }
}

@Composable
private fun ScreenShareViewerActivityClipboardEffect(
    activity: ScreenShareViewerActivity,
    ui: ScreenShareViewerActivityUiState,
) {
    LaunchedEffect(ui.lastClipboardResponse) {
        ui.lastClipboardResponse?.let { response -> activity.handleClipboardResponse(response) }
    }
}

@Composable
private fun ScreenShareViewerActivityRemoteUnlockResultEffect(
    activity: ScreenShareViewerActivity,
    ui: ScreenShareViewerActivityUiState,
) {
    LaunchedEffect(ui.lastRemoteUnlockResult) {
        ui.lastRemoteUnlockResult?.let { result -> activity.applyRemoteUnlockResult(result) }
    }
}

@Composable
private fun ScreenShareViewerActivityRoundTripEffect(
    activity: ScreenShareViewerActivity,
    ui: ScreenShareViewerActivityUiState,
) {
    LaunchedEffect(ui.lastRoundTripMillis) {
        ui.lastRoundTripMillis?.let { activity.pipeline.updateRoundTripMillis(it) }
    }
}

@Composable
private fun ScreenShareViewerActivitySavedCredentialEffect(
    activity: ScreenShareViewerActivity,
    ui: ScreenShareViewerActivityUiState,
) {
    LaunchedEffect(ui.activeRemoteUnlockState?.capabilities?.credentialRecipientKeyId) {
        activity.refreshSavedRemoteUnlockAvailability(ui)
    }
}

internal fun ScreenShareViewerActivity.applyMirrorAck(
    ack: HermesRealtimeRelayMirrorAck,
    selectedDisplayId: androidx.compose.runtime.MutableState<String?>,
) {
    mirrorSessionID = ack.sessionId ?: mirrorSessionID
    mirrorViewerRole = ack.viewerRole ?: mirrorViewerRole
    ack.selectedDisplayId?.let { selectedDisplayId.value = it }
    if (ack.viewerRole == "watcher") {
        controlStatus.value = "Watching only. Another device controls the Mac."
    }
}

internal fun ScreenShareViewerActivity.applyControlDenied(denied: HermesRealtimeRelayControlDenied) {
    controlStatus.value = controlDeniedMessage(denied)
    when (denied.reason) {
        HermesRealtimeRelayControlDenied.Reason.SIGNATURE_FAILURE,
        HermesRealtimeRelayControlDenied.Reason.COUNTER_REPLAY,
        HermesRealtimeRelayControlDenied.Reason.STALE_TIMESTAMP,
        -> {
            phoneControlSender = null
            phoneControlConnectionID = null
        }
        else -> Unit
    }
}

internal fun ScreenShareViewerActivity.applyRemoteUnlockResult(result: HermesRealtimeRelayRemoteUnlockResult) {
    when (result.status) {
        HermesRealtimeRelayRemoteUnlockResult.Status.DENIED,
        HermesRealtimeRelayRemoteUnlockResult.Status.FAILED,
        HermesRealtimeRelayRemoteUnlockResult.Status.EXPIRED,
        ->
            controlStatus.value = result.detail ?: "Remote Unlock was denied."
        HermesRealtimeRelayRemoteUnlockResult.Status.UNLOCKED ->
            controlStatus.value = "Mac unlocked"
        else -> Unit
    }
}
