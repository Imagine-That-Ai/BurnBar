import Foundation

/// The canonical event registry — the single source of macOS event names,
/// mirroring docs/analytics/event-taxonomy.md. Call sites reference cases, so an
/// off-taxonomy name can't be invented; `rawValue` is the wire name.
enum AnalyticsEvent: String, CaseIterable, Sendable {

    // MARK: Tier 1 — core cross-platform spine
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
    /// Emitted by the TelemetryService fan-out for an existing privacy-preserving
    /// feature-usage record (feature id + outcome + bucketed duration).
    case featureUsed = "feature.used"

    // MARK: Tier 2 — dashboard
    case dashboardScanRun = "dashboard.scan.run"
    case dashboardRecountRun = "dashboard.recount.run"
    case dashboardTimeRangeChanged = "dashboard.time_range.changed"
    case dashboardUnitToggled = "dashboard.unit.toggled"
    case dashboardLaneCardOpened = "dashboard.lane_card.opened"
    case dashboardSessionOpened = "dashboard.session.opened"
    case dashboardRefreshTriggered = "dashboard.refresh.triggered"

    // MARK: Tier 2 — chat
    case chatMessageSent = "chat.message.sent"
    case chatGenerationCompleted = "chat.generation.completed"
    case chatGenerationCancelled = "chat.generation.cancelled"
    case chatGenerationFailed = "chat.generation.failed"
    case chatToolInvoked = "chat.tool.invoked"
    case chatBackendSwitched = "chat.backend.switched"
    case chatModelSelected = "chat.model.selected"
    case chatPersonaSelected = "chat.persona.selected"
    case chatAttachmentAdded = "chat.attachment.added"
    case chatAttachmentFailed = "chat.attachment.failed"
    case chatHistoryCleared = "chat.history.cleared"
    case chatPanelAction = "chat.panel.action"
    case chatDesktopControlGranted = "chat.desktop_control.granted"
    case chatSearchPerformed = "chat.search.performed"

    // MARK: Tier 2 — insights
    case insightsCanvasCreated = "insights.canvas.created"
    case insightsCanvasSelected = "insights.canvas.selected"
    case insightsCanvasDeleted = "insights.canvas.deleted"
    case insightsWidgetChanged = "insights.widget.changed"
    case insightsAnalysisRequested = "insights.analysis.requested"
    case insightsAnalysisCompleted = "insights.analysis.completed"
    case insightsPrivacyModeToggled = "insights.privacy_mode.toggled"
    case insightsVerdictRefreshed = "insights.verdict.refreshed"
    case insightsAuditlogCleared = "insights.auditlog.cleared"

    // MARK: Tier 2 — quota / budget
    case quotaRefreshStarted = "quota.refresh.started"
    case quotaRefreshSucceeded = "quota.refresh.succeeded"
    case quotaRefreshFailed = "quota.refresh.failed"
    case quotaSetupSaved = "quota.setup.saved"
    case quotaWorkspaceFilterChanged = "quota.workspace.filter_changed"
    case budgetRuleChanged = "budget.rule.changed"
    case budgetThresholdWarning = "budget.threshold.warning"
    case budgetThresholdBlocked = "budget.threshold.blocked"

    // MARK: Tier 2 — cloud sync
    case cloudsyncCompleted = "cloudsync.completed"
    case cloudsyncFailed = "cloudsync.failed"
    case cloudsyncManualBackupRun = "cloudsync.manual_backup.run"

    // MARK: Tier 2 — menubar / windows / wallpaper
    case menubarPopoverShown = "menubar.popover.shown"
    case menubarAction = "menubar.action"
    case missionConsoleOpened = "mission_console.opened"
    case wallpaperToggled = "wallpaper.toggled"
    case wallpaperConfigChanged = "wallpaper.config.changed"

    // MARK: Tier 2 — visual capture
    /// Privacy-preserving surface selection for the visual capture toggle. Params:
    /// `provider` (persistedToken), `surface` (cli_pty|desktop_app), `trigger`
    /// (settings|session_header|mobile), `fallback_used` (Bool), `is_eligible` (Bool).
    /// Never includes window titles, bundle IDs beyond persistedToken, or pixel hashes.
    case visualCaptureSurfaceSelected = "visual_capture.surface_selected"

    /// Amplitude category metadata for this event (set via the SDK, never
    /// embedded in the name). Default is `primaryAction`.
    var category: AnalyticsCategory {
        switch self {
        case .appSessionStarted, .appSessionEnded, .appForegrounded, .appBackgrounded,
             .authSignedOut, .onboardingStarted, .onboardingDismissed, .consentAnalyticsGranted,
             .chatGenerationCompleted, .quotaRefreshStarted, .quotaRefreshSucceeded:
            return .lifecycle
        case .appStartupFailed, .errorHandled, .chatGenerationFailed, .chatAttachmentFailed,
             .quotaRefreshFailed, .budgetThresholdBlocked, .cloudsyncFailed:
            return .error
        case .screenViewed, .navRouteChanged, .onboardingStepViewed,
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
enum AnalyticsCategory: String, Sendable {
    case lifecycle
    case screenView = "screen_view"
    case primaryAction = "primary_action"
    case conversionAuth = "conversion_auth"
    case error
}
