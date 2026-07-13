package com.openburnbar.data

import com.openburnbar.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DomainCoreBuildProfileTest {
    @Test
    fun embeddedDevelopmentProfileAllowsValidatedOverride() {
        if (BuildConfig.DOMAIN_CORE_BUILD_AUTHORITY == "development") {
            assertEquals("rust", DomainCoreBuildProfile.mode("hermes", "RUST"))
            assertEquals(BuildConfig.HERMES_DOMAIN_CORE_MODE, DomainCoreBuildProfile.mode("hermes", "invalid"))
        }
    }

    @Test
    fun developmentProfileCannotUploadEvidence() {
        if (BuildConfig.DOMAIN_CORE_BUILD_AUTHORITY == "development") {
            assertNull(DomainCoreBuildProfile.evidenceChannel())
        }
    }
}
