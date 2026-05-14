package com.openburnbar.data.hermes.relay

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import java.security.KeyFactory
import java.security.KeyPair
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec

/**
 * Per-app-install persistent client key store for the Hermes encrypted
 * relay. Persists both the PKCS#8 private key and the X9.63 public key
 * bytes side-by-side because Android's JCA can't derive an EC public
 * key from a private key alone.
 */
class HermesRelayKeyStore(context: Context) {

    private val prefs: SharedPreferences = context
        .applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun loadOrCreateClientKeyPair(): KeyPair {
        val storedPrivate = prefs.getString(KEY_PRIVATE_PKCS8, null)
        val storedPublic = prefs.getString(KEY_PUBLIC_X963, null)
        if (storedPrivate != null && storedPublic != null) {
            return runCatching { restore(storedPrivate, storedPublic) }
                .getOrElse {
                    prefs.edit().clear().apply()
                    generateAndStore()
                }
        }
        return generateAndStore()
    }

    fun clientPublicKeyX963(): ByteArray {
        val kp = loadOrCreateClientKeyPair()
        val publicKey = kp.public as java.security.interfaces.ECPublicKey
        return HermesRelayCrypto.encodeUncompressedPublicKey(publicKey)
    }

    private fun generateAndStore(): KeyPair {
        val kp = HermesRelayCrypto.generateEphemeralKeyPair()
        val privateBytes = kp.private.encoded
            ?: throw IllegalStateException("EC private key has no PKCS#8 encoding")
        val publicBytes = HermesRelayCrypto.encodeUncompressedPublicKey(
            kp.public as java.security.interfaces.ECPublicKey
        )
        prefs.edit()
            .putString(KEY_PRIVATE_PKCS8, Base64.encodeToString(privateBytes, Base64.NO_WRAP))
            .putString(KEY_PUBLIC_X963, Base64.encodeToString(publicBytes, Base64.NO_WRAP))
            .apply()
        return kp
    }

    private fun restore(privateB64: String, publicB64: String): KeyPair {
        val privateBytes = Base64.decode(privateB64, Base64.NO_WRAP)
        val publicBytes = Base64.decode(publicB64, Base64.NO_WRAP)
        val privateKey: PrivateKey = KeyFactory.getInstance("EC")
            .generatePrivate(PKCS8EncodedKeySpec(privateBytes))
        val publicKey = HermesRelayCrypto.decodeUncompressedPublicKey(publicBytes)
        return KeyPair(publicKey, privateKey)
    }

    companion object {
        private const val PREFS_NAME = "hermes_relay_keys"
        private const val KEY_PRIVATE_PKCS8 = "client_private_pkcs8_b64"
        private const val KEY_PUBLIC_X963 = "client_public_x963_b64"
    }
}
