package com.openburnbar.data.cloud.signalsession

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.IrohRelayStream
import java.util.Base64
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage

data class AndroidSignalSessionReceivedMessage(
    val frame: HermesRealtimeRelayFrame,
    val plaintext: ByteArray,
    val messageType: Int,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AndroidSignalSessionReceivedMessage) return false
        return frame == other.frame &&
            plaintext.contentEquals(other.plaintext) &&
            messageType == other.messageType
    }

    override fun hashCode(): Int {
        var result = frame.hashCode()
        result = 31 * result + plaintext.contentHashCode()
        result = 31 * result + messageType
        return result
    }
}

class AndroidSignalSessionManager(
    private val store: AndroidSignalProtocolStore,
    private val localAddress: SignalProtocolAddress,
) {
    suspend fun establishOutbound(
        claimSignalPrekeyBundle: suspend () -> AndroidSignalClaimedPreKeyBundle,
        plaintext: ByteArray,
        stream: IrohRelayStream,
        uid: String,
        connectionId: String,
        requestId: String? = null,
    ): HermesRealtimeRelayFrame {
        val remote = AndroidSignalRemoteBundleDecoder.decode(claimSignalPrekeyBundle())
        // Constructor-order gotcha: SessionBuilder(store, REMOTE, LOCAL).
        SessionBuilder(store, remote.address, localAddress).process(remote.bundle)
        return send(
            plaintext = plaintext,
            remoteAddress = remote.address,
            stream = stream,
            uid = uid,
            connectionId = connectionId,
            requestId = requestId,
        )
    }

    suspend fun send(
        plaintext: ByteArray,
        remoteAddress: SignalProtocolAddress,
        stream: IrohRelayStream,
        uid: String,
        connectionId: String,
        requestId: String? = null,
    ): HermesRealtimeRelayFrame {
        // Constructor-order gotcha: SessionCipher(store, LOCAL, REMOTE).
        val ciphertext = SessionCipher(store, localAddress, remoteAddress).encrypt(plaintext)
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.SIGNAL_SESSION_MESSAGE,
                uid = uid,
                connectionId = connectionId,
                requestId = requestId,
                signalSessionCiphertextB64 = Base64.getEncoder().encodeToString(ciphertext.serialize()),
                signalMessageType = ciphertext.type,
            )
        stream.send(frame)
        return frame
    }

    suspend fun receive(
        stream: IrohRelayStream,
        remoteAddress: SignalProtocolAddress,
    ): AndroidSignalSessionReceivedMessage {
        val frame = stream.receive() ?: error("Signal session stream closed before a message frame arrived.")
        return decrypt(frame = frame, remoteAddress = remoteAddress)
    }

    fun decrypt(
        frame: HermesRealtimeRelayFrame,
        remoteAddress: SignalProtocolAddress,
    ): AndroidSignalSessionReceivedMessage {
        require(frame.type == HermesRealtimeRelayFrameType.SIGNAL_SESSION_MESSAGE) {
            "Expected signal.session.message frame, received ${frame.type}."
        }
        val ciphertextB64 = requireNotNull(frame.signalSessionCiphertextB64) {
            "Signal session frame is missing ciphertext."
        }
        val messageType = requireNotNull(frame.signalMessageType) {
            "Signal session frame is missing message type."
        }
        val ciphertext = Base64.getDecoder().decode(ciphertextB64)
        val cipher = SessionCipher(store, localAddress, remoteAddress)
        val plaintext =
            when (messageType) {
                CiphertextMessage.PREKEY_TYPE -> cipher.decrypt(PreKeySignalMessage(ciphertext))
                CiphertextMessage.WHISPER_TYPE -> cipher.decrypt(SignalMessage(ciphertext))
                else -> error("Unsupported Signal session message type $messageType.")
            }
        return AndroidSignalSessionReceivedMessage(frame = frame, plaintext = plaintext, messageType = messageType)
    }
}
