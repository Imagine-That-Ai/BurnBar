package com.openburnbar.data.cloud

internal object CloudVaultLegacyDocumentRewrap {
    // This deletion target owns document orchestration. AES operations stay in the separately
    // promoted CloudVault crypto slice and are reached through the typed facade below.
    private const val BLOB_AAD_CONTEXT = "OpenBurnBar-CloudVaultBlob-v2"
    private const val SEALED_PAYLOAD_AAD_CONTEXT = "OpenBurnBar-CloudVaultSealedPayload-v2"

    fun rewrapCloudVaultDocumentLegacy(
        data: Map<String, Any?>,
        uid: String,
        collection: String,
        docID: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobId: String?,
        noncePlan: List<CloudVaultDocumentRewrapNonce>,
    ): CloudVaultDocumentRewrapResult {
        val updated = data.toMutableMap()
        val changedFields = mutableListOf<String>()
        var nonceIndex = 0

        fun nextNonce(field: String): ByteArray {
            val planned = noncePlan.getOrNull(nonceIndex++) ?: error("Invalid CloudVault rewrap nonce plan")
            check(planned.fieldName == field) { "Invalid CloudVault rewrap nonce field" }
            return planned.bytes
        }

        for (field in data.keys.sorted()) {
            val raw = data[field] as? Map<*, *> ?: continue
            val context = CloudVaultAADContext(uid = uid, collection = collection, docID = docID, field = field)

            CloudVaultCrypto.sealedPayloadFromMap(raw)?.let { envelope ->
                if (envelope.vaultKeyID == newVaultKeyID) return@let
                val plaintext = openPayloadForRewrap(envelope, oldKey, context)
                val resealed = CloudVaultCrypto.sealPayloadWithNonce(plaintext, newKey, newVaultKeyID, context, nextNonce(field))
                updated[field] = CloudVaultCrypto.sealedPayloadMap(resealed)
                applyVaultKeyCompanionUpdates(updated, field, newVaultKeyID)
                changedFields += field
                return@let
            } ?: CloudVaultCrypto.sealedTextFromMap(raw)?.let { envelope ->
                val plaintext = openTextForRewrap(envelope, oldKey, context)
                val resealed = CloudVaultCrypto.sealTextWithNonce(plaintext, newKey, context, nextNonce(field))
                updated[field] = CloudVaultCrypto.sealedTextMap(resealed)
                changedFields += field
                return@let
            } ?: CloudVaultCrypto.blobEnvelopeFromMap(raw)?.let { envelope ->
                val plaintext = openBlobForRewrap(envelope, oldKey, context)
                val resealed = CloudVaultCrypto.sealBlobWithNonce(plaintext, newKey, context, nextNonce(field))
                updated[field] = CloudVaultCrypto.blobEnvelopeMap(resealed)
                changedFields += field
            }
        }

        check(nonceIndex == noncePlan.size) { "Invalid CloudVault rewrap nonce plan" }

        if (changedFields.isNotEmpty()) {
            vaultGeneration?.let { updated["vaultGeneration"] = it }
            rotationJobId?.let { updated["rewrapJobId"] = it }
        }

        return CloudVaultDocumentRewrapResult(updated.toMap(), changedFields)
    }

    private fun openTextForRewrap(envelope: CloudVaultSealedText, vaultKey: ByteArray, aadContext: CloudVaultAADContext): String =
        if ((envelope.schemaVersion ?: 1) >= CloudVaultCrypto.CURRENT_SEALED_TEXT_SCHEMA_VERSION) {
            CloudVaultCrypto.openText(envelope, vaultKey, aadContext)
        } else {
            CloudVaultCrypto.openText(envelope, vaultKey)
        }

    private fun openBlobForRewrap(envelope: CloudVaultBlobEnvelope, vaultKey: ByteArray, aadContext: CloudVaultAADContext): ByteArray =
        if (envelope.schemaVersion >= CloudVaultCrypto.CURRENT_BLOB_ENVELOPE_SCHEMA_VERSION && envelope.aad != BLOB_AAD_CONTEXT) {
            CloudVaultCrypto.openBlob(envelope, vaultKey, aadContext)
        } else {
            CloudVaultCrypto.openBlob(envelope, vaultKey)
        }

    private fun openPayloadForRewrap(envelope: CloudVaultSealedPayload, vaultKey: ByteArray, aadContext: CloudVaultAADContext): ByteArray =
        if (envelope.schemaVersion >= CloudVaultCrypto.CURRENT_SEALED_PAYLOAD_SCHEMA_VERSION && envelope.aad != SEALED_PAYLOAD_AAD_CONTEXT) {
            CloudVaultCrypto.openPayload(envelope, vaultKey, aadContext)
        } else {
            CloudVaultCrypto.openPayload(envelope, vaultKey)
        }

    private fun applyVaultKeyCompanionUpdates(data: MutableMap<String, Any?>, field: String, newVaultKeyID: String) {
        when (field) {
            "sealedPayload", "sealedReplyPayload" -> if (data.containsKey("vaultKeyID")) data["vaultKeyID"] = newVaultKeyID
            "sealedStatePayload" -> if (data.containsKey("sealedStateVaultKeyID")) data["sealedStateVaultKeyID"] = newVaultKeyID
        }
    }
}
