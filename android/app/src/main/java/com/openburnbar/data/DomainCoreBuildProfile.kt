package com.openburnbar.data

import com.openburnbar.BuildConfig

internal object DomainCoreBuildProfile {
    fun mode(domain: String, developmentOverride: String? = null): String {
        val embedded = when (domain) {
            "cloudVault" -> BuildConfig.CLOUDVAULT_DOMAIN_CORE_MODE
            "cloudVaultRewrap" -> BuildConfig.CLOUDVAULT_REWRAP_DOMAIN_CORE_MODE
            "cloudVaultSearch" -> BuildConfig.CLOUDVAULT_SEARCH_DOMAIN_CORE_MODE
            "hermes" -> BuildConfig.HERMES_DOMAIN_CORE_MODE
            else -> "legacy"
        }
        if (BuildConfig.DOMAIN_CORE_BUILD_AUTHORITY != "development") return embedded
        return developmentOverride?.trim()?.lowercase()?.takeIf { it in setOf("legacy", "shadow", "rust") } ?: embedded
    }

    fun evidenceChannel(): String? = BuildConfig.DOMAIN_CORE_ROLLOUT_CHANNEL
        .takeIf { BuildConfig.DOMAIN_CORE_BUILD_AUTHORITY == "signed" && BuildConfig.DOMAIN_CORE_EVIDENCE_ENABLED }
        ?.takeIf { it == "internal" || it == "beta" }
}
