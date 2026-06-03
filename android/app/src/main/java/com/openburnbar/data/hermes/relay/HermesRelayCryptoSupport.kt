package com.openburnbar.data.hermes.relay

internal object HermesRelayCryptoSupport {
    private const val AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
    private const val KEY_WRAP_SHARED_INFO_PREFIX = "OpenBurnBar-HermesRelay-KeyWrap-v1|"
    private const val KEY_WRAP_SHARED_INFO_PREFIX_V2 = "OpenBurnBar-HermesRelay-KeyWrap-v2|"

    fun aad(parts: List<String>): ByteArray = ("$AAD_PREFIX|" + parts.joinToString("|")).toByteArray(Charsets.UTF_8)

    fun keyWrapSharedInfo(aad: ByteArray): ByteArray = KEY_WRAP_SHARED_INFO_PREFIX.toByteArray(Charsets.UTF_8) + aad

    /**
     * v2 authenticated key-wrap `info` (HPKE-AuthEncap-shaped kem_context).
     * Byte-identical to the Swift `authenticatedWrappingKey` info:
     * `"OpenBurnBar-HermesRelay-KeyWrap-v2|" ‖ aad ‖ enc ‖ pkR ‖ pkS`.
     * `enc`, `pkR`, `pkS` MUST be the raw 65-byte X9.63 uncompressed form
     * (`0x04 ‖ X ‖ Y`), NOT a DER/SPKI encoding.
     */
    fun keyWrapSharedInfoV2(aad: ByteArray, enc: ByteArray, pkR: ByteArray, pkS: ByteArray): ByteArray =
        KEY_WRAP_SHARED_INFO_PREFIX_V2.toByteArray(Charsets.UTF_8) + aad + enc + pkR + pkS

    fun base64NoWrap(bytes: ByteArray): String = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    fun base64Decode(text: String): ByteArray = android.util.Base64.decode(text, android.util.Base64.NO_WRAP)
}
