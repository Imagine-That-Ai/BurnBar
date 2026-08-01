package com.openburnbar

import android.util.Log
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.media.MediaControlStreamCoordinator
import kotlinx.coroutines.sync.withLock

internal fun durableAndroidPeerDeviceId(deviceId: String): String {
    val normalized = deviceId.trim()
    require(normalized.startsWith("android-") && normalized.length > "android-".length) {
        "Mercury requires this installation's durable Android escrow device identity."
    }
    return normalized
}

internal fun canReuseVerifiedCoordinatorTarget(
    cachedConnectionID: String?,
    cachedPublishedAtMillis: Long?,
    cachedTargetPresent: Boolean,
    selection: IrohPairingSelection.Candidate,
): Boolean = cachedTargetPresent &&
    cachedConnectionID == selection.connectionId &&
    cachedPublishedAtMillis == selection.publishedAtMillis

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
            activeCoordinatorUid == uid &&
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
    val cachedTarget = activeCoordinatorTarget
    val target =
        if (
            canReuseVerifiedCoordinatorTarget(
                cachedConnectionID = activeCoordinatorConnection,
                cachedPublishedAtMillis = activeCoordinatorPublishedAtMillis,
                cachedTargetPresent = cachedTarget != null,
                selection = selection,
            )
        ) {
            Log.i("BurnBar", "Mercury coordinator rebuild reusing verified target connectionID=$connectionId")
            checkNotNull(cachedTarget)
        } else {
            fetchVerifiedPairingTarget(uid = uid, connectionId = connectionId)
        }
    existing?.stop()
    // A coordinator rebuild replaces only the control bi-stream. The retained
    // transport owns the shared native endpoint and controller-route identity;
    // shutting it down here invalidates unrelated iroh work and can leave the
    // replacement coordinator with EndpointNotInitialized.
    val dialer = MediaControlStreamCoordinator.StreamDialer { dialedUid, dialedConnection ->
        val dialTarget = activeCoordinatorTarget
            ?: fetchVerifiedPairingTarget(uid = dialedUid, connectionId = dialedConnection)
        dialControlStream(
            uid = dialedUid,
            connectionId = dialedConnection,
            target = dialTarget,
        )
    }
    val coordinator = MediaControlStreamCoordinator(
        dialer = dialer,
        receiver = BurnBarApplication.fileTransferService,
        peerDeviceIdProvider = {
            durableAndroidPeerDeviceId(AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId)
        },
        controlAuthorityPeerNodeIdProvider = {
            runCatching {
                com.openburnbar.data.computeruse.PhoneControlSigningKeyStore(this@rebuildMediaControlCoordinator)
                    .peerNodeId()
            }.getOrNull()
        },
        sessionGrantChallengeHandler = { delivery ->
            BurnBarApplication.sessionGrantChallengeReceiver?.ingest(delivery)
        },
        // F7: every mirror request negotiates the per-frame media seal —
        // default-off behind computer_use_media_frame_aead_enabled AND the
        // Mac advertising media_frame_aead_v1 in its heartbeat reply.
        mediaSealSessionFactory = { sealUid, sealConnectionID, viewerId, macCapabilities ->
            com.openburnbar.data.media.MediaSealSessionEstablisher.establishIfNegotiated(
                uid = sealUid,
                connectionId = sealConnectionID,
                viewerId = viewerId,
                macCapabilities = macCapabilities,
            )
        },
    )
    BurnBarApplication.mediaControlCoordinator = coordinator
    activeCoordinatorUid = uid
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

private fun MediaControlStreamCoordinator.Phase.mercuryLogLabel(): String = when (this) {
    MediaControlStreamCoordinator.Phase.Idle -> "idle"
    MediaControlStreamCoordinator.Phase.Dialing -> "dialing"
    MediaControlStreamCoordinator.Phase.Live -> "live"
    is MediaControlStreamCoordinator.Phase.Reconnecting -> "reconnecting"
    MediaControlStreamCoordinator.Phase.Stopped -> "stopped"
    is MediaControlStreamCoordinator.Phase.Failed -> "failed"
}
