package com.openburnbar.data.policy

enum class MobileProductCardDisposition(val wire: String) {
    REAL("real"),
    REMOVED("removed"),
    GATED("gated"),
}

/** Interactive card actions must be real, gated, or removed — never decorative. */
object MobileProductSurfacePolicy {
    fun disposition(
        actionId: String,
        catalogPresent: Boolean = true,
        entitlement: MobileStoreEntitlementState = MobileStoreEntitlementState.NONE,
    ): MobileProductCardDisposition = when (actionId) {
        "decorative.stop", "fake.cancel", "silent.discard" -> MobileProductCardDisposition.REMOVED
        "store.purchase", "store.restore" ->
            if (catalogPresent) MobileProductCardDisposition.REAL else MobileProductCardDisposition.REMOVED
        "budget.enforce", "surface.budget-enforce" ->
            if (entitlement == MobileStoreEntitlementState.ACTIVE) {
                MobileProductCardDisposition.REAL
            } else {
                MobileProductCardDisposition.GATED
            }
        "inbox.archive", "inbox.snooze", "inbox.feedback", "inbox.open-route",
        "store.open", "pulse.retry", "streams.retry",
        -> MobileProductCardDisposition.REAL
        else -> MobileProductCardDisposition.REMOVED
    }

    fun mayEnforceBudget(entitlement: MobileStoreEntitlementState): Boolean =
        entitlement == MobileStoreEntitlementState.ACTIVE
}
