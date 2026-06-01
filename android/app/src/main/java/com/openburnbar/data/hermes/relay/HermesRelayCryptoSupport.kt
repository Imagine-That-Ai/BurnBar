package com.openburnbar.data.hermes.relay

internal object HermesRelayCryptoSupport {
    private const val AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
    private const val KEY_WRAP_SHARED_INFO_PREFIX = "OpenBurnBar-HermesRelay-KeyWrap-v1|"

    fun aad(parts: List<String>): ByteArray = ("$AAD_PREFIX|" + parts.joinToString("|")).toByteArray(Charsets.UTF_8)

    fun keyWrapSharedInfo(aad: ByteArray): ByteArray = KEY_WRAP_SHARED_INFO_PREFIX.toByteArray(Charsets.UTF_8) + aad

    fun base64NoWrap(bytes: ByteArray): String = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    fun base64Decode(text: String): ByteArray = android.util.Base64.decode(text, android.util.Base64.NO_WRAP)
}
