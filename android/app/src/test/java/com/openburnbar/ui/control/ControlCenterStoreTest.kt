package com.openburnbar.ui.control

import com.openburnbar.data.cloud.CloudVaultCrypto
import org.junit.Assert.assertEquals
import org.junit.Test

class ControlCenterStoreTest {
    @Test
    fun recoveryKeySetupPayloadBindsWrappedKeyToVaultKeyID() {
        val wrapped =
            CloudVaultCrypto.RecoveryWrappedVaultKey(
                wrappedVaultKeyBase64 = "QUJD",
                verificationHash = "a".repeat(64),
            )
        val payload = recoveryKeySetupPayload(wrapped, "v1_${"b".repeat(32)}")

        assertEquals(CloudVaultCrypto.AES_GCM_ALGORITHM, payload["algorithm"])
        assertEquals(wrapped.wrappedVaultKeyBase64, payload["wrappedVaultKey"])
        assertEquals(wrapped.verificationHash, payload["verificationHash"])
        assertEquals(CloudVaultCrypto.CURRENT_KEY_VERSION, payload["keyVersion"])
        assertEquals("v1_${"b".repeat(32)}", payload["vaultKeyID"])
    }
}
