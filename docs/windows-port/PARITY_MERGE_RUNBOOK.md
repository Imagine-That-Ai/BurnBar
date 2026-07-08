# Parity Burndown — Merge Runbook (WS-A2/A4)

**Status:** The 14 parity-burndown PRs (#1250–#1263) are all `BLOCKED` by the repo's required status checks. This runbook documents the admin-merge path so the factory can land them without waiting for the pre-existing `main` reds to be independently fixed (WS-A4).

## The blocker

The repo's branch protection requires 23 status checks. On any PR touching `windows/` or the Engine, the following pre-existing `main` reds block merge (they fail on clean `main`, unrelated to the port):

| Check | Why it fails on `main` | Fix owner |
|-------|------------------------|-----------|
| `Daemon Swift tests (proxy + router + quota)` | Pre-existing test failure on `main` | Alberto (repo-maintenance) |
| `Debt budgets (shrink-only ratchets)` | Debt baseline drift on `main` | Alberto (run `scripts/ci/update-tech-debt-metrics.sh`, commit) |
| `Release build (debug-only escape hatches compiled out)` | Pre-existing release-config failure | Alberto |
| `Unused Dependencies (functions)` | Pre-existing dep drift | Alberto |
| `Version consistency` | Pre-existing version drift | Alberto |
| `Windows dist verify (test + sign/verify + xmllint)` | Pre-existing dist-test failure | Alberto |
| `clippy security lints (burnbar-remote)` | Pre-existing clippy toolchain failure | Alberto |
| `Fast Feedback Gate` | Aggregate of the above | Alberto |
| `PR Windows Dist Gate` | Aggregate | Alberto |

These are NOT caused by the parity-burndown PRs (each PR's diff is scoped to its lane; the failures are on `main` itself). The plan's A4 says: "Either fix them or document the admin-merge path so CI-required doesn't deadlock the port."

## The admin-merge path

The factory's merge loop (AGENTS.md §"Software factory PR loop") handles this: the admin-merge (`gh pr merge --squash --admin --delete-branch`) bypasses the required-status-check gate for PRs that are otherwise reviewable. The orchestrator (Alberto) runs:

```bash
gh pr merge <PR-NUMBER> --squash --admin --delete-branch
```

for each parity-burndown PR after confirming:
1. The PR's own CI (the checks that ARE green: `Windows skeleton`, `Functions (lint + types + unit tests)`, `Analyalyze (javascript-typescript)`, `guard`, `Secret Detection`, etc.) is green.
2. The PR's diff is scoped to its lane (no drive-by changes).
3. The PR body includes the validation run + known risks.

The pre-existing `main` reds (the table above) are Alberto's repo-maintenance call (WS-A4) and are NOT a blocker for the admin-merge of the parity-burndown PRs. They become a blocker only when WS-A2 flips the Windows lanes to REQUIRED (after the pre-existing reds are fixed OR the admin-merge path is the documented escape).

## Merge order (dependency-aware)

The parity-burndown PRs are file-disjoint and can merge in any order, but the dependency-aware order minimizes transient reds:

1. **#1250** (CLEAN parsers) + **#1251** (SEAM parsers + C4) — the parser lift; no dependencies.
2. **#1252** (B0 ADR) — the architecture decision; no code dependencies.
3. **#1253** (A3 CI) — the full-suite Windows CI; no code dependencies.
4. **#1255** (C3 wrap vectors) — the wrap-vector corpus; no dependencies.
5. **#1258** (C5 deferral) — the E2EE deferral doc; no dependencies.
6. **#1260** (C2 quota lift) — the quota adapter lift; depends on #1250/#1251 (the Core target).
7. **#1256** (B0 spike) — the end-to-end spike; no production dependencies.
8. **#1259** (B1 ConPTY) — the CLI stream; depends on the Pal.Ipc multi-target (self-contained in the PR).
9. **#1263** (B2 persistence) — the SQLCipher stores; depends on the storage multi-target (self-contained).
10. **#1257** (B5 nav pages) — the stub nav replacement; no dependencies.
11. **#1262** (B6 mission dispatch) — the Firestore mission host; depends on CloudSync (self-contained).
12. **#1255** (E2 MSIX) — the release workflow MSIX step; no code dependencies.
13. **#1261** (E3 parity cert) — the G5 evidence bundle; references all the above (merge last).
14. **#1249** (A1 test fixes) — the 5 Windows test fixes; Alberto's merge (independent of the port).

## After merge: WS-A2 (Alberto's one repo setting)

Once the parity-burndown PRs are merged + the pre-existing `main` reds are green (WS-A4), Alberto flips the Windows CI lanes (`openburnbar-engine-windows.yml` + `pr-windows-full.yml`) to **required** status checks. From that point, a Windows regression cannot merge without the gate going green — the parallel streams can't regress each other silently.

## Open dependencies (Alberto-owned, calendar-bound)

- **E1 — W0 cert procurement:** the Authenticode/Azure-Trusted-Signing cert + Microsoft Store publisher + winget publisher. Gates E2's real signed build + E3's launch.
- **Win11-Pro box/VM:** WS-D validation (GPU/render/computer-use/TPM). The Home SKU lacks the Platform Crypto Provider for R14 TPM.
- **C5 deferral sign-off:** the G2 cloud criterion deferral (PR #1258) needs Alberto's sign-off (the plan's explicit option).
- **Cloud creds:** B4's live round-trip + C5's live round-trip need the `burnbar` Firebase project secrets in CI/dev-host.