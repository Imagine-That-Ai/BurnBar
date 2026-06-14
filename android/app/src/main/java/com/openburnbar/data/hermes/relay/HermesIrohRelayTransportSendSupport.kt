
package com.openburnbar.data.hermes.relay

import android.util.Base64
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayPayload
import java.util.UUID
import org.json.JSONObject

internal data class IrohRelaySendFrames(
    val requestId: String,
    val symmetricKey: ByteArray,
    val startFrame: HermesRealtimeRelayFrame,
)

internal fun buildIrohRelaySendFrames(payload: HermesRelayPayload, uid: String, relayPubBytes: ByteArray): IrohRelaySendFrames {
    val requestId = "iroh_${UUID.randomUUID().toString().lowercase()}"
    val symmetricKey = HermesRelayCrypto.generateSymmetricKey()
    val bodyString = payload.body?.let { String(it, Charsets.UTF_8) }
    val plaintext =
        JSONObject().apply {
            put("path", payload.path)
            payload.sessionID?.let { put("sessionId", it) }
            bodyString?.let { put("body", it) }
        }.toString().toByteArray(Charsets.UTF_8)
    val requestAad = HermesRelayCrypto.requestAAD(uid, payload.connectionID, requestId)
    val keyAad = HermesRelayCrypto.keyAAD(uid, payload.connectionID, requestId)
    val payloadCiphertextB64 = HermesRelayCrypto.sealToBase64(plaintext, symmetricKey, requestAad)
    val wrappedKeyB64 = HermesRelayCrypto.wrapSymmetricKey(symmetricKey, relayPubBytes, keyAad)
    val startFrame =
        HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REQUEST_START,
            uid = uid,
            connectionId = payload.connectionID,
            requestId = requestId,
            payload =
            HermesRealtimeRelayPayload(
                operation = payload.operation,
                method = payload.method,
                payloadCiphertext = payloadCiphertextB64,
                wrappedKey = wrappedKeyB64,
                relayEncryption = payload.relayEncryption,
                relayKeyVersion = payload.relayKeyVersion ?: HermesRelayCrypto.KEY_VERSION,
            ),
        )
    return IrohRelaySendFrames(requestId = requestId, symmetricKey = symmetricKey, startFrame = startFrame)
}

internal fun decodeRelayPublicKeyBytes(relayPublicKeyB64: String): ByteArray = Base64.decode(relayPublicKeyB64, Base64.NO_WRAP)
