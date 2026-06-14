
package com.openburnbar.data.computeruse

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F2 extra credit — the Android `AppCheckAttestationBinding` mirror must
 * derive the EXACT digest the Swift `AppCheckAttestationBinding` and the
 * Cloud Functions `bindAppCheckAttestation` writer agree on:
 * `SHA-256("openburnbar.appcheck.v1|" ‖ appId ‖ "|" ‖ boundAtMillis)` hex.
 */
class AppCheckAttestationBindingTest {
    private val appId = "1:246956661961:android:abc123"
    private val boundAtMillis = 1_765_000_000_000L

    private fun expectedDigest(): String = MessageDigest.getInstance("SHA-256")
        .digest("openburnbar.appcheck.v1|$appId|$boundAtMillis".toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    @Test
    fun `digest is the canonical sha256 hex over the swift payload shape`() {
        assertEquals(expectedDigest(), AppCheckAttestationBinding.digestHex(appId, boundAtMillis))
        assertEquals(
            expectedDigest(),
            AppCheckAttestationBinding.digestHex(
                AppCheckAttestationBinding.Claim(appId = appId, boundAtMillis = boundAtMillis),
            ),
        )
    }

    @Test
    fun `claims parse from the obb_app_check map with numeric boundAtMillis shapes`() {
        for (boundAt in listOf<Any>(boundAtMillis, boundAtMillis.toDouble(), 1_700_000L)) {
            val claim =
                AppCheckAttestationBinding.parseClaim(
                    mapOf("obb_app_check" to mapOf("appId" to appId, "boundAtMillis" to boundAt)),
                )
            assertEquals(appId, claim?.appId)
            assertEquals((boundAt as? Number)?.toLong(), claim?.boundAtMillis)
        }
    }

    @Test
    fun `missing or malformed claims parse to null`() {
        assertNull(AppCheckAttestationBinding.parseClaim(null))
        assertNull(AppCheckAttestationBinding.parseClaim(emptyMap()))
        assertNull(AppCheckAttestationBinding.parseClaim(mapOf("obb_app_check" to "not-a-map")))
        assertNull(
            AppCheckAttestationBinding.parseClaim(
                mapOf("obb_app_check" to mapOf("boundAtMillis" to boundAtMillis)),
            ),
        )
        assertNull(
            AppCheckAttestationBinding.parseClaim(
                mapOf("obb_app_check" to mapOf("appId" to "", "boundAtMillis" to boundAtMillis)),
            ),
        )
        assertNull(
            AppCheckAttestationBinding.parseClaim(
                mapOf("obb_app_check" to mapOf("appId" to appId, "boundAtMillis" to "not-a-number")),
            ),
        )
    }

    @Test
    fun `freshness matches the 30-day swift window`() {
        val claim = AppCheckAttestationBinding.Claim(appId = appId, boundAtMillis = boundAtMillis)
        val maxAge = AppCheckAttestationBinding.MAX_AGE_MILLIS
        assertTrue(AppCheckAttestationBinding.isFresh(claim, nowMillis = boundAtMillis))
        assertTrue(AppCheckAttestationBinding.isFresh(claim, nowMillis = boundAtMillis + maxAge))
        assertFalse(AppCheckAttestationBinding.isFresh(claim, nowMillis = boundAtMillis + maxAge + 1))
    }
}
