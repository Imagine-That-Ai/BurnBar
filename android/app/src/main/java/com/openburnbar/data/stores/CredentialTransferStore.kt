package com.openburnbar.data.stores

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.Timestamp
import com.google.firebase.FirebaseException
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.util.Base64
import java.util.Date
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
    const val MINUTES_PER_HOUR = 60
    const val SECONDS_PER_MINUTE = 60
    const val MILLIS_PER_SECOND = 1_000L
    const val TRANSFER_CODE_LENGTH = 12
    const val KEY_DERIVATION_ITERATIONS = 210_000
    const val KEY_LENGTH_BITS = 256
    const val GCM_TAG_LENGTH_BITS = 128
    const val SALT_LENGTH_BYTES = 16
    const val IV_LENGTH_BYTES = 12
    const val ENVELOPE_VERSION = "v1"
}

internal object CredentialTransferCrypto {
    private const val CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    private val codeRegex = Regex("^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{12}$")

    fun generateTransferCode(): String {
        val secureRandom = SecureRandom()
        return (1..CredentialTransferConstants.TRANSFER_CODE_LENGTH)
            .map { CODE_ALPHABET[secureRandom.nextInt(CODE_ALPHABET.length)] }
            .joinToString("")
    }

    fun normalizeTransferCode(code: String): String =
        code.trim()
            .uppercase(Locale.US)
            .replace("-", "")
            .replace(" ", "")

    fun isValidTransferCode(code: String): Boolean = codeRegex.matches(code)

    fun encryptPayload(plaintext: String, code: String): String {
        val salt = randomBytes(CredentialTransferConstants.SALT_LENGTH_BYTES)
        val iv = randomBytes(CredentialTransferConstants.IV_LENGTH_BYTES)
        val key = deriveKeyFromCode(code, salt)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.ENCRYPT_MODE,
            key,
            GCMParameterSpec(CredentialTransferConstants.GCM_TAG_LENGTH_BITS, iv),
        )
        val encrypted = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return listOf(
            CredentialTransferConstants.ENVELOPE_VERSION,
            encodeBase64Url(salt),
            encodeBase64Url(iv),
            encodeBase64Url(encrypted),
        ).joinToString(".")
    }

    fun decryptPayload(ciphertext: String, code: String): String {
        val parts = ciphertext.split(".")
        require(parts.size == 4 && parts[0] == CredentialTransferConstants.ENVELOPE_VERSION) {
            "Unsupported transfer payload"
        }
        val salt = decodeBase64Url(parts[1])
        val iv = decodeBase64Url(parts[2])
        val encrypted = decodeBase64Url(parts[3])
        require(salt.size == CredentialTransferConstants.SALT_LENGTH_BYTES) {
            "Invalid transfer payload"
        }
        require(iv.size == CredentialTransferConstants.IV_LENGTH_BYTES) {
            "Invalid transfer payload"
        }
        val key = deriveKeyFromCode(code, salt)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(CredentialTransferConstants.GCM_TAG_LENGTH_BITS, iv),
        )
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun deriveKeyFromCode(code: String, salt: ByteArray): SecretKey {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = PBEKeySpec(
            code.toCharArray(),
            salt,
            CredentialTransferConstants.KEY_DERIVATION_ITERATIONS,
            CredentialTransferConstants.KEY_LENGTH_BITS,
        )
        return SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
    }

    private fun randomBytes(length: Int): ByteArray {
        val bytes = ByteArray(length)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    private fun encodeBase64Url(bytes: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    private fun decodeBase64Url(value: String): ByteArray =
        Base64.getUrlDecoder().decode(value)
}

enum class TransferStatus { IDLE, EXPORTING, IMPORTING, SUCCESS, ERROR }

class CredentialTransferStore : ViewModel() {
    private val db: FirebaseFirestore = Firebase.firestore
    private val functions = Firebase.functions("us-central1")

    private val _status = MutableStateFlow(TransferStatus.IDLE)
    val status: StateFlow<TransferStatus> = _status.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _transferCode = MutableStateFlow<String?>(null)
    val transferCode: StateFlow<String?> = _transferCode.asStateFlow()

    fun exportCredentials(credentialsJson: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.EXPORTING
            _lastError.value = null
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
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
                val code = CredentialTransferCrypto.generateTransferCode()
                val encryptedPayload = CredentialTransferCrypto.encryptPayload(credentialsJson, code)
                db.collection("credential_transfers").document(code)
                    .set(
                        mapOf(
                            "ownerUid" to uid,
                            "payload" to encryptedPayload,
                            "createdAt" to Date(),
                            "expiresAt" to
                                Date(
                                    System.currentTimeMillis() +
                                        CredentialTransferConstants.TRANSFER_TTL_HOURS *
                                        CredentialTransferConstants.MINUTES_PER_HOUR *
                                        CredentialTransferConstants.SECONDS_PER_MINUTE *
                                        CredentialTransferConstants.MILLIS_PER_SECOND,
                                ),
                            "consumed" to false,
                        ),
                    ).await()
                _transferCode.value = code
                _status.value = TransferStatus.SUCCESS
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Export failed", e)
                _lastError.value = e.message
                _status.value = TransferStatus.ERROR
            } catch (e: GeneralSecurityException) {
                Log.e("BurnBar", "Credential encryption failed", e)
                _lastError.value = "Credential encryption failed"
                _status.value = TransferStatus.ERROR
            }
        }
    }

    fun importCredentials(code: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.IMPORTING
            _lastError.value = null
            try {
                val normalizedCode = CredentialTransferCrypto.normalizeTransferCode(code)
                if (!CredentialTransferCrypto.isValidTransferCode(normalizedCode)) {
                    _lastError.value = "Invalid transfer code"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                val result = functions.getHttpsCallable("consumeCredentialTransfer")
                    .call(mapOf("code" to normalizedCode))
                    .await()
                val data = result.data as? Map<*, *>
                val encryptedPayload = data?.get("payload") as? String
                if (encryptedPayload == null) {
                    _lastError.value = "Invalid transfer payload"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                val decryptedJson = CredentialTransferCrypto.decryptPayload(encryptedPayload, normalizedCode)
                require(decryptedJson.isNotBlank()) { "Invalid transfer payload" }
                _status.value = TransferStatus.SUCCESS
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Import failed", e)
                _lastError.value = e.message
                _status.value = TransferStatus.ERROR
            } catch (e: javax.crypto.AEADBadTagException) {
                Log.e("BurnBar", "Decryption failed — wrong code or tampered payload", e)
                _lastError.value = "Decryption failed — wrong code or tampered payload"
                _status.value = TransferStatus.ERROR
            } catch (e: GeneralSecurityException) {
                Log.e("BurnBar", "Credential decryption failed", e)
                _lastError.value = "Credential decryption failed"
                _status.value = TransferStatus.ERROR
            } catch (e: IllegalArgumentException) {
                Log.e("BurnBar", "Invalid transfer payload", e)
                _lastError.value = "Invalid transfer payload"
                _status.value = TransferStatus.ERROR
            }
        }
    }

    private fun transferExpiryMillis(value: Any?): Long? = when (value) {
        is Date -> value.time
        is Timestamp -> value.toDate().time
        else -> null
    }

    fun reset() {
        _status.value = TransferStatus.IDLE
        _lastError.value = null
        _transferCode.value = null
    }
}
