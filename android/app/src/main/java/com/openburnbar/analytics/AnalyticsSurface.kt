package com.openburnbar.analytics

/**
 * Bounded surface labels for `screen.viewed` / the `surface` super-property.
 * Drawn from the cross-platform `surface` enum in docs/analytics/event-taxonomy.md.
 * Any unmapped navigation route collapses to [OTHER] so a unique/parameterized
 * route (e.g. `agent_insights/{slug}`, `assistants/{token}?threadId=...`) can
 * never become a unique, fingerprintable surface value or leak an object id.
 */
enum class AnalyticsSurface(val wire: String) {
    APP("app"),
    ONBOARDING("onboarding"),
    DASHBOARD("dashboard"),
    DASHBOARD_OVERVIEW("dashboard_overview"),
    DASHBOARD_ACTIVITY("dashboard_activity"),
    DASHBOARD_PROVIDER("dashboard_provider"),
    MODEL_DETAIL("model_detail"),
    PROVIDER_DETAIL("provider_detail"),
    CHAT("chat"),
    INSIGHTS("insights"),
    SETTINGS("settings"),
    QUOTA("quota"),
    BUDGET("budget"),
    CLOUD_SYNC("cloud_sync"),
    ACCOUNT("account"),
    INBOX("inbox"),
    FLEET("fleet"),
    OTHER("other"),
    ;

    companion object {
        /**
         * Map a Compose navigation route string to a bounded surface. Routes
         * carrying path arguments are matched by their leading segment, then
         * collapsed; everything unknown becomes [OTHER].
         */
        fun forRoute(route: String?): AnalyticsSurface {
            if (route.isNullOrBlank()) return OTHER
            // Strip any path/query arguments — match on the static prefix only.
            val head = route.substringBefore('/').substringBefore('?')
            return when (head) {
                "pulse" -> DASHBOARD_OVERVIEW
                "burn" -> DASHBOARD_ACTIVITY
                "inbox" -> INBOX
                "fleet" -> FLEET
                "insights", "insights_workspace", "agent_insights" -> INSIGHTS
                "streams" -> DASHBOARD
                "hermes", "assistants", "agent", "mercury_call" -> CHAT
                "you" -> ACCOUNT
                "cloud_store", "control_center" -> ACCOUNT
                "computer_use_agent", "paired_mac" -> DASHBOARD_PROVIDER
                "settings" -> SETTINGS
                "dashboard" -> DASHBOARD
                else -> OTHER
            }
        }
    }
}
