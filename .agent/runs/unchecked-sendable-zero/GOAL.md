# Eliminate all @unchecked Sendable → budget 0

Goal ID: `unchecked-sendable-zero`
Started: 2026-06-14T06:27:44Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/unchecked-sendable-zero/`

## Objective

Drive the `@unchecked Sendable` budget to **0** across OpenBurnBarCore, OpenBurnBarDaemon, AgentLens, and OpenBurnBarMobile by making types genuinely `Sendable` (no new escape hatches), then delete `budgets/unchecked-sendable-baseline.json` and flip the gate to assert-zero in CI. Flip each SwiftPM target to Swift 6 language mode as it reaches zero.

## Current measurement (real annotations, comment lines excluded)

| Root | Start | Now | Target |
|---|---|---|---|
| OpenBurnBarCore/Sources | 23 | 7 | 0 |
| OpenBurnBarDaemon/Sources | 11 | 8 | 0 |
| AgentLens | 101 | 101 | 0 |
| OpenBurnBarMobile | 26 | 26 | 0 |
| **Budget total** | **174** | **142** | **0** |

(Start 174 included 13 phantom counts from a counter bug — now fixed; real start was 161.)

## Finishing Criteria

- [done] Budget (ratchet) → 0 across all four roots. PR #371 (174→57, merged) + PR #382 (57→0).
- [done] Every reducible exception got a real fix; the 24 genuinely-irreducible ones are on a documented, gate-validated allowlist (NOT the ratchet). FileManager → SendableFileSystem seam; libsignal → actor + concurrency test.
  - FFI handles (UniFFI iroh) → keep behind a Sendable boundary type or actor wrapper that the budget can treat as resolved; if truly irreducible, move to a rationale-documented permanent allowlist (NOT the ratchet budget).
  - `FileManager`-blocked types → drop `@unchecked` once Foundation marks `FileManager: Sendable`, or stop storing the injectable `FileManager`.
  - libsignal `OBBSignalSessionCipherTransport` → actor-isolate with ratchet concurrency tests.
  - single-threaded vector-index builders → box state or restructure so Sendable is compiler-proven.
- [done] Baseline deleted; check-unchecked-sendable-budget.sh is a fail-closed assert-zero gate (+ reason-id validation; negatives proven).
- [todo] (FOLLOW-UP) Per-target `swiftLanguageMode(.v6)` flip — now unblocked (ratchet 0); land as its own PR.
- [done] docs/security/UNCHECKED_SENDABLE_REMEDIATION.md rewritten (completed-state + 24-entry allowlist registry); TECH_DEBT_METRICS row shows ratchet 0 / 24 allowlist.
- [done] Each tranche build-verified locally; PR #382 awaiting green CI. Core 1578 tests / Daemon 613 tests / macOS+iOS builds / swiftlint --strict all green locally.

## Tranche plan

1. **[done] Core + Daemon** — PR #371 (23→7, 11→8). Builds + tests green.
2. **[todo] AgentLens + Mobile plain-Sendable (57)** — pure `@unchecked` removals (compiler-proven). No dependency on #371. Needs app/mobile xcodebuild to verify.
3. **[todo] AgentLens + Mobile lock-box (32)** — `Locked`/`OSAllocatedUnfairLock` boxes. Depends on #371's plain-Sendable `Locked` (stack on #371 or land after it merges).
4. **[todo] @MainActor isolate (15)** — UI/observable types; watch caller ripple.
5. **[todo] typed-Sendable payloads (9)** + **actor (2)**.
6. **[todo] Resolve the ~19 audited exceptions** (Core 7 + Daemon 8 + AgentLens/Mobile 4) per the criteria above.
7. **[todo] Permanence** — delete baseline, assert-zero gate, Swift 6 mode flips.

Backlog detail (per-site, security-sequenced): `docs/security/UNCHECKED_SENDABLE_REMEDIATION.md`.

## Sequencing constraints

- Plain-Sendable tranche (step 2) is independent of #371 — safe to land from origin/main.
- Lock-box tranche (step 3) needs #371's `Locked` — stack or wait for merge.
- App/mobile edits need full xcodebuild verification (the SwiftPM `swift build`/`swift test` loop does NOT cover AgentLens/Mobile targets). Use the worktree build recipe (seed plists + xcframeworks, xcodegen, sim UDID).
- Don't mass-edit during active concurrent merges; tranche directory-by-directory.

## Goal Mode Coupling

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/unchecked-sendable-zero/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

Runtime native-goal coupling: **unavailable** — this Claude Code runtime exposes no native `/goal` tool (only session-scoped Task todos). File ledger is the source of truth.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- a type's only path to real `Sendable` is an unsafe semantic change (e.g. actor-isolating E2EE ratchet code) that needs its own reviewed PR + concurrency tests
- an audited exception is genuinely irreducible (FFI/raw-pointer) and belongs on a rationale allowlist, not forced to a wrong "fix"
- the app/mobile xcodebuild lane is not reproducible in the worktree (can't verify → don't ship)
- validation contradicts the goal, the repo disagrees with the classification, or the agent loops without measurable progress
- the next step risks deleting or rewriting durable memory
