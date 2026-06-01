package com.openburnbar.data.models

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MimoConnectMetadataTest {
    @Test
    fun tokenPlanProfileIdIncludesRegion() {
        assertEquals(
            "mimo.token-plan.sgp",
            MimoEndpointProfiles.tokenPlanProfileId(MimoEndpointRegion.SGP),
        )
        assertEquals(
            "mimo.token-plan.cn",
            MimoEndpointProfiles.tokenPlanProfileId(MimoEndpointRegion.CN),
        )
        assertEquals(
            "mimo.token-plan.ams",
            MimoEndpointProfiles.tokenPlanProfileId(MimoEndpointRegion.AMS),
        )
    }

    @Test
    fun resolveAuthMethodIdFromKeyPrefix() {
        assertEquals(
            MimoEndpointProfiles.AUTH_TOKEN_PLAN,
            MimoEndpointProfiles.resolveAuthMethodId("tp-test-key"),
        )
        assertEquals(
            MimoEndpointProfiles.AUTH_PAYG,
            MimoEndpointProfiles.resolveAuthMethodId("sk-test-key"),
        )
        assertNull(MimoEndpointProfiles.resolveAuthMethodId("unknown-key"))
    }

    @Test
    fun paygProfileIdIsStable() {
        assertEquals("mimo.payg.global", MimoEndpointProfiles.PAYG_PROFILE_ID)
    }
}
