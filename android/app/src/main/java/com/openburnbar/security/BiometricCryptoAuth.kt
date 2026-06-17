package com.openburnbar.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

object BiometricCryptoAuth {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "openburnbar_strong_biometric_gate"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val AUTH_CHALLENGE_TEXT = "openburnbar-biometric-gate-v1"

    suspend fun requireStrongBiometric(activity: FragmentActivity, title: String, subtitle: String, failureMessage: String) {
        withContext(Dispatchers.Main) {
            val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG
            val manager = BiometricManager.from(activity)
            if (manager.canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
                error(failureMessage)
            }
            val cipher =
                try {
                    authenticatedCipher()
                } catch (_: KeyPermanentlyInvalidatedException) {
                    deleteKey()
                    authenticatedCipher()
                }
            suspendCancellableCoroutine { continuation ->
                val prompt =
                    BiometricPrompt(
                        activity,
                        ContextCompat.getMainExecutor(activity),
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                                if (!continuation.isActive) return
                                val authenticatedCipher = result.cryptoObject?.cipher
                                if (authenticatedCipher == null) {
                                    continuation.resumeWithException(IllegalStateException(failureMessage))
                                } else {
                                    try {
                                        proveCryptoAuthentication(authenticatedCipher)
                                        continuation.resume(Unit)
                                    } catch (_: GeneralSecurityException) {
                                        continuation.resumeWithException(IllegalStateException(failureMessage))
                                    }
                                }
                            }

                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                if (continuation.isActive) {
                                    continuation.resumeWithException(IllegalStateException(failureMessage))
                                }
                            }

                            override fun onAuthenticationFailed() = Unit
                        },
                    )
                val info =
                    BiometricPrompt.PromptInfo.Builder()
                        .setTitle(title)
                        .setSubtitle(subtitle)
                        .setAllowedAuthenticators(authenticators)
                        .build()
                continuation.invokeOnCancellation { prompt.cancelAuthentication() }
                prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
            }
        }
    }

    private fun proveCryptoAuthentication(cipher: Cipher) {
        cipher.doFinal(AUTH_CHALLENGE_TEXT.toByteArray(Charsets.UTF_8))
    }

    private fun authenticatedCipher(): Cipher {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val builder =
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(true)
                .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun deleteKey() {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply {
            load(null)
            deleteEntry(KEY_ALIAS)
        }
    }
}
