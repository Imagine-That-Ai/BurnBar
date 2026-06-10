package com.openburnbar.data.computeruse

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.annotation.RequiresApi
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * F2 — Remote Config gate for minting biometry-gated StrongBox/TEE
 * phone-control signing keys. Android mirror of the Swift
 * `PhoneControlSecureEnclaveKeyPolicy` + `MobileComputerUseRemoteConfig`.
 *
 * Default-off: no Android client mints a hardware key (and therefore no
 * client emits `keyKind: "se-p256"`) until the flag is ramped, so pre-F2
 * pairings keep working unchanged. This is the first Remote Config read in
 * the Android app — `getBoolean` resolves to the static default (`false`)
 * until a fetch-and-activate ramp lands, and any Firebase initialization
 * failure (e.g. unit tests) also resolves to `false`, so the gate fails
 * closed in every environment.
 */
object PhoneControlSecureEnclaveKeyPolicy {
    /** Same key the iOS client reads (`PhoneControlSecureEnclaveKeyPolicy.remoteConfigKey`). */
    const val REMOTE_CONFIG_KEY = "computer_use_phone_control_secure_enclave_key"

    fun secureEnclaveKeyEnabled(): Boolean =
        runCatching { FirebaseRemoteConfig.getInstance().getBoolean(REMOTE_CONFIG_KEY) }
            .getOrDefault(false)
}

/**
 * F2 — AndroidKeyStore custody for the non-exportable P-256 phone-control
 * signing key: the Android mirror of the iOS `PhoneControlSigningKeyStore`
 * Secure-Enclave minting path (`PhoneControlSender.swift`).
 *
 * The key is minted `PURPOSE_SIGN`/`SHA256withECDSA` on secp256r1, preferring
 * StrongBox with a TEE fallback when `StrongBoxUnavailableException` is
 * thrown. `setUserAuthenticationRequired(true)` with per-use
 * `AUTH_BIOMETRIC_STRONG` (API 30+) and
 * `setInvalidatedByBiometricEnrollment(true)` make every signature a
 * biometric step-up — the OS refuses to sign without a live biometric match,
 * mirroring the iOS `.biometryCurrentSet` access control.
 */
internal object PhoneControlSecureEnclaveKeystore {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "ai.openburnbar.computer-use-phone-control.se-p256"

    /**
     * The already-minted hardware identity, or `null` when none exists. A
     * present-but-unusable entry also resolves to `null` (the caller falls
     * back to the legacy key rather than silently re-minting a new identity —
     * the published peerNodeId pins this key).
     */
    fun loadIdentity(): PhoneControlSigningIdentity.SecureEnclaveP256? = runCatching {
        val store = keystore()
        val entry = store.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry ?: return@runCatching null
        val publicKey = entry.certificate.publicKey as? ECPublicKey ?: return@runCatching null
        PhoneControlSigningIdentity.SecureEnclaveP256(entry.privateKey, publicKey)
    }.getOrNull()

    /** Whether a hardware key has already been minted under the alias. */
    fun hasKey(): Boolean = runCatching { keystore().containsAlias(KEY_ALIAS) }.getOrDefault(false)

    /**
     * Mint the biometry-gated hardware key. Returns `null` when the keystore
     * is unavailable or generation fails — the caller keeps the legacy
     * Ed25519 identity, never a partially-minted one. Never overwrites an
     * existing alias.
     */
    fun mintIdentity(): PhoneControlSigningIdentity.SecureEnclaveP256? = runCatching {
        if (hasKey()) return@runCatching loadIdentity()
        val keyPair =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                generatePreferringStrongBox()
            } else {
                generate(strongBoxBacked = false)
            }
        val publicKey = keyPair.public as? ECPublicKey ?: return@runCatching null
        PhoneControlSigningIdentity.SecureEnclaveP256(keyPair.private, publicKey)
    }.getOrNull()

    /** Remove the hardware key (pairing reset). */
    fun deleteKey() {
        runCatching { keystore().deleteEntry(KEY_ALIAS) }
    }

    @RequiresApi(Build.VERSION_CODES.P)
    private fun generatePreferringStrongBox(): KeyPair = try {
        generate(strongBoxBacked = true)
    } catch (_: StrongBoxUnavailableException) {
        generate(strongBoxBacked = false)
    }

    private fun generate(strongBoxBacked: Boolean): KeyPair {
        val builder =
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(true)
                .setInvalidatedByBiometricEnrollment(true)
        if (strongBoxBacked && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Timeout 0 = authenticate per use; BIOMETRIC_STRONG only (no
            // device-credential downgrade) — the F2 step-up evidence.
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        generator.initialize(builder.build())
        return generator.generateKeyPair()
    }

    private fun keystore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
}
