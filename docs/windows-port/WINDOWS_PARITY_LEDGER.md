# Windows ↔ macOS Parity Ledger

**Machine source of truth:** [`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml)  
**Scanner:** [`scripts/ci/verify-windows-parity-ledger.py`](../../scripts/ci/verify-windows-parity-ledger.py)  
**Updated:** 2026-07-09 (Phase 0 / Wave 1)

## Why this exists

Older handoffs and the certification bundle mixed **Authored** (page exists / route resolves) with **parity**. That produced false-green claims.

This ledger is the anti-false-green gate:

| Status | Meaning |
|--------|---------|
| **Real** | Production mode on Windows with real data/backend behavior (or a fully proven approved substitute). Requires ≥1 test path + ≥1 evidence file; blocking paths must pass the forbidden-token scan. |
| **Substituted** | Honest Tier-B/C substitute or production-empty-state surface that is not yet full peer parity. |
| **DeferredApproved** | Named WPD / signed deferral with revive trigger. |
| **Blocked** | Named external blocker (VM, cert, OAuth client, required CI flip, missing route). |

**Forbidden as a parity status:** `Authored` (and synonyms like “route resolves”, “sample mode OK”, “dev-host deferred”).

## How to change a row to Real

1. Wire production composition (no default sample/stub/demo/mock path).
2. Add or point to an automated test that exercises the production path.
3. Commit an evidence artifact under `docs/windows-port/evidence/` (not a `PLACEHOLDER` screenshot path).
4. List only production files (and the evidence file) in `blocking_paths`.
5. Run:

```bash
bash scripts/ci/verify-windows-parity-ledger.sh
bash scripts/ci/verify-windows-parity-ledger.test.sh
```

If the token scan fails, the row is not Real — fix the code or keep the status honest.

## Forbidden tokens (Real-row production scan)

Precision-matched in `blocking_paths` for every **Real** row:

| Token / pattern | Intent |
|-----------------|--------|
| `SampleModeEnabled` | Demo mode switch in production path |
| `*SampleData*` | Fabricated datasets as production backing |
| `DemoHost` | Demo/mission hosts |
| `MockAttestationProducer` | Mock App Check in production |
| `dev-host` | Dev-host-only posture |
| `Stub*` / `SurfaceStub*` | Stub streams/pages as the product path |
| `SettingsPlaceholderPage` / `PLACEHOLDER` | Placeholder UI or screenshot cells |
| compound `*-deferred` | Explicitly deferred production work left in “Real” paths |

See the scanner source for the exact regexes (domain enums like `ProviderQuotaSourceKind.Unavailable` are **not** auto-failed).

## macOS primary routes (must all map)

From `DashboardMainRoute.primarySections`:

`chat`, `quota`, `database`, `projects`, `missions`, `sessionLogs`, `memoryReview`

Plus required peers: `overview`, `insights`, `settings`, `flyout`, `budget`, `elderWand`.

**Current gaps (Blocked):** `database` and `projects` have **no** Windows `NavCatalog` key.

## Status counts (regenerate via scanner)

The scanner prints a status histogram on every run. Do not hand-edit a stale count here — trust the YAML + CI.

## Relationship to other docs

| Doc | Role |
|-----|------|
| `PARITY_CERTIFICATION_BUNDLE.md` | G5 evidence narrative; must not use fake screenshot paths for Real claims |
| `PARITY_100_REMEDIATION_PLAN.md` | Historical assessment; ledger wins on conflict |
| `HANDOFF.md` | Operational notes; may be stale — verify against ledger + code |
| `decisions/0003`, `0005`, `0006` | DeferredApproved / architecture anchors |

## CI

- Fast Feedback job: **Windows parity ledger (Phase 0)** runs the self-test + scanner on every PR that can load the sparse tree.
- Windows path filters also include this ledger so Windows gates re-run when honesty rules change.
