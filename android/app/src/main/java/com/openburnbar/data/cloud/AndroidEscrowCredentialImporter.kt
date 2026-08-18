package com.openburnbar.data.cloud

import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.policy.MobileEscrowImportFailure
import kotlinx.coroutines.tasks.await

/** Production escrow envelope import. Classify before decrypt, matching iOS LiveCloudReader. */
class AndroidEscrowCredentialImporter(
    private val firestoreProvider: () -> FirebaseFirestore = { AndroidEscrowDeviceRegistry().firestore },
    private val keypairProvider: () -> AndroidCloudVaultDeviceKeypair = { AndroidCloudVaultDeviceKeypair.loadOrCreate() },
    private val decrypt: (AndroidCloudVaultDeviceKeypair, String, ByteArray) -> ByteArray = { keypair, wrapped, aad ->
        keypair.decryptEscrowPayload(wrapped, aad)
    },
    private val persistSecret: (provider: String, secret: String) -> Boolean = { provider, secret ->
        AndroidEscrowSecretStore.persist(provider, secret)
    },
) {
    data class EnvelopeFields(
        val envelopeId: String,
        val ciphertextBase64: String?,
        val grantId: String?,
        val envelopeVersion: Int?,
        val targetDeviceId: String?,
        val grantStatus: String?,
        val grantExpiresAtMs: Long?,
        val providerId: String? = null,
        val sourceDeviceId: String? = null,
        val credentialKind: String? = null,
        val accountLabel: String? = null,
        val keyVersion: Int? = null,
        val metadataBinding: String? = null,
    )

    sealed class Result {
        data class Imported(val plaintext: ByteArray) : Result()
        data class Rejected(val failure: MobileEscrowImportFailure) : Result()
        data class PersistFailed(val message: String) : Result()
    }

    fun importEnvelope(
        fields: EnvelopeFields,
        currentDeviceId: String,
        nowMs: Long,
        hasPrivateKey: Boolean,
        decryptCiphertext: (String, ByteArray) -> ByteArray,
    ): Result {
        val failure =
            AndroidEscrowEnvelopeImport.rejectIfUnimportable(
                targetDeviceId = fields.targetDeviceId,
                currentDeviceId = currentDeviceId,
                grantStatus = fields.grantStatus,
                grantExpiresAtMs = fields.grantExpiresAtMs,
                nowMs = nowMs,
                hasPrivateKey = hasPrivateKey,
                ciphertextBase64 = fields.ciphertextBase64,
                grantId = fields.grantId,
                envelopeVersion = fields.envelopeVersion,
            )
        if (failure != null) return Result.Rejected(failure)
        val ciphertext = fields.ciphertextBase64?.trim().orEmpty()
        val binding =
            EscrowCredentialMetadataBinding.fromEnvelope(
                metadataBinding = fields.metadataBinding,
                grantId = fields.grantId,
                sourceDeviceId = fields.sourceDeviceId,
                targetDeviceId = fields.targetDeviceId,
                currentDeviceId = currentDeviceId,
                providerId = fields.providerId,
                credentialKind = fields.credentialKind,
                accountLabel = fields.accountLabel,
                keyVersion = fields.keyVersion,
                envelopeVersion = fields.envelopeVersion,
            ) ?: return Result.Rejected(MobileEscrowImportFailure.MALFORMED_ENVELOPE)
        return Result.Imported(decryptCiphertext(ciphertext, binding.associatedData))
    }

    /** Persist decrypted plaintext or fail. Never report SUCCESS after dropping the secret. */
    fun persistImported(result: Result, providerId: String?): Result {
        if (result !is Result.Imported) return result
        val provider = providerId?.trim().orEmpty()
        if (provider.isEmpty()) return Result.PersistFailed("missing provider")
        val secret = result.plaintext.toString(Charsets.UTF_8).trim()
        if (secret.isEmpty()) return Result.PersistFailed("empty secret")
        return if (persistSecret(provider, secret)) {
            result
        } else {
            Result.PersistFailed("secure persist failed")
        }
    }

    suspend fun importFromFirestore(uid: String, envelopeId: String, nowMs: Long = System.currentTimeMillis()): Result {
        val keypair = keypairProvider()
        val firestore = firestoreProvider()
        val envelopeSnap =
            firestore.collection("users").document(uid)
                .collection("escrow_envelopes").document(envelopeId)
                .get()
                .await()
        val data = envelopeSnap.data.orEmpty()
        val grantId = data["grantId"] as? String
        var grantStatus: String? = null
        var grantExpiresAtMs: Long? = null
        if (!grantId.isNullOrBlank()) {
            val grant =
                firestore.collection("users").document(uid)
                    .collection("escrow_grants").document(grantId)
                    .get()
                    .await()
                    .data
            grantStatus = grant?.get("status") as? String
            grantExpiresAtMs = (grant?.get("expiresAtMillis") as? Number)?.toLong()
        }
        val fields =
            EnvelopeFields(
                envelopeId = envelopeId,
                ciphertextBase64 = data["ciphertext"] as? String,
                grantId = grantId,
                envelopeVersion = (data["envelopeVersion"] as? Number)?.toInt(),
                targetDeviceId = data["targetDeviceId"] as? String,
                grantStatus = grantStatus,
                grantExpiresAtMs = grantExpiresAtMs,
                providerId = data["providerId"] as? String,
                sourceDeviceId = data["sourceDeviceId"] as? String,
                credentialKind = data["credentialKind"] as? String,
                accountLabel = data["accountLabel"] as? String,
                keyVersion = (data["keyVersion"] as? Number)?.toInt(),
                metadataBinding = data["metadataBinding"] as? String,
            )
        val imported =
            importEnvelope(
                fields = fields,
                currentDeviceId = keypair.deviceId,
                nowMs = nowMs,
                hasPrivateKey = true,
            ) { wrapped, aad -> decrypt(keypair, wrapped, aad) }
        return persistImported(imported, fields.providerId)
    }
}
