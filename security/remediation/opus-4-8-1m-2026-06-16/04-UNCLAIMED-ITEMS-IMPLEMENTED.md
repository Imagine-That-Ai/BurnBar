# Unclaimed Items — Implemented (the "b" batch)

**Lane:** Opus 4.8 (1M) · **Date:** 2026-06-16 · **Branch:** `remediation/opus-4-8-1m-unclaimed-items` (off current main `525817a1b2`; local, not pushed) · Patches: `IMPLEMENTED-bitems.patch` + `bitems-patches/`

After the first batch (V-10/V-34/V-35 on `remediation/opus-4-8-1m-2026-06-16`), I re-checked the live agent panes: **K2.7 had taken V-34/V-35/V-38 and finished V-18 (rate-limiting); gpt-5.5 was on V-07 + daemon local-auth; GLM held V-01/V-03/V-25.** So I fanned out the genuinely **unclaimed** findings via a multi-agent workflow (8 implement + 8 adversarial-verify agents in isolated worktrees), then consolidated + verified.

## What landed (8 commits)

| # | Finding | Severity | How | Verification |
|---|---------|----------|-----|--------------|
| V-24 | SSRF guard: canonicalize alt IP encodings (decimal/octal/hex/dword/short-form + IPv4-mapped IPv6) + DNS-pinning undici client (`ssrfAgent.ts`), redirects disabled; `allowPrivateHosts` GCP-metadata path preserved | Med (latent) | workflow agent | **tsc clean + 14 vitest ✓** |
| V-22 | Minimize stable `androidDeviceId` correlator in `fcm_outbound` | Low | workflow agent | **tsc clean + 2 vitest ✓** |
| V-27a/b + V-26 | `permissions: contents:read` on 2 workflows; explicit CODEOWNERS paths for security/crypto/billing/ci/libsignal/firestore; `::warning::` on missing `RELEASE_SIGNING_KEY` (cosign stays integrity root) | Low–Med | workflow agent | inspected (declarative/YAML) |
| V-32 | macOS `MacSentryScrubber` + per-install-ID unit tests (parity with iOS) | Low (coverage) | workflow agent | Swift — not compiled here |
| V-16 | App Check attestation max-age 30d→**7d default + configurable**, fail-safe (freshness can't be disabled); 2-min nonce preserved | Low | **opus (re-impl)** | **tsc clean + 4 vitest ✓** |
| V-23a | Account-deletion **scope manifest** (`accountDeletionRootCollections.ts`) + **CI completeness test** that scans `.collection("X").where("uid",…)` and fails on any unclassified root collection (mirrors BOLA catalog-completeness) | Low (latent) | **opus (re-impl)** | **tsc clean + 4 vitest ✓** |
| V-37 | Bound log-parser **file size (64 MiB)** + **JSON depth (64)** via shared `ParserInputLimits`, applied at every unbounded `Data(contentsOf:)` + the recursive flatten; Xcode targets wired | Low–Med | workflow agent | Swift — not compiled here |
| V-05/V-06 | Authenticate the legacy `/var/run` HID server peer before writing the password (`validateServerPeer`, audit-token, fail-closed); gate the `zsh -lic` exec-resolution fallback behind `allowLoginShellFallback` (off for the remote-triggered mission path) | Low | workflow agent | Swift — not compiled here |

**Net machine-verified:** the 4 TypeScript findings — **tsc clean + 24 vitest cases green** on the consolidation branch (run together). The 3 Swift findings + the declarative CI config were authored against real call sites and cross-checked symbol-by-symbol, but the bare worktree has no Xcode module graph so they were not compiled here (SourceKit's "cannot find type" noise is that same env gap — every project type is unresolvable).

## The workflow "failure" — what actually happened

The first Workflow run reported failed. Root cause (from the task notification): **`API Error: Server is temporarily limiting requests · Rate limited`** hit 7 of the 8 implement agents mid-run — not a script bug. Because the agents died on a terminal API error after retries, the workflow journaled only `started` events and their structured results were lost. **But the agents' actual code changes survived in their isolated worktrees** (`.claude/worktrees/wf_1373c0bf-1d7-N`), which I harvested directly:

- **Recovered from worktrees:** V-24, V-22, CI-config, V-32 (complete) + V-16 (partial — only the interface field).
- **Worktrees cleaned (work lost):** V-23a, V-37, V-05/06 → I re-implemented V-23a + V-16 myself (TS, verified) and re-ran V-37 + V-05/06 as **fresh focused worktree agents that commit in-place and return only a summary** (avoiding the result-payload size that compounded the rate-limit failure), then harvested their commits.

Lesson encoded for next time: for code-gen fan-outs, have agents **commit in their worktree and return a short summary**, not the full diff in structured output — and expect transient rate-limits, so make the harvest path (worktree diff) the source of truth, not the journal.

## Two branches (both local, not pushed)
- `remediation/opus-4-8-1m-2026-06-16` (off `60faa70227`) — V-10 (Critical), V-34, V-35.
- `remediation/opus-4-8-1m-unclaimed-items` (off current main `525817a1b2`) — the 8 items above.

Kept separate because the first branch is 65 commits behind main (the parallel agents merge continuously) and its V-34/V-35 would collide with K2.7's concurrent versions of the same findings; the b-items branch is current-main-based and cleanly mergeable.

## Still open (specced, not implemented)
V-11 path-bound AAD migration for `chat_threads`/`cli_sessions` (needs the writer-migrate-then-rules ordering + confirmation that all writers are Mac-only — deferred to avoid bricking writes). Everything else from `03-REMEDIATION-PLAN.md` is now either implemented (here or batch 1), owned by another agent, or verified false/already-fixed.
