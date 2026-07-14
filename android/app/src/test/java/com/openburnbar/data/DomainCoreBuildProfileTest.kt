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

    @Test
    fun signedInternalProfileMustMatchCatalogAsOneValidatedUnit() {
        val profile = requireNotNull(DomainCoreBuildProfile.resolve(input()))

        assertEquals(DomainCoreArtifactAuthority.SIGNED, profile.artifactAuthority)
        assertEquals(DomainCoreEvidenceChannel.INTERNAL, profile.evidenceChannel)
        assertEquals("rust", profile.modes.getValue("hermes"))
        assertEquals("rust", profile.modes.getValue("pricing"))
    }

    @Test
    fun signedPublicProfileAllowsRustButNeverEvidenceOrShadow() {
        val profile = requireNotNull(DomainCoreBuildProfile.resolve(publicInput()))

        assertEquals(DomainCoreArtifactAuthority.SIGNED, profile.artifactAuthority)
        assertNull(profile.evidenceChannel)
        assertEquals("rust", profile.modes.getValue("quota"))
    }

    @Test
    fun malformedOrUnknownAuthorityFailsClosed() {
        val malformed = listOf(
            input().copy(artifactAuthority = "unknown"),
            input().copy(name = "unknown"),
            input().copy(distribution = "beta"),
            input().copy(rolloutChannel = "beta"),
            input().copy(evidenceEnabled = false),
            input().copy(modes = input().modes + ("quota" to "rust")),
            publicInput().copy(modes = publicInput().modes + ("hermes" to "shadow")),
        )

        malformed.forEach { candidate ->
            val profile = DomainCoreBuildProfile.resolve(candidate)
            assertNull(profile)
            assertEquals("legacy", DomainCoreBuildProfile.resolveMode(profile, "hermes", "rust"))
        }
    }

    private fun input() = DomainCoreBuildProfile.Input(
        name = "internal",
        artifactAuthority = "signed",
        distribution = "internal",
        rolloutChannel = "internal",
        evidenceEnabled = true,
        modes = mapOf(
            "quota" to "shadow",
            "cloudVault" to "shadow",
            "cloudVaultRewrap" to "shadow",
            "cloudVaultSearch" to "shadow",
            "hermes" to "rust",
            "pricing" to "rust",
        ),
    )

    private fun publicInput() = DomainCoreBuildProfile.Input(
        name = "public-production",
        artifactAuthority = "signed",
        distribution = "public",
        rolloutChannel = "",
        evidenceEnabled = false,
        modes = mapOf(
            "quota" to "rust",
            "cloudVault" to "legacy",
            "cloudVaultRewrap" to "rust",
            "cloudVaultSearch" to "legacy",
            "hermes" to "rust",
            "pricing" to "rust",
        ),
    )
}
