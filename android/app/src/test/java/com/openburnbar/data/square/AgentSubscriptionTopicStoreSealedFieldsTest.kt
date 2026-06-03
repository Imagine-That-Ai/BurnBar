@file:Suppress("MagicNumber")

package com.openburnbar.data.square

import com.google.firebase.firestore.FieldValue
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.assistants.SkillRunEventImportance
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
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Round-trip + privacy-posture tests for the cloaked `subscription_topics`: not
 * only the display text but the GRAPH EDGE (`agentURI` / `topicID`, telling the
 * server which agents the user follows) is sealed, and the doc id is an opaque
 * vault-keyed HMAC. Mirrors `BudgetRuleSealedFieldsTest`:
 *  - sealed `sealedAgentURI` / `sealedTopicID` / `sealedDisplayName` /
 *    `sealedDescription` envelopes decode back with the vault key and never leak
 *    plaintext into the stored map;
 *  - legacy plaintext docs (no sealed field) still decode (migration fallback);
 *  - without a key, sealed fields stay opaque (null), never throwing;
 *  - `documentID` is opaque, deterministic per `(agentURI, topicID, key)`, and
 *    varies by key — so unsubscribe-by-id survives while the server cannot
 *    enumerate the graph.
 *
 * Exercises the top-level `internal` `decodeSubscriptionTopicDisplay` /
 * `decodeSubscriptionTopicGraph` seams, which the production listener decode
 * (`decodeFirestoreTopic`) delegates to, so there is zero drift between the test
 * and the real code path. `android.util.Base64` is stubbed to JDK Base64.
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
    fun sealedSubscriptionTopicPayloadWritesNoPlaintextGraphOrDisplayText() {
        val topic =
            AgentSubscriptionTopic(
                agentURI = "agent://burnbar/research-scout",
                topicID = "agent-updates",
                displayName = "Research Scout updates",
                description = "Digests from Research Scout.",
                cadence = SubscriptionCadence.WEEKLY,
                muted = false,
                deliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
                minimumEventImportance = SkillRunEventImportance.NORMAL,
                createdAtEpoch = 1_700_000_000_000,
            )

        val payload = sealedSubscriptionTopicPayload(topic, vaultKey)

        // The graph edge AND the display text are sealed.
        assertTrue(payload.containsKey("sealedAgentURI"))
        assertTrue(payload.containsKey("sealedTopicID"))
        assertTrue(payload.containsKey("sealedDisplayName"))
        assertTrue(payload.containsKey("sealedDescription"))
        // Merge writes actively delete every legacy plaintext copy.
        assertTrue(payload["agentURI"] is FieldValue)
        assertTrue(payload["topicID"] is FieldValue)
        assertTrue(payload["displayName"] is FieldValue)
        assertTrue(payload["description"] is FieldValue)
        // Nothing identifying the followed agent appears verbatim.
        assertFalse(
            payload.values.any {
                it == topic.agentURI || it == topic.topicID ||
                    it == topic.displayName || it == topic.description
            },
        )
    }

    @Test
    fun decodeOpensSealedGraphEdge() {
        val data: Map<String, Any?> =
            mapOf(
                "sealedAgentURI" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("agent://burnbar/research-scout", vaultKey)),
                "sealedTopicID" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("agent-updates", vaultKey)),
                "cadence" to "weekly",
            )

        val (agentURI, topicID) = decodeSubscriptionTopicGraph(data, vaultKey)
        assertEquals("agent://burnbar/research-scout", agentURI)
        assertEquals("agent-updates", topicID)
        // The followed agent never appeared verbatim in the stored doc.
        assertFalse(data.values.any { it == "agent://burnbar/research-scout" || it == "agent-updates" })
    }

    @Test
    fun decodeGraphFallsBackToLegacyPlaintext() {
        val data: Map<String, Any?> =
            mapOf(
                "agentURI" to "agent://burnbar/legacy",
                "topicID" to "agent-updates",
            )
        val (agentURI, topicID) = decodeSubscriptionTopicGraph(data, vaultKey)
        assertEquals("agent://burnbar/legacy", agentURI)
        assertEquals("agent-updates", topicID)
    }

    @Test
    fun decodeGraphWithoutKeyKeepsSealedOpaque() {
        val sealedOnly: Map<String, Any?> =
            mapOf(
                "sealedAgentURI" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("agent://burnbar/hidden", vaultKey)),
                "sealedTopicID" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("agent-updates", vaultKey)),
            )
        // No key, no legacy plaintext: the graph edge stays invisible.
        val (agentURI, topicID) = decodeSubscriptionTopicGraph(sealedOnly, vaultKey = null)
        assertNull(agentURI)
        assertNull(topicID)
    }

    @Test
    fun documentIDIsOpaqueDeterministicAndKeyVarying() {
        val keyB = ByteArray(32) { 0x17.toByte() }
        val id1 =
            AgentSubscriptionTopicStore.documentID("agent://burnbar/research-scout", "agent-updates", vaultKey)
        val id2 =
            AgentSubscriptionTopicStore.documentID("agent://burnbar/research-scout", "agent-updates", vaultKey)
        val idOtherKey =
            AgentSubscriptionTopicStore.documentID("agent://burnbar/research-scout", "agent-updates", keyB)

        // Deterministic → unsubscribe-by-id and upsert idempotency survive.
        assertEquals(id1, id2)
        // Different vault key → unrelated id.
        assertFalse(id1 == idOtherKey)
        // Opaque: nothing about the followed agent leaks into the id.
        assertTrue(id1.startsWith("sub_"))
        assertFalse(id1.contains("research-scout"))
        assertFalse(id1.contains("burnbar"))
    }

    @Test
    fun documentIDMatchesCrossPlatformGoldenVector() {
        // Locked interop vector — the IDENTICAL assertion guards the iOS
        // `CloudVaultCrypto.subscriptionDocID` test. HKDF<SHA256>(0x5A*32,
        // salt = ∅, info = "subscription-topic") → HMAC<SHA256>(
        // "agent://burnbar/research-scout:agent-updates"), first 16 bytes hex.
        val id =
            AgentSubscriptionTopicStore.documentID("agent://burnbar/research-scout", "agent-updates", vaultKey)
        assertEquals("sub_64ad3397dff90692866fcdaf93e3c028", id)
    }

    @Test
    fun legacyCleartextDocumentIDsCoverKnownPreCloakVariants() {
        val ids =
            AgentSubscriptionTopicStore.legacyCleartextDocumentIDs(
                "agent://burnbar/research-scout",
                "agent-updates",
            )
        assertTrue(ids.contains("agent:__burnbar_research-scout:agent-updates"))
        assertTrue(ids.contains("agent___burnbar_research-scout_agent-updates"))
        assertTrue(ids.contains("agent_burnbar_research-scout_agent-updates"))
        assertFalse(ids.any { it.contains("/") })
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
