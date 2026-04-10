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

## Handoff Discipline Requirements

Every EndFeatureRun handoff MUST satisfy both of the following requirements to be considered valid:

### 1. Full SHA Commit ID

The `commitId` field in handoffs MUST be a **full machine-resolvable SHA-1 commit ID** (40 hexadecimal characters). Short hashes or symbolic references (e.g., `HEAD`, `main`) are NOT acceptable.

**Verification:** Run `git rev-parse <commitId>` — it must resolve to the actual commit. If this command fails or returns a different hash, the handoff is non-compliant.

**Why this matters:** Short hashes and symbolic refs are ambiguous across clones and can become dangling references after rebases or force-pushes. Full SHAs are immutable and universally auditable.

### 2. Context Read Evidence for `followedProcedure=true`

Before setting `followedProcedure: true` in `skillFeedback`, you MUST demonstrate concrete evidence that you read the required context files listed in Phase 1.1 of `worker-base`. This is not self-certification — it requires showing what you actually read.

**Required evidence format:** In your `verification.commandsRun` array, include entries like:

```json
{
  "command": "head -n 3 mission.md && grep -n 'fulfills' AGENTS.md | head -n 5",
  "exitCode": 0,
  "observation": "Read mission.md goal section and AGENTS.md fulfills list during Phase 1.1 startup."
}
```

The evidence must demonstrate actual content was read (e.g., `head`, `grep`, `cat`, `rg` output showing file content), not merely that files exist (which `test -f` proves). For example, `rg -n 'phase' AGENTS.md` shows actual matching lines, while `test -f AGENTS.md` only proves the file exists.

### 3. Implementation Commit Traceability

When the final commit referenced by `commitId` is a **non-implementation artifact commit** (e.g., `chore(...)`, `docs(...)`, `test(validation):...`, or any commit that does not contain the feature's production/test code changes), the worker MUST also include the actual implementation commit SHA(s) in the handoff so that scrutiny reviewers can unambiguously map the implementation diff to the feature scope.

**Implementation commits** are commits whose diff contains the substantive code changes for the assigned feature (production code, test code, configuration changes that implement the feature behavior).

**Artifact commits** are commits whose diff is limited to validation synthesis, documentation updates, `.factory/` state commits, or other non-implementation housekeeping.

**How to provide implementation commit traceability:**

1. **During work**: Record the commit SHA(s) of your implementation commit(s) as you make them (use `git rev-parse HEAD` after each implementation commit).
2. **At handoff**: If your `commitId` points to an artifact commit, include the implementation SHA(s) in `handoff.whatWasImplemented` with a clear reference, e.g.:
   ```
   "whatWasImplemented": "Implemented X (implementation commit: abc1234...full SHA...). Final commit def... includes validation artifacts."
   ```
3. **Verification**: Scrutiny reviewers can then run `git show <implementation-sha> --stat` to see the actual feature diff.

**Compliance:** If your `commitId` references an artifact commit but no implementation commit SHA is included, `followedProcedure` MUST be set to `false` with a deviation documenting the omission.

### 4. Deviation Reporting

**If you deviated from the procedure:** You MUST set `followedProcedure: false` and document every deviation in `skillFeedback.deviations` with:
- `step`: Which phase/step was skipped or altered
- `whatIDidInstead`: What you actually did
- `why`: Blocking condition, better approach discovered, or unclear instruction

**Auditability:** These requirements make every handoff independently verifiable:
- Full SHAs can be checked with `git rev-parse` and compared against `git log`
- Context read evidence can be validated against Phase 1.1 requirements in `worker-base`
- Implementation commit traceability can be validated by checking whether `commitId` is an artifact commit and whether implementation SHAs are provided

## When to Return to Orchestrator

- A required invariant depends on upstream architecture decisions not represented in current milestone scope.
- Testability is blocked by missing fixture infrastructure for projection or retrieval replay.
- Incremental behavior cannot be implemented without broad schema changes outside agreed boundaries.
