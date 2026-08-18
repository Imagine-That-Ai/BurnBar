package com.openburnbar.data.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileComputerUseSafetyPolicyTest {
    @Test
    fun localFlagsRejectBeforeKindAndExplainWhy() {
        assertEquals(MobileComputerUseSafetyDecision.REJECT, MobileComputerUseSafetyPolicy.decision(kind = "valid-control", panic = true))
        assertEquals("panic", MobileComputerUseSafetyPolicy.reason(kind = "valid-control", panic = true))
        assertEquals(MobileComputerUseSafetyDecision.REJECT, MobileComputerUseSafetyPolicy.decision(kind = "valid-control", sessionExpired = true))
        assertEquals("session-expiry", MobileComputerUseSafetyPolicy.reason(kind = "valid-control", sessionExpired = true))
        assertEquals(MobileComputerUseSafetyDecision.REJECT, MobileComputerUseSafetyPolicy.decision(kind = "valid-control", rateLimited = true))
        assertEquals("rate-limit", MobileComputerUseSafetyPolicy.reason(kind = "valid-control", rateLimited = true))
        assertEquals(MobileComputerUseSafetyDecision.REJECT, MobileComputerUseSafetyPolicy.decision(kind = "valid-control", viewOnly = true, intentKind = "tap"))
        assertEquals("view-only", MobileComputerUseSafetyPolicy.reason(kind = "valid-control", viewOnly = true, intentKind = "tap"))
        assertEquals(MobileComputerUseSafetyDecision.ALLOW, MobileComputerUseSafetyPolicy.decision(kind = "valid-control", viewOnly = true, intentKind = "panic"))
        assertEquals("ok", MobileComputerUseSafetyPolicy.reason(kind = "valid-control", viewOnly = true, intentKind = "panic"))
        assertEquals(MobileComputerUseSafetyDecision.REJECT, MobileComputerUseSafetyPolicy.decision(kind = "unknown-kind"))
        assertEquals("unknown-kind", MobileComputerUseSafetyPolicy.reason(kind = "unknown-kind"))
    }

    @Test
    fun shouldSendPhoneControlAllowsOnlyUnblockedValidControl() {
        assertTrue(
            MobileComputerUseSafetyPolicy.shouldSendPhoneControl(
                authenticated = true,
                grantExpired = false,
                bindingMatches = true,
                replayed = false,
                tampered = false,
                rateLimited = false,
                sessionExpired = false,
                panic = false,
                viewOnly = false,
                intentKind = "tap",
            ),
        )
        assertFalse(
            MobileComputerUseSafetyPolicy.shouldSendPhoneControl(
                authenticated = true,
                grantExpired = false,
                bindingMatches = true,
                replayed = false,
                tampered = false,
                rateLimited = true,
                sessionExpired = false,
                panic = false,
                viewOnly = false,
                intentKind = "tap",
            ),
        )
    }
}
