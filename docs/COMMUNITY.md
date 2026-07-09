# BurnBar Community — Consent-Gated Cross-Platform Leaderboards + Looking Glass Mode

> **Status:** Structured-large PR. Leaderboards are the centerpiece: city, region/state, country, and world boards per time window, with your rank pinned, percentile movement arrows, and k-anonymity thresholds (k=10).

## Architecture

```
Local usage → Consent gate
  ├─ L1 only  → Personal analytics (local render, no egress)
  ├─ L2       → share_snapshot doc → hourly aggregate → community_leaderboards (public)
  │             ├─ k ≥ 10 → publish board
  │             └─ k < 10 → belowThreshold doc (UI falls back to broader tier)
  └─ L3       → Looking Glass traces + export bundles (never feeds leaderboards)
```

### Data flow

1. **Client** computes `CommunityShareSnapshotDoc` from existing `UsageRollupDoc` merge (tokens, costUSD, model mix, purpose mix per window).
2. **Client** writes the snapshot to `users/{uid}/community/share_snapshot` only while L2 is granted.
3. **Hourly onSchedule** (`aggregateCommunityLeaderboards`) collectionGroups over all share snapshots, server-side consent recheck, computes leaderboards per window × tier, applies k-anonymity, and writes public `community_leaderboards/{window}_{tier}_{geoKey}` docs.
4. **Clients** read leaderboards (public authenticated read-only) and render the UI.

## Consent Model

Three independent tri-state ladders, modeled on `AnalyticsConsentStore.swift` / `ConsentSignal`:

| Level | Name | Scope | Egress |
|-------|------|-------|--------|
| L1 | Private Analytics | Local-only personal dashboard | None |
| L2 | Community Rankings | Per-geography-tier sub-toggles (world/country/region/city) | share_snapshot only |
| L3 | Looking Glass Mode | Richer traces + export bundles | Traces + exports |

### Tri-state semantics

| State | Meaning | Server behavior |
|-------|---------|-----------------|
| `unset` | Default dark — user hasn't decided | No collection, no network, no location lookup |
| `granted` | Explicit opt-in | Permitted |
| `declined` | Explicit refusal | Identical to unset (fail closed) |

**City tier** additionally requires the separate `locationConsent` tri-state. Revoking L2 = declined, triggers `revokeCommunityParticipation`.

### Per-platform stores

- **macOS** `CommunityConsentStore.swift` (AppStorage, shared file with iOS)
- **iOS** `CommunityConsentStore.swift` (same shared file)
- **Android** `CommunityConsentStore.kt` (DataStore)
- **Windows** C# settings-backed store
- **Linux/Web** TS store (localStorage + Firestore mirror)

All default `unset` = fully dark: no collection, no location lookup, no network.

## Schema

TypeSpec-first in `tools/schema-sync/typespec/domains/community.tsp`. Emits TS/Swift/Kotlin.

| Path | Document | Access |
|------|----------|--------|
| `users/{uid}/community/consent` | `CommunityConsentDoc` | Owner read; callable write (Admin SDK) |
| `users/{uid}/community/profile` | `CommunityProfileDoc` | Owner read; callable write |
| `users/{uid}/community/share_snapshot` | `CommunityShareSnapshotDoc` | Owner read+write (client-written) |
| `community_leaderboards/{window}_{tier}_{geoKey}` | `CommunityLeaderboardDoc` | Public authenticated read; no client write |
| `community_handles/{handleLower}` | `{ uid, createdAt }` | No client access (callable-managed) |
| `users/{uid}/looking_glass_traces/{id}` | `LookingGlassTraceDoc` | Owner read+write |
| `users/{uid}/looking_glass_exports/{id}` | `LookingGlassExportDoc` | Owner read; callable write |

`tspOnlyModels`: `CommunityShareSnapshotDoc`, `CommunityWindowTotals`, `CommunityUsageTotal` (Record<> + @encodedName don't round-trip through the canon gate; hand-maintained in `functions/src/community/shareTypes.ts` and platform-native equivalents).

## Ranking Algorithm

### k-Anonymity threshold (k = 10)

A cohort needs ≥ 10 members to publish a board. Below threshold:

- `belowThreshold: true`
- `entries: []` — **no individual data published** (no handle, no anonId, no tokens, no cost)
- `percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 }` — all zeros
- `cohortSize: 0` — exact count withheld (avoids revealing "only 3 people in this city")

The UI falls back to the next-broader tier (city → region → country → world).

### Movement arrows

Each entry carries a `movement` field computed by comparing the entry's rank against the previous aggregation cycle's all_time world board:

| Movement | Condition |
|----------|-----------|
| `up` | Current rank < previous rank |
| `down` | Current rank > previous rank |
| `same` | Rank unchanged |
| `new` | No previous rank (first cycle) |

### Percentile bands

Computed using nearest-rank linear interpolation on the sorted token totals: p50, p75, p90, p99.

### Tiebreaker

Sort by `totalTokens` descending, then `costUSD` descending.

## Geography

- **Country/region tiers** use locale/timezone without any location permission.
- **City tier** requires coarse OS location consent (separate from L2):
  - Apple: reduced-accuracy CoreLocation
  - Android: `ACCESS_COARSE_LOCATION`
  - Windows: `Windows.Devices.Geolocation`
  - Linux/web: timezone/locale-derived region + manual picker
- Client-side reverse-geocode → keys only (`countryCode`, `regionKey`, `cityKey`). Never raw coordinates.
- The OS prompt appears only when enabling the city tier.

## Model-Purpose Classifier

Canonical TS reference: `functions/src/community/classifier.ts`. Ported to Swift/Kotlin/C#.

Categories: `ui`, `backend`, `logic`, `writing`, `research`, `debugging`, `orchestration`, `other`.

Signals:
- File extensions (strong weight)
- Session keywords (medium weight)
- Boolean flags (error output, code execution, search results, multi-step planning)
- Model bias (weak weight)
- App surface bias (weak weight)

Inferred label shown with a correction affordance; corrections persist locally and bias future inference via fingerprint matching. L3 exports include corrected labels.

Golden fixtures: `tests/fixtures/classifier-goldens.json` verify cross-platform parity.

## Backend (`functions/src/community/`)

| Module | Purpose |
|--------|---------|
| `consent.ts` | Server-side consent recheck (`recheckConsent`), K_THRESHOLD, CommunityPaths |
| `aggregation.ts` | Hourly `onSchedule`: collectionGroup, consent recheck, leaderboard computation |
| `callables.ts` | `joinCommunity`, `updateCommunityProfile`, `revokeCommunityParticipation`, `exportLookingGlassBundle` |
| `classifier.ts` | Canonical model-purpose classifier (shared spec) |
| `shareTypes.ts` | Hand-maintained types for Record/@encodedName models |

### Handle uniqueness

Transactional `community_handles/{handleLower}` doc-ID claim — atomic, no TOCTOU race, no collectionGroup scan or index. Released on handle change and revoke.

## Platform UI Map

Shared layout (identical IA, native skin per platform):

```
Personal hero (tokens/cost/model mix/trend delta)
  → Leaderboard cards (city→world, top rows + your pinned rank + movement)
  → Percentile strip
  → Time filter (today/7d/30d/90d/all)
  → Peer comparison chart (anonymized cohort bands)
  → Purpose breakdown
  → Consent center (toggles, data preview, export, pause, revoke, delete)
```

| Platform | Location | Entry point | Design language |
|----------|----------|-------------|-----------------|
| macOS | `AgentLens/Views/Community/` | Popover + Dashboard | GlassCard / mercury |
| iOS/iPadOS | `OpenBurnBarMobile/Views/Community/` | Pulse card + You tab | Editorial Observatory |
| Android | `ui/community/` | Nav route + `burnbar://community` deep link | Material-glass / aurora |
| Windows | `OpenBurnBar.App/Community/` | Dashboard nav | WinUI MVVM |
| Linux | `apps/linux-desktop/src/community/` | App nav | Tauri/React |
| Web | `apps/console/app/dashboard/community/` | Dashboard sidebar | Next.js responsive glass |

Empty states invite opt-in without pressure. Threshold states explain "needs N more burners in {city}".

## Test Strategy

| Area | Location | Coverage |
|------|----------|----------|
| Functions | `functions/src/__tests__/community.test.ts` | Dark gate, k-threshold, geography fallback, revoke sweep, export bundle shape, handle validation/collision |
| Firestore rules | `firestore-rules-tests/community.test.js` | Leaderboard read-only, owner-only private docs, share_snapshot client write, no client writes to aggregates |
| Swift | `AgentLensTests/` + `OpenBurnBarMobileTests/` | Consent store, classifier goldens, render states (opted-out/empty/threshold/live), revocation UI |
| Kotlin JVM | `android/app/src/test/` | Consent store, classifier goldens, snapshot merge, Compose screen states |
| Schema | `./tools/schema-sync/check-drift.sh` | TypeSpec canon parity, hand-mirror drift |

## Validation

Run the cheapest relevant checks per area:

```bash
# Schema drift (fast)
bash tools/schema-sync/check-drift.sh

# Functions tests
cd functions && npx jest --testPathPattern community

# Firestore rules tests
cd firestore-rules-tests && npx jest community

# Android JVM tests
cd android && ./gradlew :app:testDebugUnitTest --tests "*Community*" --tests "*Classifier*"

# macOS app tests
./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/CommunityTests
```
