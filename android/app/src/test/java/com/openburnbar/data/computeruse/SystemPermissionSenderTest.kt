package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionAction
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class SystemPermissionSenderTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }

    @Test
    fun sendWritesSignedSystemPermissionFrame() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )

        val signedWire = sender.send(
            PhoneControlSystemPermissionRequest(
                requestId = "req-1",
                kind = PhoneControlSystemPermissionKind.SCREEN_RECORDING,
                action = PhoneControlSystemPermissionAction.PROMPT_AND_OPEN_SETTINGS,
                bundleId = null,
                originatingToolCallId = "tool-call-1",
                originatingToolName = "screencapture",
                clientIntentId = "intent-1",
                requestedAtMillis = 1_700_000_000_000L,
            ),
        )

        assertEquals(1, frames.size)
        val frame = frames.single()
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_SYSTEM_PERMISSION_REQUEST, frame.type)
        val request = frame.control?.systemPermissionRequest
        assertNotNull(request)
        assertEquals(HermesRealtimeRelaySystemPermissionKind.SCREEN_RECORDING, request?.kind)
        assertEquals(HermesRealtimeRelaySystemPermissionAction.PROMPT_AND_OPEN_SETTINGS, request?.action)
        assertEquals("tool-call-1", request?.originatingToolCallId)
        assertEquals("screencapture", request?.originatingToolName)
        assertEquals("android-phone-1", request?.authority?.peerNodeId)
        assertEquals(signedWire.authority.intentHashBlake3, request?.authority?.intentHashBlake3)
    }
}
