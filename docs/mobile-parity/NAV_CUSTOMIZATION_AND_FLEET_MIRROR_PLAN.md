# Customizable mobile navigation + AI Inbox / Agent Fleet everywhere

Status: implementation in flight (this document is the design contract for the
feature branch `worktree-mobile-nav-inbox-fleet`).

## Goal

1. **AI Inbox** and **Agent Fleet** become first-class, user-addable navigation
   destinations on iOS, iPadOS, and Android (the inbox already ships on all
   three platforms; the fleet dashboard was macOS-only).
2. The bottom navigation bar becomes **user-editable** on iPhone and Android:
   add, remove, reorder, and configure items; the item count is variable.
   iPhone additionally supports **multiple AI Inbox instances**, each with an
   optional filter preset (Attention / Active / Resolved / Archived).
3. **Swipe between tabs** (content-area horizontal swipe advances one tab) is
   available on iPhone (already shipped) and Android (new), and is now
   **user-toggleable, default ON**, on both.

## Fleet cloud mirror (the new transport)

The fleet snapshot was deliberately local-only (`docs/fleet/BURNBAR_FLEET_API.md`).
Mobile needs a transport, so the Mac app gains a **sealed Firestore mirror**
following the exact `AIInboxSyncService` pattern (Mac-as-publisher, cloud-vault
sealed payloads, pref-gated):

- **Collection:** `users/{uid}/fleet_snapshot`, single document `current`.
- **Document fields (plaintext envelope):**
  - `schemaVersion` — mirror envelope version, `1`.
  - `updatedAt` — Firestore `Timestamp`, mirror write time (staleness signal).
  - `generatedAt` — Firestore `Timestamp`, snapshot generation time on the Mac.
  - sealed payload fields exactly as produced by the shared sealed-envelope
    codec (same shape as `ai_inbox_items` documents: ciphertext + vault key id
    + associated data binding `uid` and document path).
- **Sealed content:** the canonical `BurnBarFleetSnapshot` JSON
  (`OpenBurnBarKernel/Contracts/BurnBarFleetContracts.swift`, schemaVersion 1,
  ISO-8601 UTC dates). No field subsetting — the mobile dashboard renders the
  same truth the Mac renders.
- **Publisher:** `AgentLens/Services/CloudSync/FleetSyncService.swift`, a
  `CloudSyncDomain` registered in `CloudSyncCoordinator`/`CloudSyncService`.
  Fetches the snapshot the same way `FleetService` does (daemon socket RPC
  `daemon.fleet.snapshot`, falling back to `fleet-snapshot.json`), seals, and
  writes `current`. A content hash of the snapshot JSON gates the write so a
  dead daemon does not re-publish the same bytes every cycle.
- **Preference:** `fleet.cloudMirror.enabled`, default **true** (absent =
  enabled), surfaced next to the inbox mirror toggle in Mac Settings → Privacy.
- **Mobile consumption is read-only in v1.** Orchestrator designation and
  directives remain Mac/daemon-local; no write-back collection exists. The
  mobile dashboard renders snapshot + staleness honestly ("Synced from your
  Mac …" provenance, explicit Mac-offline state when `updatedAt` goes stale).
- **Firestore rules:** owner-only read/write, same posture as
  `ai_inbox_items` (any of the user's devices may write; content is sealed).

`docs/fleet/BURNBAR_FLEET_API.md` must be updated in this branch: "Fleet is
local-only" becomes "Fleet is local-first; an optional sealed cloud mirror
(default on, pref `fleet.cloudMirror.enabled`) publishes the snapshot for the
user's own mobile devices."

## Navigation model

### iOS / iPadOS

- `AuroraNavDestination` gains cases `inbox` (id `"inbox"`) and `fleet`
  (id `"fleet"`), matching the canonical route-map ids. Icons follow the
  existing `insights` SF-Symbol path inside `AuroraNavIcon`.
- New `AuroraNavItem` (`Identifiable, Codable, Hashable`): `id` (stable
  instance id), `kind: AuroraNavDestination`, `inboxFilter: String?`
  (an `AIInboxStore.Filter` raw value; `inbox` kind only). Only `inbox` may
  appear more than once; `.you` is always present (it hosts Settings); item
  count is clamped to 2…8.
- `AppCustomization` persists `[AuroraNavItem]` under `customNavItems`
  (JSON). Empty/corrupt → default `[pulse, burn, insights, streams, hermes,
  you]`. First read migrates the legacy iPad `customPrimaryTabs` order when
  present.
- `RootTabView` (iPhone + compact iPad) renders the tray from `navItems`;
  selection becomes item-based so duplicate inbox instances work. The tray
  computes per-tab width from available width (clamped 40…56 pt) instead of a
  fixed 56 pt so up to 8 items fit on small phones. `AuroraNavGestureModel`
  keeps its pure functions but works over generic element arrays.
- Root swipe gains `@AppStorage("rootSwipeNavigationEnabled")` (default true)
  AND-ed into the existing `isRootSwipeEnabled` gates.
- `RootNavigationView` (regular-width iPad) derives its primary sidebar rows
  from `navItems` kinds (deduped — instances are a tray concept), adds
  `inbox` and `fleet` detail branches (`AIInboxSplitLayout`, fleet dashboard).
- The inbox deep link (`burnbar://inbox[/{itemId}]`) and inbox push routing
  prefer a present `inbox` nav item and fall back to the Streams segment
  (which remains, unchanged, for users who don't add the tab).
- New settings page "Navigation" (`SettingsPageRoute` + manifest + search):
  edit items (reorder / delete / add / configure inbox preset), swipe toggle.

### Android

- `GlobalVisualSettingsTabs` vocabulary bug fixed: reads map legacy `agents` →
  `hermes` (the stored default silently dropped the Assistants tab to the end).
  The prefs vocabulary is aligned to `BurnBarTab.route` strings.
- Tab customization becomes real: the `BurnBarTab.all` merge honors removals
  (guards: `you` is always present; minimum 2 tabs; unknown routes dropped;
  every *default* tab that has never been explicitly removed is re-appended,
  tracked via a `removedTabs` pref so "removed" and "not yet known" are
  distinct states).
- New `BurnBarTab.FLEET` (route `fleet`) + `AuroraNavDestination.FLEET` +
  route builder + `FleetScreen` (Compose) + `FleetStore` (Firestore listener
  on `users/{uid}/fleet_snapshot/current`, cloud-vault unseal, hand-rolled
  JSON parsing into Kotlin models mirroring the Swift contracts).
- Content-area swipe: a `PointerEventPass.Final` observer on the phone shell's
  content box — acts only on unconsumed, predominantly-horizontal drags past
  a 30 dp threshold, one tab advance per gesture (ports
  `AuroraNavGestureModel` semantics; pure logic extracted + unit-tested).
  Toggleable via a new `GlobalVisualSettings` boolean, default true.
- New settings screen "Navigation" following the `QuotaCustomizationScreen`
  pattern (visibility toggles + up/down reorder), registered in the manifest.
- Inbox stays single-instance on Android in this pass (it is already a primary
  tab there); multi-instance inbox is an accepted iOS divergence recorded in
  the route map.

### Parity lockstep (must land together)

- `docs/mobile-parity/mobile-route-map.json`: canonical id `fleet` + bindings
  (`BurnBarTab.FLEET`, `AuroraNavDestination.fleet`), `inbox` binding gains
  the iOS destination id, shells updated, divergence notes for multi-instance
  inbox (iOS-only) and inbox-primary-android (retained).
- `burnbar://fleet` host added to `MobileOsIntegrationPolicy.allowlistedHosts`
  in **both** the Kotlin and Swift policies plus
  `fixtures/product/os-integration-vectors.json`, and to `MobileOsDestination`.
- Capability registry rows for `fleet.dashboard` (ios/android surfaces);
  ledger regenerated via `scripts/mobile-parity/render-mobile-parity-ledger.mjs`.

## Validation matrix

- Android: `:app:compileDebugKotlin`, `testDebugUnitTest` (nav host, tabs
  persistence, gesture model, fleet parsing, OS-integration parity), ktlint.
- iOS/macOS: unit tests for `AppCustomization` (round-trip, migration,
  corrupt JSON), `AuroraNavigationTrayTests` (updated for dynamic items),
  analytics mapping exhaustiveness, `FleetSyncService` watermark/gating,
  Swift OS-integration parity tests.
- Parity validators: `validate-mobile-parity.mjs`,
  `check-mobile-os-integration.mjs`, ledger render.
