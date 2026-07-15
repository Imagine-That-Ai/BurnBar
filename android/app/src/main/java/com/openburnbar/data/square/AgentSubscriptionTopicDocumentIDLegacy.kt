package com.openburnbar.data.square

import com.openburnbar.data.cloud.CloudVaultCryptoSearch
import java.util.Arrays
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object AgentSubscriptionTopicDocumentIDLegacy {
    private const val INFO = "subscription-topic"
    private const val KEY_BYTES = 32
    private const val ID_BYTES = 16
    private const val HEX_BYTE_MASK = 0xff

    fun documentID(agentURI: String, topicID: String, vaultKey: ByteArray): String {
        val docKey = CloudVaultCryptoSearch.hkdfSha256(
            vaultKey,
            ByteArray(0),
            INFO.toByteArray(),
            KEY_BYTES,
        )
        return try {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(docKey, "HmacSHA256"))
            val digest = mac.doFinal("$agentURI:$topicID".toByteArray(Charsets.UTF_8))
            try {
                val hex = digest.take(ID_BYTES).joinToString("") {
                    "%02x".format(it.toInt() and HEX_BYTE_MASK)
                }
                "sub_$hex"
            } finally {
                Arrays.fill(digest, 0)
            }
        } finally {
            Arrays.fill(docKey, 0)
        }
    }
}
