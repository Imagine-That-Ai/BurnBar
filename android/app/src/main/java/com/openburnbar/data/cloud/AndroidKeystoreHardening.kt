package com.openburnbar.data.cloud

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * Which hardware/auth protections a wrapping-key generation attempt requests. Pure value
 * type so the [AndroidKeystoreHardening] fallback ladder is unit-testable on the JVM
 * without the (device-only) AndroidKeyStore provider.
 */
internal data class KeystoreHardeningProfile(
    val strongBox: Boolean,
    val userAuth: Boolean,
)

/**
 * T-AND-01 — shared AndroidKeyStore hardening for the AES-GCM wrapping keys that
 * protect the cloud-vault device keypair, the Signal at-rest identity key, and the
 * Hermes relay client key at rest (all three persist their secret bytes as
 * AES-GCM ciphertext in SharedPreferences, with the wrapping key materialized
 * inside the AndroidKeyStore — see [AndroidLocalSecretBox] and
 * `HermesRelayKeyStore.wrappingKey`).
 *
 * Two protections are layered on, both with graceful fallback so an unusual device
 * never loses the ability to mint the key (which would brick the feature):
 *
 *  1. **StrongBox** (`setIsStrongBoxBacked(true)`, API 28+): when the device has a
 *     dedicated hardware security module the wrapping key lives there, so the
 *     wrapped secret cannot be extracted even from a rooted / forensic image. A
 *     device without StrongBox throws [StrongBoxUnavailableException] at
 *     `generateKey()`, so we transparently retry without it (still TEE-backed on
 *     any modern device) — mirroring `PhoneControlSecureEnclaveKeystore`.
 *
 *  2. **User authentication** (`setUserAuthenticationRequired(true)`): the OS
 *     refuses to release the key unless the user has authenticated. To keep the
 *     non-interactive read/write paths (background chat sync, relay bootstrap,
 *     warm app start while the device is unlocked) working, the key is bound to a
 *     recent device-unlock *window* — `AUTH_DEVICE_CREDENTIAL or
 *     AUTH_BIOMETRIC_STRONG` with a validity duration — rather than a per-use
 *     biometric prompt. The forensic-extraction value is the same (an attacker
 *     imaging a powered-off / locked device can never satisfy the auth), while a
 *     legitimate unlocked device keeps decrypting transparently.
 *
 * The user-auth binding is itself best-effort: a device with NO secure lock
 * screen cannot enroll an auth-bound key (`generateKey()` throws), so we fall back
 * one more step to a non-auth-bound key. On such a device there is no secret to
 * gate against in the first place (no keyguard), so this preserves functionality
 * without weakening any protection the device could actually offer.
 */
internal object AndroidKeystoreHardening {
    /** Device-unlock window, in seconds, the auth-bound wrapping key stays usable for. */
    const val USER_AUTH_VALIDITY_SECONDS = 60

    /**
     * The order generation attempts are made in: most-protected first, degrading in
     * well-defined steps so an unusual device still ends up with a usable key (fail-open
     * on the protection, never on the functionality). Pure + unit-tested.
     */
    val FALLBACK_LADDER: List<KeystoreHardeningProfile> =
        listOf(
            KeystoreHardeningProfile(strongBox = true, userAuth = true),
            KeystoreHardeningProfile(strongBox = false, userAuth = true),
            KeystoreHardeningProfile(strongBox = true, userAuth = false),
            KeystoreHardeningProfile(strongBox = false, userAuth = false),
        )

    /**
     * Walk [FALLBACK_LADDER], invoking [attempt] for each profile until one succeeds.
     * Pure (no AndroidKeyStore dependency) so the fallback semantics are unit-testable:
     * the first non-throwing attempt wins and its result is returned; if every attempt
     * throws, the LAST failure is rethrown. Extracted so a test can assert that a
     * StrongBox-unavailable device still mints an auth-bound key and a lock-screen-less
     * device still mints *some* key.
     */
    @Suppress("TooGenericExceptionCaught") // any keystore-generation failure (StrongBox unavailable,
    // no secure lock screen, provider error) must degrade to the next, less-hardened profile.
    fun <T> generateWithFallback(attempt: (KeystoreHardeningProfile) -> T): T {
        var lastError: Throwable? = null
        for (profile in FALLBACK_LADDER) {
            try {
                return attempt(profile)
            } catch (error: Throwable) {
                lastError = error
            }
        }
        lastError?.let { throw it }
        error("Keystore hardening produced no generation attempt")
    }

    /**
     * Generate an AES-GCM wrapping key under [alias] in the AndroidKeyStore, hardened
     * with StrongBox + user-authentication where the device supports them and degrading
     * gracefully where it does not. [configure] applies the caller's block mode / padding
     * / key-size (kept caller-side so each store keeps its existing parameters).
     */
    fun generateHardenedWrappingKey(
        androidKeyStore: String,
        alias: String,
        configure: KeyGenParameterSpec.Builder.() -> Unit,
    ): SecretKey =
        generateWithFallback { profile -> build(androidKeyStore, alias, profile, configure) }

    /**
     * Apply [profile] to a builder. Pure (no keystore I/O) so a test can assert that the
     * `userAuth` profile sets `setUserAuthenticationRequired(true)` + the unlock window and
     * the StrongBox profile requests StrongBox on supported API levels.
     */
    fun configureBuilder(builder: KeyGenParameterSpec.Builder, profile: KeystoreHardeningProfile) {
        if (profile.strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        if (profile.userAuth) {
            builder.setUserAuthenticationRequired(true)
            applyUserAuthenticationWindow(builder)
        }
    }

    private fun build(
        androidKeyStore: String,
        alias: String,
        profile: KeystoreHardeningProfile,
        configure: KeyGenParameterSpec.Builder.() -> Unit,
    ): SecretKey {
        val builder =
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).apply(configure)
        configureBuilder(builder, profile)
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, androidKeyStore)
        generator.init(builder.build())
        return generator.generateKey()
    }

    /**
     * Bind the key to a recent device-unlock *window* (not a per-use prompt) so the
     * non-interactive sync/bootstrap paths keep working while the device is unlocked.
     * `AUTH_DEVICE_CREDENTIAL or AUTH_BIOMETRIC_STRONG` accepts either the device
     * lock-screen credential or a strong biometric, matching the protection a
     * forensic image cannot reproduce.
     */
    @Suppress("DEPRECATION")
    private fun applyUserAuthenticationWindow(builder: KeyGenParameterSpec.Builder) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(
                USER_AUTH_VALIDITY_SECONDS,
                KeyProperties.AUTH_DEVICE_CREDENTIAL or KeyProperties.AUTH_BIOMETRIC_STRONG,
            )
        } else {
            builder.setUserAuthenticationValidityDurationSeconds(USER_AUTH_VALIDITY_SECONDS)
        }
    }
}
