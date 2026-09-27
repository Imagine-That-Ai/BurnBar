# SOTA 10/10 Sign-off — master revision Waves 0–5

Wave 4 stale-docs closer: the assurance pointer allowlisted in
`scripts/security/internal-content-policy.mjs` (`assurance-docs`).
Records the verified end state of
[`plans/2026-09-24-revision-waves-0-5.md`](../../plans/2026-09-24-revision-waves-0-5.md).
Design-level assurance only — no open findings against the Wave 0–5 bars;
two out-of-scope main-reds are disclosed under Build proof.

Verified at:

- Commit: `32b5d9bafad79cf8ac416605e8137d6ee7e89425` (origin/main, PR #2683 merge)
- Date: `2026-09-26`
- Supersedes: `2c5dacdfb32841dec3a5130551644ec17b534cc0` (2026-09-25,
  PR-branch commit, not on main — re-verified at the merge)

## Wave 3 — decomposition (all 8 done)

| # | Bar | Evidence |
|---|---|---|
| 3.1 | Core/Lab split; PR door runs Core only | `scripts/debt/check-lab-boundary.sh` green |
| 3.2 | Kernel under 50%, ceiling lowered | `scripts/debt/check-kernel-sharedmodels-purity.sh` green |
| 3.3 | Umbrella imports under 100, trend committed | 76 files; `budgets/umbrella-imports-trend.jsonl` |
| 3.4 | 21 non-view twins to Core; gl-engine deduped; jscpd covers lib | 20/21 moved (`AmplitudeTransport` documented true fork in `docs/LINT_RATIONALE.md`); parser twins 0; single `packages/gl-engine`; no blanket `**/lib/**` ignore in `.jscpd.json` (only scoped `functions/lib/**` build output) |
| 3.5 | Functions deploy codebases + `domains/` layout | 4 codebases (`admin`, `identity`, `sync`, `media`); cold-start delta measured |
| 3.6 | TypeSpec-first RPC catalog + N-1 test | `tools/ipc/generate-burnbarrpc-canon.mjs --check` rejects hand edits |
| 3.7 | Legacy path never loads Wasm | `scripts/debt/check-domain-core-freeze.sh` green: 6 baselined adapters + 4 pure `@_exported` re-export shims exempt (script tightened 2026-09-26 to exempt comment-only + single-`@_exported`-import files; negative controls: logic adapter and logic-smuggling shim both trip red) |
| 3.8 | Native proof without blocking PR iteration | CORRECTED 2026-09-26: the PR-door smoke lane was parked during #2683 batch-H (singlefile + source-built gRPC take ~40 min before tests start; job parked behind unset `MACOS_APP_SMOKE_ENABLED`, see `pr-native-fast.yml` comment). Enforcement is on `merge_group` via `app-pr-gate` (240-min budgets), green on the merge. Lane scripts stay live for local runs; re-enable when warm-disk fleet or a fitting build lands |

## Wave 4 — quality burn-down (all done)

| Bar | End state | Evidence |
|---|---|---|
| SwiftLint shrink-only per rule | `implicitly_unwrapped_optional` 326, `discouraged_optional_boolean` 227, ceilings locked | `scripts/debt/check-swiftlint-rules-budget.sh` |
| `[String: Any]` 2,325 → < 800 | **777** (app 285 / mobile 155 / core 227 / daemon 110) | `scripts/debt/check-string-any-boundary-budget.sh` |
| Force-unwraps near 0 (first-party) | **18**, all in `Generated/` FFI bindings | `budgets/force-unwrap-baseline.json` |
| 0 files over 1,500 lines; `send()` split | 33 → 0; `send` in 7 phases | `scripts/debt/check-swift-file-size-budget.sh` |
| Skips 153 → < 50, dated revival targets | **46/46** (ceiling fully consumed), `revive-by:`/`env-guard:` enforced | `scripts/debt/check-xctskip-budget.sh` |
| DESIGN palette from shipped tokens + check | 21 tokens match | `scripts/ci/check-design-tokens.sh` |
| `TECH_DEBT_METRICS.md` regenerated | Byte-identical re-run at the merge commit (numbers stable) | `scripts/ci/update-tech-debt-metrics.sh` |
| This sign-off | This file | `scripts/security/internal-content-policy.mjs` |
| Docs freshness check | Ratchet green (**68/68**, ceiling fully consumed) | `scripts/ci/check-docs-freshness.sh` |
| Fetch guard as ESLint rule | `no-restricted-globals` + `no-restricted-properties` catch `globalThis.fetch` | `functions/eslint.config.mjs`, enforced by `fast-feedback.yml` |

Build proof (merge-commit CI verdicts, `32b5d9ba`): `Fast Feedback
Gate` success, `App build + test (AgentLens)` success, Android compile +
detekt + unit tests success, `Android ktlint` success, CodeQL
(java-kotlin / javascript-typescript / python) success, AGPL posture
success, `BurnBar CI Gate` success (observe mode — Wave 1 flip to
enforce still pending). Disclosed reds, out of Wave 0–5 scope:
`candidate-bundle` (`bundle.benchmarks[0]` exceeds 500bp; green on the
parent — open benchmark-forensics item, not a revision bar) with
consequential `Domain Core PR Gate` failure, plus one Dependabot updater
infra failure unrelated to tree state.

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
- `docs/ops/UNIT_ECONOMICS_COST_MODEL.md` still carries 24 TODO cells;
  needs a real week of billing data (filled-model pointer:
  `UNIT_ECONOMICS_COST_MODEL.md`).
- `Vendor/libsignal` carries a 2-line Swift 6 compat shim
  (`extendLifetime` → `withExtendedLifetime` in
  `AuthMessagesService.swift`); upstream or re-apply on submodule bump.
- Domain-core `candidate-bundle` benchmark red on main (>500bp vs
  parent-green): needs benchmark forensics (noise vs real regression);
  tracked outside this sign-off's bar scope.

## Attestation scope

Each signature below attests, for commit `32b5d9ba` only, that: (a) every
Wave 3/4 bar above was verified against its cited evidence; (b) the two
build-proof reds are acknowledged and tracked outside this sign-off;
(c) the residual list is complete to the signatory's knowledge. It does
NOT attest to: external penetration-test coverage, runtime security of
deployed environments, absence of undiscovered vulnerabilities, or any
later commit. Re-verification is required if any bar's evidence goes red.

## Signatures

| Role | Name | Date (UTC) | Statement |
|---|---|---|---|
| Engineering owner | Alberto Nunez (@Ajnunezg) | 2026-09-26 | Verified the bars and evidence above at the pinned commit. |
| Security reviewer (non-author human) | _pending_ | _pending_ | Reviewed the bars, evidence, disclosed reds, and residual list; concur. |
