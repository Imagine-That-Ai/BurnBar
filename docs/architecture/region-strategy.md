# Region strategy — single-region `us-central1` for GA

**Status:** Accepted (GA)
**Date:** 2026-06-02
**Owner:** Backend (Cloud Functions / Firestore / GCS)
**Implements:** SOTA remediation plan B-BE-2

## Context

Every OpenBurnBar Cloud Function deploys to a single Google Cloud region,
`us-central1`, alongside the project's Firestore database and Cloud Storage
buckets. Until B-BE-2, that region was a raw `"us-central1"` string literal
duplicated ~102 times across `functions/src` (inline `region:` option fields on
`onCall`/`onRequest`/`onDocument*`/`onSchedule`, plus a few module-level
`const REGION = "us-central1"`). A region change meant a fragile find-and-replace,
and a typo in one literal would silently strand a function in the wrong region.

Firestore's location is **fixed at database creation** and cannot be changed in
place. The colocated Functions region must match the data's region to keep read
and write latency low and avoid cross-region egress. So the region is not an
independent per-function knob — it is one project-wide decision.

## Decision

1. **One source of truth.** `functions/src/runtimeOptions.ts` exports
   `FUNCTIONS_REGION` (default `"us-central1"`, overridable via the
   `FUNCTIONS_REGION` environment variable). Every function option object
   references this constant; no raw region literal remains in `functions/src`
   (except the export itself and an illustrative URL in a `health.ts` docstring).

2. **Inherited default.** `adminRuntime.ts` calls
   `setGlobalOptions({ region: FUNCTIONS_REGION })` from `firebase-functions/v2`
   early on cold start (imported first via `index.ts`), so any function that
   omits an explicit region still inherits the single region. Per-function
   options continue to pass `FUNCTIONS_REGION` explicitly, which keeps the
   region visible at each definition site and robust to import ordering.

3. **Single-region is the right call for GA.** Per SOTA plan §7, multi-region is
   an XL dual-write migration (Firestore single-region cannot be migrated in
   place) — net-new operational, IAM, and backup surface with no product value at
   current scale. The accepted outage-recovery mechanism for GA is
   **cross-region restore** (B-BE-1: PITR + scheduled exports + a drill-tested
   restore runbook), not live multi-region replication.

4. **CI guard against regressions.** `scripts/ci/check-region-literals.mjs`
   greps `functions/src/**/*.ts` (excluding `runtimeOptions.ts`) for the bare
   quoted region literal and exits non-zero if any are found. It runs locally via
   `npm run check:region-literals` in `functions/`, and is exercised by the unit
   suite (`src/__tests__/check-region-literals.test.ts`) — green on a clean tree,
   red when a literal is injected.

## Consequences

- A region flip is a one-line change to `FUNCTIONS_REGION` (or the
  `FUNCTIONS_REGION` env var) — but note that flipping it alone is **not** a real
  multi-region migration; Firestore/GCS data must move too (see flip-triggers).
- Emulator and CI can pin a region via the env var without editing source.
- New code that hardcodes `"us-central1"` fails CI, so the invariant holds.

## Flip-triggers — when single-region stops being the accepted decision

Build multi-region (or relocate the single region) only when one of these fires;
do **not** build it speculatively:

- **First regional-outage post-mortem.** A real `us-central1` outage that takes
  OpenBurnBar down and whose post-mortem concludes cross-region restore (B-BE-1)
  was too slow for the business → promote multi-region from deferred to planned.
- **Revenue / scale trigger: `> $X` MRR.** Once recurring revenue clears the
  threshold the team sets (placeholder `$X` — set at the next ops review), the
  availability premium of multi-region outweighs its XL cost and ongoing burden.

Until a trigger fires, single-region `us-central1` is the **documented, accepted**
GA decision. See `docs/SOTA_REMEDIATION_PLAN.md` §4 (Backend / infra →
Multi-region, "XL — explicitly deferred") and §7 ("Do NOT build multi-region
before the trigger").
