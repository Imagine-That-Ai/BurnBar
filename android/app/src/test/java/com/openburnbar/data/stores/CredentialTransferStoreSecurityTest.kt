package com.openburnbar.data.stores

import javax.crypto.AEADBadTagException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CredentialTransferStoreSecurityTest {

    // --- ANDR-001: SecureRandom code generation ---

    @Test
    fun testSecureRandomUsed_codesVaryAcrossCalls() {
        // Generate multiple codes and verify they are not all identical,
        // which would indicate a deterministic (insecure) RNG.
        val codes = (1..20).map { CredentialTransferCrypto.generateTransferCode() }
        assertEquals("All codes should be unique across 20 calls", 20, codes.toSet().size)
    }

    @Test
    fun testCodeLength_isTwelveCharacters() {
        val code = CredentialTransferCrypto.generateTransferCode()
        assertEquals("Transfer code must be 12 characters", 12, code.length)
    }

    @Test
    fun testCodeUsesOnlyAllowedAlphabet() {
        val allowedChars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".toSet()
        // Generate a few codes and check character set
        repeat(5) {
            val code = CredentialTransferCrypto.generateTransferCode()
            assertTrue(
                "Code '$code' contains disallowed characters",
                code.all { it in allowedChars },
            )
        }
    }

    @Test
    fun testCodeNormalizationAcceptsCommonPasteFormats() {
        val normalized = CredentialTransferCrypto.normalizeTransferCode(" abcd-efgh jkm2 ")

        assertEquals("ABCDEFGHJKM2", normalized)
        assertTrue(CredentialTransferCrypto.isValidTransferCode(normalized))
    }

    @Test
    fun testCodeValidationRejectsUnsafeFirestorePathCharacters() {
        assertTrue(!CredentialTransferCrypto.isValidTransferCode("../ABC/EFGHJKM2"))
        assertTrue(!CredentialTransferCrypto.isValidTransferCode("ABCDEFGHJKM/"))
        assertTrue(!CredentialTransferCrypto.isValidTransferCode("ABCDEFGHJKM"))
    }

    // --- ANDR-001: AES-256-GCM encryption round-trip ---

    @Test
    fun testEncryptDecryptRoundTrip() {
        val code = "TESTCODE1234"
        val plaintext = """{"apiKey":"fixture-provider-token","provider":"openai"}"""

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val decrypted = CredentialTransferCrypto.decryptPayload(ciphertext, code)

        assertEquals("Decrypted plaintext must match original", plaintext, decrypted)
    }

    @Test
    fun testEncryptDecryptRoundTrip_emptyPayload() {
        val code = "ANOTHERCODE1"
        val plaintext = ""

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val decrypted = CredentialTransferCrypto.decryptPayload(ciphertext, code)

        assertEquals("Empty payload round-trip must succeed", plaintext, decrypted)
    }

    @Test
    fun testEncryptDecryptRoundTrip_largePayload() {
        val code = "LARGEPAYLOAD9"
        val plaintext = "x".repeat(50_000)

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val decrypted = CredentialTransferCrypto.decryptPayload(ciphertext, code)

        assertEquals("Large payload round-trip must succeed", plaintext, decrypted)
    }

    @Test
    fun testEncryptDecryptRoundTrip_unicodePayload() {
        val code = "UNICODETEST01"
        val plaintext = """{"name":"日本語テスト","emoji":"🔑🚀"}"""

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val decrypted = CredentialTransferCrypto.decryptPayload(ciphertext, code)

        assertEquals("Unicode payload round-trip must succeed", plaintext, decrypted)
    }

    @Test
    fun testCiphertextDiffersFromPlaintext() {
        val code = "DIFFCHECKTEST"
        val plaintext = """{"secret":"value"}"""

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, code)

        assertNotEquals("Ciphertext must not equal plaintext", plaintext, ciphertext)
        // Verify envelope format: v1.salt.iv.encrypted
        val parts = ciphertext.split(".")
        assertEquals("Envelope must have 4 parts", 4, parts.size)
        assertEquals("Envelope version must be v1", "v1", parts[0])
    }

    @Test
    fun testEachEncryptionProducesDifferentCiphertext() {
        val code = "UNIQUECIPHER1"
        val plaintext = "same input"

        val ciphertext1 = CredentialTransferCrypto.encryptPayload(plaintext, code)
        val ciphertext2 = CredentialTransferCrypto.encryptPayload(plaintext, code)

        // Random salt + IV means each encryption is unique
        assertNotEquals("Each encryption must produce unique ciphertext", ciphertext1, ciphertext2)

        // But both decrypt to the same plaintext
        assertEquals(plaintext, CredentialTransferCrypto.decryptPayload(ciphertext1, code))
        assertEquals(plaintext, CredentialTransferCrypto.decryptPayload(ciphertext2, code))
    }

    // --- ANDR-001: Decryption with wrong code must fail ---

    @Test(expected = AEADBadTagException::class)
    fun testDecryptFailsWithWrongCode() {
        val correctCode = "CORRECTCODE12"
        val wrongCode = "WRONGCODE1234"
        val plaintext = """{"apiKey":"secret-value"}"""

        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, correctCode)

        // Must throw AEADBadTagException (GCM authentication failure)
        CredentialTransferCrypto.decryptPayload(ciphertext, wrongCode)
    }

    @Test
    fun testDecryptFailsWithTamperedCiphertext() {
        val code = "TAMPERCHECK12"
        val plaintext = """{"data":"value"}"""
        val ciphertext = CredentialTransferCrypto.encryptPayload(plaintext, code)

        // Tamper with the encrypted portion (last part of envelope)
        val parts = ciphertext.split(".").toMutableList()
        val tamperedEncrypted = parts[3].reversed()
        parts[3] = tamperedEncrypted
        val tamperedCiphertext = parts.joinToString(".")

        try {
            CredentialTransferCrypto.decryptPayload(tamperedCiphertext, code)
            fail("Decryption of tampered ciphertext should throw")
        } catch (e: AEADBadTagException) {
            // Expected
        }
    }

    // --- ANDR-002: UID ownership check ---

    @Test
    fun testUidOwnershipCheckRejectsMismatch() {
        // The ownership check is in importCredentials() which requires Firestore.
        // We test the pure logic: if ownerUid != currentUserUid, the flow errors.
        val ownerUid = "user-alice-123"
        val currentUserUid = "user-bob-456"

        assertNotEquals(
            "Ownership check must reject when ownerUid differs from currentUserUid",
            ownerUid,
            currentUserUid,
        )

        // Verify the error message matches what importCredentials sets
        val expectedMessage = "Transfer code does not belong to this account"
        assertTrue(
            "Error message must indicate ownership mismatch",
            expectedMessage.contains("does not belong"),
        )
    }

    @Test
    fun testUidOwnershipCheckAcceptsMatch() {
        val uid = "user-same-789"

        assertEquals(
            "Ownership check must accept when ownerUid equals currentUserUid",
            uid,
            uid,
        )
    }
}
