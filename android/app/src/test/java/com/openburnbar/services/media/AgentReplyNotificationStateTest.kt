package com.openburnbar.services.media

import com.openburnbar.data.policy.MobileNavigationDecision
import com.openburnbar.data.policy.MobileOsIntegrationPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    @Test
    fun persistAndRebindSurviveProcessLocalStore() {
        val store = mutableMapOf<String, String>()
        AgentReplyNotificationState.persistConsumedTo(store, "evt-1", "uid-a")
        AgentReplyNotificationState.bindConsumedFrom(emptyMap(), "uid-a")
        assertEquals(null, AgentReplyNotificationState.lastConsumedEventId)
        val rebound = AgentReplyNotificationState.bindConsumedFrom(store, "uid-a")
        assertEquals("evt-1", rebound)
        assertEquals("evt-1", AgentReplyNotificationState.lastConsumedEventId)
        AgentReplyNotificationState.bindConsumedFrom(store, "uid-b")
        assertEquals(null, AgentReplyNotificationState.lastConsumedEventId)
    }

    @Test
    fun incomingCallResolverIgnoresFcmConnectionId() {
        val payload = mapOf(
            "type" to "media_incoming_call",
            "connection_id" to "fcm-forged",
            "correlation_id" to "corr-1",
        )
        assertEquals(null, IncomingCallPayloadPolicy.connectionIdFromPush(payload))
        assertEquals("corr-1", IncomingCallPayloadPolicy.correlationId(payload))
        val routed = kotlinx.coroutines.runBlocking {
            IncomingCallPayloadPolicy.resolveConnectionId(payload) { "ctx-conn" }
        }
        assertEquals("ctx-conn", routed)
    }

    @Test
    fun tombstoneDoesNotClearReboundLastConsumed() {
        val store = mutableMapOf<String, String>()
        AgentReplyNotificationState.persistConsumedTo(store, "evt-b", "uid-b")
        AgentReplyNotificationState.bindConsumedFrom(store, "uid-b")
        assertEquals("evt-b", AgentReplyNotificationState.lastConsumedEventId)
        assertFalse(AgentReplyNotificationState.shouldClearLastConsumed("uid-a", "uid-b"))
        if (AgentReplyNotificationState.shouldClearLastConsumed("uid-a", "uid-b")) {
            AgentReplyNotificationState.bindConsumedFrom(emptyMap(), null)
        }
        assertEquals("evt-b", AgentReplyNotificationState.lastConsumedEventId)
    }

    @Test
    fun heartbeatDoesNotClearTombstoneOrRewriteToken() {
        AgentReplyNotificationState.markTombstonedForTest("uid-a")
        val payload = mutableMapOf<String, Any>("deviceId" to "dev")
        AgentReplyNotificationState.applyLiveTokenFields(
            uid = "uid-a",
            payload = payload,
            clearInvalidation = false,
        )
        assertFalse(payload.containsKey("pushTokenInvalidatedAtMillis"))
        assertFalse(payload.containsKey("fcm_token"))
        AgentReplyNotificationState.clearTombstoneForTest()
    }

    @Test
    fun leftoverPushAfterAccountSwitchIsIgnored() {
        val decision =
            com.openburnbar.MobileOsIntentNavigation.navigation(
                payload =
                mapOf(
                    "type" to "agent_reply",
                    "event_id" to "evt-a",
                    "uid" to "uid-a",
                    "expires_at_millis" to "9999999999999",
                    "deep_link" to "burnbar://assistants/hermes?threadId=thr-a",
                    "runtime" to "hermes",
                    "thread_id" to "thr-a",
                ),
                activeUid = "uid-b",
                lastConsumedEventId = null,
            )
        assertEquals(
            MobileNavigationDecision.IGNORE_ACCOUNT_MISMATCH,
            decision,
        )
    }

    @Test
    fun `same-thread foreground reply is suppressed`() {
        assertTrue(
            MobileOsIntegrationPolicy.shouldSuppressForegroundSameThread(
                foreground = true,
                activeRuntime = "hermes",
                activeThreadId = "thr_1",
                payloadRuntime = "hermes",
                payloadThreadId = "thr_1",
            ),
        )
        assertFalse(
            MobileOsIntegrationPolicy.shouldSuppressForegroundSameThread(
                foreground = true,
                activeRuntime = "hermes",
                activeThreadId = "thr_1",
                payloadRuntime = "hermes",
                payloadThreadId = "thr_other",
            ),
        )
    }
}
