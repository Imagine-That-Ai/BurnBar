# Packet A6: OpenBurnBarUI — curation (largest internalization set)

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

Read A0-README.md shared rules FIRST.

## Scope

### dead (23) — delete after re-verification
AgentWatchLiveActivityIntentSecurity, BurnBarLaunchSplashModifier, CardFormat,
CardLayout, CardMissionRefView, CardTooLargeView, CardUnknownView, GemLogoView,
MissionActivityTicker, MissionApprovalCard, MissionConsolePreviewHost,
MissionGlassSurface, MissionGlassVariant, MissionLiveBurnGauge,
NestHubPreviewSnapshot, PixelClockOperationState, PlatformColor, QueryOptions,
SmartHubDisplayOperationState, SmartHubRepairError, SubstrateShape,
UnifiedToolCallAccent, VerdictBulletRow
CAUTION (SwiftUI): views can be referenced ONLY from #Preview blocks or
PreviewProvider — the grep counts those as same-file uses, so a "dead" View may
be preview-only. Preview-only Views in a LIBRARY module are still deletion
candidates, but say so in the PR body. Check Widget/LiveActivity plists and
@main entry points for indirect (string) references to Intent types
(AgentWatchLiveActivityIntentSecurity).

### own-module-only (30) — make internal
AgentInsightsCanvasGridView, AgentInsightsEmptyStateView, AgentInsightsHeaderView,
AgentInsightsKPIStripView, AgentInsightsMissionRailView, InsightAnomalyTableView,
InsightASCIIView, InsightCohortView, InsightDrilldownListView,
InsightFocusMatrixView, InsightForecastView, InsightFunnelView,
InsightMissionApprovalMode, InsightMissionDepth, InsightNarrativeView,
InsightQuotaPulseView, InsightRecommendationView, InsightUseCaseClusterView,
InsightWidgetChrome, MissionApprovalLever, MissionDepthDial,
MissionDispatchButton, MissionPermissionsRow, MissionProjectField,
MissionTitlePromptFields, VerdictBulletList, VerdictDeltaChip,
VerdictProvenanceChip, VerdictRingsStrip, VerdictTraceStripView

### test-only (7) — DO NOT TOUCH (WAIT-FOR-WS-B, packet A9)

## Method
Dead deletions first (own commit), then internalizations (own commit). This is
UI code: also spot-build the app target if any deletion touches a file the app
target compiles directly. Full V-list. Converged-reality section into this card.
