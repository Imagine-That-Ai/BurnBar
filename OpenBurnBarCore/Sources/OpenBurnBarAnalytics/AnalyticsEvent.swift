import Foundation

/// The canonical event registry — the single source of iOS/widget/keyboard event
/// names, mirroring docs/analytics/event-taxonomy.md. Call sites reference cases,
/// so an off-taxonomy name can't be invented; `rawValue` is the wire name.
///
/// Tier 1 names are SHARED across every platform and are byte-identical to the
/// macOS `AnalyticsEvent`. Tier 2 names here are the iOS trio's platform-specific
/// additions (surface.object.action, snake_case props) — the widget and keyboard
/// surfaces emit outcomes only (never content / keystrokes / text).
public enum AnalyticsEvent: String, CaseIterable, Sendable {

    // MARK: Tier 1 — core cross-platform spine (identical schema on every platform)
    case appSessionStarted = "app.session.started"
    case appSessionEnded = "app.session.ended"
    case appForegrounded = "app.foregrounded"
    case appBackgrounded = "app.backgrounded"
    case appStartupFailed = "app.startup.failed"
    case screenViewed = "screen.viewed"
    case navRouteChanged = "nav.route.changed"
    case authSignInCompleted = "auth.sign_in.completed"
    case authSignUpCompleted = "auth.sign_up.completed"
    case authSignedOut = "auth.signed_out"
    case authAccountDeleted = "auth.account.deleted"
    case onboardingStarted = "onboarding.started"
    case onboardingStepViewed = "onboarding.step.viewed"
    case onboardingCompleted = "onboarding.completed"
    case onboardingDismissed = "onboarding.dismissed"
    case subscriptionUpgradeInitiated = "subscription.upgrade.initiated"
    case settingsChanged = "settings.changed"
    case errorHandled = "error.handled"
    case consentAnalyticsGranted = "consent.analytics.granted"

    // MARK: CMO acquisition funnel (taxonomy-legal aliases of page_viewed / app_opened / …)
    case pageViewed = "page.viewed"
    case appOpened = "app.opened"
    case ctaClicked = "cta.clicked"
    case downloadClicked = "download.clicked"
    case installStarted = "install.started"
    case emailCaptured = "email.captured"

    // MARK: Tier 2 — dashboard (shared with macOS; iOS reuses the parameterized set)
    case dashboardTimeRangeChanged = "dashboard.time_range.changed"
    case dashboardUnitToggled = "dashboard.unit.toggled"
    case dashboardLaneCardOpened = "dashboard.lane_card.opened"
    case dashboardSessionOpened = "dashboard.session.opened"
    case dashboardRefreshTriggered = "dashboard.refresh.triggered"

    // MARK: Tier 2 — chat (shared family; mobile assistants reuse the schema)
    case chatMessageSent = "chat.message.sent"
    case chatGenerationCompleted = "chat.generation.completed"
    case chatGenerationCancelled = "chat.generation.cancelled"
    case chatGenerationFailed = "chat.generation.failed"
    case chatBackendSwitched = "chat.backend.switched"
    case chatModelSelected = "chat.model.selected"
    case chatAttachmentAdded = "chat.attachment.added"

    // MARK: Tier 2 — quota / budget (shared families)
    case quotaRefreshSucceeded = "quota.refresh.succeeded"
    case quotaRefreshFailed = "quota.refresh.failed"
    case budgetRuleChanged = "budget.rule.changed"

    // MARK: Tier 2 — iOS-specific (platform: ios / ipados)
    /// A primary tab was selected on the mobile tab/sidebar root.
    case mobileTabSelected = "mobile.tab.selected"
    /// The iOS share/connect handoff to a paired Mac was initiated.
    case mobilePairingInitiated = "mobile.pairing.initiated"

    // MARK: Tier 2 — widget (platform: widget) — render/tap OUTCOMES only, no content
    /// A WidgetKit timeline render completed (family + freshness outcome).
    case widgetRendered = "widget.render.completed"
    /// The user tapped the widget (deep-link target only; no rendered values).
    case widgetTapped = "widget.tap.opened"

    // MARK: Tier 2 — keyboard (platform: keyboard) — usage OUTCOME only, NEVER text
    /// The custom keyboard became the active input view (appearance outcome).
    case keyboardActivated = "keyboard.session.activated"
    /// A saved snippet was inserted from the keyboard composer (count bucket only;
    /// never the snippet text, never keystrokes, never the document context).
    case keyboardSnippetInserted = "keyboard.snippet.inserted"

    /// Amplitude category metadata for this event (set via the SDK, never
    /// embedded in the name). Default is `primaryAction`.
    public var category: AnalyticsCategory {
        switch self {
        case .appSessionStarted, .appOpened, .installStarted, .appSessionEnded, .appForegrounded, .appBackgrounded,
             .authSignedOut, .onboardingStarted, .onboardingDismissed, .consentAnalyticsGranted,
             .chatGenerationCompleted, .quotaRefreshSucceeded, .keyboardActivated:
            return .lifecycle
        case .appStartupFailed, .errorHandled, .chatGenerationFailed, .quotaRefreshFailed:
            return .error
        case .screenViewed, .pageViewed, .navRouteChanged, .onboardingStepViewed,
             .mobileTabSelected, .widgetRendered:
            return .screenView
        case .authSignInCompleted, .authSignUpCompleted, .authAccountDeleted,
             .onboardingCompleted, .subscriptionUpgradeInitiated,
             .ctaClicked, .downloadClicked, .emailCaptured:
            return .conversionAuth
        default:
            return .primaryAction
        }
    }
}

/// Amplitude event-category metadata. Mirrors the five categories in the taxonomy.
/// Byte-identical to the macOS `AnalyticsCategory`.
public enum AnalyticsCategory: String, Sendable {
    case lifecycle
    case screenView = "screen_view"
    case primaryAction = "primary_action"
    case conversionAuth = "conversion_auth"
    case error
}
