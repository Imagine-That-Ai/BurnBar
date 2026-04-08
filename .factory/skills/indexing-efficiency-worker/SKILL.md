---
name: indexing-efficiency-worker
description: Implement hybrid event-driven indexing, incremental projection/embedding efficiency, and indexing reliability invariants.
---

# Indexing Efficiency Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for features that modify projection jobs, indexing queues, chunk/embedding update logic, rebuild/re-embed flows, and cross-surface consistency between indexing and reporting.

## Required Skills

None.

## Work Procedure

1. Read `mission.md`, `AGENTS.md`, `.factory/library/architecture.md`, and `.factory/library/user-testing.md`.
2. Enumerate assertion IDs in `fulfills`, including edge-case invariants (stale jobs, lease recovery, pagination completeness).
3. Apply TDD red/green:
   - Add failing test/fixture coverage first for each targeted invariant.
   - Implement minimal code to satisfy failing assertions.
4. Preserve incremental-first behavior:
   - Avoid broad rebuilds for small deltas.
   - Skip unchanged chunks/embeddings where hashes/versions prove no delta.
5. Validate reliability paths:
   - stale-version no-op behavior
   - retry/lease-recovery idempotency
   - remote reprojection re-enqueue semantics
6. Run scoped validators, then milestone-level checks:
   - `swift test --package-path OpenBurnBarCore`
   - scoped `xcodebuild test -only-testing` for projection/index tests
   - `scripts/test-openburnbar-retrieval-evals.sh` when retrieval/projection output changed
7. Ensure no orphaned test runners/processes.
8. Return evidence with concrete counters/logs for write amplification and skipped work.

## Example Handoff

```json
{
  "salientSummary": "Implemented event-driven dedupe and stale-version no-op handling in projection jobs, plus hash/version-based embedding skips. Added coverage for lease-recovery idempotency and remote reprojection re-enqueue after content change. Retrieval replay and scoped indexing tests pass.",
  "whatWasImplemented": "Updated queue/job processing semantics so burst updates collapse to latest effective work, stale source-version jobs no-op without writes, and retry/reclaim paths remain idempotent. Added incremental chunk/embedding guards to avoid full rewrites when hashes and model versions are unchanged, and ensured remote conversation updates can enqueue new projection work after a prior completion.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/ProjectionPipelineServiceTests\"",
        "exitCode": 0,
        "observation": "Projection job invariants and stale/no-op tests passed."
      },
      {
        "command": "scripts/test-openburnbar-retrieval-evals.sh",
        "exitCode": 0,
        "observation": "Retrieval replay/golden suites remained green after incremental indexing changes."
      },
      {
        "command": "swift test --package-path OpenBurnBarCore",
        "exitCode": 0,
        "observation": "Core package tests passed with new indexing fixtures."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Manual: run repeated small-delta projection fixture and inspect reindex/reembed counters",
        "observed": "No full rebuild trigger; only impacted chunks were rewritten."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/ProjectionIncrementalContractsTests.swift",
        "cases": [
          {
            "name": "test_staleSourceVersionJobNoOpsWithoutWrites",
            "verifies": "Stale jobs complete without rewriting artifacts."
          },
          {
            "name": "test_remoteUpdateCanReenqueueProjectionAfterCompletion",
            "verifies": "Remote content updates can schedule a fresh projection pass."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- A required invariant depends on upstream architecture decisions not represented in current milestone scope.
- Testability is blocked by missing fixture infrastructure for projection or retrieval replay.
- Incremental behavior cannot be implemented without broad schema changes outside agreed boundaries.
