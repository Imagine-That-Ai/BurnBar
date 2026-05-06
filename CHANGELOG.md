# Changelog

All notable changes to OpenBurnBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — iPadOS Port Phase 2 Hardening (2026-05-02)

### Changed
- **Responsiveness/performance pass:** dashboard usage now caches date-window
  aggregates and builds provider/model summaries in one pass; quota refreshes
  are bounded and coalesced across popover/dashboard entry points; the database
  workspace rebuilds snapshots on debounced input changes instead of polling;
  startup defers the first heavy refresh; mobile quota/provider stores keep
  derived state cached and lower idle animation cadences. SQLite now carries
  token-usage indexes for sync, provider, model, and provider-id time-window
  queries.
- **Hermes accent: gold → dark platinum.** `hermesAureate` is no longer a divine
  gold (`#B8942E` / `#D4AA3C`) — it is now a sophisticated dark platinum
  (`#3F4651` light, `#A2ACBA` dark). The mercury gradient (silver → platinum) now
  reads as polished gunmetal instead of mercury → gold, giving the Hermes
  surfaces a colder, more premium feel that better matches the app's industrial
  / utilitarian aesthetic. Cascades through the entire app (nav tab accent,
  badges, send buttons, message strokes, sidebar marker, popover strip border).

### Added
- **Provider-connection onboarding wizard (iOS / iPadOS):** replaced the placeholder
  welcome/cloud/Hermes screens with a five-stage wizard that walks new users from
  sign-in to a connected first account — `welcome → pick → connect → review → done`.
  Picker tile grid surfaces recommended providers first; the connect step uses a
  shared `ProviderSetupGuide` registry (per-provider instructions, dashboard URL,
  supported credential kinds, paste hints, hosted/self-hosted gating) and ships
  the same component (`OnboardingProviderConnectStep`) the renovated manual sheet
  embeds, so muscle memory transfers between first-run and post-onboarding adds.
- **Renovated manual "Add Account" sheet (iOS / iPadOS):** `AddProviderConnectionView`
  is now a 3-sub-step guided flow (`guide → paste → connecting/result`) backed by
  `OnboardingProviderConnectStep`. Provider hints, dashboard links, and credential
  kind options are pulled from the same `ProviderSetupGuide`, ending duplicate copy
  between the wizard and manual surfaces. The "Available providers" list now shows
  a one-line setup hint per provider (e.g. *Cursor — "Sign in once, then we capture
  the cookie"*) so the list reads as a menu, not a wall of avatars.

### Fixed
- **Dashboard agent/model ranking correctness:** token mode now ranks providers,
  models, and model/provider drill-down stacks by token volume instead of
  spend; currency mode still ranks by spend. Kimi imports now reject
  `chatcmpl-*` request ids as model names, and the database repair drops or
  normalizes existing Kimi request-id rows so the Kimi agent bucket is not
  inflated by stale model identity pollution.
- **Cursor "Included usage" gauge renders as currency on iOS / iPadOS:**
  `ProviderQuotaUnit` gains a `.currency` case; `CursorQuotaAdapter` flips the
  `cursor-plan` and `cursor-ondemand` buckets to `.currency` (they already store
  dollars, not percentages). `UnifiedQuotaSignalView` reads `meta["unit"]` and
  formats `$0.39 / $3.61 / $4.00` instead of `39 / 361 / 400`. Mobile receives
  the corrected unit automatically via the existing `QuotaSnapshotSyncService`
  schema — no Firestore migration needed.

### Added
- **iOS App Store release runbook and ASC review tooling:** documented the
  iOS submission path in `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md`, including
  reviewer account seeding, subscription selection, build compliance,
  manual-release mode, and final-submit confirmation gates. The App Store
  Connect helper can now patch build encryption compliance, set manual release,
  and upsert App Review credentials/notes with redacted local credential input.
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

## [Unreleased] — Server-side Apple JWS Verification (2026-05-04)

### Added
- **Full Apple App Store JWS verification pipeline (`functions/src/appstore/`).**
  Hosted-quota entitlements are now derived from chain-verified, live-reconciled
  Apple state. Replaces the v1 callable that only stored a SHA-256 of a
  client-supplied JWS.
  - `verifier.ts` — `AppleJWSVerifier` wraps `@apple/app-store-server-library`
    against three vendored root certificates (`AppleRootCA-G3`, `AppleRootCA-G2`,
    `AppleIncRootCertificate`) with SHA-256 fingerprint pinning enforced at
    cold start. Per-environment `SignedDataVerifier` instances, optional
    `autoFallbackEnvironment` retry, and stable `apple-jws-…` error codes.
  - `client.ts` — Cached `AppStoreServerAPIClient` per environment; surfaces
    `getAllSubscriptionStatuses` and `getTransactionInfo` for live reconciliation.
  - `reconciler.ts` — Single writer for `users/{uid}/entitlements/hosted_quota_sync`.
    Resolves UID via `appAccountToken` ↔ `entitlement_bindings`, picks the
    most recent `signedDate` transaction across the JWS + ASC view, enforces
    monotonicity on `lastVerifiedAt`, and merges stable fields forward.
  - `audit.ts` — Append-only `users/{uid}/entitlement_events/{eventId}` with
    `notificationUUID`-keyed idempotency, `signedTransactionInfo`/
    `signedRenewalInfo`/`signedPayload` redaction (raw JWS hashed,
    `appAccountToken` truncated).
  - `notifications.ts` — Public `appStoreServerNotificationsV2` HTTPS
    endpoint; verifies S2S `signedPayload`, distinguishes 4xx (terminal
    invalid) from 5xx (Apple-retry), idempotent on `notificationUUID`.
  - `scheduled.ts` — Daily `reconcileHostedEntitlementsDaily` rebuilds
    every active entitlement from ASC truth so missed webhooks converge
    within 24h.
  - `callable.ts` — Three iOS-facing callables: `beginEntitlementBinding`
    (mints `appAccountToken` UUID before purchase),
    `verifyHostedQuotaEntitlement` (verifies + reconciles a JWS),
    `restoreHostedQuotaEntitlement` (re-runs reconciliation for the
    signed-in user's known `originalTransactionID`).
- **Pinned Apple root certificates.** DER-encoded certs vendored under
  `functions/src/appstore/certs/` and copied to `lib/` by
  `scripts/copy-certs.mjs` (chained from `npm run build`). SHA-256
  fingerprints pinned in `verifier.ts:ROOT_CERT_FILES`.
- **`HostedQuotaEntitlementDoc` schema v2** (`schemaVersion: 2`,
  `verificationVersion: 2`, `source: "apple_jws_verified"`). Adds
  `revokedAt`, `revocationReason`, `environment`, `ownershipType`,
  `appAccountToken`, `signedTransactionHash`, `lastNotificationUUID`,
  `lastVerifiedAt`. Carries forward stable fields when a JWS omits them.
- **`EntitlementBindingDoc`** at `users/{uid}/entitlement_bindings/{token}` —
  server-only collection that maps a server-minted UUID to a Firebase UID
  pre-purchase. Required to attribute incoming JWS payloads when the
  callable was untrusted (e.g. S2S notifications).
- **`EntitlementEventDoc`** append-only audit log surfaced under
  `users/{uid}/entitlement_events/{eventId}` for forensics.
- **iOS `HostedQuotaSubscriptionStore` rewritten** for the new pipeline.
  Mints `appAccountToken` via `beginEntitlementBinding`, passes it through
  `Product.PurchaseOption.appAccountToken`, forwards the JWS to
  `verifyHostedQuotaEntitlement`, observes `Transaction.updates` for
  renewals/revocations, and adds `restorePurchases()` backed by
  `restoreHostedQuotaEntitlement`. Prefers the server's view of
  inactivity over the local StoreKit cache.
- **Firestore rules (`firestore.rules`):** server-only writes to
  `users/{uid}/entitlements/*` and `users/{uid}/entitlement_events/*`;
  `users/{uid}/entitlement_bindings/*` denied to clients for both reads
  and writes.
- **Regression suite (`functions/scripts/test-appstore.mjs`):** 31
  `node:test` cases covering root cert fingerprint pinning, environment
  enum round-trip, reconciler selection / merge / monotonicity logic,
  audit redaction + idempotency, binding doc construction, and stable
  error codes. Wired into `npm test` via `npm run test:appstore`.
- **`@apple/app-store-server-library` v3** added to `functions/package.json`.

### Security
- Trust pipeline: every entitlement field is now derived from a chain-verified
  Apple JWS, reconciled against live App Store Server API truth, and bound
  to a Firebase UID via a server-minted `appAccountToken`. Client-supplied
  values are no longer authoritative for activation, expiration, or
  ownership — see `docs/THREAT_MODEL.md` § "Hosted Quota Subscription".
- `entitlement_events` audit log makes every state change reviewable by
  the owner and replayable from raw JWS hashes.

### Migration notes
- Legacy v1 entitlement docs (where the server stored only a SHA-256 of a
  client-supplied JWS) keep their fields untouched until the next verified
  event. The first call into `verifyHostedQuotaEntitlement` /
  `restoreHostedQuotaEntitlement` upgrades the doc to schema v2 in place.
- Operators must populate `APP_STORE_ASC_KEY_ID`, `APP_STORE_ASC_ISSUER_ID`,
  and `APP_STORE_ASC_KEY_P8` via Secret Manager before the production
  callables are reachable; see `docs/HOSTED_QUOTA_SYNC.md`
  § "App Store JWS verification config".

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
