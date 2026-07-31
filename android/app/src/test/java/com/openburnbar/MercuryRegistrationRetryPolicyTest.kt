package com.openburnbar

import com.openburnbar.data.cloud.MercuryDeviceRegistrationState
import org.junit.Assert.assertEquals
import org.junit.Test

class MercuryRegistrationRetryPolicyTest {
    @Test
    fun delayGrowsExponentiallyFromFiveSeconds() {
        assertEquals(5_000L, MercuryRegistrationRetryPolicy.delayMillis(1))
        assertEquals(10_000L, MercuryRegistrationRetryPolicy.delayMillis(2))
        assertEquals(20_000L, MercuryRegistrationRetryPolicy.delayMillis(3))
        assertEquals(160_000L, MercuryRegistrationRetryPolicy.delayMillis(6))
    }

    @Test
    fun delayIsClampedAtBothEnds() {
        // Out-of-range attempts must never shift by a negative or unbounded amount.
        assertEquals(5_000L, MercuryRegistrationRetryPolicy.delayMillis(0))
        assertEquals(5_000L, MercuryRegistrationRetryPolicy.delayMillis(-3))
        assertEquals(160_000L, MercuryRegistrationRetryPolicy.delayMillis(50))
    }

    @Test
    fun trustedEscrowStateMapsToReady() {
        assertEquals(
            MercuryDeviceRegistrationState.Ready("device-1"),
            escrowTrustRegistrationState(trustState = "trusted", deviceId = "device-1"),
        )
    }

    @Test
    fun anyOtherEscrowStateMapsToPendingApproval() {
        assertEquals(
            MercuryDeviceRegistrationState.PendingApproval("device-1"),
            escrowTrustRegistrationState(trustState = "pending", deviceId = "device-1"),
        )
        assertEquals(
            MercuryDeviceRegistrationState.PendingApproval("device-1"),
            escrowTrustRegistrationState(trustState = "revoked", deviceId = "device-1"),
        )
    }
}
