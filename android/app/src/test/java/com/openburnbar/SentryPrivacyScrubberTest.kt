package com.openburnbar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-AND-06 — verifies crash/ANR payload + breadcrumb redaction strips prompt/credential fragments. */
class SentryPrivacyScrubberTest {
    @Test
    fun redactsInlinePromptInExceptionMessage() {
        val scrubbed = SentryPrivacyScrubber.scrubMessage("seal failed prompt='buy 100 shares of ACME' retrying")
        assertTrue(scrubbed!!.contains("prompt="))
        assertTrue(scrubbed.contains(SentryPrivacyScrubber.REDACTED))
        assertFalse(scrubbed.contains("buy 100 shares"))
    }

    @Test
    fun redactsPasswordAndTokenAndBearer() {
        assertFalse(SentryPrivacyScrubber.scrubMessage("password: hunter2")!!.contains("hunter2"))
        assertFalse(SentryPrivacyScrubber.scrubMessage("api_key=sk-secret-123")!!.contains("sk-secret-123"))
        val bearer = SentryPrivacyScrubber.scrubMessage("Authorization Bearer eyJhbGciOi.abc.def")
        assertFalse(bearer!!.contains("eyJhbGciOi"))
        assertTrue(bearer.contains("Bearer ${SentryPrivacyScrubber.REDACTED}"))
    }

    @Test
    fun leavesInnocuousMessageUntouched() {
        val msg = "Mercury iroh transport reconnect attempt 3"
        assertEquals(msg, SentryPrivacyScrubber.scrubMessage(msg))
    }

    @Test
    fun nullMessageStaysNull() {
        assertNull(SentryPrivacyScrubber.scrubMessage(null))
    }

    @Test
    fun sensitiveKeysAreRecognized() {
        assertTrue(SentryPrivacyScrubber.isSensitiveKey("userPrompt"))
        assertTrue(SentryPrivacyScrubber.isSensitiveKey("mac_credential"))
        assertTrue(SentryPrivacyScrubber.isSensitiveKey("VAULT_KEY"))
        assertTrue(SentryPrivacyScrubber.isSensitiveKey("sealedPayload"))
        assertFalse(SentryPrivacyScrubber.isSensitiveKey("connectionId"))
        assertFalse(SentryPrivacyScrubber.isSensitiveKey(null))
    }

    @Test
    fun scrubDataMapDropsSensitiveValuesAndScrubsTextValues() {
        val data =
            mapOf<String, Any?>(
                "prompt" to "delete production",
                "connectionId" to "conn-abc",
                "note" to "password=hunter2 was wrong",
                "retryCount" to 3,
            )
        val scrubbed = SentryPrivacyScrubber.scrubDataMap(data)
        assertEquals(SentryPrivacyScrubber.REDACTED, scrubbed["prompt"])
        assertEquals("conn-abc", scrubbed["connectionId"])
        assertFalse((scrubbed["note"] as String).contains("hunter2"))
        assertEquals(3, scrubbed["retryCount"])
    }
}
