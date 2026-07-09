# Windows ↔ macOS Parity Ledger

**Machine source of truth:** [`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml)  
**Scanner:** [`scripts/ci/verify-windows-parity-ledger.py`](../../scripts/ci/verify-windows-parity-ledger.py)  
**Updated:** 2026-07-09 (Phase 0 + H0 honesty / IA-1 scaffolding)  
**Finish line:** **F1 Ship Peer** default (`finish_line: F1_Ship_Peer` in YAML). F2 is post-F1 unless product overrides.

## Why this exists

Older handoffs and the certification bundle mixed **Authored** (page exists / route resolves) with **parity**. That produced false-green claims.

This ledger is the anti-false-green gate:

| Status | Meaning |
|--------|---------|
| **Real** | Production mode on Windows with real data/backend behavior (or a fully proven approved substitute). Requires ≥1 test-shaped path + ≥1 evidence file + ≥1 production-prefix `blocking_paths` entry that passes the forbidden-token scan. |
| **Substituted** | Honest Tier-B/C substitute or production-empty-state surface that is not yet full peer parity. |
| **DeferredApproved** | Named WPD / signed deferral. Requires non-empty `revive_trigger` + existing evidence path. |
| **Blocked** | Named external blocker (VM, cert, OAuth client, required CI flip, missing route). |

**Forbidden as a parity status:** `Authored` (and synonyms like “route resolves”, “sample mode OK”, “dev-host deferred”).

## How to change a row to Real

1. Wire production composition (no default sample/stub/demo/mock path).
2. Add or point to an automated **test-shaped** path (`*Tests*`, `windows/tests/`, `Fixtures`, `*Parity*`, golden fixtures).
3. Commit an evidence artifact under `docs/windows-port/evidence/` with markers `Ledger row:` and `What this proves` (≥200 chars). No `PLACEHOLDER`.
4. List only **non-test production** files in `blocking_paths` (prefix `windows/`, `OpenBurnBarCore/`, `packages/`, or `crates/`). Test trees (`windows/tests/`, `*.Tests`, `*Tests.cs`) do **not** earn Real production credit. Do **not** put evidence markdown there.
5. Run:

```bash
python3 -m pip install --user 'pyyaml>=6,<7'   # once / as CI does
bash scripts/ci/verify-windows-parity-ledger.sh
bash scripts/ci/verify-windows-parity-ledger.test.sh
```

If the token scan fails, the row is not Real — fix the code or keep the status honest.

## Forbidden tokens (Real-row production scan)

Exact patterns live in `FORBIDDEN_TOKEN_PATTERNS` in the scanner. Summary:

| Token name | Pattern intent |
|------------|----------------|
| `SampleModeEnabled` | Demo mode switch identifier |
| `SampleData` | `*SampleData*` fabricated datasets |
| `DemoHost` | `*DemoHost*` demo hosts |
| `MockAttestationProducer` | Mock App Check producer |
| `dev-host` | Dev-host-only posture (case-insensitive) |
| `Stub` | `\bStub\b`, `\bStub[A-Z]\w*\b`, `\bIStub\w*\b`, `\bSurfaceStub\w*\b` (e.g. bare `Stub`, `StubCliStream`, `IStubTokenSource`, `StubFirebaseIdTokenSource`) |
| `Placeholder` | `SettingsPlaceholderPage`, `PlaceholderCard`, `PLACEHOLDER` |
| `deferred` | Compound only: `host-deferred`, `CI-deferred`, `adapter-deferred`, `dev-host/CI-deferred`, … — **not** prose “none are deferred” |
| `Unavailable` | Production substitutes: `UnavailableChatStreamDriver`, `UnavailableHost`, `UnavailableSource`, `UnavailableDriver`, `UnavailableService`, `UnavailableClient` — **not** domain enums like `ProviderQuotaSourceKind.Unavailable` |

Docs under `docs/` listed in `blocking_paths` are **not** token-scanned (avoids honest non-claims failing), but they also **cannot** satisfy the production-prefix rule for Real.

## macOS primary routes (must all map)

From `DashboardMainRoute.primarySections`:

`chat`, `quota`, `database`, `projects`, `missions`, `sessionLogs`, `memoryReview`

Plus required peers: `overview`, `insights`, `settings`, `flyout`, `budget`, `elderWand`.

**Current gaps (Blocked):** `database` and `projects` have **no** Windows `NavCatalog` key.

## Status counts

The scanner prints a status histogram on every run. Do not hand-edit a stale count here — trust the YAML + CI.

## Relationship to other docs

| Doc | Role |
|-----|------|
| `PARITY_CERTIFICATION_BUNDLE.md` | G5 evidence narrative; Status cells must mirror ledger vocabulary |
| `PARITY_100_REMEDIATION_PLAN.md` | Historical assessment; ledger wins on conflict |
| `HANDOFF.md` | Operational notes; may be stale — verify against ledger + code |
| `decisions/0003`, `0005`, `0006` | DeferredApproved / architecture anchors |

## CI

- Fast Feedback job **Windows parity ledger (Phase 0)** — full checkout, installs PyYAML, runs self-test + scanner on every PR.
- PR Windows fast gate runs the same job when Windows paths (including `docs/windows-port/`) change.
