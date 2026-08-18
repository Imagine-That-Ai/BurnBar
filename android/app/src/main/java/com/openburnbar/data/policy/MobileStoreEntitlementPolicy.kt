package com.openburnbar.data.policy

enum class MobileStoreProductRole {
    CLOUD_MONTHLY,
    CLOUD_ANNUAL,
    PRO_MONTHLY,
    PRO_ANNUAL,
    ULTRA_MONTHLY,
    ULTRA_ANNUAL,
    AGENT_CONTROL_TOP_UP,
    FLOO_RELAY_TOP_UP,
    ELDER_WAND_100,
    ELDER_WAND_500,
}

enum class MobileStoreEntitlementState(val wire: String) {
    NONE("none"),
    ACTIVE("active"),
    EXPIRED("expired"),
    REFUNDED("refunded"),
    REVOKED("revoked"),
    MISSING_CATALOG("missing-catalog"),
    RESTORE_PENDING("restore-pending"),
}

sealed class MobileStorePriceDisplay {
    data class Live(val price: String) : MobileStorePriceDisplay()
    data object Unavailable : MobileStorePriceDisplay()

    val customerFacingText: String
        get() = when (this) {
            is Live -> price
            Unavailable -> MobileStoreEntitlementPolicy.UNAVAILABLE_PRICE_LABEL
        }

    val isLivePrice: Boolean get() = this is Live
}

object MobileStoreEntitlementPolicy {
    const val UNAVAILABLE_PRICE_LABEL = "Price unavailable"

    const val APPLE_CLOUD_MONTHLY = "com.openburnbar.pro.monthly"
    const val APPLE_CLOUD_ANNUAL = "com.openburnbar.pro.annual"
    const val APPLE_PRO_MONTHLY = "com.openburnbar.proMax.v2.monthly"
    const val APPLE_PRO_ANNUAL = "com.openburnbar.proMax.annual"
    const val APPLE_ULTRA_MONTHLY = "com.openburnbar.ultra.monthly"
    const val APPLE_ULTRA_ANNUAL = "com.openburnbar.ultra.annual.v2"
    const val APPLE_AGENT_CONTROL = "com.openburnbar.agentControl.actions100"
    const val APPLE_FLOO_RELAY = "com.openburnbar.floo.relay50gb"
    const val APPLE_ELDER_WAND_100 = "com.openburnbar.elderWand.searches100"
    const val APPLE_ELDER_WAND_500 = "com.openburnbar.elderWand.searches500"

    const val PLAY_CLOUD_MONTHLY = "com.openburnbar.pro.monthly"
    const val PLAY_CLOUD_ANNUAL = "com.openburnbar.pro.annual"
    const val PLAY_PRO_MONTHLY = "com.openburnbar.promax.v2.monthly"
    const val PLAY_PRO_ANNUAL = "com.openburnbar.promax.annual"
    const val PLAY_ULTRA_MONTHLY = "com.openburnbar.ultra.monthly"
    const val PLAY_ULTRA_ANNUAL = "com.openburnbar.ultra.annual"
    const val PLAY_AGENT_CONTROL = "com.openburnbar.agentcontrol.actions100"
    const val PLAY_FLOO_RELAY = "com.openburnbar.floo.relay50gb"
    const val PLAY_ELDER_WAND_100 = "com.openburnbar.elderwand.searches100"
    const val PLAY_ELDER_WAND_500 = "com.openburnbar.elderwand.searches500"

    fun role(productID: String): MobileStoreProductRole? = when (productID) {
        APPLE_CLOUD_MONTHLY, PLAY_CLOUD_MONTHLY -> MobileStoreProductRole.CLOUD_MONTHLY
        APPLE_CLOUD_ANNUAL, PLAY_CLOUD_ANNUAL -> MobileStoreProductRole.CLOUD_ANNUAL
        APPLE_PRO_MONTHLY, PLAY_PRO_MONTHLY -> MobileStoreProductRole.PRO_MONTHLY
        APPLE_PRO_ANNUAL, PLAY_PRO_ANNUAL -> MobileStoreProductRole.PRO_ANNUAL
        APPLE_ULTRA_MONTHLY, PLAY_ULTRA_MONTHLY -> MobileStoreProductRole.ULTRA_MONTHLY
        APPLE_ULTRA_ANNUAL, PLAY_ULTRA_ANNUAL -> MobileStoreProductRole.ULTRA_ANNUAL
        APPLE_AGENT_CONTROL, PLAY_AGENT_CONTROL -> MobileStoreProductRole.AGENT_CONTROL_TOP_UP
        APPLE_FLOO_RELAY, PLAY_FLOO_RELAY -> MobileStoreProductRole.FLOO_RELAY_TOP_UP
        APPLE_ELDER_WAND_100, PLAY_ELDER_WAND_100 -> MobileStoreProductRole.ELDER_WAND_100
        APPLE_ELDER_WAND_500, PLAY_ELDER_WAND_500 -> MobileStoreProductRole.ELDER_WAND_500
        else -> null
    }

    fun displayPrice(livePrice: String?): MobileStorePriceDisplay {
        val trimmed = livePrice?.trim().orEmpty()
        return if (trimmed.isEmpty() || trimmed == UNAVAILABLE_PRICE_LABEL) {
            MobileStorePriceDisplay.Unavailable
        } else {
            MobileStorePriceDisplay.Live(trimmed)
        }
    }

    fun classify(
        catalogPresent: Boolean,
        restoring: Boolean,
        revoked: Boolean,
        refunded: Boolean,
        expired: Boolean,
        active: Boolean,
    ): MobileStoreEntitlementState = when {
        !catalogPresent -> MobileStoreEntitlementState.MISSING_CATALOG
        restoring -> MobileStoreEntitlementState.RESTORE_PENDING
        revoked -> MobileStoreEntitlementState.REVOKED
        refunded -> MobileStoreEntitlementState.REFUNDED
        expired -> MobileStoreEntitlementState.EXPIRED
        active -> MobileStoreEntitlementState.ACTIVE
        else -> MobileStoreEntitlementState.NONE
    }
}
