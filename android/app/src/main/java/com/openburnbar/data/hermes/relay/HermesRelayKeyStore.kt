package com.openburnbar.data.hermes.relay

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import com.openburnbar.irohrelay.IrohSecretKeyMaterial
import java.security.KeyFactory
import java.security.KeyPair
import java.security.PrivateKey
import java.security.SecureRandom
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

    /**
     * 32-byte iroh secret used to bootstrap the local iroh endpoint.
     * Generated lazily on first use and persisted alongside the relay
     * ECDH keypair. The iroh secret is INDEPENDENT from the relay
     * ECDH keypair — different algorithm (Curve25519 vs P-256), different
     * use (NodeId vs E2E sealing), so we never reuse bytes.
     */
    fun irohSecretKeyMaterial(): IrohSecretKeyMaterial {
        val stored = prefs.getString(KEY_IROH_SECRET, null)
        val raw = if (stored != null) {
            try {
                Base64.decode(stored, Base64.NO_WRAP).also {
                    if (it.size != 32) throw IllegalStateException("iroh secret length != 32")
                }
            } catch (_: Throwable) {
                generateIrohSecretAndStore()
            }
        } else {
            generateIrohSecretAndStore()
        }
        return IrohSecretKeyMaterial(raw)
    }

    private fun generateIrohSecretAndStore(): ByteArray {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit()
            .putString(KEY_IROH_SECRET, Base64.encodeToString(bytes, Base64.NO_WRAP))
            .apply()
        return bytes
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
        private const val KEY_PRIVATE_PKCS8 = "************************"
        private const val KEY_PUBLIC_X963 = "**********************"
        /** Persisted as a base64-encoded 32-byte secret; ed25519 surface form. */
        private const val KEY_IROH_SECRET = "iroh_secret_v1"
    }
}
