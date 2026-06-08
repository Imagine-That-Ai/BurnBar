package com.openburnbar.data.cloud

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

private const val SIGNAL_DEVICE_KAT_PRIVATE_KEY_B64 = "yGZ5zfds7ljkjsopcLya1ayDbjV+TCL6/b4BQBpqfV0="
private const val SIGNAL_DEVICE_KAT_PUBLIC_KEY_B64_CANONICAL = "BVw7AC8duGgSdz/wLmMLMe+ymSUCcMkOcoJ+E6Eb+RhO"
private const val SIGNAL_DEVICE_KAT_CIPHERTEXT_B64 =
    "AQt/WxZMem2jpwxChzbQuzg/yMY5kdPdzuOmgLoJwoIZOFUfdEr33hTkLyIzwQTD7J2uShoruECN2ty8j1QlSe2siO6trszlngaJe7Zhb7liPArb1x/A+J/nrS5GNw=="
private const val SIGNAL_DEVICE_KAT_PLAINTEXT_B64 = "Y3Jvc3MtbGFuZ3VhZ2UgaW50ZXJvcCBzZWNyZXQg4oCUIG5vZGUgc2VhbGVk"

@RunWith(AndroidJUnit4::class)
class CloudVaultCryptoSignalInstrumentedTest {
    @Test
    fun signalAtRestLibsignalOpensNodeKatAndRejectsRelocationOnDevice() {
        val privateKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PRIVATE_KEY_B64)
        val binding = signalBinding(docId = "doc-42", field = "body")

        val plaintext = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PLAINTEXT_B64)
        val ciphertext = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_CIPHERTEXT_B64)

        assertArrayEquals(plaintext, CloudVaultCryptoSupport.atRestOpen(ciphertext, privateKey, binding))
        assertTrue(
            "relocated docId must fail closed on physical Android/libsignal",
            runCatching {
                CloudVaultCryptoSupport.atRestOpen(
                    ciphertext,
                    privateKey,
                    binding.copy(docId = "relocated-doc"),
                )
            }.isFailure,
        )
    }

    @Test
    fun signalCloudVaultEnvelopeRoundTripsAndRejectsExpectedBindingMismatchOnDevice() {
        val privateKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PRIVATE_KEY_B64)
        val publicKey = CloudVaultCryptoSupport.decodeBase64(SIGNAL_DEVICE_KAT_PUBLIC_KEY_B64_CANONICAL)
        val binding = cloudBinding(docId = "android-physical-doc", field = "signalEnvelope")
        val plaintext = """{"device":"android","signal":true}""".toByteArray()

        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                plaintext = plaintext,
                recipients = listOf(CloudVaultSignalRecipient("device", "android-device-key-v1", publicKey)),
                binding = binding,
            )

        assertEquals(binding, envelope.binding)
        assertArrayEquals(
            plaintext,
            CloudVaultCrypto.openSignalPayload(
                envelope = envelope,
                recipientIdentityKeyId = "android-device-key-v1",
                recipientIdentityPrivateKey = privateKey,
                expectedBinding = binding,
            ),
        )
        assertTrue(
            "high-level opener must reject caller/envelope binding mismatch on physical Android/libsignal",
            runCatching {
                CloudVaultCrypto.openSignalPayload(
                    envelope = envelope,
                    recipientIdentityKeyId = "android-device-key-v1",
                    recipientIdentityPrivateKey = privateKey,
                    expectedBinding = cloudBinding(docId = "relocated-doc", field = "signalEnvelope"),
                )
            }.isFailure,
        )
    }

    private fun signalBinding(docId: String, field: String): SignalEnvelopeBinding = SignalEnvelopeBinding(
        uid = "u1",
        scope = "cloudvault",
        collection = "pensieve",
        docId = docId,
        field = field,
        mode = "at-rest",
        formatVersion = 1,
    )

    private fun cloudBinding(docId: String, field: String): CloudVaultSignalBinding = CloudVaultSignalBinding(
        uid = "android-physical-user",
        collection = "mobile_assistant_chats",
        docId = docId,
        field = field,
    )
}
