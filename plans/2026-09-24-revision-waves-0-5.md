# BurnBar master revision plan (62 → 10/10) — Waves 0–5

Recovered 2026-09-24 from the working session log into this file so the
wave definitions survive context compaction. Waves 0–1 and 2.1–2.7 are
done; what follows is the authoritative scope for the remaining work.

## Wave 2: One data spine (weeks 2–6) — remaining

| # | Work | Done when |
|---|---|---|
| 2.8 | Dashboard: materialized per-window rollups using the `WorkflowInsightRollupService` pattern. Point the perf budget at the live function, not dead `fetchAllUsage()` | Constant query count at 5 GB (fixture DB). Reload p95 recorded |

Done: 2.1/2.1c single-writer cutovers, 2.2 single migrator, 2.3 generated
schema docs, 2.4 daemon SQLCipher fail-closed, 2.5 cost unification,
2.6 growth caps, 2.7 Codex rollout jail + MAS xcconfig.

## Wave 3: Architecture decomposition (weeks 4–10)

| # | Work | Done when |
|---|---|---|
| 3.1 | Execute the Core/Lab split (decision 1): build flags, a separate CI lane set, and a Lab directory boundary | The PR door only runs Core. Lab builds nightly |
| 3.2 | Split `OpenBurnBarKernel` (194 files, 53.6k/54k lines) by domain out of `SharedModels/`, then lower the ceiling | Kernel under 50% of its current size, with the ceiling lowered to match |
| 3.3 | Burn down umbrella imports (911 files) with a codemod to explicit module imports, and a ratchet that only shrinks | Under 100 files, with a trend line committed |
| 3.4 | Move the 21 non-view Mac/iOS twin services into Core. Delete the 59 duplicated gl-engine files and remove `**/lib/**` from the `.jscpd.json` ignore | Twin non-view count 0. jscpd covers lib |
| 3.5 | Functions: 3–5 deploy codebases (identity/billing, sync/quota, media/relay, admin/scheduled), plus a structured `domains/` layout for the 93 callables | Independent deploys, with a cold-start delta measured |
| 3.6 | Generate the RPC method catalog from TypeSpec (188-case enum becomes generated), with an N-1 compatibility test | Adding a method is a TypeSpec edit, and CI rejects hand edits |
| 3.7 | Carry out the domain-core decision (decision 4) | Production no longer loads Wasm on the legacy path, or pricing runs through Rust in one profile with the legacy twin deleted |
| 3.8 | Cut Mac app CI from 53–69 minutes to under 20 on the PR door: impact-based test selection (`ci-impact.yml` exists), prebuilt vendor xcframeworks, cached SwiftPM, and a split test plan. This is the root cause of CHEAP_FAST, the observe breaker and post-merge-only app tests | App smoke plus impacted tests run on every PR in under 20 minutes |

## Wave 4: Quality burn-down (continuous, measured monthly)

- Reverse the lint debt trend. Implicitly-unwrapped optionals are up 92% and `discouraged_optional_boolean` is up 130%. Make SwiftLint shrink-only per rule.
- Types and unwraps. Cut `[String: Any]` from 2,325 to under 800 at boundaries (decode into typed structs). Take force-unwraps to near 0 in first-party code.
- Large files. Get to 0 files over 1,500 lines by splitting the 35 that exceed it. The 642-line `send` gets broken up.
- Skipped tests. Bring the 153 XCTSkips below 50, each with a dated revival target.
- Stale docs.
  - Rewrite the palette section of `DESIGN.md` from the shipped tokens, and add a check against the token source.
  - Regenerate `TECH_DEBT_METRICS.md`.
  - Add the missing `docs/security/SOTA_10_10_SIGNOFF.md` reference or remove the pointer.
  - Prune stale docs (2,015 files under `docs/`) with a freshness check.
- Fetch guard. Replace the regex that bans raw `fetch` with an ESLint `no-restricted-globals` rule on the PR door, which catches `globalThis.fetch`.

## Wave 5: Diligence and organization (Alberto-owned, in parallel)

- Second human with merge authority (closes AR-008).
- External security review (daemon IPC, vault crypto, rules vs App Check gap, hosted MCP token flow).
- Unit economics: fill in `UNIT_ECONOMICS_COST_MODEL.md` (~10× counter fan-out, 36-index `session_logs` write amplification, or trim those indexes).
- Licensing: counsel sign-off on AGPL + App Store/commercial position.
- Repo size: 79.4 MB AAR to LFS/CI artifacts, prune 8,061 remote branches, consolidate tags. **Rewrites history — needs Alberto's explicit go-ahead.**
- Onboarding doc: subsystem → modules → canonical tests → runbooks map.

## Standing constraints (from the plan)

- Preserve Core vs Lab, single-writer, costUSD canon, freeze-not-delete, opt-in sync.
- Prove with real binaries and green ratchets.
- CHEAP_FAST: ~8 themed PRs; Mac app build nightly, not a merge ticket.
