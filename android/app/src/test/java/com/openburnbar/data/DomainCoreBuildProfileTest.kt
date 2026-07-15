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
        assertEquals(3L, profile.candidateIdentity?.abiVersion)
        assertEquals("rust", profile.modes.getValue("hermes"))
        assertEquals("rust", profile.modes.getValue("pricing"))
    }

    @Test
    fun signedPublicProfileAllowsRustButNeverEvidenceOrShadow() {
        val profile = requireNotNull(DomainCoreBuildProfile.resolve(publicInput()))

        assertEquals(DomainCoreArtifactAuthority.SIGNED, profile.artifactAuthority)
        assertNull(profile.evidenceChannel)
        assertEquals("0.3.0", profile.candidateIdentity?.coreVersion)
        assertEquals("rust", profile.modes.getValue("quota"))
    }

    @Test
    fun signedBetaProfileIsImmutableAndIgnoresDevelopmentOverrides() {
        val beta = input().copy(
            name = "beta",
            distribution = "beta",
            rolloutChannel = "beta",
        )
        val profile = requireNotNull(DomainCoreBuildProfile.resolve(beta))

        assertEquals(DomainCoreEvidenceChannel.BETA, profile.evidenceChannel)
        assertEquals("rust", DomainCoreBuildProfile.resolveMode(profile, "hermes", "legacy"))
        assertEquals("legacy", DomainCoreBuildProfile.resolveMode(profile, "unknown", "rust"))
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
            input().copy(modes = input().modes - "pricing"),
            input().copy(modes = input().modes + ("unknown" to "legacy")),
            input().copy(modes = input().modes + ("hermes" to "future")),
            publicInput().copy(modes = publicInput().modes + ("hermes" to "shadow")),
            input().copy(candidateIdentity = ""),
            input().copy(candidateIdentity = candidateIdentityWire(commit = "A".repeat(40))),
            input().copy(candidateIdentity = candidateIdentityWire(version = "01.2.3")),
            input().copy(candidateIdentity = candidateIdentityWire(version = "1.2.3-01")),
            input().copy(candidateIdentity = candidateIdentityWire(version = "1.2.3\n")),
            input().copy(candidateIdentity = candidateIdentityWire(version = "1.2.3-" + "a".repeat(59))),
            input().copy(candidateIdentity = candidateIdentityWire(abiVersion = "0")),
            input().copy(candidateIdentity = candidateIdentityWire(abiVersion = "4294967296")),
            input().copy(candidateIdentity = candidateIdentityWire(sourceSha256 = "B".repeat(64))),
            publicInput().copy(candidateIdentity = ""),
            input().copy(candidateIdentity = candidateIdentityWire() + "|extra"),
        )

        malformed.forEach { candidate ->
            val profile = DomainCoreBuildProfile.resolve(candidate)
            assertNull(profile)
            assertEquals("legacy", DomainCoreBuildProfile.resolveMode(profile, "hermes", "rust"))
        }
    }

    @Test
    fun developerCandidateIdentityIsOptionalButPartialValuesFailClosed() {
        val developer = input().copy(
            name = "developer",
            artifactAuthority = "development",
            distribution = "development",
            rolloutChannel = "",
            evidenceEnabled = false,
            modes = input().modes.mapValues { "legacy" },
            candidateIdentity = "",
        )
        assertNull(requireNotNull(DomainCoreBuildProfile.resolve(developer)).candidateIdentity)
        assertNull(DomainCoreBuildProfile.resolve(developer.copy(candidateIdentity = "a".repeat(40))))

        val withCandidate = developer.copy(candidateIdentity = candidateIdentityWire())
        assertEquals("a".repeat(40), DomainCoreBuildProfile.resolve(withCandidate)?.candidateIdentity?.candidateCommit)
    }

    private fun input() = DomainCoreBuildProfile.Input(
        name = "internal",
        artifactAuthority = "signed",
        distribution = "internal",
        rolloutChannel = "internal",
        evidenceEnabled = true,
        candidateIdentity = candidateIdentityWire(),
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
        candidateIdentity = candidateIdentityWire(),
        modes = mapOf(
            "quota" to "rust",
            "cloudVault" to "legacy",
            "cloudVaultRewrap" to "rust",
            "cloudVaultSearch" to "legacy",
            "hermes" to "rust",
            "pricing" to "rust",
        ),
    )

    private fun candidateIdentityWire(
        commit: String = "a".repeat(40),
        version: String = "0.3.0",
        abiVersion: String = "3",
        sourceSha256: String = "b".repeat(64),
    ): String = listOf(commit, version, abiVersion, sourceSha256).joinToString("|")
}
