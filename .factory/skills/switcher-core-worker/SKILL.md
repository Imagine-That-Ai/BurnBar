---
name: switcher-core-worker
description: Build account-switcher core domain models, persistence, and secure launch orchestration.
---

# Switcher Core Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for features that implement profile models, validation, persistence, active-state transitions, browser/CLI launch adapters, and security boundaries.

## Required Skills

None.

## Work Procedure

1. Read `mission.md`, mission `AGENTS.md`, `.factory/library/architecture.md`, and `.factory/library/user-testing.md`.
2. List `fulfills` assertion IDs and expected pass/fail outcomes before coding.
3. Follow red/green TDD:
   - Add failing unit/integration tests first.
   - Implement minimal production changes to pass.
4. Enforce boundaries:
   - No cookie/session import.
   - No plaintext credential persistence.
   - Browser/CLI launch allowlisting and deterministic errors.
5. Run scoped verification first, then broader checks:
   - `swift test --package-path OpenBurnBarCore`
   - scoped `xcodebuild test -only-testing:...`
6. Record launch evidence (argv/env key set/error typing) for launch assertions.
7. Ensure no orphaned processes remain.
8. Return a concrete handoff with exact commands, outputs, tests, and discovered issues.

## Example Handoff

```json
{
  "salientSummary": "Implemented switcher profile domain + persistence and browser/CLI launch adapters with deterministic error typing and allowlisted launch specs.",
  "whatWasImplemented": "Added profile store schema, active-profile transition logic, and secure launch adapters for Chrome/Safari and Codex/Claude/OpenCode. Added validation and guardrails for malformed profiles, missing executables/apps, and injection-like metadata.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarCore",
        "exitCode": 0,
        "observation": "Domain and launch contract tests passed."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/SwitcherLaunchContractsTests\"",
        "exitCode": 0,
        "observation": "Launch adapter integration tests passed."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Manual: run browser app resolvability smoke and CLI executable resolution checks",
        "observed": "Expected app/executable presence and typed failures for missing fixtures."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/SwitcherLaunchContractsTests.swift",
        "cases": [
          {
            "name": "test_browserLaunchRejectsProfileMismatch",
            "verifies": "Browser/profile mismatch fails safely."
          },
          {
            "name": "test_cliLaunchUsesAllowlistedEnvironment",
            "verifies": "CLI env is allowlisted and deterministic."
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

**If you deviated from the procedure:** You MUST set `followedProcedure: false` and document every deviation in `skillFeedback.deviations` with:
- `step`: Which phase/step was skipped or altered
- `whatIDidInstead`: What you actually did
- `why`: Blocking condition, better approach discovered, or unclear instruction

**Auditability:** These two requirements make every handoff independently verifiable:
- Full SHAs can be checked with `git rev-parse` and compared against `git log`
- Context read evidence can be validated against Phase 1.1 requirements in `worker-base`

## When to Return to Orchestrator

- Required profile model decisions conflict with mission constraints.
- Browser/CLI behavior requires external dependency that cannot be validated locally.
- Assertion cannot be satisfied without broad architectural change beyond feature scope.
