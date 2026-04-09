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

## When to Return to Orchestrator

- Required profile model decisions conflict with mission constraints.
- Browser/CLI behavior requires external dependency that cannot be validated locally.
- Assertion cannot be satisfied without broad architectural change beyond feature scope.
