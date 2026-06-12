package com.openburnbar.data.computeruse

import com.openburnbar.data.hermes.relay.RelaySealSenderIdentity
import com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.wireValue
import java.util.concurrent.ConcurrentHashMap

/**
 * F10 — phone-side control-seal session establishment plus the sealing frame
 * sink, shared by every [PhoneControlSender] call site so the negotiation,
 * key wrap, and seal behavior cannot drift between surfaces. Android mirror
 * of the iOS `ControlSealSessionEstablisher`
 * (`OpenBurnBarMobile/Services/ComputerUse/ControlSealSessionEstablisher.swift`).
 *
 * Default-off: [ControlFrameSealNegotiation.REMOTE_CONFIG_KEY] resolves to
 * `false` until a fetch-and-activate ramp lands (and on any Firebase
 * initialization failure, e.g. unit tests), so the gate fails closed in every
 * environment — flags off ⇒ no establishment ⇒ emitted bytes identical to the
 * legacy lane.
 */
object ControlSealSessionEstablisher {
    data class Session(
        val envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        val key: ByteArray,
        val controllerPeerNodeId: String,
    )

    /**
     * F10 — sessions by connection id. The Mac keys its open-side session the
     * same way, so any sender on the same connection (inline agent mirror,
     * remote-unlock credentials) can reuse the session the classify-time
     * establishment created instead of sealing under a key the Mac never saw.
     */
    private val sessionsByConnection = ConcurrentHashMap<String, Session>()

    fun activeSession(connectionId: String): Session? = sessionsByConnection[connectionId]

    /** Exposed for the establishment path + tests. */
    fun register(session: Session, connectionId: String) {
        sessionsByConnection[connectionId] = session
    }

    internal fun clearForTests() = sessionsByConnection.clear()

    /** Default-ON protection flag, same key the iOS client reads; a fetched
     * Remote Config value is the kill switch and always wins. */
    fun remoteConfigEnabled(): Boolean =
        remoteConfigProtectionFlag(ControlFrameSealNegotiation.REMOTE_CONFIG_KEY)

    /**
     * Establish when (and only when) the default-off RC flag is on AND the
     * Mac advertised `control_seal_v1` in its presence-heartbeat capability
     * strings. Returns null — the legacy plaintext-at-app-layer lane —
     * otherwise, or when wrap preparation fails: sealing is defense-in-depth
     * on top of the iroh transport seal, and a phone that cannot establish
     * must not lose remote control. The Mac's HPKE relay recipient key comes
     * from the paired connection record — never from the stream itself.
     */
    suspend fun establishIfNegotiated(
        uid: String,
        connectionId: String,
        controllerPeerNodeId: String,
        macCapabilities: Set<String>,
    ): Session? {
        if (!remoteConfigEnabled()) return null
        if (!ControlFrameSealNegotiation.resolveSealingEnabled(
                localSupports = true,
                remoteSupports = macCapabilities.contains(ControlFrameSealNegotiation.CAPABILITY),
            )
        ) {
            return null
        }
        return runCatching {
            val recipientKey =
                RelaySealSenderIdentity.macRelayPublicKeyBase64(uid = uid, connectionId = connectionId)
                    ?: return null
            val sender =
                RelaySealSenderIdentity.prepareAndPublish(
                    uid = uid,
                    connectionId = connectionId,
                    counterKeyPrefix = RelaySealSenderIdentity.CONTROL_SEAL_COUNTER_PREFIX,
                )
            val established =
                ControlFrameSealSession.establish(
                    uid = uid,
                    connectionId = connectionId,
                    peerNodeId = controllerPeerNodeId,
                    senderDeviceId = sender.senderDeviceId,
                    senderPeerNodeId = sender.senderPeerNodeId,
                    senderKeyId = sender.keyId,
                    senderCounter = sender.senderCounter,
                    recipientPublicKeyBase64 = recipientKey,
                    senderPrivateKey = sender.senderPrivateKey,
                )
            Session(
                envelope = established.envelope,
                key = established.key,
                controllerPeerNodeId = controllerPeerNodeId,
            ).also { register(it, connectionId) }
        }.getOrNull()
    }

    /**
     * Wrap a [PhoneControlSender] frame sink so every outgoing control
     * payload is replaced by its sealed shell (`streamClass` +
     * `sealedFrameBase64` only) before it reaches the stream.
     */
    fun sealingFrameSink(
        base: suspend (HermesRealtimeRelayFrame) -> Unit,
        session: Session,
    ): suspend (HermesRealtimeRelayFrame) -> Unit = { frame ->
        val control = frame.control
        val outbound =
            if (control != null) {
                frame.copy(
                    control =
                    ControlFrameSealSession.sealPayload(
                        payload = control,
                        key = session.key,
                        peerNodeId = session.controllerPeerNodeId,
                        frameType = frame.type.wireValue,
                    ),
                )
            } else {
                frame
            }
        base(outbound)
    }
}
