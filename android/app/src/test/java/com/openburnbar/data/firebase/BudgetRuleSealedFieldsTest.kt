
package com.openburnbar.data.firebase

import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.cloud.CloudVaultCrypto
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Round-trip + privacy-posture tests for the sealed `budgetRules` / `usage`
 * project text. Proves:
 *  - a sealed `sealedProjectName` / `sealedLabel` envelope decodes back to
 *    plaintext with the vault key, and never leaks the plaintext into the doc;
 *  - legacy plaintext docs (no sealed field) still decode (migration fallback);
 *  - `projectKeyHash` is a deterministic, keyed, opaque group-by token.
 *
 * The Android `CloudVaultCrypto` uses `android.util.Base64`, stubbed to JDK
 * Base64 — the same idiom as `HermesRelayCryptoTest`.
 */
class BudgetRuleSealedFieldsTest {
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
    fun toBudgetRuleOpensSealedProjectNameAndLabel() {
        val data: Map<String, Any?> =
            mapOf(
                "scope" to "project",
                "sealedProjectName" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Mercury Media", vaultKey)),
                "sealedLabel" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Q3 cap", vaultKey)),
                "projectKeyHash" to CloudVaultSealedTextCodec.projectKeyHash("Mercury Media", vaultKey),
                "amountUSD" to 50.0,
                "period" to "month",
                "behavior" to "warnThenBlock",
                "isEnabled" to true,
            )
        val snapshot = mockk<DocumentSnapshot>()
        every { snapshot.data } returns data
        every { snapshot.id } returns "rule-1"

        val rule = snapshot.toBudgetRule(vaultKey)
        requireNotNull(rule)
        assertEquals("Mercury Media", rule.projectName)
        assertEquals("Q3 cap", rule.label)
        assertEquals("project", rule.scope)
        assertEquals(50.0, rule.amountUSD, 0.0)
        // The decoded plaintext never appeared verbatim in the stored document.
        assertFalse(data.values.any { it == "Mercury Media" || it == "Q3 cap" })
    }

    @Test
    fun toBudgetRuleFallsBackToLegacyPlaintext() {
        val data: Map<String, Any?> =
            mapOf(
                "scope" to "project",
                "projectName" to "Legacy Project",
                "label" to "Legacy label",
                "amountUSD" to 10.0,
                "period" to "day",
                "behavior" to "warnOnly",
            )
        val snapshot = mockk<DocumentSnapshot>()
        every { snapshot.data } returns data
        every { snapshot.id } returns "rule-legacy"

        val rule = snapshot.toBudgetRule(vaultKey)
        requireNotNull(rule)
        assertEquals("Legacy Project", rule.projectName)
        assertEquals("Legacy label", rule.label)
    }

    @Test
    fun toBudgetRuleWithSealedFieldDoesNotFallBackToLegacyPlaintext() {
        val sealedData: Map<String, Any?> =
            mapOf(
                "scope" to "project",
                "sealedProjectName" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText("Hidden", vaultKey)),
                "projectName" to "Legacy leak",
            )
        val sealedSnapshot = mockk<DocumentSnapshot>()
        every { sealedSnapshot.data } returns sealedData
        every { sealedSnapshot.id } returns "rule-sealed"

        // No vault key: sealed project name cannot be opened. Because the sealed
        // field is present, the legacy sibling must NOT leak.
        val rule = sealedSnapshot.toBudgetRule(vaultKey = null)
        requireNotNull(rule)
        assertNull(rule.projectName)
    }

    @Test
    fun sealedTextCodecRoundTrips() {
        val sealed = CloudVaultCrypto.sealText("users/work/secret-dir", vaultKey)
        val map = CloudVaultSealedTextCodec.toMap(sealed)
        assertEquals("AES-256-GCM", map["algorithm"])
        assertEquals(1, map["keyVersion"])
        assertTrue(map.containsKey("nonce") && map.containsKey("ciphertext") && map.containsKey("tag"))

        val opened = CloudVaultSealedTextCodec.open(map, vaultKey)
        assertEquals("users/work/secret-dir", opened)

        // Wrong key → null (no plaintext escapes), not an exception.
        assertNull(CloudVaultSealedTextCodec.open(map, ByteArray(32) { 0x01.toByte() }))
        // Absent / malformed envelope → null.
        assertNull(CloudVaultSealedTextCodec.open(null, vaultKey))
        assertNull(CloudVaultSealedTextCodec.open(mapOf("nonce" to "x"), vaultKey))
    }

    @Test
    fun projectKeyHashIsDeterministicKeyedAndOpaque() {
        val a = CloudVaultSealedTextCodec.projectKeyHash("Mercury Media", vaultKey)
        val again = CloudVaultSealedTextCodec.projectKeyHash("Mercury Media", vaultKey)
        val normalizedSame = CloudVaultSealedTextCodec.projectKeyHash("mercury media", vaultKey)
        val differentName = CloudVaultSealedTextCodec.projectKeyHash("Apollo", vaultKey)
        val differentKey = CloudVaultSealedTextCodec.projectKeyHash("Mercury Media", ByteArray(32) { 0x77.toByte() })

        requireNotNull(a)
        assertEquals(a, again)
        // Normalization collapses case + punctuation so the same project groups.
        assertEquals(a, normalizedSame)
        assertNotEquals(a, differentName)
        assertNotEquals(a, differentKey)
        // 16-byte (32-hex) opaque trapdoor; never the plaintext.
        assertTrue(Regex("^[a-f0-9]{32}$").matches(a))
        assertNull(CloudVaultSealedTextCodec.projectKeyHash("   ", vaultKey))
    }

    /**
     * Cross-platform contract with the Swift writer
     * (`CloudVaultCrypto.projectKeyHash`): both collapse a project name to ASCII
     * `[a-z0-9]` ONLY — stopwords/short tokens are KEPT — so the same project used
     * on Android and Mac/iOS lands in ONE group-by bucket. "The API v2" must hash
     * the same as its raw filtered form "theapiv2" (NOT a stopword-stripped
     * "apiv2"), which is what Swift now produces after aligning to this contract.
     */
    @Test
    fun projectKeyHashUsesAsciiOnlyCrossPlatformContract() {
        val stopwordName = CloudVaultSealedTextCodec.projectKeyHash("The API v2", vaultKey)
        requireNotNull(stopwordName)
        assertEquals(stopwordName, CloudVaultSealedTextCodec.projectKeyHash("theapiv2", vaultKey))
    }
}
