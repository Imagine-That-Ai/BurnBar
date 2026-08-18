package com.openburnbar.data.cloud

internal object CloudVaultLegacyAad {
    fun aadV1(uid: String, collection: String, docId: String, field: String): String {
        listOf(uid, collection, docId, field).forEach(::requireValidAadPart)
        return "${CloudVaultCrypto.LEGACY_AAD_CONTEXT_PREFIX}|$uid|$collection|$docId|$field"
    }

    fun aadV2(uid: String, collection: String, docId: String, field: String, schemaVersion: Int, purpose: String): String {
        require(schemaVersion >= 2) { "Invalid CloudVault AAD context" }
        listOf(uid, collection, docId, field, purpose).forEach(::requireValidAadPart)
        return "${CloudVaultCrypto.AAD_CONTEXT_PREFIX}|$uid|$collection|$docId|$field|$schemaVersion|$purpose"
    }

    private fun requireValidAadPart(value: String) {
        require(value.isNotEmpty() && value.none { it == '|' || it.code < 0x20 || it.code == 0x7f }) {
            "Invalid CloudVault AAD context"
        }
    }
}
