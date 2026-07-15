package com.openburnbar.data.hermes.relay

import uniffi.openburnbar_domain_ffi.HermesAadKind

internal object HermesRelayCryptoSupport {
    fun aad(parts: List<String>): ByteArray {
        val legacy = { HermesRelayLegacyCrypto.aad(parts) }
        val kind = when (parts.firstOrNull()) {
            "request" -> HermesAadKind.REQUEST
            "key" -> HermesAadKind.KEY
            "request-v3" -> HermesAadKind.AUTHENTICATED_REQUEST
            "key-v3" -> HermesAadKind.AUTHENTICATED_KEY
            "chunk" -> HermesAadKind.CHUNK
            "mediaSealKey" -> HermesAadKind.MEDIA_SEAL_KEY
            "controlSealKey" -> HermesAadKind.CONTROL_SEAL_KEY
            "gatewayEvent" -> HermesAadKind.GATEWAY_EVENT
            "gatewayEventKey" -> HermesAadKind.GATEWAY_EVENT_KEY
            "gatewayMessage" -> HermesAadKind.GATEWAY_MESSAGE
            "gatewayMessageKey" -> HermesAadKind.GATEWAY_MESSAGE_KEY
            "gatewayAttachmentKey" -> HermesAadKind.GATEWAY_ATTACHMENT_KEY
            "gatewayAttachmentManifest" -> HermesAadKind.GATEWAY_ATTACHMENT_MANIFEST
            "gatewayAttachmentBody" -> HermesAadKind.GATEWAY_ATTACHMENT_BODY
            else -> return legacy()
        }
        return HermesDomainCoreAdapter.aad(kind, parts.drop(1), legacy)
    }

    fun keyWrapSharedInfo(aad: ByteArray): ByteArray = HermesDomainCoreAdapter.keyWrapInfoV1(aad) {
        HermesRelayLegacyCrypto.keyWrapInfoV1(aad)
    }

    /**
     * v2 authenticated key-wrap `info` (HPKE-AuthEncap-shaped kem_context).
     * Byte-identical to the Swift `authenticatedWrappingKey` info:
     * `"OpenBurnBar-HermesRelay-KeyWrap-v2|" ‖ aad ‖ enc ‖ pkR ‖ pkS`.
     * `enc`, `pkR`, `pkS` MUST be the raw 65-byte X9.63 uncompressed form
     * (`0x04 ‖ X ‖ Y`), NOT a DER/SPKI encoding.
     */
    fun keyWrapSharedInfoV2(aad: ByteArray, enc: ByteArray, pkR: ByteArray, pkS: ByteArray): ByteArray =
        HermesDomainCoreAdapter.keyWrapInfoV2(aad, enc, pkR, pkS) {
            HermesRelayLegacyCrypto.keyWrapInfoV2(aad, enc, pkR, pkS)
        }

    fun base64NoWrap(bytes: ByteArray): String = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    fun base64Decode(text: String): ByteArray = android.util.Base64.decode(text, android.util.Base64.NO_WRAP)
}
