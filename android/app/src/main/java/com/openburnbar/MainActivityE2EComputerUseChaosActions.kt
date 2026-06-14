// E2E harness uses literal intent bounds and interval defaults for adb-driven chaos tests.

package com.openburnbar

import android.content.Intent
import com.openburnbar.data.computeruse.PhoneControlAuthorityEnvelope
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSignerSign
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.IrohRelayStream
import kotlinx.coroutines.delay

internal object MainActivityE2EComputerUseChaosActions {
    suspend fun runIntentBurst(sender: MainActivityE2EComputerUseStreamSetup.TrackingPhoneControlSender, config: BurstConfig) {
        MainActivityE2EComputerUseLogging.computerUseProofLog(
            "burst_start count=${config.intentCount} intervalMillis=${config.intervalMillis} sendPanic=${config.sendPanic}",
        )
        for (index in 0 until config.intentCount) {
            val authority = sendBurstIntent(sender, index)
            val kind = if (index % 2 == 0) "tap" else "scroll"
            MainActivityE2EComputerUseLogging.computerUseProofLog("sent_$kind index=${index + 1} counter=${authority.counter}")
            if (config.intervalMillis > 0L) delay(config.intervalMillis)
        }
        MainActivityE2EComputerUseLogging.computerUseProofLog("burst_complete count=${config.intentCount}")
    }

    private suspend fun sendBurstIntent(sender: MainActivityE2EComputerUseStreamSetup.TrackingPhoneControlSender, index: Int): PhoneControlAuthorityEnvelope =
        if (index % 2 == 0) {
            sender.send(
                PhoneControlIntent(
                    kind = PhoneControlIntentKind.TAP,
                    normalizedX =
                    MainActivityE2EConstants.COMPUTER_USE_TAP_ORIGIN_NORMALIZED +
                        index % MainActivityE2EConstants.COMPUTER_USE_TAP_MODULO_X *
                        MainActivityE2EConstants.COMPUTER_USE_TAP_OFFSET_STEP,
                    normalizedY =
                    MainActivityE2EConstants.COMPUTER_USE_TAP_ORIGIN_NORMALIZED +
                        index % MainActivityE2EConstants.COMPUTER_USE_TAP_MODULO_Y *
                        MainActivityE2EConstants.COMPUTER_USE_TAP_OFFSET_STEP,
                ),
            )
        } else {
            sender.send(
                PhoneControlIntent(
                    kind = PhoneControlIntentKind.SCROLL,
                    normalizedX = MainActivityE2EConstants.COMPUTER_USE_SCROLL_CENTER_X,
                    normalizedY = MainActivityE2EConstants.COMPUTER_USE_SCROLL_START_Y,
                    normalizedX2 = MainActivityE2EConstants.COMPUTER_USE_SCROLL_CENTER_X,
                    normalizedY2 = MainActivityE2EConstants.COMPUTER_USE_SCROLL_END_Y,
                ),
            )
        }

    suspend fun runReplayChaos(stream: IrohRelayStream, config: BurstConfig, lastSentFrame: HermesRealtimeRelayFrame?) {
        if (config.replayCount <= 0) return
        val replayFrame = lastSentFrame ?: error("replay chaos requires at least one sent frame")
        MainActivityE2EComputerUseLogging.computerUseProofLog("replay_chaos_start count=${config.replayCount}")
        repeat(config.replayCount) { index ->
            stream.send(replayFrame)
            if ((index + 1) % MainActivityE2EConstants.COMPUTER_USE_REPLAY_PROGRESS_INTERVAL == 0) {
                MainActivityE2EComputerUseLogging.computerUseProofLog("replay_chaos_progress count=${index + 1}")
            }
        }
        MainActivityE2EComputerUseLogging.computerUseProofLog("replay_chaos_complete count=${config.replayCount}")
    }

    suspend fun runTamperChaos(stream: IrohRelayStream, uid: String, connectionId: String, keyStore: PhoneControlSigningKeyStore, config: BurstConfig) {
        if (config.tamperCount <= 0) return
        val privateKeySeed =
            keyStore.privateKeySeed()
                ?: error("tamper chaos requires a phone-control private key")
        MainActivityE2EComputerUseLogging.computerUseProofLog("tamper_chaos_start count=${config.tamperCount}")
        for (index in 0 until config.tamperCount) {
            sendTamperedIntent(
                transport =
                TamperedIntentTransport(
                    stream = stream,
                    uid = uid,
                    connectionId = connectionId,
                    keyStore = keyStore,
                ),
                config = config,
                index = index,
                privateKeySeed = privateKeySeed,
            )
            if ((index + 1) % MainActivityE2EConstants.COMPUTER_USE_TAMPER_PROGRESS_INTERVAL == 0) {
                MainActivityE2EComputerUseLogging.computerUseProofLog("tamper_chaos_progress count=${index + 1}")
            }
        }
        MainActivityE2EComputerUseLogging.computerUseProofLog("tamper_chaos_complete count=${config.tamperCount}")
    }

    private data class TamperedIntentTransport(
        val stream: IrohRelayStream,
        val uid: String,
        val connectionId: String,
        val keyStore: PhoneControlSigningKeyStore,
    )

    private fun sendTamperedIntent(transport: TamperedIntentTransport, config: BurstConfig, index: Int, privateKeySeed: ByteArray) {
        val stream = transport.stream
        val uid = transport.uid
        val connectionId = transport.connectionId
        val keyStore = transport.keyStore
        val counter = config.intentCount.toLong() + index + 1L
        val signedIntent =
            PhoneControlIntent(
                kind = PhoneControlIntentKind.TAP,
                normalizedX = MainActivityE2EConstants.COMPUTER_USE_TAMPER_TAP_X,
                normalizedY = MainActivityE2EConstants.COMPUTER_USE_TAMPER_TAP_X,
            )
        val tamperedIntent =
            signedIntent.copy(
                normalizedX =
                MainActivityE2EConstants.COMPUTER_USE_TAMPER_OFFSET_BASE +
                    index % MainActivityE2EConstants.COMPUTER_USE_TAMPER_MODULO *
                    MainActivityE2EConstants.COMPUTER_USE_TAMPER_OFFSET_STEP,
            )
        val authority =
            PhoneControlSignerSign.sign(
                intent = signedIntent,
                peerNodeId = keyStore.peerNodeId(),
                counter = counter,
                timestampMillis = System.currentTimeMillis() + index * config.tamperTimestampStepMillis,
                privateKeySeed = privateKeySeed,
            )
        kotlinx.coroutines.runBlocking {
            stream.send(
                MainActivityComputerUseFrameFactory.intentFrame(
                    uid = uid,
                    connectionId = connectionId,
                    intent = tamperedIntent,
                    authority = authority,
                ),
            )
        }
    }

    suspend fun sendPanicIfRequested(sender: MainActivityE2EComputerUseStreamSetup.TrackingPhoneControlSender, sendPanic: Boolean) {
        if (!sendPanic) return
        val authority = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
        MainActivityE2EComputerUseLogging.computerUseProofLog("sent_panic counter=${authority.counter}")
    }

    fun readBurstConfig(intent: Intent): BurstConfig = BurstConfig(
        intentCount =
        intent.getIntExtra(
            MainActivity.EXTRA_E2E_COMPUTER_USE_INTENT_COUNT,
            MainActivityE2EConstants.COMPUTER_USE_DEFAULT_INTENT_COUNT,
        ).coerceIn(1, MainActivityE2EConstants.COMPUTER_USE_MAX_INTENT_COUNT),
        intervalMillis =
        intent.getLongExtra(
            MainActivity.EXTRA_E2E_COMPUTER_USE_INTENT_INTERVAL_MILLIS,
            MainActivityE2EConstants.COMPUTER_USE_DEFAULT_INTERVAL_MILLIS,
        ).coerceIn(0L, MainActivityE2EConstants.COMPUTER_USE_MAX_INTERVAL_MILLIS),
        sendPanic = intent.getBooleanExtra(MainActivity.EXTRA_E2E_COMPUTER_USE_SEND_PANIC, true),
        replayCount =
        intent.getIntExtra(MainActivity.EXTRA_E2E_COMPUTER_USE_REPLAY_COUNT, 0)
            .coerceIn(0, MainActivityE2EConstants.COMPUTER_USE_MAX_REPLAY_COUNT),
        tamperCount =
        intent.getIntExtra(MainActivity.EXTRA_E2E_COMPUTER_USE_TAMPER_COUNT, 0)
            .coerceIn(0, MainActivityE2EConstants.COMPUTER_USE_MAX_TAMPER_COUNT),
        tamperTimestampStepMillis =
        intent.getLongExtra(MainActivity.EXTRA_E2E_COMPUTER_USE_TAMPER_TIMESTAMP_STEP_MILLIS, 0L)
            .coerceIn(0L, MainActivityE2EConstants.COMPUTER_USE_MAX_TAMPER_TIMESTAMP_STEP_MILLIS),
    )

    data class BurstConfig(
        val intentCount: Int,
        val intervalMillis: Long,
        val sendPanic: Boolean,
        val replayCount: Int,
        val tamperCount: Int,
        val tamperTimestampStepMillis: Long,
    )
}
