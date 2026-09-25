# SOTA 10/10 Sign-off — master revision Waves 0–5

Wave 4 stale-docs closer: the assurance pointer allowlisted in
`scripts/security/internal-content-policy.mjs` (`assurance-docs`).
Records the verified end state of
[`plans/2026-09-24-revision-waves-0-5.md`](../../plans/2026-09-24-revision-waves-0-5.md).
Design-level assurance only — no open findings disclosed.

Verified at:

- Commit: `2c5dacdfb32841dec3a5130551644ec17b534cc0`
- Date: `2026-09-25`

## Wave 3 — decomposition (all 8 done)

| # | Bar | Evidence |
|---|---|---|
| 3.1 | Core/Lab split; PR door runs Core only | `scripts/debt/check-lab-boundary.sh` green |
| 3.2 | Kernel under 50%, ceiling lowered | `scripts/debt/check-kernel-sharedmodels-purity.sh` green |
| 3.3 | Umbrella imports under 100, trend committed | 76 files; `budgets/umbrella-imports-trend.jsonl` |
| 3.4 | 21 non-view twins to Core; gl-engine deduped; jscpd covers lib | 20/21 moved (`AmplitudeTransport` documented true fork); parser twins 0; single `packages/gl-engine`; no `**/lib/**` in `.jscpd.json` |
| 3.5 | Functions deploy codebases + `domains/` layout | Independent codebases; cold-start delta measured |
| 3.6 | TypeSpec-first RPC catalog + N-1 test | `tools/ipc/generate-burnbarrpc-canon.mjs --check` rejects hand edits |
| 3.7 | Legacy path never loads Wasm | `scripts/debt/check-domain-core-freeze.sh` green |
| 3.8 | Smoke + impacted tests on every PR < 20 min | `pr-native-fast.yml` (`timeout-minutes: 20`) via `scripts/ci/select-pr-app-tests.sh` |

## Wave 4 — quality burn-down (all done)

| Bar | End state | Evidence |
|---|---|---|
| SwiftLint shrink-only per rule | `implicitly_unwrapped_optional` 326, `discouraged_optional_boolean` 227, ceilings locked | `scripts/debt/check-swiftlint-rules-budget.sh` |
| `[String: Any]` 2,325 → < 800 | **777** (app 285 / mobile 155 / core 227 / daemon 110) | `scripts/debt/check-string-any-boundary-budget.sh` |
| Force-unwraps near 0 (first-party) | **18**, all in `Generated/` FFI bindings | `budgets/force-unwrap-baseline.json` |
| 0 files over 1,500 lines; `send()` split | 33 → 0; `send` in 7 phases | `scripts/debt/check-swift-file-size-budget.sh` |
| Skips 153 → < 50, dated revival targets | **46**, `revive-by:`/`env-guard:` enforced | `scripts/debt/check-xctskip-budget.sh` |
| DESIGN palette from shipped tokens + check | 21 tokens match | `scripts/ci/check-design-tokens.sh` |
| `TECH_DEBT_METRICS.md` regenerated | Fresh snapshot, current timestamp | `scripts/ci/update-tech-debt-metrics.sh` |
| This sign-off | This file | `scripts/security/internal-content-policy.mjs` |
| Docs freshness check | Ratchet green (68 ceiling) | `scripts/ci/check-docs-freshness.sh` |
| Fetch guard as ESLint rule | `no-restricted-globals` + `no-restricted-properties` catch `globalThis.fetch` | `functions/eslint.config.mjs`, enforced by `fast-feedback.yml` |

Build proof: Core + daemon `swift build`/`swift test`, app + mobile
`xcodebuild` BUILD SUCCEEDED, functions `tsc` + ESLint clean.

## Standing invariants (preserved)

Core vs Lab, single-writer, `costUSD` canon, freeze-not-delete, opt-in
sync — proved with real binaries and green shrink-only ratchets
(`budgets/` + `scripts/debt/` + `scripts/ci/`).

## Residual owner items (Wave 5, Alberto-owned)

- Second human with merge authority (AR-008).
- External security review (daemon IPC, vault crypto, rules vs App Check
  gap, hosted MCP token flow).
- Licensing: counsel sign-off on AGPL + App Store/commercial position.
- Repo size: AAR to LFS/CI artifacts, remote-branch prune, tag
  consolidation — rewrites history, needs explicit go-ahead.
- `docs/ops/UNIT_ECONOMICS_COST_MODEL.md` TODO cells need a real week of
  billing data; the filled model is at `UNIT_ECONOMICS_COST_MODEL.md`.
- `Vendor/libsignal` carries a 2-line Swift 6 compat shim
  (`extendLifetime` → `withExtendedLifetime` in
  `AuthMessagesService.swift`); upstream or re-apply on submodule bump.
