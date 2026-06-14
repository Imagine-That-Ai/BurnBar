package com.openburnbar.data.hermes.relay

import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit coverage for [SharedPreferencesIrohPairingHostKeyPinStore] driven through
 * the [IrohPairingHostKeyPinPersistence] seam so the trust-on-first-use pinning,
 * key-change rejection, persistence fail-closed, and scoping semantics can be
 * verified without an Android Keystore / Robolectric.
 *
 * The production store binds this same logic to an [EncryptedSharedPreferences]
 * persistence (Android Keystore-backed AES-256), so this exercises the exact
 * branch logic the encrypted store runs at rest (M-006).
 */
class IrohPairingHostKeyPinStoreTest {
    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            // The fingerprint/scoped-uid use URL_SAFE | NO_PADDING; mirror that
            // so two distinct keys map to two distinct fingerprints.
            Base64.getUrlEncoder().withoutPadding().encodeToString(firstArg<ByteArray>())
        }
    }

    @After
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    private class FakePinPersistence(
        var commitResult: Boolean = true,
        var throwOnPut: Boolean = false,
        var throwOnGet: Boolean = false,
    ) : IrohPairingHostKeyPinPersistence {
        val strings = mutableMapOf<String, String>()
        val longs = mutableMapOf<String, Long>()

        override fun getString(key: String): String? {
            if (throwOnGet) throw IllegalStateException("keystore unavailable")
            return strings[key]
        }

        override fun putPin(pinKey: String, fingerprint: String, firstSeenKey: String, firstSeenMillis: Long): Boolean {
            if (throwOnPut) throw IllegalStateException("keystore write failed")
            if (!commitResult) return false
            strings[pinKey] = fingerprint
            longs[firstSeenKey] = firstSeenMillis
            return true
        }

        override fun remove(vararg keys: String) {
            keys.forEach {
                strings.remove(it)
                longs.remove(it)
            }
        }
    }

    private fun store(persistence: IrohPairingHostKeyPinPersistence): SharedPreferencesIrohPairingHostKeyPinStore =
        SharedPreferencesIrohPairingHostKeyPinStore(persistence)

    @Test
    fun first_use_pins_the_host_key_and_records_first_seen() {
        val persistence = FakePinPersistence()
        val pinStore = store(persistence)
        val uid = "uid-first"
        val key = ByteArray(32) { 0x11 }

        val returned = pinStore.requireTrustedHostKey(uid, key)

        assertTrue("returned key must equal advertised key", returned.contentEquals(key))
        assertEquals(1, persistence.strings.size)
        assertEquals(1, persistence.longs.size)
        assertEquals(
            IrohPairingHostKeyPinning.fingerprint(key),
            persistence.strings.values.first(),
        )
    }

    @Test
    fun same_host_key_on_second_fetch_is_accepted() {
        val persistence = FakePinPersistence()
        val pinStore = store(persistence)
        val uid = "uid-stable"
        val key = ByteArray(32) { 0x22 }

        pinStore.requireTrustedHostKey(uid, key)
        val again = pinStore.requireTrustedHostKey(uid, key)

        assertTrue(again.contentEquals(key))
        // No second write: the pin already matched.
        assertEquals(1, persistence.strings.size)
    }

    @Test
    fun substituted_host_key_is_rejected_with_key_change_exception() {
        val persistence = FakePinPersistence()
        val pinStore = store(persistence)
        val uid = "uid-mismatch"
        val pinnedKey = ByteArray(32) { 0x33 }
        val substitutedKey = ByteArray(32) { 0x44 }

        pinStore.requireTrustedHostKey(uid, pinnedKey)

        val thrown =
            assertThrows(IrohPairingHostKeyChangedException::class.java) {
                pinStore.requireTrustedHostKey(uid, substitutedKey)
            }
        assertEquals(IrohPairingHostKeyPinning.fingerprint(pinnedKey), thrown.expectedFingerprint)
        assertEquals(IrohPairingHostKeyPinning.fingerprint(substitutedKey), thrown.observedFingerprint)
        assertNotEquals(thrown.expectedFingerprint, thrown.observedFingerprint)
    }

    @Test
    fun persistence_failure_on_first_use_fails_closed() {
        val persistence = FakePinPersistence(commitResult = false)
        val pinStore = store(persistence)

        assertThrows(IrohPairingHostKeyPinPersistenceException::class.java) {
            pinStore.requireTrustedHostKey("uid-nopersist", ByteArray(32) { 0x55 })
        }
    }

    @Test
    fun keystore_write_exception_on_first_use_fails_closed() {
        val persistence = FakePinPersistence(throwOnPut = true)
        val pinStore = store(persistence)

        assertThrows(IrohPairingHostKeyPinPersistenceException::class.java) {
            pinStore.requireTrustedHostKey("uid-throw-put", ByteArray(32) { 0x56 })
        }
    }

    @Test
    fun keystore_read_exception_fails_closed() {
        val persistence = FakePinPersistence(throwOnGet = true)
        val pinStore = store(persistence)

        assertThrows(IrohPairingHostKeyPinPersistenceException::class.java) {
            pinStore.requireTrustedHostKey("uid-throw-get", ByteArray(32) { 0x57 })
        }
    }

    @Test
    fun clear_allows_re_pinning_a_new_host_key() {
        val persistence = FakePinPersistence()
        val pinStore = store(persistence)
        val uid = "uid-clear"
        val firstKey = ByteArray(32) { 0x66 }
        val newKey = ByteArray(32) { 0x77 }

        pinStore.requireTrustedHostKey(uid, firstKey)
        pinStore.clearTrustedHostKey(uid)
        assertTrue(persistence.strings.isEmpty())

        // After a deliberate clear, a brand-new host key is adopted on first use.
        val adopted = pinStore.requireTrustedHostKey(uid, newKey)
        assertTrue(adopted.contentEquals(newKey))
        assertEquals(IrohPairingHostKeyPinning.fingerprint(newKey), persistence.strings.values.first())
    }

    @Test
    fun pins_are_scoped_per_uid() {
        val persistence = FakePinPersistence()
        val pinStore = store(persistence)
        val keyA = ByteArray(32) { 0x01 }
        val keyB = ByteArray(32) { 0x02 }

        // Different users pinning different keys do not collide.
        pinStore.requireTrustedHostKey("uid-a", keyA)
        pinStore.requireTrustedHostKey("uid-b", keyB)
        assertEquals(2, persistence.strings.size)

        // And uid-a is unaffected by uid-b's pin.
        val reA = pinStore.requireTrustedHostKey("uid-a", keyA)
        assertTrue(reA.contentEquals(keyA))
    }

    @Test
    fun clearing_one_uid_does_not_clear_another() {
        val persistence = FakePinPersistence()
        val pinStore = store(persistence)
        val keyA = ByteArray(32) { 0x03 }
        val keyB = ByteArray(32) { 0x04 }
        pinStore.requireTrustedHostKey("uid-x", keyA)
        pinStore.requireTrustedHostKey("uid-y", keyB)

        pinStore.clearTrustedHostKey("uid-x")

        // uid-y still pinned → substituting its key still fails closed.
        assertThrows(IrohPairingHostKeyChangedException::class.java) {
            pinStore.requireTrustedHostKey("uid-y", ByteArray(32) { 0x09 })
        }
        // uid-x was cleared → its slot is gone.
        assertNull(persistence.strings["host_key_pin_v1.${IrohPairingHostKeyPinning.scopedUid("uid-x")}"])
    }
}
