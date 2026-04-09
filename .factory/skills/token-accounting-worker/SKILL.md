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

1. Read `mission.md`, `AGENTS.md`, `.factory/library/architecture.md`, and `.factory/library/user-testing.md`.
2. Identify the exact assertion IDs in `fulfills` and list their pass/fail conditions before editing.
3. Implement TDD red/green:
   - Add or update failing scoped tests first.
   - Confirm failure.
   - Implement minimal code changes to satisfy assertions.
4. Preserve exact-first precedence:
   - Exact rows must never be downgraded by lower-confidence writes.
   - Fallback must only run when exact buckets are absent.
5. For persistence/reconciliation features, include datastore evidence:
   - Add assertions/queries validating dedupe, precedence, checkpoint safety, and idempotency.
6. Run scoped validators relevant to changed area first, then broader gates:
   - `swift test --package-path OpenBurnBarCore`
   - `xcodebuild test` scoped `-only-testing` targets for changed contracts
   - `scripts/test-openburnbar-app.sh` when app-layer behavior changed
   - `npm --prefix extensions/openburnbar run lint`
7. In `skillFeedback`, report procedure adherence truthfully:
   - Set `followedProcedure=false` if required red/green or required reads/verification were skipped.
   - Do not mark `followedProcedure=true` when deviations occurred.
8. Keep commit/handoff traceability strict:
   - Use a resolvable commit SHA in handoff `commitId` (verify with `git rev-parse`).
9. Ensure no long-running or watch processes remain.
10. Produce a complete handoff with concrete evidence, not generic statements.

## Example Handoff

```json
{
  "salientSummary": "Implemented exact-first upsert precedence with row-level provenance metadata and checkpoint-safe resume for token ingestion. Added focused tests for estimate-to-exact promotion and failure-safe watermark advancement. Scoped validators pass and sqlite evidence confirms no duplicate canonical rows.",
  "whatWasImplemented": "Added provenance fields to canonical usage persistence and conflict-resolution logic that blocks exact-row downgrades while allowing deterministic estimate-to-exact upgrades. Updated reconciliation/checkpoint paths to advance progress markers only on durable success and added fixtures for retry safety and idempotent convergence.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
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
  "command": "test -f mission.md && test -f AGENTS.md && echo 'context files present'",
  "exitCode": 0,
  "observation": "Required context files were present and read during Phase 1.1 startup."
}
```

**If you deviated from the procedure:** You MUST set `followedProcedure: false` and document every deviation in `skillFeedback.deviations` with:
- `step`: Which phase/step was skipped or altered
- `whatIDidInstead`: What you actually did
- `why`: Blocking condition, better approach discovered, or unclear instruction

**Auditability:** These two requirements make every handoff independently verifiable:
- Full SHAs can be checked with `git rev-parse` and compared against `git log`
- Context read evidence can be validated against Phase 1.1 requirements in `worker-base`

## When to Return to Orchestrator

- Required precedence semantics conflict with existing product behavior and no clear policy is documented.
- Feature needs cross-subsystem schema changes beyond the scoped milestone.
- External sync/API dependencies are unavailable and block required assertion verification.
