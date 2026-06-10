@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; epoch
// fixtures are literal by design.

package com.openburnbar.data.firebase

import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.openburnbar.data.models.BudgetEvent
import io.mockk.every
import io.mockk.mockk
import java.util.Date
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure-decoder tests for the [FirestoreRepository] file: the tolerant
 * [FirestoreValueParsers] value coercions, the budget-event wire codec, and
 * the [CloudVaultSealedTextCodec] envelope validation that gates the
 * sealed-or-legacy fallback. (The sealed-field crypto behavior itself is
 * pinned by `BudgetRuleSealedFieldsTest`.)
 */
class FirestoreRepositoryTest {
    // ── FirestoreValueParsers ──

    @Test
    fun `millis coerces every wire representation firestore can return`() {
        // Timestamp carries seconds + nanos; only whole millis survive.
        assertEquals(1_700_000_000_123L, FirestoreValueParsers.millis(Timestamp(1_700_000_000L, 123_999_999)))
        assertEquals(42L, FirestoreValueParsers.millis(42L))
        assertEquals(42L, FirestoreValueParsers.millis(42.0))
        assertEquals(1_700_000_000_000L, FirestoreValueParsers.millis(Date(1_700_000_000_000L)))
        assertEquals(0L, FirestoreValueParsers.millis("not-a-date"))
        assertEquals(0L, FirestoreValueParsers.millis("   "))
        assertEquals(0L, FirestoreValueParsers.millis(null))
        assertEquals(0L, FirestoreValueParsers.millis(mapOf("nested" to true)))
    }

    @Test
    fun `string skips blank candidates and falls through key aliases`() {
        val data = mapOf("projectName" to "   ", "project_name" to "legacy-name")
        assertEquals("legacy-name", FirestoreValueParsers.string(data, "projectName", "project_name"))
        assertNull(FirestoreValueParsers.string(mapOf("projectName" to 7), "projectName"))
    }

    // ── BudgetEvent codec ──

    @Test
    fun `toBudgetEvent decodes a full document and tolerates bad numerics`() {
        val occurredAt = Date(1_700_000_000_000L)
        val snapshot = mockk<DocumentSnapshot>()
        every { snapshot.id } returns "evt-1"
        every { snapshot.data } returns mapOf(
            "ruleID" to "rule-1",
            "kind" to "warning",
            "source" to "daemon",
            // Firestore returns Long for whole numbers.
            "amountAtEvent" to 12L,
            "limitAtEvent" to 20.5,
            "detailJSON" to """{"threshold":0.8}""",
            "occurredAt" to Timestamp(occurredAt),
            "sourceDeviceID" to "mac-1",
        )

        val event = requireNotNull(snapshot.toBudgetEvent())
        assertEquals("evt-1", event.id)
        assertEquals("rule-1", event.ruleID)
        assertEquals("warning", event.kind)
        assertEquals("daemon", event.source)
        assertEquals(12.0, event.amountAtEvent, 0.0)
        assertEquals(20.5, event.limitAtEvent, 0.0)
        assertEquals("""{"threshold":0.8}""", event.detailJSON)
        assertEquals(occurredAt, event.occurredAt)
        assertNull(event.syncedAt)
        assertEquals("mac-1", event.sourceDeviceID)
    }

    @Test
    fun `toBudgetEvent returns null for a document without data and defaults missing fields`() {
        val empty = mockk<DocumentSnapshot>()
        every { empty.id } returns "evt-x"
        every { empty.data } returns null
        assertNull(empty.toBudgetEvent())

        val sparse = mockk<DocumentSnapshot>()
        every { sparse.id } returns "evt-2"
        every { sparse.data } returns mapOf("amountAtEvent" to "not-a-number")
        val event = requireNotNull(sparse.toBudgetEvent())
        assertEquals("", event.ruleID)
        assertEquals(0.0, event.amountAtEvent, 0.0)
        assertNull(event.occurredAt)
    }

    @Test
    fun `budget event toMap stamps server time and round trips occurredAt`() {
        val occurredAt = Date(1_700_000_000_000L)
        val map = BudgetEvent(
            id = "evt-1",
            ruleID = "rule-1",
            kind = "block",
            occurredAt = occurredAt,
            sourceDeviceID = "android-1",
        ).toMap()

        assertEquals("evt-1", map["id"])
        assertEquals(Timestamp(occurredAt), map["occurredAt"])
        assertEquals(FieldValue.serverTimestamp(), map["syncedAt"])
        // Without a local occurredAt the server clock is authoritative.
        assertEquals(FieldValue.serverTimestamp(), BudgetEvent(id = "evt-2").toMap()["occurredAt"])
    }

    // ── CloudVaultSealedTextCodec envelope validation ──

    @Test
    fun `fromMap requires nonce ciphertext and tag and defaults the header`() {
        val complete = mapOf("nonce" to "n", "ciphertext" to "c", "tag" to "t")
        val envelope = requireNotNull(CloudVaultSealedTextCodec.fromMap(complete))
        assertEquals("AES-256-GCM", envelope.algorithm)
        assertEquals(1, envelope.keyVersion)

        assertNull(CloudVaultSealedTextCodec.fromMap(null))
        assertNull(CloudVaultSealedTextCodec.fromMap(mapOf("nonce" to "n", "ciphertext" to "c")))
        assertNull(CloudVaultSealedTextCodec.fromMap(mapOf("nonce" to "n", "tag" to "t")))
        assertNull(CloudVaultSealedTextCodec.fromMap(mapOf("ciphertext" to "c", "tag" to "t")))
    }

    @Test
    fun `openOrLegacy uses legacy plaintext only when no sealed envelope exists`() {
        val sealed = mapOf("nonce" to "n", "ciphertext" to "c", "tag" to "t")
        // A sealed field with no local vault key is decrypt-or-nil — it must
        // NEVER fall back to attacker-controllable legacy plaintext.
        assertNull(CloudVaultSealedTextCodec.openOrLegacy(sealed, null, "legacy"))
        // No sealed envelope at all → migration fallback to legacy plaintext.
        assertEquals("legacy", CloudVaultSealedTextCodec.openOrLegacy(null, null, "legacy"))
        assertEquals("legacy", CloudVaultSealedTextCodec.openOrLegacy("a-plain-string", null, "legacy"))
        assertEquals("legacy", CloudVaultSealedTextCodec.openOrLegacy(mapOf("nonce" to "n"), null, "legacy"))
    }

    @Test
    fun `open fails closed without a key or a well formed envelope`() {
        val sealed = mapOf("nonce" to "n", "ciphertext" to "c", "tag" to "t")
        assertNull(CloudVaultSealedTextCodec.open(sealed, null))
        assertNull(CloudVaultSealedTextCodec.open(null, ByteArray(32)))
        assertNull(CloudVaultSealedTextCodec.open("not-a-map", ByteArray(32)))
    }
}
