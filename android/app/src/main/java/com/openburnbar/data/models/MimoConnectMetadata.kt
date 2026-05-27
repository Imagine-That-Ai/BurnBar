package com.openburnbar.data.models

enum class MimoEndpointRegion(val raw: String, val displayName: String) {
    CN("cn", "China"),
    SGP("sgp", "Singapore"),
    AMS("ams", "Europe (Amsterdam)");

    companion object {
        val selectable = listOf(CN, SGP, AMS)
    }
}

enum class MimoTokenPlanTier(val raw: String, val displayName: String) {
    LITE("lite", "Lite"),
    STANDARD("standard", "Standard"),
    PRO("pro", "Pro"),
    MAX("max", "Max");

    companion object {
        val all = entries
    }
}

enum class MimoTokenPlanBillingCycle(val raw: String) {
    MONTHLY("monthly"),
    ANNUAL("annual")
}

object MimoEndpointProfiles {
    const val AUTH_TOKEN_PLAN = "mimo-token-plan"
    const val AUTH_PAYG = "mimo-payg"
    const val PAYG_PROFILE_ID = "mimo.payg.global"

    fun tokenPlanProfileId(region: MimoEndpointRegion): String =
        "mimo.token-plan.${region.raw}"

    fun resolveAuthMethodId(apiKey: String): String? {
        val trimmed = apiKey.trim().lowercase()
        return when {
            trimmed.startsWith("tp-") -> AUTH_TOKEN_PLAN
            trimmed.startsWith("sk-") -> AUTH_PAYG
            else -> null
        }
    }
}
