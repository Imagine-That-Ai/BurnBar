package com.openburnbar.analytics

/**
 * The canonical Android event registry — the single source of Android event
 * names, mirroring docs/analytics/event-taxonomy.md and
 * AgentLens/Services/Analytics/AnalyticsEvent.swift. Call sites reference enum
 * entries, so an off-taxonomy name can't be invented; [wire] is the on-the-wire
 * name and is validated against the taxonomy regex in the unit tests.
 *
 * Tier 1 entries are shared verbatim across every platform. Tier 2 (Android)
 * entries are this platform's surface-specific events; they follow
 * `surface.object.action` with snake_case props and are returned to the
 * taxonomy orchestrator for central merge.
 */
enum class AnalyticsEvent(val wire: String, val category: AnalyticsCategory) {

    // ── Tier 1 — core cross-platform spine ──
    APP_SESSION_STARTED("app.session.started", AnalyticsCategory.LIFECYCLE),
    APP_SESSION_ENDED("app.session.ended", AnalyticsCategory.LIFECYCLE),
    APP_FOREGROUNDED("app.foregrounded", AnalyticsCategory.LIFECYCLE),
    APP_BACKGROUNDED("app.backgrounded", AnalyticsCategory.LIFECYCLE),
    APP_STARTUP_FAILED("app.startup.failed", AnalyticsCategory.ERROR),
    SCREEN_VIEWED("screen.viewed", AnalyticsCategory.SCREEN_VIEW),
    NAV_ROUTE_CHANGED("nav.route.changed", AnalyticsCategory.SCREEN_VIEW),
    AUTH_SIGN_IN_COMPLETED("auth.sign_in.completed", AnalyticsCategory.CONVERSION_AUTH),
    AUTH_SIGN_UP_COMPLETED("auth.sign_up.completed", AnalyticsCategory.CONVERSION_AUTH),
    AUTH_SIGNED_OUT("auth.signed_out", AnalyticsCategory.LIFECYCLE),
    AUTH_ACCOUNT_DELETED("auth.account.deleted", AnalyticsCategory.CONVERSION_AUTH),
    SETTINGS_CHANGED("settings.changed", AnalyticsCategory.PRIMARY_ACTION),
    ERROR_HANDLED("error.handled", AnalyticsCategory.ERROR),
    CONSENT_ANALYTICS_GRANTED("consent.analytics.granted", AnalyticsCategory.LIFECYCLE),
    FEATURE_USED("feature.used", AnalyticsCategory.PRIMARY_ACTION),

    // CMO acquisition funnel (taxonomy-legal aliases of page_viewed / app_opened / …)
    PAGE_VIEWED("page.viewed", AnalyticsCategory.SCREEN_VIEW),
    APP_OPENED("app.opened", AnalyticsCategory.LIFECYCLE),
    CTA_CLICKED("cta.clicked", AnalyticsCategory.CONVERSION_AUTH),
    DOWNLOAD_CLICKED("download.clicked", AnalyticsCategory.CONVERSION_AUTH),
    INSTALL_STARTED("install.started", AnalyticsCategory.LIFECYCLE),
    EMAIL_CAPTURED("email.captured", AnalyticsCategory.CONVERSION_AUTH),

    // ── Tier 1 — subscription / upgrade funnel (shared) ──
    SUBSCRIPTION_UPGRADE_INITIATED("subscription.upgrade.initiated", AnalyticsCategory.CONVERSION_AUTH),

    // ── Tier 2 — Android: chat / assistants (surface: chat*) ──
    CHAT_MESSAGE_SENT("chat.message.sent", AnalyticsCategory.PRIMARY_ACTION),
    CHAT_GENERATION_COMPLETED("chat.generation.completed", AnalyticsCategory.LIFECYCLE),
    CHAT_GENERATION_FAILED("chat.generation.failed", AnalyticsCategory.ERROR),
    CHAT_BACKEND_SWITCHED("chat.backend.switched", AnalyticsCategory.PRIMARY_ACTION),

    // ── Tier 2 — Android: dashboard / pulse (surface: dashboard*) ──
    DASHBOARD_TIME_RANGE_CHANGED("dashboard.time_range.changed", AnalyticsCategory.PRIMARY_ACTION),
    DASHBOARD_LANE_CARD_OPENED("dashboard.lane_card.opened", AnalyticsCategory.PRIMARY_ACTION),

    // ── Tier 2 — Android: quota (surface: quota) ──
    QUOTA_REFRESH_STARTED("quota.refresh.started", AnalyticsCategory.LIFECYCLE),
    QUOTA_REFRESH_SUCCEEDED("quota.refresh.succeeded", AnalyticsCategory.LIFECYCLE),
    QUOTA_REFRESH_FAILED("quota.refresh.failed", AnalyticsCategory.ERROR),

    // ── Tier 2 — Android: store / billing (surface: account) ──
    STORE_PURCHASE_COMPLETED("store.purchase.completed", AnalyticsCategory.CONVERSION_AUTH),

    // ── Tier 2 — Android: search (surface: chat / streams) ──
    // Reuses the shared chat Tier 2 event so the search funnel reads across
    // platforms; the taxonomy's Android section lists chat.search.performed.
    CHAT_SEARCH_PERFORMED("chat.search.performed", AnalyticsCategory.PRIMARY_ACTION),
    ;

    companion object {
        /** The set of valid wire names — the generated allow-list the taxonomy governance requires. */
        val wireNames: Set<String> = entries.map { it.wire }.toSet()
    }
}

/** Amplitude event-category metadata. Mirrors the five categories in the taxonomy. */
enum class AnalyticsCategory(val wire: String) {
    LIFECYCLE("lifecycle"),
    SCREEN_VIEW("screen_view"),
    PRIMARY_ACTION("primary_action"),
    CONVERSION_AUTH("conversion_auth"),
    ERROR("error"),
}
