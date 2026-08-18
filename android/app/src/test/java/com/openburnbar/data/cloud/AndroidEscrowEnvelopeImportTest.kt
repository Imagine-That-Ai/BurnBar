package com.openburnbar.data.cloud

import com.openburnbar.data.policy.MobileEscrowImportFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidEscrowEnvelopeImportTest {
    @Test
    fun missingGrantExpiryIsExpired() {
        val now = 1_700_000_000_000L
        assertEquals(
            MobileEscrowImportFailure.EXPIRED_GRANT,
            AndroidEscrowEnvelopeImport.rejectIfUnimportable(
                targetDeviceId = "phone-a",
                currentDeviceId = "phone-a",
                grantStatus = "granted",
                grantExpiresAtMs = null,
                nowMs = now,
                hasPrivateKey = true,
                ciphertextBase64 = "YWJj",
                grantId = "grant-1",
                envelopeVersion = 2,
            ),
        )
    }

    @Test
    fun versionOneIsMalformed() {
        val now = 1_700_000_000_000L
        assertEquals(
            MobileEscrowImportFailure.MALFORMED_ENVELOPE,
            AndroidEscrowEnvelopeImport.rejectIfUnimportable(
                targetDeviceId = "phone-a",
                currentDeviceId = "phone-a",
                grantStatus = "granted",
                grantExpiresAtMs = now + 1,
                nowMs = now,
                hasPrivateKey = true,
                ciphertextBase64 = "YWJj",
                grantId = "grant-1",
                envelopeVersion = 1,
            ),
        )
    }

    @Test
    fun wellFormedGrantImports() {
        val now = 1_700_000_000_000L
        assertNull(
            AndroidEscrowEnvelopeImport.rejectIfUnimportable(
                targetDeviceId = "phone-a",
                currentDeviceId = "phone-a",
                grantStatus = "granted",
                grantExpiresAtMs = now + 1,
                nowMs = now,
                hasPrivateKey = true,
                ciphertextBase64 = "YWJj",
                grantId = "grant-1",
                envelopeVersion = 2,
            ),
        )
    }
}
