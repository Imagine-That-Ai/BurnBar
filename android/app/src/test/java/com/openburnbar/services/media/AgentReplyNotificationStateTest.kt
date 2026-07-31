package com.openburnbar.services.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AgentReplyNotificationStateTest {
    @Test
    fun `escrow cross-reference publishes the escrow trust identity`() {
        val payload = mutableMapOf<String, Any>("deviceId" to "presence-id")

        AgentReplyNotificationState.applyEscrowCrossReference(payload) { "android-abc123" }

        assertEquals("android-abc123", payload["escrowDeviceId"])
        assertEquals("presence-id", payload["deviceId"])
    }

    @Test
    fun `escrow cross-reference stays best-effort when the keypair is unavailable`() {
        val payload = mutableMapOf<String, Any>("deviceId" to "presence-id")

        AgentReplyNotificationState.applyEscrowCrossReference(payload) {
            error("Cloud Vault keypair unavailable")
        }

        assertFalse(payload.containsKey("escrowDeviceId"))
        assertEquals(mapOf<String, Any>("deviceId" to "presence-id"), payload)
    }

    @Test
    fun `escrow cross-reference with the production loader never throws off-device`() {
        val payload = mutableMapOf<String, Any>("deviceId" to "presence-id")

        // On the local JVM the Cloud Vault keypair (Android app context + keystore) is
        // unavailable; the production loader must fail soft and leave the payload untouched.
        AgentReplyNotificationState.applyEscrowCrossReference(payload)

        assertFalse(payload.containsKey("escrowDeviceId"))
    }
}
