package com.openburnbar

import android.util.Log
import com.openburnbar.data.media.MediaControlStreamCoordinator
import kotlinx.coroutines.sync.withLock

internal suspend fun BurnBarApplication.ensureMediaControlCoordinatorManaged(
    uid: String,
    selection: IrohPairingSelection.Candidate,
    forceRestart: Boolean = false,
) {
    mediaCoordinatorLock.withLock {
        val connectionId = selection.connectionId
        val existing = BurnBarApplication.mediaControlCoordinator
        val existingPhase = existing?.phase?.value
        if (
            MediaControlCoordinatorReusePolicy.shouldReuse(
                activeConnectionID = activeCoordinatorConnection,
                phase = existingPhase,
                selection = selection,
                forceRestart = forceRestart,
            )
        ) {
            if (activeCoordinatorPublishedAtMillis != selection.publishedAtMillis) {
                activeCoordinatorPublishedAtMillis = selection.publishedAtMillis
                runCatching {
                    activeCoordinatorTarget = fetchVerifiedPairingTarget(
                        uid = uid,
                        connectionId = connectionId,
                    )
                }.onFailure {
                    Log.w("BurnBar", "Mercury pairing refresh target update failed: ${it.message}")
                }
            }
            Log.i(
                "BurnBar",
                "Mercury coordinator reuse connectionID=$connectionId phase=${existingPhase?.mercuryLogLabel()}",
            )
            return
        }

        rebuildMediaControlCoordinator(uid = uid, selection = selection, existing = existing)
    }
}

private suspend fun BurnBarApplication.rebuildMediaControlCoordinator(
    uid: String,
    selection: IrohPairingSelection.Candidate,
    existing: MediaControlStreamCoordinator?,
) {
    val connectionId = selection.connectionId
    val existingPhase = existing?.phase?.value
    Log.i(
        "BurnBar",
        "Mercury coordinator rebuild connectionID=$connectionId previousPhase=${existingPhase?.mercuryLogLabel() ?: "none"}",
    )
    val target = fetchVerifiedPairingTarget(uid = uid, connectionId = connectionId)
    existing?.stop()
    controlTransportPool.shutdown()
    val dialer = MediaControlStreamCoordinator.StreamDialer { dialedUid, dialedConnection ->
        val dialTarget = activeCoordinatorTarget
            ?: fetchVerifiedPairingTarget(uid = dialedUid, connectionId = dialedConnection)
        dialControlStream(dialTarget)
    }
    val coordinator = MediaControlStreamCoordinator(
        dialer = dialer,
        receiver = BurnBarApplication.fileTransferService,
        controlAuthorityPeerNodeIdProvider = {
            runCatching {
                com.openburnbar.data.computeruse.PhoneControlSigningKeyStore(this@rebuildMediaControlCoordinator)
                    .peerNodeId()
            }.getOrNull()
        },
    )
    BurnBarApplication.mediaControlCoordinator = coordinator
    activeCoordinatorConnection = connectionId
    activeCoordinatorPublishedAtMillis = selection.publishedAtMillis
    activeCoordinatorTarget = target
    BurnBarApplication.fileTransferService?.let { receiver ->
        runCatching {
            coordinator.attachReceiver(receiver)
            receiver.attachControlStream(coordinator)
        }.onFailure { Log.w("BurnBar", "attachControlStream failed: ${it.message}") }
    }
    runCatching { coordinator.start(uid = uid, connectionID = connectionId) }
        .onFailure { Log.w("BurnBar", "MediaControlStreamCoordinator.start failed: ${it.message}") }
}

private fun MediaControlStreamCoordinator.Phase.mercuryLogLabel(): String =
    when (this) {
        MediaControlStreamCoordinator.Phase.Idle -> "idle"
        MediaControlStreamCoordinator.Phase.Dialing -> "dialing"
        MediaControlStreamCoordinator.Phase.Live -> "live"
        is MediaControlStreamCoordinator.Phase.Reconnecting -> "reconnecting"
        MediaControlStreamCoordinator.Phase.Stopped -> "stopped"
        is MediaControlStreamCoordinator.Phase.Failed -> "failed"
    }
