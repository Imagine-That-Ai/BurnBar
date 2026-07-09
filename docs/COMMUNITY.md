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
3. **Hourly onSchedule** (`aggregateCommunityLeaderboards`) publishes the Community public-read status, collectionGroups over all share snapshots, server-side consent rechecks, validates freshness/shape, computes leaderboards per window × tier, applies k-anonymity, and writes public `community_leaderboards/{window}_{tier}_{geoKey}` docs.
4. **Clients** read leaderboards only after the backend-published public-read envelope enables authenticated public reads.

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
| `users/{uid}/community/share_snapshot` | `CommunityShareSnapshotDoc` | Owner read+write (server-refreshed from trusted rollups) |
| `community_leaderboards/{window}_{tier}_{geoKey}` | `CommunityLeaderboardDoc` | Public authenticated read; no client write |
| `community_handles/{handleLower}` | `{ uid, createdAt }` | No client access (callable-managed) |
| `users/{uid}/looking_glass_traces/{id}` | `LookingGlassTraceDoc` | Owner read+write |
| `users/{uid}/looking_glass_exports/{id}` | `LookingGlassExportDoc` | Owner read; callable write |

`CommunityShareSnapshotDoc`, `CommunityWindowTotals`, and `CommunityUsageTotal` are emitted from TypeSpec into TS/Swift/Kotlin. The emitter owns the language-native map shapes and non-identifier window keys (`7d`, `30d`, `90d`, `all_time`) so every platform consumes the same generated contract.

## Ranking Algorithm

### k-Anonymity threshold (k = 10)

A cohort needs ≥ 10 members to publish a board. Below threshold:

- `belowThreshold: true`
- `entries: []` — **no individual data published** (no handle, no anonId, no tokens, no cost)
- `percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 }` — all zeros
- `cohortSize: 0` — exact count withheld (avoids revealing "only 3 people in this city")

The UI falls back to the next-broader tier (city → region → country → world).

### Movement arrows

Each entry carries a `movement` field computed by comparing the entry's rank against the previous aggregation cycle for the same `window × tier × geoKey` board:

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

### Snapshot validation and cleanup

Aggregation rejects malformed or implausible share snapshots before ranking: missing windows, non-monotonic window totals, negative or unsafe token/cost values, oversized mix maps, invalid geo keys, timestamps older than seven days, and timestamps more than ten minutes in the future. Revoked snapshots are tombstones and are deleted before publication. A successful aggregation deletes stale public board docs that were not produced in the current generation; `cleanupStaleCommunityLeaderboards` also runs daily as a safety net.

## Geography

- **Country/region tiers** use locale/timezone without any location permission.
- **City tier** requires coarse OS location consent (separate from L2):
  - Apple: reduced-accuracy CoreLocation
  - Android: `ACCESS_COARSE_LOCATION`
  - Windows: `Windows.Devices.Geolocation`
  - Linux/web: timezone/locale-derived region + manual picker
- Client-side reverse-geocode → keys only (`countryCode`, `regionKey`, `cityKey`). Never raw coordinates.
- The OS prompt appears only when enabling the city tier.

### City-confidence copy

Every Community surface shows the source of its city confidence before or near the city-tier control:

- **No city lookup:** city tier is off; country/region may still derive from timezone/locale.
- **Paused:** city tier is on but coarse/approximate location is unset or declined; broader tiers keep working.
- **Approximate OS location:** Apple, Android, and Windows resolve a canonical city key on save; raw coordinates never leave the device.
- **Manual-only desktop/browser fallback:** Web and Linux use a manual city label only; they never send browser or desktop coordinates to a reverse-geocoder. Both store only canonical geo keys.

The copy is intentionally user-facing, not diagnostic: it explains confidence and privacy source without exposing coordinates, provider internals, or exact geocoder output.

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
| `rollout.ts` | Runtime kill switch and Firestore public-read status publisher |
| `aggregation.ts` | Hourly `onSchedule`: collectionGroup, consent recheck, plausibility validation, per-cohort previous-rank reads, leaderboard computation, stale cleanup |
| `callables.ts` | `joinCommunity`, `updateCommunityProfile`, `revokeCommunityParticipation`, `exportLookingGlassBundle` (`jsonl` default, optional `parquet`) |
| `classifier.ts` | Canonical model-purpose classifier (shared spec) |
| `functions/src/types/generated/community.ts` + generated Swift/Kotlin models | TypeSpec-emitted community document contracts, including share snapshots |

### Handle uniqueness

Transactional `community_handles/{handleLower}` doc-ID claim — atomic, no TOCTOU race, no collectionGroup scan or index. Released on handle change and revoke.

### Rollout gates and exports

`OPENBURNBAR_COMMUNITY_KILL_SWITCH` / `community_kill_switch` hard-disable joins, profile updates, Looking Glass exports, and aggregation while preserving owner reads and cleanup paths. `OPENBURNBAR_COMMUNITY_PUBLIC_READS_ENABLED` / `community_public_reads_enabled` controls the `/ops/community_status/state/current` envelope that Firestore rules require before public leaderboard reads. Looking Glass exports default to JSONL and accept `format: "parquet"` for typed Parquet bundles with `sessionId`, `recordedAt`, and a raw `json` column.

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

City-confidence copy appears beside the consent center/hero on every surface so users understand whether a city rank is based on approximate OS location, a manual city label, or no city lookup.

Looking Glass export copy has explicit idle/ready/error states. Ready copy states the 15-minute link lifetime; error copy states that no traces left the device.

## Test Strategy

| Area | Location | Coverage |
|------|----------|----------|
| Functions | `functions/src/__tests__/community.test.ts` | Dark gate, k-threshold (including k=10 boundary), per-cohort previous-rank movement (`up`/`down`/`same`/`new`), share snapshot plausibility, stale cleanup, revoke sweep, JSONL/Parquet export bundle shape, handle validation/collision |
| Firestore rules | `firestore-rules-tests/community.test.js` | Leaderboard fail-closed public reads, rollout status gate, owner-only private docs, realistic world-only/city share_snapshot writes, malformed shape rejection, no client writes to aggregates |
| Swift | `AgentLensTests/` + `OpenBurnBarMobileTests/` | Consent store, classifier goldens, render states (opted-out/empty/threshold/live), revocation UI |
| Kotlin JVM | `android/app/src/test/` | Consent store, classifier goldens, snapshot merge, Compose screen states |
| Schema | `./tools/schema-sync/check-drift.sh` | TypeSpec canon parity, hand-mirror drift, Community golden fixture mirror drift |
| Ops scripts | `functions/scripts/community-leaderboard-canary.mjs`, `functions/scripts/community-postmerge-check.mjs` | Synthetic authenticated reads for threshold/live boards, revoked anonId exclusion, active participant counts, below-threshold grouping, stale public board cleanup reporting (`--stale-hours`, including `0` for rollback) |
| Ops script tests | `cd functions && npm run test:community-ops` | Unit tests for canary/postmerge parsers and aggregate summaries (no live Firebase) |
| Real-device validation | `node scripts/e2e/community-permission-validation.mjs` | Android/iOS/macOS/Windows denied/granted/unavailable location-permission checklist and evidence paths; Android `--execute` uses package-scoped permission reset |
| Visual states | `apps/console/test/community.visual-states.test.ts`, `apps/linux-desktop/src/community/community.visual-states.test.tsx` | Opted-out, below-threshold, live, revoked/local-paused, Looking Glass ready/error, city-confidence copy snapshots |

## Operator Runbook

### Scheduled cadence

- `aggregateCommunityLeaderboards` runs every 60 minutes in `FUNCTIONS_REGION`.
- `cleanupStaleCommunityLeaderboards` runs every 24 hours as a safety net. Normal aggregation also deletes stale public boards after a successful generation.
- Public docs are expected to be stale by up to one aggregation interval plus scheduler jitter. This is a product tradeoff that keeps cost bounded and avoids real-time social pressure.

### Public-doc rollback

1. Set `OPENBURNBAR_COMMUNITY_PUBLIC_READS_ENABLED=false` or the matching Remote Config value so Firestore rules fail closed for `community_leaderboards`.
2. Leave owner reads intact; private `users/{uid}/community/*` docs remain readable by their owner.
3. If a bad public generation shipped, run `cd functions && npm run community:postmerge-check -- --project <project> --stale-hours 0 --delete-stale` after confirming the rollback window. `--stale-hours 0` treats every public leaderboard doc as stale (full public-board cleanup); the script deletes public leaderboard docs only and does not touch consent, profiles, share snapshots, traces, or exports.
4. Re-enable public reads (`OPENBURNBAR_COMMUNITY_PUBLIC_READS_ENABLED=true` or Remote Config) only after `npm run community:canary` passes against known threshold/live docs.

### Kill switch

- `OPENBURNBAR_COMMUNITY_KILL_SWITCH=true` or `community_kill_switch=true` disables joins, profile updates, Looking Glass exports, and aggregation.
- Cleanup paths and owner reads stay available so operators can unwind public docs without trapping users.
- After clearing the kill switch, run one manual aggregation or wait for the next hourly sweep, then run the canary.

### Threshold and debug queries

```bash
# Synthetic public-read canary; requires Firebase Web API key and ADC/Admin auth.
cd functions
FIREBASE_PROJECT=<project> FIREBASE_WEB_API_KEY=<web-api-key> \
  npm run community:canary -- \
  --threshold-doc <window>_<tier>_<geoKey> \
  --live-doc <window>_<tier>_<geoKey> \
  --revoked-anon-id <anon-id-known-revoked>

# Post-merge aggregate report; dry-run by default.
cd functions
npm run community:postmerge-check -- --project <project>

# Optional stale public-board cleanup after review.
cd functions
npm run community:postmerge-check -- --project <project> --delete-stale
```

The post-merge report prints active Community participants, share snapshots, revoked tombstones, below-threshold public boards grouped by `window/tier`, total public boards, stale public boards eligible for cleanup, and stale public boards actually cleaned.

### Real-device UI validation

```bash
# Print the full Android/iOS/macOS/Windows matrix without mutating devices.
node scripts/e2e/community-permission-validation.mjs --platform all --mode all

# Execute safe automated Android/macOS setup steps where available.
node scripts/e2e/community-permission-validation.mjs --platform android --mode denied --execute
```

Capture the screenshot/log paths printed by the script for denied, granted, and unavailable states. Permission prompts that cannot be controlled programmatically on physical iOS/macOS/Windows remain explicit manual checklist steps.

## Validation

Run the cheapest relevant checks per area:

```bash
# Schema drift (fast)
bash tools/schema-sync/check-drift.sh

# Functions tests
cd functions && npm run test:community

# Ops script unit tests (canary + postmerge parsers)
cd functions && npm run test:community-ops

# Firestore rules tests
cd firestore-rules-tests && npm run test:community

# Android JVM tests
cd android && ./gradlew :app:testDebugUnitTest --tests "com.openburnbar.data.community.*"

# macOS app Community classifier focus
OPENBURNBAR_ENABLE_COVERAGE=NO OPENBURNBAR_APP_TEST_FILTERS="OpenBurnBarTests/ModelPurposeClassifierTests" ./scripts/test-openburnbar-app.sh

# Real-device permission matrix (dry-run)
node scripts/e2e/community-permission-validation.mjs --platform all --mode all
```
