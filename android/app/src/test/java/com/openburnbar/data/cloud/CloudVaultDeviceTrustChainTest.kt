package com.openburnbar.data.cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudVaultDeviceTrustChainTest {
    @Test
    fun signalIdentityTrustChainSignatureVerifiesAndBindsTarget() {
        val approver = AndroidSignalIdentityKeypair.generate("phone-a", 1)
        val payload =
            CloudVaultDeviceTrustChainPayload(
                uid = "user-1",
                targetDeviceId = "mac-1",
                targetEscrowPublicKeyFingerprint = "escrow-fingerprint",
                targetKeyVersion = 1,
                targetSignalIdentityKeyId = "mac-1_1",
                targetSignalIdentityPublicKeyFingerprint = "signal-fingerprint",
                approverDeviceId = "phone-a",
                approverSignalIdentityKeyId = approver.identityKeyId,
                approverSignalIdentityPublicKeyFingerprint = CloudVaultCrypto.sha256Base64(approver.publicKeyData),
            )

        val signature = CloudVaultDeviceTrustChain.sign(payload, approver)

        assertTrue(CloudVaultDeviceTrustChain.verify(payload, signature, approver.publicKeyData))
        assertFalse(
            CloudVaultDeviceTrustChain.verify(
                payload.copy(targetDeviceId = "mac-2"),
                signature,
                approver.publicKeyData,
            ),
        )
    }
}
