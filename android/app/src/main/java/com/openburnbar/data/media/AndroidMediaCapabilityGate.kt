package com.openburnbar.data.media

/**
 * Android-side mirror of the iOS `MediaCapabilityGate`. Decision 2 of
 * the Mercury Media master plan: the Mac is the authoritative gate;
 * Android is informational. We surface the Mac's denial reason to the
 * UI (toast + Settings → Media banner) so the user always knows whether
 * Mercury is available and why not.
 *
 * Inputs are wired from Firestore (`media_quota_usage`,
 * `ops/media_budget_status/state/current`, paired Mac entitlement). We
 * do not ourselves admit or deny a session — the Mac broadcasts its
 * decision over the chat envelope and we render it.
 */
class AndroidMediaCapabilityGate(
    private val entitlementProvider: () -> EntitlementState = { EntitlementState() },
    private val budgetProvider: () -> BudgetState = { BudgetState() },
    private val killSwitchProvider: () -> Boolean = { false },
) {
    sealed class Check {
        data class Allowed(val envelope: Envelope) : Check()

        data class Denied(val reason: DenialReason) : Check()

        val isAllowed: Boolean get() = this is Allowed
    }

    enum class DenialReason(val raw: String) {
        ENTITLEMENT_MISSING("entitlementMissing"),
        ENTITLEMENT_EXPIRED("entitlementExpired"),
        DAILY_CAP_REACHED("dailyCapReached"),
        SESSION_CAP_REACHED("sessionCapReached"),
        CONCURRENT_SESSION_CAP_REACHED("concurrentSessionCapReached"),
        BUDGET_SOFT_CAP_REACHED("budgetSoftCapReached"),
        BUDGET_HARD_CAP_REACHED("budgetHardCapReached"),
        KILL_SWITCH_ACTIVE("killSwitchActive"),
    }

    enum class BudgetLevel { NORMAL, SOFT_CAP, HARD_CAP }

    data class EntitlementState(
        val active: Boolean = false,
        val fileTransfer: Boolean = false,
        val screenShare: Boolean = false,
        val videoCall: Boolean = false,
    )

    data class BudgetState(
        val level: BudgetLevel = BudgetLevel.NORMAL,
        val allowsFeature: (MediaStreamClass.Feature) -> Boolean = { true },
    )

    data class Envelope(
        val feature: MediaStreamClass.Feature,
        val remainingSecondsToday: Int? = null,
        val remainingBytesToday: Long? = null,
        val perSessionMaxSeconds: Int? = null,
        val perSessionMaxBytes: Long? = null,
        val concurrentSessionsRemaining: Int = 1,
    )

    fun check(feature: MediaStreamClass.Feature): Check {
        if (killSwitchProvider()) return Check.Denied(DenialReason.KILL_SWITCH_ACTIVE)
        val entitlement = entitlementProvider()
        if (!entitlement.active) return Check.Denied(DenialReason.ENTITLEMENT_MISSING)
        val featureEntitled =
            when (feature) {
                MediaStreamClass.Feature.FILE_TRANSFER -> entitlement.fileTransfer
                MediaStreamClass.Feature.SCREEN_SHARE -> entitlement.screenShare
                MediaStreamClass.Feature.VIDEO_CALL -> entitlement.videoCall
                // Android is the informational viewer/controller for Computer
                // Use; the Mac host enforces the paid host entitlement and
                // dispatch policy. Android only mirrors the Mac's gate result.
                MediaStreamClass.Feature.COMPUTER_USE -> true
            }
        if (!featureEntitled) return Check.Denied(DenialReason.ENTITLEMENT_MISSING)
        val budget = budgetProvider()
        return when (budget.level) {
            BudgetLevel.HARD_CAP -> Check.Denied(DenialReason.BUDGET_HARD_CAP_REACHED)
            BudgetLevel.SOFT_CAP ->
                if (budget.allowsFeature(feature)) {
                    Check.Allowed(Envelope(feature = feature))
                } else {
                    Check.Denied(DenialReason.BUDGET_SOFT_CAP_REACHED)
                }
            BudgetLevel.NORMAL -> Check.Allowed(Envelope(feature = feature))
        }
    }
}
