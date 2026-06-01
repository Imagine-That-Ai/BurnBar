package com.openburnbar

import android.content.Intent
import android.util.Log
import androidx.lifecycle.lifecycleScope
import com.google.firebase.FirebaseException
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal object MainActivityE2EComputerUseActions {
    fun launchFromIntent(activity: MainActivity, intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(MainActivity.EXTRA_E2E_COMPUTER_USE, false) != true) return
        activity.lifecycleScope.launch {
            try {
                runComputerUseProof(activity, intent)
            } catch (err: FirebaseException) {
                MainActivityE2EComputerUseLogging.computerUseProofLog("failed error=${err.message ?: err.javaClass.simpleName}")
                Log.e(MainActivityE2EConstants.TAG, "Android Computer Use E2E failed: ${err.message}", err)
            }
        }
    }

    private suspend fun runComputerUseProof(activity: MainActivity, intent: Intent) {
        val uid =
            MainActivityE2EAuth.ensureSignedIn(
                intent,
                "Android Computer Use E2E requires the expected Firebase user to already be signed in, or email/password extras.",
            )
        val connectionId =
            intent.getStringExtra(MainActivity.EXTRA_E2E_COMPUTER_USE_CONNECTION_ID)
                ?.takeIf { it.isNotBlank() }
                ?: error("Android Computer Use E2E requires connectionId.")
        MainActivityE2EComputerUseLogging.computerUseProofLog("start uid=$uid connection=$connectionId")

        val streamSession = MainActivityE2EComputerUseStreamSetup.openVerifiedStream(activity, uid, connectionId)
        try {
            val keyStore = PhoneControlSigningKeyStore(activity.applicationContext)
            MainActivityE2EComputerUseStreamSetup.publishPhoneControlAuthority(activity, uid, connectionId, keyStore)
            val approvalJob =
                MainActivityE2EComputerUseApprovalActions.launchIfNeeded(
                    intent,
                    activity.lifecycleScope,
                    uid,
                    connectionId,
                    streamSession.stream,
                )

            MainActivityE2EComputerUseStreamSetup.sendControlClassify(
                uid,
                connectionId,
                keyStore.peerNodeId(),
                streamSession.stream,
            )
            MainActivityE2EComputerUseLogging.computerUseProofLog("classified_live connection=$connectionId")
            approvalJob?.join()

            val burstConfig = MainActivityE2EComputerUseChaosActions.readBurstConfig(intent)
            val sender =
                MainActivityE2EComputerUseStreamSetup.createPhoneControlSender(
                    uid,
                    connectionId,
                    keyStore,
                    streamSession.stream,
                )
            delay(MainActivityE2EConstants.COMPUTER_USE_BURST_WARMUP_MILLIS)
            MainActivityE2EComputerUseChaosActions.runIntentBurst(sender, burstConfig)
            MainActivityE2EComputerUseChaosActions.runReplayChaos(streamSession.stream, burstConfig, sender.lastSentFrame)
            MainActivityE2EComputerUseChaosActions.runTamperChaos(
                streamSession.stream,
                uid,
                connectionId,
                keyStore,
                burstConfig,
            )
            MainActivityE2EComputerUseChaosActions.sendPanicIfRequested(sender, burstConfig.sendPanic)
            if (burstConfig.replayCount > 0 || burstConfig.tamperCount > 0) {
                delay(MainActivityE2EConstants.COMPUTER_USE_CHAOS_SETTLE_MILLIS)
            }
        } finally {
            streamSession.stream.close()
            streamSession.transport.shutdown()
        }
    }
}

internal object MainActivityComputerUseFrameFactory {
    fun intentFrame(
        uid: String,
        connectionId: String,
        intent: com.openburnbar.data.computeruse.PhoneControlIntent,
        authority: com.openburnbar.data.computeruse.PhoneControlAuthorityEnvelope,
    ): com.openburnbar.irohrelay.HermesRealtimeRelayFrame = com.openburnbar.irohrelay.HermesRealtimeRelayFrame(
        type = com.openburnbar.irohrelay.HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
        uid = uid,
        connectionId = connectionId,
        control =
        com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload(
            streamClass = com.openburnbar.data.media.MediaStreamClass.CONTROL_INPUT.raw,
            inputIntent = MainActivityComputerUseInputIntentMapper.map(intent, authority),
        ),
    )
}
