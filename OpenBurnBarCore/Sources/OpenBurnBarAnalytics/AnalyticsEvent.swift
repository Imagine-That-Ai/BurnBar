import Foundation

/// The canonical event registry — the single source of macOS + iOS/widget/keyboard
/// event names, mirroring docs/analytics/event-taxonomy.md. Call sites reference cases,
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

    // MARK: Tier 2 — macOS platform-specific additions
    /// Emitted by the TelemetryService fan-out for an existing privacy-preserving
    /// feature-usage record (feature id + outcome + bucketed duration).
    case featureUsed = "feature.used"
    case dashboardScanRun = "dashboard.scan.run"
    case dashboardRecountRun = "dashboard.recount.run"
    case chatToolInvoked = "chat.tool.invoked"
    case chatPersonaSelected = "chat.persona.selected"
    case chatAttachmentFailed = "chat.attachment.failed"
    case chatHistoryCleared = "chat.history.cleared"
    case chatPanelAction = "chat.panel.action"
    case chatDesktopControlGranted = "chat.desktop_control.granted"
    case chatSearchPerformed = "chat.search.performed"
    case insightsCanvasCreated = "insights.canvas.created"
    case insightsCanvasSelected = "insights.canvas.selected"
    case insightsCanvasDeleted = "insights.canvas.deleted"
    case insightsWidgetChanged = "insights.widget.changed"
    case insightsAnalysisRequested = "insights.analysis.requested"
    case insightsAnalysisCompleted = "insights.analysis.completed"
    case insightsPrivacyModeToggled = "insights.privacy_mode.toggled"
    case insightsVerdictRefreshed = "insights.verdict.refreshed"
    case insightsAuditlogCleared = "insights.auditlog.cleared"
    case quotaRefreshStarted = "quota.refresh.started"
    case quotaSetupSaved = "quota.setup.saved"
    case quotaWorkspaceFilterChanged = "quota.workspace.filter_changed"
    case budgetThresholdWarning = "budget.threshold.warning"
    case budgetThresholdBlocked = "budget.threshold.blocked"
    case cloudsyncCompleted = "cloudsync.completed"
    case cloudsyncFailed = "cloudsync.failed"
    case cloudsyncManualBackupRun = "cloudsync.manual_backup.run"
    case menubarPopoverShown = "menubar.popover.shown"
    case menubarAction = "menubar.action"
    case missionConsoleOpened = "mission_console.opened"
    case wallpaperToggled = "wallpaper.toggled"
    case wallpaperConfigChanged = "wallpaper.config.changed"
    /// Privacy-preserving surface selection for the visual capture toggle. Params:
    /// `provider` (persistedToken), `surface` (cli_pty|desktop_app), `trigger`
    /// (settings|session_header|mobile), `fallback_used` (Bool), `is_eligible` (Bool).
    /// Never includes window titles, bundle IDs beyond persistedToken, or pixel hashes.
    case visualCaptureSurfaceSelected = "visual_capture.surface_selected"

    /// Amplitude category metadata for this event (set via the SDK, never
    /// embedded in the name). Default is `primaryAction`.
    public var category: AnalyticsCategory {
        switch self {
        case .appSessionStarted, .appSessionEnded, .appForegrounded, .appBackgrounded,
             .authSignedOut, .onboardingStarted, .onboardingDismissed, .consentAnalyticsGranted,
             .chatGenerationCompleted, .quotaRefreshStarted, .quotaRefreshSucceeded, .keyboardActivated:
            return .lifecycle
        case .appStartupFailed, .errorHandled, .chatGenerationFailed, .chatAttachmentFailed,
             .quotaRefreshFailed, .budgetThresholdBlocked, .cloudsyncFailed:
            return .error
        case .screenViewed, .navRouteChanged, .onboardingStepViewed,
             .mobileTabSelected, .widgetRendered,
             .menubarPopoverShown, .missionConsoleOpened:
            return .screenView
        case .authSignInCompleted, .authSignUpCompleted, .authAccountDeleted,
             .onboardingCompleted, .subscriptionUpgradeInitiated,
             .chatDesktopControlGranted, .cloudsyncCompleted:
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
