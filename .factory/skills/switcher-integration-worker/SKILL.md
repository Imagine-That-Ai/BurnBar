---
name: switcher-integration-worker
description: Complete cross-surface synchronization, navigation flows, and security/log hardening for the account switcher.
---

# Switcher Integration Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for cross-surface flows, relaunch persistence, race handling, log redaction, and end-to-end integration contracts spanning Settings, Dashboard, Popover, Browser, and CLI actions.

## Required Skills

None.

## Work Procedure

1. Read mission artifacts and all relevant assertion IDs in `fulfills`.
2. Write failing integration tests first for cross-surface flows and security guarantees.
3. Implement minimal changes to pass:
   - Shared active-state propagation
   - Navigation/recovery flows
   - Launch chaining consistency
   - Logging redaction
4. Verify race safety with deterministic tests.
5. Run validation stack:
   - `swift test --package-path OpenBurnBarCore`
   - scoped `xcodebuild test -only-testing:...`
   - `scripts/test-openburnbar-app.sh`
   - browser/CLI smoke commands when relevant
6. Collect evidence across UI traces, state snapshots, launch traces, and logs.
7. Return detailed handoff and flag any unresolved infra blockers.

## Example Handoff

```json
{
  "salientSummary": "Completed cross-surface switcher integration: state consistency, relaunch restoration, recovery navigation, and secret-safe logging.",
  "whatWasImplemented": "Wired global active profile synchronization across Settings/Dashboard/Popover, added end-to-end create->switch->launch flows, enforced deterministic launch chaining after rapid switches, and redacted switcher launch logs.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarCore",
        "exitCode": 0,
        "observation": "Cross-flow and redaction tests passed."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/SwitcherCrossFlowTests\"",
        "exitCode": 0,
        "observation": "Cross-surface integration tests passed."
      },
      {
        "command": "open -Ra \"Safari\" && open -Ra \"Google Chrome\"",
        "exitCode": 0,
        "observation": "Browser targets are resolvable for launch flows."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Manual: empty-state recovery from popover/dashboard to settings create flow then return",
        "observed": "Profile available immediately across surfaces and switching worked without relaunch."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/SwitcherCrossFlowTests.swift",
        "cases": [
          {
            "name": "test_switchInPopoverLaunchInDashboardUsesSameActiveProfile",
            "verifies": "Cross-surface chaining uses current active profile."
          },
          {
            "name": "test_relaunchRestoresActiveProfileAcrossAllSurfaces",
            "verifies": "Active state persists and rehydrates consistently."
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

- Cross-surface assertions require feature reprioritization across milestones.
- Validation cannot proceed due to environment-level issues outside repository control.
- Security assertions fail due to unresolved legacy logging behavior requiring wider policy decisions.
