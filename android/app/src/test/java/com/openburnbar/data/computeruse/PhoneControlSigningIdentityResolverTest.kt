package com.openburnbar.data.computeruse

import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Test

class PhoneControlSigningIdentityResolverTest {
    private val legacyIdentity = PhoneControlSigningIdentity.Ed25519(ByteArray(32) { index -> (index + 1).toByte() })

    @Test
    fun `disabled hardware ramp ignores an existing p256 alias`() {
        val existing = softwareP256Identity()
        val hardwareStore = FakeHardwareSigningStore(existing = existing)

        val resolved =
            PhoneControlSigningIdentityResolver.resolve(
                secureEnclaveEnabled = false,
                hardwareSigningStore = hardwareStore,
                legacyIdentity = { legacyIdentity },
            )

        assertSame(legacyIdentity, resolved)
        assertEquals(PhoneControlSigningKeyKind.ED25519, resolved.kind)
        assertFalse("disabled ramp must not load a stale hardware signer", hardwareStore.loadCalled)
        assertFalse("disabled ramp must not mint a hardware signer", hardwareStore.mintCalled)
    }

    @Test
    fun `enabled hardware ramp prefers an existing p256 identity`() {
        val existing = softwareP256Identity()
        val hardwareStore = FakeHardwareSigningStore(existing = existing)

        val resolved =
            PhoneControlSigningIdentityResolver.resolve(
                secureEnclaveEnabled = true,
                hardwareSigningStore = hardwareStore,
                legacyIdentity = { legacyIdentity },
            )

        assertSame(existing, resolved)
        assertEquals(PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256, resolved.kind)
        assertFalse("existing hardware signer should not be replaced", hardwareStore.mintCalled)
    }

    @Test
    fun `enabled hardware ramp mints once when no existing p256 identity is present`() {
        val minted = softwareP256Identity()
        val hardwareStore = FakeHardwareSigningStore(minted = minted)

        val resolved =
            PhoneControlSigningIdentityResolver.resolve(
                secureEnclaveEnabled = true,
                hardwareSigningStore = hardwareStore,
                legacyIdentity = { legacyIdentity },
            )

        assertSame(minted, resolved)
        assertEquals(PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256, resolved.kind)
    }

    @Test
    fun `enabled hardware ramp falls back to legacy identity when hardware is unavailable`() {
        val hardwareStore = FakeHardwareSigningStore()

        val resolved =
            PhoneControlSigningIdentityResolver.resolve(
                secureEnclaveEnabled = true,
                hardwareSigningStore = hardwareStore,
                legacyIdentity = { legacyIdentity },
            )

        assertSame(legacyIdentity, resolved)
        assertEquals(PhoneControlSigningKeyKind.ED25519, resolved.kind)
    }

    private class FakeHardwareSigningStore(
        private val existing: PhoneControlSigningIdentity.SecureEnclaveP256? = null,
        private val minted: PhoneControlSigningIdentity.SecureEnclaveP256? = null,
    ) : PhoneControlHardwareSigningIdentityStore {
        var loadCalled = false
            private set
        var mintCalled = false
            private set

        override fun loadIdentity(): PhoneControlSigningIdentity.SecureEnclaveP256? {
            loadCalled = true
            return existing
        }

        override fun hasKey(): Boolean = existing != null

        override fun mintIdentity(): PhoneControlSigningIdentity.SecureEnclaveP256? {
            mintCalled = true
            return minted
        }

        override fun deleteKey() = Unit
    }

    private fun softwareP256Identity(): PhoneControlSigningIdentity.SecureEnclaveP256 {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        return PhoneControlSigningIdentity.SecureEnclaveP256(
            pair.private,
            pair.public as? ECPublicKey ?: error("expected EC public key"),
        )
    }
}
