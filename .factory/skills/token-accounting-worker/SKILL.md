---
name: token-accounting-worker
description: Implement exact-first token ingestion, provenance persistence, checkpoint/reconciliation behavior, and reporting parity for token usage.
---

# Token Accounting Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for features that modify token extraction, parser precedence, usage persistence, provenance/confidence metadata, checkpoint/watermark behavior, reconciliation logic, and reporting contracts tied to token correctness.

## Required Skills

None.

## Work Procedure

### Phase 0: Startup Context Reads (MANDATORY — must be evidenced before `followedProcedure=true`)

Before beginning any implementation work, you MUST read ALL of the following files and record evidence of each read in `verification.commandsRun`. This is a hard prerequisite — if any required read is missing from command evidence, `followedProcedure` MUST be set to `false`.

**Required reads (from `worker-base` Phase 1.1):**

| # | File | Purpose | Evidence Command |
|---|------|---------|-----------------|
| 1 | `{missionDir}/mission.md` | Understand full scope and strategy | `head -n 10 {missionDir}/mission.md` or equivalent |
| 2 | `{missionDir}/AGENTS.md` | Mission boundaries, implementation conventions | `head -n 20 {missionDir}/AGENTS.md` or equivalent |
| 3 | `{missionDir}/features.json` | Feature status, milestone context | `jq '.features \| length' {missionDir}/features.json` |
| 4 | `.factory/services.yaml` | Command/service manifest | `head -n 5 .factory/services.yaml` |
| 5 | `.factory/library/architecture.md` | Component boundaries, data flows | `head -n 5 .factory/library/architecture.md` |
| 6 | `.factory/library/user-testing.md` | User testing guidance | `head -n 5 .factory/library/user-testing.md` |

**Additional conditional reads:**
- If your feature has `fulfills` assertion IDs → read those from `{missionDir}/validation-contract.md`
- If milestone context is needed → `jq --arg m "<milestone>" '.features \| map(select(.milestone == $m)) \| map({id, status})' {missionDir}/features.json`
- If library has other relevant files → `ls .factory/library/` and read as needed

**Evidence requirements:**
- Each read MUST produce a `commandsRun` entry in the final handoff's `verification` section.
- The entry MUST show actual file content was read (e.g., `head`, `grep`, `cat` output), not merely that the file exists.
- Example acceptable evidence:
  ```json
  {"command": "head -n 10 {missionDir}/mission.md", "exitCode": 0, "observation": "Read mission goal section confirming token accounting scope."}
  ```
- Example UNACCEPTABLE evidence:
  ```json
  {"command": "test -f {missionDir}/mission.md", "exitCode": 0, "observation": "File exists."}
  ```

### Phase 1–4: Implementation

1. **Identify assertions** — If your feature has `fulfills`, list assertion IDs and pass/fail conditions before editing code.
2. **TDD red/green:**
   - Add or update failing scoped tests first.
   - Confirm failure.
   - Implement minimal code changes to satisfy assertions.
3. **Preserve exact-first precedence:**
   - Exact rows must never be downgraded by lower-confidence writes.
   - Fallback must only run when exact buckets are absent.
4. **Datastore evidence** (for persistence/reconciliation features):
   - Add assertions/queries validating dedupe, precedence, checkpoint safety, and idempotency.
5. **Run scoped validators** relevant to changed area first, then broader gates:
   - `swift test --package-path OpenBurnBarCore`
   - `xcodebuild test` scoped `-only-testing` targets for changed contracts
   - `scripts/test-openburnbar-app.sh` when app-layer behavior changed
   - `npm --prefix extensions/openburnbar run lint`

### Phase 5: Skill Feedback Integrity

6. In `skillFeedback`, report procedure adherence truthfully:
   - **MUST set `followedProcedure=false`** if ANY of these were skipped or missing:
     - Any required Phase 0 startup read (from the table above)
     - Any required read-evidence entry in `verification.commandsRun`
     - TDD red/green steps for features with `fulfills` assertions
   - **MAY set `followedProcedure=true`** ONLY when:
     - All required reads are present in `verification.commandsRun` with actual content evidence
     - All applicable implementation steps were followed without deviation
7. Keep commit/handoff traceability strict:
   - Use a resolvable commit SHA in handoff `commitId` (verify with `git rev-parse`).
8. Ensure no long-running or watch processes remain.
9. Produce a complete handoff with concrete evidence, not generic statements.

## Example Handoff

```json
{
  "salientSummary": "Implemented exact-first upsert precedence with row-level provenance metadata and checkpoint-safe resume for token ingestion. Added focused tests for estimate-to-exact promotion and failure-safe watermark advancement. Scoped validators pass and sqlite evidence confirms no duplicate canonical rows.",
  "whatWasImplemented": "Added provenance fields to canonical usage persistence and conflict-resolution logic that blocks exact-row downgrades while allowing deterministic estimate-to-exact upgrades. Updated reconciliation/checkpoint paths to advance progress markers only on durable success and added fixtures for retry safety and idempotent convergence.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "head -n 10 ~/.factory/missions/<mission-id>/mission.md",
        "exitCode": 0,
        "observation": "Read mission goal section — confirmed token accounting scope and milestones."
      },
      {
        "command": "head -n 20 ~/.factory/missions/<mission-id>/AGENTS.md",
        "exitCode": 0,
        "observation": "Read AGENTS mission boundaries — noted port constraints 3190-3199, off-limits ports 5000/7000/8642/11434."
      },
      {
        "command": "jq '.features | length' ~/.factory/missions/<mission-id>/features.json",
        "exitCode": 0,
        "observation": "Confirmed feature count — read milestone context for m1-provenance-foundation."
      },
      {
        "command": "head -n 5 .factory/services.yaml",
        "exitCode": 0,
        "observation": "Read services manifest — verified test command path (scripts/test-openburnbar-swift.sh)."
      },
      {
        "command": "head -n 5 .factory/library/architecture.md",
        "exitCode": 0,
        "observation": "Read architecture doc — confirmed component boundaries for persistence layer."
      },
      {
        "command": "head -n 5 .factory/library/user-testing.md",
        "exitCode": 0,
        "observation": "Read user-testing guidance — noted flow validator isolation rules."
      },
      {
        "command": "swift test --package-path OpenBurnBarCore",
        "exitCode": 0,
        "observation": "Core package tests passed after adding precedence fixtures."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/CLIBridgeTests\"",
        "exitCode": 0,
        "observation": "Scoped contract tests for usage extraction and precedence passed."
      },
      {
        "command": "sqlite3 /tmp/mission-token-test.db \"SELECT provider,sessionId,model,COALESCE(sourceDeviceId,''),COUNT(*) FROM token_usage GROUP BY 1,2,3,4 HAVING COUNT(*)>1;\"",
        "exitCode": 0,
        "observation": "No duplicate canonical keys found."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Manual: replay mixed exact+estimated fixture twice and inspect canonical row after late exact arrival",
        "observed": "Canonical row promoted to exact once and remained stable on rerun."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/TokenAccountingPrecedenceTests.swift",
        "cases": [
          {
            "name": "test_exactRowIsNotDowngradedByLowerConfidenceEstimate",
            "verifies": "Exact canonical rows are downgrade-protected."
          },
          {
            "name": "test_lateExactPromotesEstimatedCanonicalRow",
            "verifies": "Estimate rows deterministically upgrade when exact data arrives."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## Handoff Discipline Requirements

Every EndFeatureRun handoff MUST satisfy all of the following requirements to be considered valid:

### 1. Full SHA Commit ID

The `commitId` field in handoffs MUST be a **full machine-resolvable SHA-1 commit ID** (40 hexadecimal characters). Short hashes or symbolic references (e.g., `HEAD`, `main`) are NOT acceptable.

**Verification:** Run `git rev-parse <commitId>` — it must resolve to the actual commit. If this command fails or returns a different hash, the handoff is non-compliant.

**Why this matters:** Short hashes and symbolic refs are ambiguous across clones and can become dangling references after rebases or force-pushes. Full SHAs are immutable and universally auditable.

### 2. Startup Read Evidence for `followedProcedure=true`

**This is a hard gate.** Setting `followedProcedure: true` without ALL required read-evidence entries in `verification.commandsRun` is a compliance violation that will be caught by scrutiny.

**Required evidence** — Before setting `followedProcedure: true`, you MUST include `commandsRun` entries for each of the following (see Phase 0 table above for the canonical list):

| Read | Minimum Evidence |
|------|-----------------|
| `mission.md` | `head -n N` or `grep` showing actual file content |
| `AGENTS.md` | `head -n N` or `grep` showing actual file content (especially boundaries) |
| `features.json` | `jq` query or `head` showing feature/milestone context |
| `.factory/services.yaml` | `head -n N` showing command/service manifest |
| `.factory/library/architecture.md` | `head -n N` showing component overview |
| `.factory/library/user-testing.md` | `head -n N` showing testing guidance |

**Evidence quality rules:**
- MUST demonstrate actual content was read (e.g., `head`, `grep`, `cat`, `rg` output showing file content).
- MUST NOT be existence checks only (`test -f`, `ls` without content).
- Example acceptable: `head -n 10 mission.md` → observation describes what was in those lines.
- Example unacceptable: `test -f mission.md` → only proves file exists, not that content was read.

**Checklist before submitting handoff (verify each):**
- [ ] `mission.md` read evidence present in `commandsRun`
- [ ] `AGENTS.md` read evidence present in `commandsRun`
- [ ] `features.json` read evidence present in `commandsRun`
- [ ] `.factory/services.yaml` read evidence present in `commandsRun`
- [ ] `.factory/library/architecture.md` read evidence present in `commandsRun`
- [ ] `.factory/library/user-testing.md` read evidence present in `commandsRun`

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
- Context read evidence can be validated against the Phase 0 table and checklist above
- Scrutiny validators can programmatically check for required evidence entries
- Implementation commit traceability can be validated by checking whether `commitId` is an artifact commit and whether implementation SHAs are provided

## When to Return to Orchestrator

- Required precedence semantics conflict with existing product behavior and no clear policy is documented.
- Feature needs cross-subsystem schema changes beyond the scoped milestone.
- External sync/API dependencies are unavailable and block required assertion verification.
