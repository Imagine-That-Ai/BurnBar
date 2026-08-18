package com.openburnbar.data.cloud

/** Android twin of Swift `EscrowCredentialMetadataBinding`. */
data class EscrowCredentialMetadataBinding(
    val grantId: String,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val providerId: String,
    val credentialKind: String,
    val accountLabel: String,
    val keyVersion: Int,
    val envelopeVersion: Int = ENVELOPE_VERSION,
) {
    val associatedData: ByteArray
        get() =
            listOf(
                "OpenBurnBar-Escrow-Credential-Binding-v1",
                field("grant", grantId),
                field("source", sourceDeviceId),
                field("target", targetDeviceId),
                field("provider", providerId),
                field("kind", credentialKind),
                field("account", accountLabel),
                field("keyVersion", keyVersion.toString()),
                field("envelopeVersion", envelopeVersion.toString()),
            ).joinToString("\n").toByteArray(Charsets.UTF_8)

    private fun field(name: String, value: String): String = "$name:${value.toByteArray(Charsets.UTF_8).size}:$value"

    companion object {
        const val ENVELOPE_VERSION = 2
        const val METADATA_BINDING = "escrow-credential-aad-v1"

        fun fromEnvelope(
            metadataBinding: String?,
            grantId: String?,
            sourceDeviceId: String?,
            targetDeviceId: String?,
            currentDeviceId: String,
            providerId: String?,
            credentialKind: String?,
            accountLabel: String?,
            keyVersion: Int?,
            envelopeVersion: Int?,
        ): EscrowCredentialMetadataBinding? {
            val version = envelopeVersion ?: 1
            if (version < ENVELOPE_VERSION) return null
            if (metadataBinding != METADATA_BINDING) return null
            val grant = grantId?.trim().orEmpty()
            val source = sourceDeviceId?.trim().orEmpty()
            val target = targetDeviceId?.trim().orEmpty()
            val provider = providerId?.trim().orEmpty()
            val kind = credentialKind?.trim().orEmpty()
            val label = accountLabel?.trim().orEmpty()
            if (grant.isEmpty() || source.isEmpty() || target.isEmpty() || provider.isEmpty() || kind.isEmpty()) {
                return null
            }
            if (target != currentDeviceId.trim()) return null
            if (keyVersion == null) return null
            return EscrowCredentialMetadataBinding(
                grantId = grant,
                sourceDeviceId = source,
                targetDeviceId = target,
                providerId = provider,
                credentialKind = kind,
                accountLabel = label,
                keyVersion = keyVersion,
                envelopeVersion = version,
            )
        }
    }
}
