package com.openburnbar.data.computeruse

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

private const val AES_KEY_BITS = 256

/**
 * Android-local Remote Unlock credential persistence. The Mac never receives
 * anything at rest from this store: passwords are AES-GCM wrapped with an
 * AndroidKeyStore key, scoped per Remote Unlock recipient, and decrypted only
 * after the caller has completed BiometricPrompt / device-credential auth.
 *
 * T-AND-05: beyond the AndroidKeyStore backstop (the wrapping key is itself
 * `setUserAuthenticationRequired(true)`), [load] is CODE-LEVEL coupled to a prior
 * successful BiometricPrompt: the `authenticateForRemoteUnlock` success path calls
 * [recordAuthenticationSuccess], minting a short-lived single-use ticket that [load]
 * requires and consumes. A caller that reaches [load] without first authenticating —
 * a reordered call site, a future refactor, or a test harness — gets `null` and a
 * logged refusal rather than the plaintext credential, so the biometric gate cannot be
 * silently bypassed by a code path that merely possesses the store reference.
 */
class RemoteUnlockSavedCredentialStore internal constructor(
    context: Context,
    /** Monotonic clock (ms). Injectable so the auth-ticket gate is unit-testable off-device;
     *  production uses [SystemClock.elapsedRealtime]. */
    private val elapsedRealtimeMillis: () -> Long,
) {
    constructor(context: Context) : this(context, { SystemClock.elapsedRealtime() })

    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * Single-use authentication ticket gating [load]. Holds the elapsed-realtime millis at which
     * the most recent BiometricPrompt succeeded; cleared (consumed) on the next [load], and ignored
     * once older than [AUTH_TICKET_VALIDITY_MILLIS]. `AtomicReference` so the success callback (main
     * thread) and the load (IO coroutine) hand the ticket off without a data race.
     */
    private val authTicket = AtomicReference<Long?>(null)

    /**
     * Record a successful BiometricPrompt / device-credential authentication, minting the single-use
     * ticket the next [load] consumes. Call this ONLY from the verified BiometricPrompt
     * `onAuthenticationSucceeded` callback.
     */
    fun recordAuthenticationSuccess() {
        authTicket.set(elapsedRealtimeMillis())
    }

    /** Whether a fresh, unconsumed authentication ticket is currently present (does not consume it). */
    fun hasFreshAuthentication(): Boolean = isTicketFresh(authTicket.get())

    /** Test/seam hook: consume the current ticket the same way [load] does, returning its freshness. */
    internal fun consumeAuthenticationTicketForTest(): Boolean = isTicketFresh(authTicket.getAndSet(null))

    private fun isTicketFresh(stampMillis: Long?): Boolean {
        if (stampMillis == null) return false
        val age = elapsedRealtimeMillis() - stampMillis
        return age in 0..AUTH_TICKET_VALIDITY_MILLIS
    }

    fun hasCredential(storeKey: String): Boolean {
        val key = scopedKey(storeKey)
        return prefs.contains(ciphertextPreferenceKey(key)) && prefs.contains(ivPreferenceKey(key))
    }

    fun save(storeKey: String, credential: String) {
        val secretKey = wrappingKey()
        val cipher =
            Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                init(Cipher.ENCRYPT_MODE, secretKey)
            }
        val iv = cipher.iv
        require(iv.size == GCM_IV_BYTES) { "Unexpected AES-GCM IV length ${iv.size}" }
        val wrapped = cipher.doFinal(credential.toByteArray(Charsets.UTF_8))
        val key = scopedKey(storeKey)
        prefs.edit()
            .putString(ciphertextPreferenceKey(key), Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .putString(ivPreferenceKey(key), Base64.encodeToString(iv, Base64.NO_WRAP))
            .apply()
    }

    fun load(storeKey: String): String? {
        // T-AND-05: consume the single-use authentication ticket. No fresh ticket ⇒ refuse to
        // surface the plaintext credential even though the Keystore backstop would also gate the
        // underlying decrypt — fail closed at the code level so a caller cannot read the store
        // without a prior `authenticateForRemoteUnlock`.
        val ticket = authTicket.getAndSet(null)
        if (!isTicketFresh(ticket)) {
            Log.w(
                "RemoteUnlockSavedCredentialStore",
                "load() refused: no fresh BiometricPrompt authentication ticket (authenticateForRemoteUnlock required first).",
            )
            return null
        }
        val key = scopedKey(storeKey)
        val wrappedB64 = prefs.getString(ciphertextPreferenceKey(key), null)
        val ivB64 = prefs.getString(ivPreferenceKey(key), null)
        val wrapped = wrappedB64?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() }
        val iv = ivB64?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() }
        val secretKey = runCatching { wrappingKey() }.getOrNull()
        if (wrapped == null || iv == null || secretKey == null) return null
        return try {
            val cipher =
                Cipher.getInstance(AES_GCM_TRANSFORM).apply {
                    init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
                }
            cipher.doFinal(wrapped).toString(Charsets.UTF_8)
        } catch (_: Throwable) {
            null
        }
    }

    fun delete(storeKey: String) {
        val key = scopedKey(storeKey)
        prefs.edit()
            .remove(ciphertextPreferenceKey(key))
            .remove(ivPreferenceKey(key))
            .apply()
    }

    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        store.getEntry(KEY_ALIAS, null)?.let { entry ->
            val secretEntry =
                entry as? KeyStore.SecretKeyEntry
                    ?: error("Keystore entry $KEY_ALIAS is not a secret key")
            return secretEntry.secretKey
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec =
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(AES_KEY_BITS)
                .setUserAuthenticationRequired(true)
                .applyUserAuthenticationParameters()
                .setInvalidatedByBiometricEnrollment(true)
                .build()
        generator.init(spec)
        return generator.generateKey()
    }

    @Suppress("DEPRECATION")
    private fun KeyGenParameterSpec.Builder.applyUserAuthenticationParameters(): KeyGenParameterSpec.Builder =
        apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setUserAuthenticationParameters(
                    0,
                    KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                )
            } else {
                setUserAuthenticationValidityDurationSeconds(-1)
            }
        }

    private fun scopedKey(storeKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(storeKey.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(digest, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    }

    private fun ciphertextPreferenceKey(scopedKey: String): String = "credential.$scopedKey"

    private fun ivPreferenceKey(scopedKey: String): String = "iv.$scopedKey"

    companion object {
        /**
         * How long (ms) a BiometricPrompt success ticket stays valid for a single [load].
         * Short — the UI authenticates immediately before reading — so a stale success cannot be
         * replayed long after the prompt.
         */
        const val AUTH_TICKET_VALIDITY_MILLIS = 30_000L
        private const val PREFS_NAME = "remote_unlock_saved_credentials"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "ai.openburnbar.remote-unlock.saved-credential"
        private const val AES_GCM_TRANSFORM = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }
}
