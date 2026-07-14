package com.openburnbar.data

import com.openburnbar.BuildConfig

internal enum class DomainCoreArtifactAuthority {
    DEVELOPMENT,
    SIGNED,
}

internal enum class DomainCoreEvidenceChannel(val wireValue: String) {
    INTERNAL("internal"),
    BETA("beta"),
}

internal data class AndroidDomainCoreRuntimeProfile(
    val name: String,
    val artifactAuthority: DomainCoreArtifactAuthority,
    val distribution: String,
    val evidenceChannel: DomainCoreEvidenceChannel?,
    val modes: Map<String, String>,
)

internal object DomainCoreBuildProfile {
    internal data class Input(
        val name: String,
        val artifactAuthority: String,
        val distribution: String,
        val rolloutChannel: String,
        val evidenceEnabled: Boolean,
        val modes: Map<String, String>,
    )

    private data class CatalogContract(
        val artifactAuthority: DomainCoreArtifactAuthority,
        val distribution: String,
        val evidenceChannel: DomainCoreEvidenceChannel?,
        val evidenceEnabled: Boolean,
    )

    private val androidDomains = setOf("quota", "cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes", "pricing")
    private val validModes = setOf("legacy", "shadow", "rust")
    private val catalogContracts = mapOf(
        "developer" to CatalogContract(
            DomainCoreArtifactAuthority.DEVELOPMENT,
            "development",
            null,
            false,
        ),
        "public-production" to CatalogContract(
            DomainCoreArtifactAuthority.SIGNED,
            "public",
            null,
            false,
        ),
        "internal" to CatalogContract(
            DomainCoreArtifactAuthority.SIGNED,
            "internal",
            DomainCoreEvidenceChannel.INTERNAL,
            true,
        ),
        "beta" to CatalogContract(
            DomainCoreArtifactAuthority.SIGNED,
            "beta",
            DomainCoreEvidenceChannel.BETA,
            true,
        ),
    )

    private val embeddedRuntimeProfile: AndroidDomainCoreRuntimeProfile? by lazy {
        resolve(
            Input(
                name = BuildConfig.DOMAIN_CORE_BUILD_PROFILE,
                artifactAuthority = BuildConfig.DOMAIN_CORE_BUILD_AUTHORITY,
                distribution = BuildConfig.DOMAIN_CORE_DISTRIBUTION,
                rolloutChannel = BuildConfig.DOMAIN_CORE_ROLLOUT_CHANNEL,
                evidenceEnabled = BuildConfig.DOMAIN_CORE_EVIDENCE_ENABLED,
                modes = mapOf(
                    "quota" to BuildConfig.QUOTA_DOMAIN_CORE_MODE,
                    "cloudVault" to BuildConfig.CLOUDVAULT_DOMAIN_CORE_MODE,
                    "cloudVaultRewrap" to BuildConfig.CLOUDVAULT_REWRAP_DOMAIN_CORE_MODE,
                    "cloudVaultSearch" to BuildConfig.CLOUDVAULT_SEARCH_DOMAIN_CORE_MODE,
                    "hermes" to BuildConfig.HERMES_DOMAIN_CORE_MODE,
                    "pricing" to BuildConfig.PRICING_DOMAIN_CORE_MODE,
                ),
            ),
        )
    }

    fun runtimeProfile(): AndroidDomainCoreRuntimeProfile? = embeddedRuntimeProfile

    fun mode(domain: String, developmentOverride: String? = null): String = resolveMode(
        embeddedRuntimeProfile,
        domain,
        developmentOverride,
    )

    fun evidenceChannel(): DomainCoreEvidenceChannel? = embeddedRuntimeProfile?.evidenceChannel

    internal fun resolve(input: Input): AndroidDomainCoreRuntimeProfile? {
        val contract = catalogContracts[input.name] ?: return null
        if (input.artifactAuthority != contract.artifactAuthority.name.lowercase()) return null
        if (input.distribution != contract.distribution) return null
        if (input.evidenceEnabled != contract.evidenceEnabled) return null
        if (input.rolloutChannel != contract.evidenceChannel?.wireValue.orEmpty()) return null
        if (input.modes.keys != androidDomains || input.modes.values.any { it !in validModes }) return null
        if (contract.artifactAuthority == DomainCoreArtifactAuthority.SIGNED) {
            val validSignedModes = when (input.name) {
                "public-production" -> input.modes.values.none { it == "shadow" }
                "internal", "beta" -> input.modes["quota"] == "shadow"
                else -> false
            }
            if (!validSignedModes) return null
        }

        return AndroidDomainCoreRuntimeProfile(
            name = input.name,
            artifactAuthority = contract.artifactAuthority,
            distribution = contract.distribution,
            evidenceChannel = contract.evidenceChannel,
            modes = input.modes.toMap(),
        )
    }

    internal fun resolveMode(profile: AndroidDomainCoreRuntimeProfile?, domain: String, developmentOverride: String? = null): String {
        val embedded = profile?.modes?.get(domain) ?: return "legacy"
        if (profile.artifactAuthority != DomainCoreArtifactAuthority.DEVELOPMENT) return embedded
        return developmentOverride
            ?.trim()
            ?.lowercase()
            ?.takeIf { it in validModes }
            ?: embedded
    }
}
