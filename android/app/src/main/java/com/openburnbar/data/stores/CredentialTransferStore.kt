package com.openburnbar.data.stores

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.cloud.AndroidEscrowCredentialImporter
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

private object CredentialTransferConstants {
    const val TRANSFER_TTL_HOURS = 24
    const val CLAIM_TIMEOUT_MINUTES = 10
    const val TRANSFER_ID_PREFIX = "ct_"
    const val TRANSFER_ID_RANDOM_BYTES = 18
    const val TRANSFER_SECRET_LENGTH = 26
    const val KEY_DERIVATION_ITERATIONS = 210_000
    const val KEY_LENGTH_BITS = 256
    const val GCM_TAG_LENGTH_BITS = 128
    const val SALT_LENGTH_BYTES = 16
    const val IV_LENGTH_BYTES = 12
    const val ENVELOPE_VERSION = "v2"
    const val TOKEN_PREFIX = "obbct_v2"
    const val ENVELOPE_PART_COUNT = 4
    const val ENCRYPTED_PART_INDEX = 3
    const val TOKEN_PART_COUNT = 3
    const val SECRET_GROUP_SIZE = 4
}

internal data class ParsedCredentialTransferToken(
    val transferId: String,
    val secret: String,
)

internal object CredentialTransferCrypto {
    private val SECRET_ALPHABET = ('A'..'Z').filterNot { it == 'I' || it == 'L' || it == 'O' } + ('2'..'9')
    private val legacyHumanCodeRegex = Regex("^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{12}$")
    private val transferIdRegex = Regex("^ct_[A-Za-z0-9_-]{24}$")
    private val secretRegex = Regex("^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{26}$")
    private val envelopeRegex = Regex("^v2\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$")

    fun generateTransferId(): String = CredentialTransferConstants.TRANSFER_ID_PREFIX +
        encodeBase64Url(randomBytes(CredentialTransferConstants.TRANSFER_ID_RANDOM_BYTES))

    fun generateTransferSecret(): String {
        val secureRandom = SecureRandom()
        return (1..CredentialTransferConstants.TRANSFER_SECRET_LENGTH)
            .map { SECRET_ALPHABET[secureRandom.nextInt(SECRET_ALPHABET.size)] }
            .joinToString("")
    }

    fun isValidTransferId(transferId: String): Boolean = transferIdRegex.matches(transferId)

    fun isValidTransferSecret(secret: String): Boolean = secretRegex.matches(secret)

    fun formatTransferToken(transferId: String, secret: String): String {
        require(isValidTransferId(transferId)) { "Invalid transfer handle" }
        require(isValidTransferSecret(secret)) { "Invalid transfer secret" }
        val groupedSecret = secret.chunked(CredentialTransferConstants.SECRET_GROUP_SIZE).joinToString("-")
        return "${CredentialTransferConstants.TOKEN_PREFIX}.$transferId.$groupedSecret"
    }

    fun parseTransferToken(token: String): ParsedCredentialTransferToken {
        val trimmed = token.trim()
        val compactLegacy = trimmed.uppercase(Locale.US).replace("-", "").replace(" ", "")
        require(!legacyHumanCodeRegex.matches(compactLegacy)) {
            "Legacy transfer codes are not supported"
        }

        val parts = trimmed.split(".")
        require(parts.size == CredentialTransferConstants.TOKEN_PART_COUNT && parts[0] == CredentialTransferConstants.TOKEN_PREFIX) {
            "Invalid transfer token"
        }
        val transferId = parts[1]
        val secret = parts[2].uppercase(Locale.US).replace("-", "").replace(" ", "")
        require(isValidTransferId(transferId)) { "Invalid transfer token" }
        require(isValidTransferSecret(secret)) { "Invalid transfer token" }
        return ParsedCredentialTransferToken(transferId = transferId, secret = secret)
    }

    fun createTransferCallablePayload(transferId: String, encryptedPayload: String): Map<String, String> {
        require(isValidTransferId(transferId)) { "Invalid transfer handle" }
        require(envelopeRegex.matches(encryptedPayload)) { "Invalid transfer payload" }
        return mapOf("transferId" to transferId, "payload" to encryptedPayload)
    }

    fun consumeTransferCallablePayload(parsed: ParsedCredentialTransferToken): Map<String, String> = mapOf("transferId" to parsed.transferId)

    fun claimResolutionCallablePayload(transferId: String, claimId: String): Map<String, String> = mapOf("transferId" to transferId, "claimId" to claimId)

    fun encryptPayload(plaintext: String, secret: String, ownerUid: String, transferId: String): String {
        require(isValidTransferSecret(secret)) { "Invalid transfer secret" }
        require(isValidTransferId(transferId)) { "Invalid transfer handle" }
        val salt = randomBytes(CredentialTransferConstants.SALT_LENGTH_BYTES)
        val iv = randomBytes(CredentialTransferConstants.IV_LENGTH_BYTES)
        val key = deriveKeyFromSecret(secret, salt)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.ENCRYPT_MODE,
            key,
            GCMParameterSpec(CredentialTransferConstants.GCM_TAG_LENGTH_BITS, iv),
        )
        cipher.updateAAD(aad(ownerUid, transferId))
        val encrypted = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return listOf(
            CredentialTransferConstants.ENVELOPE_VERSION,
            encodeBase64Url(salt),
            encodeBase64Url(iv),
            encodeBase64Url(encrypted),
        ).joinToString(".")
    }

    fun decryptPayload(ciphertext: String, secret: String, ownerUid: String, transferId: String): String {
        val parts = ciphertext.split(".")
        require(parts.size == CredentialTransferConstants.ENVELOPE_PART_COUNT && parts[0] == CredentialTransferConstants.ENVELOPE_VERSION) {
            "Unsupported transfer payload"
        }
        val salt = decodeBase64Url(parts[1])
        val iv = decodeBase64Url(parts[2])
        val encrypted = decodeBase64Url(parts[CredentialTransferConstants.ENCRYPTED_PART_INDEX])
        require(salt.size == CredentialTransferConstants.SALT_LENGTH_BYTES) {
            "Invalid transfer payload"
        }
        require(iv.size == CredentialTransferConstants.IV_LENGTH_BYTES) {
            "Invalid transfer payload"
        }
        require(isValidTransferSecret(secret)) { "Invalid transfer secret" }
        require(isValidTransferId(transferId)) { "Invalid transfer handle" }
        val key = deriveKeyFromSecret(secret, salt)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(CredentialTransferConstants.GCM_TAG_LENGTH_BITS, iv),
        )
        cipher.updateAAD(aad(ownerUid, transferId))
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun deriveKeyFromSecret(secret: String, salt: ByteArray): SecretKey {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = PBEKeySpec(
            secret.toCharArray(),
            salt,
            CredentialTransferConstants.KEY_DERIVATION_ITERATIONS,
            CredentialTransferConstants.KEY_LENGTH_BITS,
        )
        return SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
    }

    private fun aad(ownerUid: String, transferId: String): ByteArray = "credential_transfers:v2:$ownerUid:$transferId".toByteArray(Charsets.UTF_8)

    private fun randomBytes(length: Int): ByteArray {
        val bytes = ByteArray(length)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    private fun encodeBase64Url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    private fun decodeBase64Url(value: String): ByteArray = Base64.getUrlDecoder().decode(value)
}

enum class TransferStatus { IDLE, EXPORTING, IMPORTING, SUCCESS, ERROR }

class CredentialTransferStore(
    private val escrowImporter: AndroidEscrowCredentialImporter = AndroidEscrowCredentialImporter(),
) : ViewModel() {
    private val functions = Firebase.functions("us-central1")

    private val _status = MutableStateFlow(TransferStatus.IDLE)
    val status: StateFlow<TransferStatus> = _status.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _transferToken = MutableStateFlow<String?>(null)
    val transferToken: StateFlow<String?> = _transferToken.asStateFlow()

    fun exportCredentials(credentialsJson: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.EXPORTING
            _lastError.value = null
            try {
                val uid = FirebaseAuth.getInstance().currentUser?.uid
                if (uid == null) {
                    _lastError.value = "Not signed in"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                if (credentialsJson.isBlank()) {
                    _lastError.value = "No credentials to transfer"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                val transferId = CredentialTransferCrypto.generateTransferId()
                val secret = CredentialTransferCrypto.generateTransferSecret()
                val encryptedPayload = CredentialTransferCrypto.encryptPayload(
                    plaintext = credentialsJson,
                    secret = secret,
                    ownerUid = uid,
                    transferId = transferId,
                )
                functions.getHttpsCallable("createCredentialTransfer")
                    .call(CredentialTransferCrypto.createTransferCallablePayload(transferId, encryptedPayload))
                    .await()

                _transferToken.value = CredentialTransferCrypto.formatTransferToken(transferId, secret)
                _status.value = TransferStatus.SUCCESS
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Export failed", e)
                _lastError.value = e.message
                _status.value = TransferStatus.ERROR
            } catch (e: GeneralSecurityException) {
                Log.e("BurnBar", "Credential encryption failed", e)
                _lastError.value = "Credential encryption failed"
                _status.value = TransferStatus.ERROR
            } catch (e: IllegalArgumentException) {
                Log.e("BurnBar", "Invalid transfer token", e)
                _lastError.value = "Invalid transfer token"
                _status.value = TransferStatus.ERROR
            }
        }
    }

    fun importEscrowEnvelope(envelopeId: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.IMPORTING
            _lastError.value = null
            val uid = FirebaseAuth.getInstance().currentUser?.uid
            if (uid == null) {
                _lastError.value = "Not signed in"
                _status.value = TransferStatus.ERROR
                return@launch
            }
            val imported = runCatching { escrowImporter.importFromFirestore(uid, envelopeId) }
            imported.exceptionOrNull()?.let { error ->
                if (error is kotlinx.coroutines.CancellationException) throw error
                Log.e("BurnBar", "Escrow envelope import failed", error)
                _lastError.value = error.message ?: "Escrow import failed"
                _status.value = TransferStatus.ERROR
                return@launch
            }
            when (val result = imported.getOrThrow()) {
                is AndroidEscrowCredentialImporter.Result.Rejected -> {
                    _lastError.value = result.failure.userVisibleLabel
                    _status.value = TransferStatus.ERROR
                }
                is AndroidEscrowCredentialImporter.Result.PersistFailed -> {
                    _lastError.value = result.message
                    _status.value = TransferStatus.ERROR
                }
                is AndroidEscrowCredentialImporter.Result.Imported -> {
                    _status.value = TransferStatus.SUCCESS
                }
            }
        }
    }

    fun importCredentials(token: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.IMPORTING
            _lastError.value = null
            var claimedTransferId: String? = null
            var claimId: String? = null
            try {
                val uid = FirebaseAuth.getInstance().currentUser?.uid
                if (uid == null) {
                    _lastError.value = "Not signed in"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                val parsed = CredentialTransferCrypto.parseTransferToken(token)
                claimedTransferId = parsed.transferId
                val result = functions.getHttpsCallable("consumeCredentialTransfer")
                    .call(CredentialTransferCrypto.consumeTransferCallablePayload(parsed))
                    .await()
                val data = result.getData() as? Map<*, *>
                val encryptedPayload = data?.get("payload") as? String
                claimId = data?.get("claimId") as? String
                val activeClaimId = claimId
                if (encryptedPayload == null || activeClaimId == null) {
                    _lastError.value = "Invalid transfer payload"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                val decryptedJson = CredentialTransferCrypto.decryptPayload(
                    ciphertext = encryptedPayload,
                    secret = parsed.secret,
                    ownerUid = uid,
                    transferId = parsed.transferId,
                )
                require(decryptedJson.isNotBlank()) { "Invalid transfer payload" }

                functions.getHttpsCallable("completeCredentialTransfer")
                    .call(CredentialTransferCrypto.claimResolutionCallablePayload(parsed.transferId, activeClaimId))
                    .await()
                _status.value = TransferStatus.SUCCESS
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Import failed", e)
                _lastError.value = e.message
                _status.value = TransferStatus.ERROR
            } catch (e: javax.crypto.AEADBadTagException) {
                cancelClaimAfterDecryptFailure(claimedTransferId, claimId)
                Log.e("BurnBar", "Decryption failed for transfer payload", e)
                _lastError.value = "Decryption failed"
                _status.value = TransferStatus.ERROR
            } catch (e: GeneralSecurityException) {
                Log.e("BurnBar", "Credential decryption failed", e)
                _lastError.value = "Credential decryption failed"
                _status.value = TransferStatus.ERROR
            } catch (e: IllegalArgumentException) {
                Log.e("BurnBar", "Invalid transfer token", e)
                _lastError.value = "Invalid transfer token"
                _status.value = TransferStatus.ERROR
            }
        }
    }

    private fun cancelClaimAfterDecryptFailure(transferId: String?, claimId: String?) {
        if (transferId == null || claimId == null) return
        viewModelScope.launch {
            runCatching {
                functions.getHttpsCallable("cancelCredentialTransfer")
                    .call(CredentialTransferCrypto.claimResolutionCallablePayload(transferId, claimId))
                    .await()
            }.onFailure { error ->
                Log.w("BurnBar", "Unable to release credential transfer claim", error)
            }
        }
    }

    fun reset() {
        _status.value = TransferStatus.IDLE
        _lastError.value = null
        _transferToken.value = null
    }
}
