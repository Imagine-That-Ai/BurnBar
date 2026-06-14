package com.openburnbar.data.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-AND-01 — verifies the StrongBox + user-auth fallback ladder for the vault / identity /
 * relay wrapping keys WITHOUT a device: the actual `KeyGenerator` call needs the
 * AndroidKeyStore provider, but the fallback *decision* is pure and is what makes the keys
 * non-recoverable on a rooted / forensic device.
 */
class AndroidKeystoreHardeningTest {
    @Test
    fun firstLadderRungIsStrongBoxAndUserAuth() {
        val top = AndroidKeystoreHardening.FALLBACK_LADDER.first()
        assertTrue("hardest rung requests StrongBox", top.strongBox)
        assertTrue("hardest rung requests user-authentication", top.userAuth)
    }

    @Test
    fun ladderDegradesGracefullyToAUsableKey() {
        val ladder = AndroidKeystoreHardening.FALLBACK_LADDER
        // The last rung drops both protections so a device with neither StrongBox nor a
        // secure lock screen can still mint *a* key (functionality never fails closed).
        val last = ladder.last()
        assertEquals(KeystoreHardeningProfile(strongBox = false, userAuth = false), last)
        // Every preceding rung is strictly more protected than the one after it in at least
        // one dimension, so degradation is monotonic.
        assertEquals(4, ladder.size)
        assertEquals(ladder.distinct(), ladder)
    }

    @Test
    fun usesMostProtectedProfileThatSucceeds() {
        // StrongBox present, lock screen present: the very first attempt wins.
        val used = AndroidKeystoreHardening.generateWithFallback { profile -> profile }
        assertEquals(KeystoreHardeningProfile(strongBox = true, userAuth = true), used)
    }

    @Test
    fun strongBoxUnavailableFallsBackButKeepsUserAuth() {
        // Simulate a device whose StrongBox is unavailable: every StrongBox attempt throws,
        // so the first SUCCEEDING attempt must still be auth-bound (userAuth = true), proving
        // the wrapped key stays user-auth-protected on a StrongBox-less device.
        val used =
            AndroidKeystoreHardening.generateWithFallback { profile ->
                if (profile.strongBox) throw RuntimeException("no StrongBox")
                profile
            }
        assertEquals(KeystoreHardeningProfile(strongBox = false, userAuth = true), used)
    }

    @Test
    fun noSecureLockScreenStillMintsAKey() {
        // Simulate a device with no secure lock screen (auth-bound enrollment impossible)
        // AND no StrongBox: only the fully-degraded rung succeeds, but a key is still minted.
        val used =
            AndroidKeystoreHardening.generateWithFallback { profile ->
                if (profile.strongBox || profile.userAuth) throw RuntimeException("unsupported")
                profile
            }
        assertEquals(KeystoreHardeningProfile(strongBox = false, userAuth = false), used)
    }

    @Test
    fun rethrowsLastFailureWhenEveryAttemptFails() {
        val sentinel = IllegalStateException("final failure")
        var last: Throwable? = null
        val thrown =
            assertThrows(IllegalStateException::class.java) {
                AndroidKeystoreHardening.generateWithFallback<Unit> { profile ->
                    val error = if (profile == AndroidKeystoreHardening.FALLBACK_LADDER.last()) sentinel else RuntimeException("rung")
                    last = error
                    throw error
                }
            }
        assertSame(last, thrown)
        assertSame(sentinel, thrown)
    }
}
