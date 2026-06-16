# GOAL — Finish all remaining Project Code Memory remediation items

## Objective
Close every remaining audit finding for Project Code Memory to a "done, with passing tests"
bar on branch `feature/pcm-remediation`, verified against the worktree's Swift/Rust/Python
build+test loops.

## Finishing criteria
- All 8 remaining items implemented + verified: MED-4, MED-5, MED-6, MED-7, §2.1, HIGH-1, HIGH-2, HIGH-3.
- Each lands as its own commit with a test that fails without the fix.
- Final state: `cargo test`, `pytest`, `swift build`, `swift test` (PCM) all green together.
- `implementation-notes.html` current; `.agent/GOALS.md` updated.

## Parent goal
PCM audit remediation (LOW-9, LOW-10, MED-8 already closed in commits 2b3b9e0665, 26cf8f26cf).

## Runtime goal coupling
No native goal tool in this runtime — file ledger only. Maintain the agent-owned ledger at
`.agent/runs/pcm-remediation-finish-2026-06-16/` and keep implementation-notes.html current at
checkpoints, before compaction, and before final handoff.

## Escape Hatch
Pause / ask / mark `[blocked]` or `[incomplete]` if:
- a fix needs cloud/Firebase infra the daemon cannot reach locally (HIGH-1 cloud delete; HIGH-3 upload),
- verification (build/test) contradicts the intended change,
- the change would require rewriting durable user data or another agent's in-flight work,
- looping without measurable progress.

## Working environment
Isolated worktree: `/Users/albertonunez/Documents/Developer/BurnBar-pcm-remediation`
(Vendor/* symlinked from the main tree for the daemon build — local-only, not for merge).
