@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F2 fail-closed tests for the Remote Config gate and the AndroidKeyStore
 * custody object. A plain JVM has neither a `FirebaseApp` nor the
 * `AndroidKeyStore` provider, which is exactly the documented fail-closed
 * environment: the gate must resolve to `false` and every keystore operation
 * must resolve to "no hardware key" (`null`/`false`) without throwing —
 * callers then keep the legacy Ed25519 identity instead of crashing or
 * half-minting a hardware one.
 */
class PhoneControlSecureEnclaveKeystoreTest {
    @Test
    fun `remote config key matches the cross platform flag name`() {
        // iOS reads the same key (PhoneControlSecureEnclaveKeyPolicy.remoteConfigKey);
        // renaming it on one platform would silently strand the other at default-off.
        assertEquals(
            "computer_use_phone_control_secure_enclave_key",
            PhoneControlSecureEnclaveKeyPolicy.REMOTE_CONFIG_KEY,
        )
    }

    @Test
    fun `gate defaults ON when firebase is unavailable`() {
        // Default-ON posture: with no FirebaseApp (so no fetched remote value
        // — the operator kill switch — can exist) the protection flag resolves
        // ON. Safety holds because the keystore mint itself falls back to the
        // legacy software key on any hardware/keystore failure.
        assertTrue(PhoneControlSecureEnclaveKeyPolicy.secureEnclaveKeyEnabled())
    }

    @Test
    fun `hasKey is false when the android keystore is unavailable`() {
        assertFalse(PhoneControlSecureEnclaveKeystore.hasKey())
    }

    @Test
    fun `loadIdentity resolves to null instead of throwing`() {
        assertNull(PhoneControlSecureEnclaveKeystore.loadIdentity())
    }

    @Test
    fun `mintIdentity never returns a partially minted identity`() {
        // Without StrongBox/TEE the caller must keep the legacy Ed25519 key —
        // a null here is the contract that prevents a silent identity rotation.
        assertNull(PhoneControlSecureEnclaveKeystore.mintIdentity())
    }

    @Test
    fun `deleteKey is a safe no op without a keystore`() {
        // Pairing reset must never crash on devices/processes without the
        // AndroidKeyStore provider.
        PhoneControlSecureEnclaveKeystore.deleteKey()
        assertFalse(PhoneControlSecureEnclaveKeystore.hasKey())
    }
}
