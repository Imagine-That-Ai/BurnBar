---
name: context-pack-core-worker
description: Implement ContextPack model, assembly/ranking/capping logic, and export formatting contracts.
---

# Context Pack Core Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE.

## When to Use This Skill

Use for Context Pack domain/service work:
- `ContextPack` model and export target types
- ranking heuristics and deterministic tie-break behavior
- dedupe/cap logic (5 sessions, 12k chars, oldest-first trim)
- export envelope generation and deterministic formatting tests

## Required Skills

None.

## Work Procedure

1. Read mission artifacts (`mission.md`, `validation-contract.md`, `AGENTS.md`) and list target assertion IDs from `fulfills`.
2. Add/extend failing tests first for those assertions in scoped test files.
3. Implement model/service/export changes minimally to satisfy tests.
4. Verify deterministic behavior with repeated-run tests for ordering/format stability.
5. Run scoped tests first, then required repo validators from `.factory/services.yaml`.
6. Confirm no unrelated files are modified.
7. Prepare explicit handoff evidence for each assertion group.

## Example Handoff

```json
{
  "salientSummary": "Implemented ContextPack core assembly and export envelopes with deterministic ranking/capping behavior. Added service/export tests for heuristics, caps, and envelope correctness; all scoped and required validators passed.",
  "whatWasImplemented": "Added ContextPack domain types and ContextPackService with same-project boost, 7-day weighted recency, summary/signal ranking factors, deterministic tie-breaks, dedupe-before-rank, 5-session cap, and 12k-char oldest-first trimming. Implemented target export envelopes for claude/hermes/codex/cursor/markdown while preserving shared-body semantics.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/ContextPackServiceTests\" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO",
        "exitCode": 0,
        "observation": "ContextPackServiceTests passed."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/ContextPackExportTests\" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO",
        "exitCode": 0,
        "observation": "ContextPackExportTests passed."
      },
      {
        "command": "scripts/test-openburnbar-swift.sh",
        "exitCode": 0,
        "observation": "Swift/package validation passed."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/ContextPackServiceTests.swift",
        "cases": [
          {
            "name": "test_rankingOrdersByScoreDescending",
            "verifies": "ranking order and deterministic tie-breaks"
          },
          {
            "name": "test_overflowTrimsOldestIncludedFirst",
            "verifies": "12k cap overflow trims oldest included sessions first"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- Required ranking/export behavior conflicts with existing app contracts.
- Needed test targets/files are missing from the Xcode test bundle and require orchestration.
- Assertions cannot be validated due to infrastructure/tooling breakage outside feature scope.
