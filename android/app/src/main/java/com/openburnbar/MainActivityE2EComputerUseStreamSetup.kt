package com.openburnbar

import com.openburnbar.data.computeruse.InMemoryPhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.HermesIrohRelayTransport
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.IrohPairingPublisher
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport

internal object MainActivityE2EComputerUseStreamSetup {
    suspend fun openVerifiedStream(activity: MainActivity, uid: String, connectionId: String): StreamSession {
        val pairingPublicKey = FirestoreIrohPairingPublicKeyProvider().fetchPublicKey(uid)
        val target =
            IrohPairingPublisher(FirestoreIrohPairingDirectory()).fetchAndVerify(
                uid = uid,
                connectionId = connectionId,
                publicKey = pairingPublicKey,
            )
        MainActivityE2EComputerUseLogging.computerUseProofLog("pairing_verified node=${target.nodeId}")

        val transport =
            HermesIrohRelayTransport.defaultTransport(
                keyStore = HermesRelayKeyStore(activity.applicationContext),
                relayURL = target.relayURL,
            )
        transport.start()
        val stream = transport.connect(target, timeoutMillis = MainActivityE2EConstants.COMPUTER_USE_DIAL_TIMEOUT_MILLIS)
        MainActivityE2EComputerUseLogging.computerUseProofLog("dial_opened connection=$connectionId")
        return StreamSession(transport, stream)
    }

    suspend fun publishPhoneControlAuthority(activity: MainActivity, uid: String, connectionId: String, keyStore: PhoneControlSigningKeyStore) {
        val publicKey = keyStore.publicKey()
        val peerNodeId = keyStore.peerNodeId()
        val deviceId = MainActivityE2EComputerUseLogging.androidDeviceIdForComputerUseProof(activity)
        val authority =
            PhoneControlAuthorityDocumentFactory.document(
                connectionId = connectionId,
                deviceId = deviceId,
                publicKey = publicKey,
                publishedAtMillis = System.currentTimeMillis(),
            )
        MainActivityE2EComputerUseLogging.computerUseProofLog(
            "authority_attempt peer=$peerNodeId device=$deviceId keys=${authority.asMap().keys.sorted()}",
        )
        PhoneControlAuthorityPublisher().publish(uid = uid, authority = authority)
        MainActivityE2EComputerUseLogging.computerUseProofLog("authority_published peer=$peerNodeId device=$deviceId")
    }

    fun sendControlClassify(uid: String, connectionId: String, peerNodeId: String, stream: IrohRelayStream) {
        stream.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
                uid = uid,
                connectionId = connectionId,
                control =
                HermesRealtimeRelayControlPayload(
                    streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                    authorityPeerNodeId = peerNodeId,
                ),
            ),
        )
    }

    fun createPhoneControlSender(
        uid: String,
        connectionId: String,
        keyStore: PhoneControlSigningKeyStore,
        stream: IrohRelayStream,
    ): TrackingPhoneControlSender {
        var lastSentFrame: HermesRealtimeRelayFrame? = null
        val sender =
            PhoneControlSender(
                uid = uid,
                connectionId = connectionId,
                peerNodeId = keyStore.peerNodeId(),
                privateKeySeedProvider = { keyStore.privateKeySeed() },
                counterStore = InMemoryPhoneControlCounterStore(),
                frameSink = { frame ->
                    lastSentFrame = frame
                    stream.send(frame)
                },
            )
        return TrackingPhoneControlSender(sender) { lastSentFrame }
    }

    data class StreamSession(
        val transport: IrohRelayTransport,
        val stream: IrohRelayStream,
    )

    class TrackingPhoneControlSender(
        private val delegate: PhoneControlSender,
        private val lastFrameProvider: () -> HermesRealtimeRelayFrame?,
    ) {
        val lastSentFrame: HermesRealtimeRelayFrame?
            get() = lastFrameProvider()

        suspend fun send(intent: PhoneControlIntent) = delegate.send(intent)
    }
}
