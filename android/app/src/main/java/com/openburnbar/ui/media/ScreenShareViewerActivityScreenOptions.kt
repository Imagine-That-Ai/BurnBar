package com.openburnbar.ui.media

import com.openburnbar.irohrelay.HermesRealtimeRelayClipboardAction

internal fun ScreenShareViewerActivity.screenShareViewerScreenOptions(
    ui: ScreenShareViewerActivityUiState,
): ScreenShareViewerScreenOptions =
    ScreenShareViewerScreenOptions(
        lastPeerHeartbeatAtMillis = ui.lastPeerHeartbeatAtMillis,
        availableDisplays = ui.lastMirrorAck?.availableDisplays ?: emptyList(),
        selectedDisplayId = ui.activeDisplayId,
        latestFocusContext = ui.smartZoomContext.value,
        remoteUnlockState = ui.activeRemoteUnlockState,
        savedRemoteUnlockCredentialAvailable = ui.savedRemoteUnlockCredentialAvailable.value,
        onSelectDisplay = { displayId ->
            ui.selectedDisplayId.value = displayId
            sendMirrorDisplaySelect(displayId)
        },
        onClose = { closeMirrorAndFinish() },
        onEnterPictureInPicture = { enterMirrorPictureInPicture() },
        onReconnect = { reconnectMirror() },
        onTapNormalized = { x, y, mouseButton, displayId -> sendTapNormalized(x, y, mouseButton, displayId) },
        onScrollDragNormalized = { x1, y1, x2, y2, displayId -> sendScrollDragNormalized(x1, y1, x2, y2, displayId) },
        onScrollNormalized = { deltaY, displayId -> sendScrollNormalized(deltaY, displayId) },
        onPointerMove = { dx, dy -> sendPointerMoveNormalized(dx, dy, ui.activeDisplayId) },
        onPointerClick = { mouseButton -> sendPointerClickNormalized(mouseButton, ui.activeDisplayId) },
        onTypeText = { text -> sendTypeTextNormalized(text, ui.activeDisplayId) },
        onShortcut = { key, modifiers -> sendShortcutNormalized(key, modifiers, ui.activeDisplayId) },
        onPanic = { sendPanicNormalized(ui.activeDisplayId) },
        onAgentContextTargetNormalized = { x, y, instruction, runtime, displayId ->
            sendPhoneControlContextTarget(
                normalizedX = x,
                normalizedY = y,
                instruction = instruction,
                runtime = runtime,
                threadId = null,
                displayId = displayId,
            )
        },
        onPasteClipboardToMac = { sendClipboardRequest(HermesRealtimeRelayClipboardAction.PASTE_TO_MAC) },
        onGrabClipboardFromMac = { sendClipboardRequest(HermesRealtimeRelayClipboardAction.GRAB_FROM_MAC) },
        onSendRemoteUnlockPassword = { password -> sendRemoteUnlockPassword(password) },
        onSaveRemoteUnlockPassword = { password ->
            saveRemoteUnlockPassword(
                password = password,
                store = ui.savedCredentialStore,
                state = ui.activeRemoteUnlockState,
                onAvailabilityChanged = { refreshSavedRemoteUnlockAvailability(ui) },
            )
        },
        onSendSavedRemoteUnlockPassword = {
            sendSavedRemoteUnlockPassword(store = ui.savedCredentialStore, state = ui.activeRemoteUnlockState)
        },
        onDeleteSavedRemoteUnlockPassword = {
            deleteSavedRemoteUnlockPassword(ui)
        },
        controlStatus = controlStatus.value,
        onTrustControlDevice = { trustThisAndroidForControl() },
    )

internal fun ScreenShareViewerActivity.refreshSavedRemoteUnlockAvailability(ui: ScreenShareViewerActivityUiState) {
    ui.savedRemoteUnlockCredentialAvailable.value =
        remoteUnlockCredentialStoreKey(ui.activeRemoteUnlockState)
            ?.let { ui.savedCredentialStore.hasCredential(it) }
            ?: false
}

internal fun ScreenShareViewerActivity.deleteSavedRemoteUnlockPassword(ui: ScreenShareViewerActivityUiState) {
    remoteUnlockCredentialStoreKey(ui.activeRemoteUnlockState)?.let { storeKey ->
        ui.savedCredentialStore.delete(storeKey)
    }
    ui.savedRemoteUnlockCredentialAvailable.value = false
    controlStatus.value = "Saved Remote Unlock credential removed from this Android."
}
