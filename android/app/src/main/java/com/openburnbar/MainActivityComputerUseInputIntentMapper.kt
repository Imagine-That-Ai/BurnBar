package com.openburnbar

import com.openburnbar.data.computeruse.PhoneControlAuthorityEnvelope
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntent
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind

internal object MainActivityComputerUseInputIntentMapper {
    fun map(intent: PhoneControlIntent, authority: PhoneControlAuthorityEnvelope): HermesRealtimeRelayInputIntent = HermesRealtimeRelayInputIntent(
        kind = mapKind(intent.kind),
        displayId = intent.displayId,
        normalizedX = intent.normalizedX,
        normalizedY = intent.normalizedY,
        normalizedX2 = intent.normalizedX2,
        normalizedY2 = intent.normalizedY2,
        text = intent.text,
        key = intent.key,
        modifiers = intent.modifiers,
        mouseButton = intent.mouseButton,
        authority =
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = authority.peerNodeId,
            counter = authority.counter,
            timestamp = authority.swiftDateReferenceSeconds,
            intentHashBlake3 = authority.intentHashBlake3,
            signatureEd25519 = authority.signatureEd25519,
            keyKind = authority.keyKind,
        ),
    )

    private fun mapKind(kind: PhoneControlIntentKind): HermesRealtimeRelayInputIntentKind = when (kind) {
        PhoneControlIntentKind.TAP -> HermesRealtimeRelayInputIntentKind.TAP
        PhoneControlIntentKind.DRAG_START -> HermesRealtimeRelayInputIntentKind.DRAG_START
        PhoneControlIntentKind.DRAG_MOVE -> HermesRealtimeRelayInputIntentKind.DRAG_MOVE
        PhoneControlIntentKind.DRAG_END -> HermesRealtimeRelayInputIntentKind.DRAG_END
        PhoneControlIntentKind.TYPE -> HermesRealtimeRelayInputIntentKind.TYPE
        PhoneControlIntentKind.SHORTCUT -> HermesRealtimeRelayInputIntentKind.SHORTCUT
        PhoneControlIntentKind.SCROLL -> HermesRealtimeRelayInputIntentKind.SCROLL
        PhoneControlIntentKind.POINTER_MOVE -> HermesRealtimeRelayInputIntentKind.POINTER_MOVE
        PhoneControlIntentKind.POINTER_CLICK -> HermesRealtimeRelayInputIntentKind.POINTER_CLICK
        PhoneControlIntentKind.PANIC -> HermesRealtimeRelayInputIntentKind.PANIC
    }
}
