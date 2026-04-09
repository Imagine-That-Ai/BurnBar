---
name: switcher-ui-worker
description: Implement polished account-switcher UI across Settings, Dashboard, and Popover.
---

# Switcher UI Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for UI features on Settings/Dashboard/Popover including profile management controls, switch actions, status/error/empty states, and accessibility behavior.

## Required Skills

None.

## Work Procedure

1. Read mission context plus design constraints in `DESIGN.md` and `.factory/library/architecture.md`.
2. Identify all `fulfills` IDs and map each to visible UI behavior.
3. Implement red/green:
   - Add/update failing UI or view-model tests first.
   - Implement UI changes to pass tests.
4. Reuse existing BurnBar UI patterns (GlassCard/buttons/spacing/typography) and avoid introducing new visual systems.
5. Ensure UX quality:
   - Explicit active, loading, empty, and error states.
   - Keyboard and accessibility support.
   - Deterministic interaction handling under rapid input.
6. Run scoped and broad validation:
   - scoped `xcodebuild test -only-testing:...`
   - `scripts/test-openburnbar-app.sh`
7. Perform manual UI sanity checks for all affected surfaces.
8. Produce evidence-rich handoff.

## Example Handoff

```json
{
  "salientSummary": "Added account-switcher UI to Settings, Dashboard, and Popover with consistent BurnBar styling, keyboard parity, and actionable error states.",
  "whatWasImplemented": "Implemented profile management form and list UX in Settings, quick switch controls in Dashboard and Popover, and deterministic status transitions for switch/launch actions including empty/loading/error paths.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/SwitcherUITests\"",
        "exitCode": 0,
        "observation": "Switcher UI contract tests passed."
      },
      {
        "command": "scripts/test-openburnbar-app.sh",
        "exitCode": 0,
        "observation": "App test suite passed with switcher changes."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Manual: create profile in Settings and switch from Dashboard/Popover",
        "observed": "Active state and visual indicators updated consistently."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/SwitcherUITests.swift",
        "cases": [
          {
            "name": "test_dashboardShowsActiveSwitcherState",
            "verifies": "Dashboard reflects active profile state."
          },
          {
            "name": "test_popoverEmptyStateShowsRecoveryCTA",
            "verifies": "Popover empty state is actionable."
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

- Required UX behavior is blocked by unresolved core/state dependencies.
- Accessibility or keyboard parity conflicts with existing shared components.
- Performance target ("switch in seconds") cannot be met due to external blocker.