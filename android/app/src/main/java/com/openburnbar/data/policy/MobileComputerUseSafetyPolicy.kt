package com.openburnbar.data.policy

enum class MobileComputerUseSafetyDecision(val wire: String) {
    ALLOW("allow"),
    REJECT("reject"),
}

/** Fail-closed Computer Use decisions. Android must match iOS. */
object MobileComputerUseSafetyPolicy {
    fun decision(
        kind: String,
        viewOnly: Boolean = false,
        authenticated: Boolean = true,
        grantExpired: Boolean = false,
        bindingMatches: Boolean = true,
        replayed: Boolean = false,
        tampered: Boolean = false,
        rateLimited: Boolean = false,
        sessionExpired: Boolean = false,
        panic: Boolean = false,
        intentKind: String = "tap",
    ): MobileComputerUseSafetyDecision {
        if (panic) return MobileComputerUseSafetyDecision.REJECT
        if (!authenticated) return MobileComputerUseSafetyDecision.REJECT
        if (grantExpired) return MobileComputerUseSafetyDecision.REJECT
        if (sessionExpired) return MobileComputerUseSafetyDecision.REJECT
        if (!bindingMatches) return MobileComputerUseSafetyDecision.REJECT
        if (replayed) return MobileComputerUseSafetyDecision.REJECT
        if (tampered) return MobileComputerUseSafetyDecision.REJECT
        if (rateLimited) return MobileComputerUseSafetyDecision.REJECT
        if (viewOnly && intentKind != "panic") return MobileComputerUseSafetyDecision.REJECT
        return when (kind) {
            "replay",
            "tamper",
            "expired-grant",
            "unauthenticated",
            "binding-mismatch",
            "view-only-control",
            "panic",
            "rate-limit",
            "session-expiry",
            -> MobileComputerUseSafetyDecision.REJECT
            "valid-control" -> MobileComputerUseSafetyDecision.ALLOW
            else -> MobileComputerUseSafetyDecision.REJECT
        }
    }

    fun reason(
        kind: String,
        viewOnly: Boolean = false,
        authenticated: Boolean = true,
        grantExpired: Boolean = false,
        bindingMatches: Boolean = true,
        replayed: Boolean = false,
        tampered: Boolean = false,
        rateLimited: Boolean = false,
        sessionExpired: Boolean = false,
        panic: Boolean = false,
        intentKind: String = "tap",
    ): String {
        if (panic) return "panic"
        if (!authenticated) return "unauthenticated"
        if (grantExpired) return "expired-grant"
        if (sessionExpired) return "session-expiry"
        if (!bindingMatches) return "binding-mismatch"
        if (replayed) return "replay"
        if (tampered) return "tamper"
        if (rateLimited) return "rate-limit"
        if (viewOnly && intentKind != "panic") return "view-only"
        if (kind == "valid-control") return "ok"
        return kind
    }

    fun shouldSendPhoneControl(
        authenticated: Boolean,
        grantExpired: Boolean,
        bindingMatches: Boolean,
        replayed: Boolean,
        tampered: Boolean,
        rateLimited: Boolean,
        sessionExpired: Boolean,
        panic: Boolean,
        viewOnly: Boolean,
        intentKind: String,
    ): Boolean =
        decision(
            kind = "valid-control",
            viewOnly = viewOnly,
            authenticated = authenticated,
            grantExpired = grantExpired,
            bindingMatches = bindingMatches,
            replayed = replayed,
            tampered = tampered,
            rateLimited = rateLimited,
            sessionExpired = sessionExpired,
            panic = panic,
            intentKind = intentKind,
        ) == MobileComputerUseSafetyDecision.ALLOW
}
