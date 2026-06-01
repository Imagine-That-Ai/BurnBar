package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private const val SHA256_DIGEST_BYTES = 32
private const val VAL_7 = 7

class AgentCapabilityGrantSignerTest {
    @Test
    fun canonicalGrantRequestJsonMatchesSwiftSortedShape() {
        val request = sampleWireRequest()

        assertEquals(
            "{" +
                "\"capabilities\":[\"desktop_file_export\",\"workspace_read\"]," +
                "\"clientIntentId\":\"intent-1\"," +
                "\"deliveryMode\":\"live_then_queued\"," +
                "\"expiresAt\":800000300.123," +
                "\"grantDurationSeconds\":1800," +
                "\"localAuthenticationSatisfied\":true," +
                "\"preset\":\"desktop\"," +
                "\"requestId\":\"request-1\"," +
                "\"requestedAt\":800000000.123," +
                "\"runtime\":\"hermes\"," +
                "\"sourceDeviceId\":\"android-device-1\"," +
                "\"threadId\":\"thread-1\"," +
                "\"trustMode\":\"manual\"" +
                "}",
            PhoneControlSignerCanonicalJson.canonicalAgentGrantRequestJson(request),
        )
    }

    @Test
    fun signedGrantRequestBindsAuthorityToCanonicalHash() {
        val seed = ByteArray(SHA256_DIGEST_BYTES) { index -> (index + 1).toByte() }
        val request = sampleWireRequest()

        val authority =
            PhoneControlSignerSign.signAgentGrantRequest(
                request = request,
                peerNodeId = "android-phone-test",
                counter = 7,
                timestampMillis = 1_700_000_000_123,
                privateKeySeed = seed,
            )

        assertEquals(VAL_7, authority.counter)
        assertEquals(
            PhoneControlSigner.canonicalAgentGrantRequestHashHex(request),
            authority.intentHashBlake3,
        )
        assertTrue(authority.signatureEd25519.isNotBlank())
    }

    private fun sampleWireRequest(): HermesRealtimeRelayAgentGrantRequest = HermesRealtimeRelayAgentGrantRequest(
        requestId = "request-1",
        runtime = "hermes",
        threadId = "thread-1",
        preset = "desktop",
        capabilities = listOf("workspace_read", "desktop_file_export"),
        trustMode = "manual",
        deliveryMode = "live_then_queued",
        requestedAt = 800000000.123,
        expiresAt = 800000300.123,
        grantDurationSeconds = 1800.0,
        sourceDeviceId = "android-device-1",
        clientIntentId = "intent-1",
        localAuthenticationSatisfied = true,
        authority =
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId = "",
            counter = 0,
            timestamp = 800000000.123,
            intentHashBlake3 = "",
            signatureEd25519 = "",
        ),
    )
}
