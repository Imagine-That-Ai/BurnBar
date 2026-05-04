# Changelog

All notable changes to OpenBurnBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — iPadOS Port Phase 2 Hardening (2026-05-02)

### Added
- **Routing-aware provider account cockpit (Mac + Mobile):** every quota- and
  account-bearing surface now shows which provider account is *currently* serving
  traffic, the next fallback, and any blocked/cooling-down accounts with
  sanitized switch reasons — never credential material. Mac surfaces in scope:
  `ProvidersSettingsView`, `ProviderDashboardQuotaPanel`, expanded popover
  rows. Mobile/iPad surfaces in scope: `QuotaView` cards, `QuotaDetailSheet`,
  `ProviderConnectionsView` group sections (with per-account
  Active/Next/Blocked chips), and `ProviderDashboardView` quota section.
  Backed by the existing `ProviderRoutingPolicy.decide` contract — no new
  routing semantics, just unified visualization.
- **Single source of truth for `AgentProvider` / `TokenUsage`:** the
  ~600-line macOS-only `AgentLens.AgentProvider` and `AgentLens.TokenUsage`
  duplicate definitions are deleted. The macOS app now uses
  `OpenBurnBarCore.AgentProvider`, `OpenBurnBarCore.TokenUsage`,
  `UsageProvenanceMethod`, `UsageProvenanceConfidence`, and `UsageSource`
  as the canonical types via thin module-level typealiases in
  `AgentLens/Models/AgentProvider.swift`. Mac-only behaviors
  (`logDirectory`, `filePattern`, `supportLevel`, `dataConfidence`,
  per-row `cacheEfficiency`, `CacheEfficiency.aggregate(_:)`) live as
  extensions on the package types so the macOS file watcher and dashboard
  surfaces still compile. The Mac module shrank by **−421 lines (−56%)**
  in `AgentProvider.swift`. RawValues, Codable keys, and init signatures
  were verified byte-identical before the consolidation, so SQLite rows
  and Firestore docs persist losslessly across the change. `ProviderSummary`,
  `ModelSummary`, and `ProviderUsage` carry an aggregate
  `OpenBurnBarCore.CacheEfficiency` so dashboard cache hit rate badges work
  end-to-end.
- **`scripts/clear-xcode-caches.sh`:** repo helper to clear DerivedData,
  SwiftPM caches, and XCFramework device-support caches. Use after
  shared-core migrations when SourceKit shows ghost errors or XCFramework
  symbol mismatches between Mac and Mobile targets. Supports `--dry-run`,
  `--derived-only`, `--xcframeworks`, `--packages`.
- **First-class provider accounts:** shared `ProviderAccountDoc` contracts,
  local SQLite persistence, account-aware quota snapshots, usage rollup account
  summaries, Cloud Functions account APIs, and mobile provider/account lists.
- **OpenAI provider accounts:** OpenAI is now a catalog-backed provider identity
  with backend credential validation and usage refresh through the OpenAI
  organization usage endpoint.
- **iPad Onboarding Wizard (`iPadOnboardingWizardView`):** 4-step onboarding (Welcome → Cloud Connect → Hermes Setup → Complete) with staggered entrance animations, progress dots, skip functionality, and `@AppStorage` persistence. Presented from `AuthGateView` on first launch.
- **Live Activity Infrastructure (`BurnBarLiveActivityAttributes`, `LiveActivityManager`, `BurnBarLiveActivityWidget`):** Lock screen banner + Dynamic Island with real-time cost, tokens, top provider, and pulsing session-active dot. Auto-managed by `DashboardStore`. All ActivityKit code guarded with `#available(iOS 16.1, *)`.
- **Siri Shortcuts Intent (`BurnBarStatusIntent`):** Voice query "What's my burn today?" returns cost, tokens, and provider count.
- **Deep Linking (`burnbar://dashboard`, `burnbar://settings`, `burnbar://chat`):** Handled in `OpenBurnBarMobileApp` via `.onOpenURL`. Widget tap routes to dashboard via `widgetURL`.
- **iPad Navigation UI Tests (`iPadNavigationUITests`):** 14 tests covering route model, settings tabs, auth gate, provider aggregates, Hermes state, session search, and deep links.
- **Keyboard Shortcuts:** ⌘1–4 (navigation), ⌘R (refresh), ⌘H (Hermes), ⌘, (settings), ⌘[ (back).

### Changed
- Provider quota sync now uploads non-secret provider account metadata and
  account-scoped snapshots so iPhone/iPad can show cloud-refreshable and
  Mac-local accounts honestly.
- **`DashboardView`:** Staggered entrance animations, chart entrance, hover scale on all interactive rows.
- **`ChatView`:** Real Hermes SSE streaming (`HermesService`), connection status bar, graceful error bubbles.
- **Settings:** All 7 tabs have real data — live Firestore provider connections, alert sliders, system settings link, multi-profile switcher.
- **Session search:** Expanded from 3 → 6 fields (session ID, cost, device name added).
- **Widget `Info.plist`:** Removed invalid `NSExtensionPrincipalClass` that blocked simulator installs.

### Fixed
- Secret Manager version names are kept out of public provider account docs and
  destroy-failure logs.
- `ProviderDashboardStoreTests` compilation (`usages` access).
- `FirestoreNormalizationTests` `TimeInterval?` coercion.
- Auth identity label showing raw email instead of provider.

## [0.1.3-beta.1] — 2026-05-01

### Added
- **Warp provider (`AgentProvider.warp`):** New parser, quota adapter, brand identity, tests.
- **App test driver (`scripts/test-openburnbar-app.sh`):** Retry logic, hang detection, JSONL telemetry.
- **Test-host short-circuit (`AgentLensApp`):** Skips Firebase/Sentry/DataStore when XCTest-injected.
- **Provider stable persistence token (`AgentProvider.persistedToken`).**
- **Synchronous test mode for settings persistence.**
- **Executable-path injection on `SwitcherCLIAuthCoordinator.Dependencies`.**

### Changed
- `SettingsPersistenceCoordinator` legacy migration scoped to `UserDefaults.standard`.
- Settings min-clamp policy falls back to default instead of floor.
- `TokenExtractionUtility.normalizeModelName` case-insensitive `custom:` strip.
- `TokenExtractionUtility.detectModelHint` captures first token only.
- `AlertSettings.costAlertThreshold = nil` fully removes keys.
- `SettingsSecretPersistence` no longer deletes legacy on keychain failure.
- `KeychainStore.set` verifies write bytes.
- `ProviderPathSettings` persists under `logPath_<persistedToken>`.

### Fixed
- DataStore-pollution test isolation.
- Snapshot reference refresh (22 images).
- `TimestampNormalizationTests` UTC-anchored calendar.
- Mobile app data-loading after auth (Firestore shape mismatches, Timestamp→Double, ISO date→Double, `sanitizeForJSON`, `decodeWithDocID`).
- `FirestoreRepository` reliability (typed errors, exponential backoff).
- Protocol-oriented normalization (`FirestoreNormalizable`).

## [Unreleased] — iOS / iPad Visual Depth & Polish Pass (2026-05-04)

### Added
- **38 provider logos shipped to iOS bundle:** all `AgentProvider.allCases` now have bundled image assets in `OpenBurnBarMobile/Resources/Assets.xcassets`, resolving the long-standing gap where iOS showed only SF Symbol fallbacks.
- **`ProviderAvatar` — canonical avatar component:** replaces `ProviderBadge` everywhere with three display modes (`.plain`, `.tile`, `.aurora`). The `.aurora` mode renders a radial glow, gradient ring, and `glassEffect()` on iOS 26+.
- **`EmberSurfaceBackground` — reusable brand backdrop:** promoted from `SignInScene` into `OpenBurnBarCore`. Warm gradient + drifting ember orbs + floating particles in dark mode; botanical cream wash in light mode. Respects `accessibilityReduceMotion` and `accessibilityReduceTransparency`.
- **`EmberSkeleton` — branded skeleton loading:** warm ember-tinted shimmer band on `surfaceElevated` base. Respects `accessibilityReduceMotion`.
- **`Haptics` — centralized feedback helper:** debounced impact/notification/selection generators hooked to period switches, refresh, quota thresholds, Hermes send, and errors.
- **`MercuryThinkingIndicator` — mercury pool animation:** three droplets that pool and separate (1.8s cycle, 0.3s stagger), replacing the old 3-dot pulse in `ChatView`.
- **`MercuryShimmerOverlay` — slow shimmer stroke:** mercury-tinted gradient band for assistant chat bubble overlays.
- **`FlameRefreshIndicator` — branded pull-to-refresh:** rotating flame spinner.
- **`RollingNumberText` — numeric transition wrapper:** `.numericText(countsDown:)` with proper font/scale handling.
- **iPad onboarding wizard upgrade:** animated SF Symbol scenes (`symbolEffect(.bounce/.pulse/.variableColor)`) layered over the ember backdrop with a continuous progress capsule.
- **iPad placeholder views (`ProjectsView`, `MissionsView`, `ModelDashboardView`):** meaningful shells with animated symbols, "Coming in v0.2" badges, and ember backdrops.
- **Widget refresh:** `HeroSmallView`, `CostSparklineMediumView`, and `DashboardLargeView` now use `UnifiedProviderLogoView` for the top provider. Sparkline gets soft area gradient + glow on the trailing dot. Live Activity expanded center swaps `flame.fill` for the active provider's logo.

### Changed
- **`DashboardView`:** `UnifiedGlassCard` hero with aurora avatar, rolling cost number with trend delta, `AreaMark` + `LineMark` chart with provider-tinted gradient, `RuleMark` annotation for today, iPad velocity sparkline in 2-column layout.
- **`QuotaView`:** glass cards with aurora avatars, `UnifiedQuotaSignalView` battery bars, warning/healthy section halos.
- **`ActivityView`:** grouped by day with sticky headers, provider-colored 3pt rail, monospaced token badge, glass `UnifiedGlassCard` rows, search result transitions.
- **`SessionDetailView`:** hero panel with aurora avatar, animated horizontal token-mix bar with provider chart palette, inset glass panels for provenance/device.
- **`AccountView`:** animated gradient halo around avatar (12s rotation), live account health line, pulsing sync dot, overlapping aurora avatars for connections, destructive sign-out with `confirmationDialog`.
- **`ChatView` (Hermes):** assistant bubbles get `mercuryGradient` 1pt stroke + shimmer overlay, caduceus glyph (`☿`) prefix, "via Hermes" badge, glass input bar with `glassEffect()` on iOS 26+.
- **`RootTabView`:** iOS 18+ value-based `Tab` API with `Tab(role: .search)`. iOS 26+ `tabBarMinimizeBehavior(.onScrollDown)`.
- **`RootNavigationView`:** glass sync health pill with pulsing dot + last-sync timestamp, keyboard shortcuts (`⌘1–4`, `⌘H`, `⌘,`) wired to sidebar items.
- **iPad settings views:** `.grouped` forms with `scrollContentBackground(.hidden)` so the ember backdrop shows through subtly.
- **`QuotaDetailSheet`:** provider hero with aurora avatar + gradient backdrop, horizontally swipable account card carousel, stats row for confidence/source/freshness.

### Tests
- `OpenBurnBarMobileTests/ProviderAvatarTests.swift`: asserts every `AgentProvider.allCases` resolves a bundled image asset.
