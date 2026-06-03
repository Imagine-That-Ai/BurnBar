@file:Suppress("MagicNumber")

package com.openburnbar.data.square

import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.CloudVaultSealedTextCodec
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Round-trip + privacy-posture tests for the sealed `subscription_topics` display
 * text (`displayName` / `description` — the subscription graph echoing which agent
 * the user follows). Mirrors `BudgetRuleSealedFieldsTest`:
 *  - sealed `sealedDisplayName` / `sealedDescription` envelopes decode back with
 *    the vault key and never leak plaintext into the stored map;
 *  - legacy plaintext docs (no sealed field) still decode (migration fallback);
 *  - without a key, sealed fields stay opaque (null), never throwing.
 *
 * Exercises the top-level `internal` `decodeSubscriptionTopicDisplay` seam, which
 * the production listener decode (`decodeFirestoreTopic`) delegates to, so there is
 * zero drift between the test and the real code path. `android.util.Base64` is
 * stubbed to JDK Base64.
 */
class AgentSubscriptionTopicStoreSealedFieldsTest {
    private val vaultKey = ByteArray(32) { 0x5A.toByte() }

    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    @Test
    fun decodeOpensSealedDisplayNameAndDescription() {
        val data: Map<String, Any?> =
            mapOf(
                "agentURI" to "agent://burnbar/research-scout",
                "topicID" to "agent-updates",
                "sealedDisplayName" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Research Scout updates", vaultKey)),
                "sealedDescription" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Digests from Research Scout.", vaultKey)),
                "cadence" to "weekly",
            )

        val (displayName, description) = decodeSubscriptionTopicDisplay(data, vaultKey)
        assertEquals("Research Scout updates", displayName)
        assertEquals("Digests from Research Scout.", description)
        // The agent the user follows never appeared verbatim in the stored doc.
        assertFalse(data.values.any { it == "Research Scout updates" || it == "Digests from Research Scout." })
    }

    @Test
    fun decodeFallsBackToLegacyPlaintext() {
        val data: Map<String, Any?> =
            mapOf(
                "agentURI" to "agent://burnbar/legacy",
                "displayName" to "Legacy updates",
                "description" to "Legacy description",
            )

        val (displayName, description) = decodeSubscriptionTopicDisplay(data, vaultKey)
        assertEquals("Legacy updates", displayName)
        assertEquals("Legacy description", description)
    }

    @Test
    fun decodeWithoutKeyKeepsSealedOpaqueButLegacyWorks() {
        val sealedOnly: Map<String, Any?> =
            mapOf(
                "sealedDisplayName" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Hidden", vaultKey)),
            )
        // No key: sealed display name cannot open and there is no legacy plaintext.
        val (displayName, description) = decodeSubscriptionTopicDisplay(sealedOnly, vaultKey = null)
        assertNull(displayName)
        assertNull(description)

        // Legacy plaintext still resolves even without a key.
        val legacy: Map<String, Any?> = mapOf("displayName" to "Plain", "description" to "Desc")
        assertEquals("Plain" to "Desc", decodeSubscriptionTopicDisplay(legacy, vaultKey = null))
    }
}
