package com.openburnbar

import android.util.Log
import com.openburnbar.data.computeruse.AgentCapabilityGrantController
import com.openburnbar.data.computeruse.ComputerUseSessionGrantChallengeReceiver
import com.openburnbar.data.computeruse.ComputerUseSessionGrantNotificationCenter
import com.openburnbar.data.computeruse.ForegroundFragmentActivityTracker
import com.openburnbar.data.media.AndroidFileTransferService
import com.openburnbar.data.media.IrohBlobKeyStore
import com.openburnbar.data.media.MediaFileTransferService
import com.openburnbar.irohrelay.OpenBurnBarIrohBlobFfiBackend
import java.io.File
import java.security.MessageDigest

private const val LOG_CHALLENGE_ID_DIGEST_LENGTH = 16

/**
 * One-way digest used so logs can correlate challenge failures without ever
 * writing any portion of the raw challenge identifier to the log stream.
 */
private fun challengeIdLogDigest(challengeId: String): String = MessageDigest.getInstance("SHA-256")
    .digest(challengeId.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }
    .take(LOG_CHALLENGE_ID_DIGEST_LENGTH)

internal fun BurnBarApplication.installComputerUseSessionGrantReceiver() {
    ForegroundFragmentActivityTracker.install(this)
    val controller = AgentCapabilityGrantController(this)
    val notificationCenter = ComputerUseSessionGrantNotificationCenter(this)
    BurnBarApplication.agentCapabilityGrantController = controller
    BurnBarApplication.sessionGrantChallengeReceiver =
        ComputerUseSessionGrantChallengeReceiver(
            scope = BurnBarApplication.applicationScope,
            foregroundActivityProvider = { challengeId, expiresAtMillis ->
                ForegroundFragmentActivityTracker.current()
                    ?: run {
                        notificationCenter.showPendingChallenge(challengeId, expiresAtMillis)
                        try {
                            ForegroundFragmentActivityTracker.awaitResumedUntil(expiresAtMillis)
                        } finally {
                            notificationCenter.dismissPendingChallenge(challengeId)
                        }
                    }
            },
            grantHandler = { activity, delivery ->
                controller.grant(activity = activity, delivery = delivery)
            },
            failureHandler = { challenge, error ->
                Log.w(
                    "BurnBar",
                    "Session grant challenge failed " +
                        "idSha256=${challengeIdLogDigest(challenge.challengeId)}: ${error.message}",
                )
            },
        )
}

internal fun BurnBarApplication.installFileTransferService() {
    val blobKeyStore = IrohBlobKeyStore(applicationContext)
    val transferService =
        MediaFileTransferService(
            backend = OpenBurnBarIrohBlobFfiBackend(),
            configuration =
            MediaFileTransferService.Configuration(
                storeDirectory = File(filesDir, "mercury_blob_store"),
                inboxDirectory = File(filesDir, "mercury_blob_inbox"),
                secretKeyProvider = { blobKeyStore.secretKeyMaterial() },
            ),
        )
    registerFileTransferService(
        AndroidFileTransferService(
            appContext = applicationContext,
            service = transferService,
            settingsProvider = {
                getSharedPreferences("mercury_media", android.content.Context.MODE_PRIVATE)
                    .getBoolean("media_blob_transfer_enabled", true)
            },
        ),
    )
}
