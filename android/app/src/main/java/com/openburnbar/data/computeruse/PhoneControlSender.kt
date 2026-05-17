package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntent
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind

class PhoneControlSender(
    private val uid: String,
    private val connectionId: String,
    private val peerNodeId: String,
    private val privateKeySeedProvider: () -> ByteArray?,
    private val counterStore: PhoneControlCounterStore,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
    private val frameSink: suspend (HermesRealtimeRelayFrame) -> Unit,
) {
    sealed class SendError(message: String) : RuntimeException(message) {
        object SigningKeyMissing : SendError("phone-control signing key missing")
    }

    suspend fun send(intent: PhoneControlIntent): PhoneControlAuthorityEnvelope {
        val privateKeySeed = privateKeySeedProvider() ?: throw SendError.SigningKeyMissing
        val counter = counterStore.nextCounter(peerNodeId)
        val timestampMillis = nowMillis()
        val authority = PhoneControlSigner.sign(
            intent = intent,
            peerNodeId = peerNodeId,
            counter = counter,
            timestampMillis = timestampMillis,
            privateKeySeed = privateKeySeed,
        )
        val relayAuthority = authority.toRelayAuthority()
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
            uid = uid,
            connectionId = connectionId,
            control = HermesRealtimeRelayControlPayload(
                streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                inputIntent = intent.toRelayIntent(relayAuthority),
            ),
        )
        frameSink(frame)
        return authority
    }

    private fun PhoneControlAuthorityEnvelope.toRelayAuthority(): HermesRealtimeRelayAuthorityEnvelope =
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = peerNodeId,
            counter = counter,
            timestamp = swiftDateReferenceSeconds,
            intentHashBlake3 = intentHashBlake3,
            signatureEd25519 = signatureEd25519,
        )

    private fun PhoneControlIntent.toRelayIntent(
        authority: HermesRealtimeRelayAuthorityEnvelope,
    ): HermesRealtimeRelayInputIntent =
        HermesRealtimeRelayInputIntent(
            kind = when (kind) {
                PhoneControlIntentKind.TAP -> HermesRealtimeRelayInputIntentKind.TAP
                PhoneControlIntentKind.DRAG_START -> HermesRealtimeRelayInputIntentKind.DRAG_START
                PhoneControlIntentKind.DRAG_MOVE -> HermesRealtimeRelayInputIntentKind.DRAG_MOVE
                PhoneControlIntentKind.DRAG_END -> HermesRealtimeRelayInputIntentKind.DRAG_END
                PhoneControlIntentKind.TYPE -> HermesRealtimeRelayInputIntentKind.TYPE
                PhoneControlIntentKind.SHORTCUT -> HermesRealtimeRelayInputIntentKind.SHORTCUT
                PhoneControlIntentKind.SCROLL -> HermesRealtimeRelayInputIntentKind.SCROLL
                PhoneControlIntentKind.PANIC -> HermesRealtimeRelayInputIntentKind.PANIC
            },
            normalizedX = normalizedX,
            normalizedY = normalizedY,
            normalizedX2 = normalizedX2,
            normalizedY2 = normalizedY2,
            text = text,
            key = key,
            modifiers = modifiers,
            authority = authority,
        )
}

interface PhoneControlCounterStore {
    fun nextCounter(peerNodeId: String): Long
}

class InMemoryPhoneControlCounterStore(
    initialCounters: Map<String, Long> = emptyMap(),
) : PhoneControlCounterStore {
    private val counters = initialCounters.toMutableMap()

    override fun nextCounter(peerNodeId: String): Long {
        val next = (counters[peerNodeId] ?: 0L) + 1L
        counters[peerNodeId] = next
        return next
    }
}
