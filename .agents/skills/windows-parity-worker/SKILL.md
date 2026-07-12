---
name: windows-parity-worker
description: Implement a bounded OpenBurnBar Windows parity milestone from reviewed VAL contracts with main-app composition, focused tests, baseline discipline, and Windows-host evidence preparation.
---

# Windows Parity Worker

## Inputs

Read the assigned task, every targeted `contract/VAL-*.md`, project `AGENTS.md`,
`MEMORY.md`, `mission.md`, `scope-inventory.md`, `oracle-matrix.md`,
`budgets.md`, `surface-contract-map.md`, `settings-control-inventory.md`, and
`target-baseline.md`. Read repository `AGENTS.md` and query BurnBar mem0 before
opening broad docs. Treat mem0 as navigation only and verify against live code.

## Baseline And Scope

1. Confirm branch `codex/windows-macos-parity-audit-implementation` and starting
   candidate commit. Record `git status --short --branch` before edits.
2. Preserve every pre-existing classified change. Do not edit frozen unrelated
   Linux paths. Do not reset, stash, checkout, regenerate, or clean them.
3. Search existing Windows/core/macOS implementations, callers, tests, fixtures,
   and composition roots before creating a type or framework.
4. Every edited line must serve assigned targets. Report discovered adjacent
   gaps; do not silently implement or defer another owner's assertions.

## Implementation Rules

- Product reachability is mandatory: compose behavior from `App.OnLaunched` or
  the accepted runtime owner through the real WinUI actor flow. A portable core,
  test-only consumer, manifest declaration, mock, or sample/empty fallback does
  not satisfy a target.
- Extend existing PALs, storage, cloud, Computer Use, Mercury, updater, UI,
  design-token, and automation patterns. Use structured serializers/parsers and
  typed state models.
- Never put secrets in config, logs, child environments, screenshots, tests, or
  evidence. Use canaries and leak scanners without exposing real credentials.
- Failure must be typed and visible. Never convert invalid storage, corrupt data,
  auth failure, missing runtime, or integration failure to legitimate empty data.
- Keep UI Windows-native and use existing icon/design systems. Honor the exact
  state/display/settings inventories; workers cannot mark rows N/A or delete IDs.
- Preserve macOS v1.0.29 behavior using the frozen oracle protocols and document
  only Windows-native API/chrome adaptations.
- Add or update production tests and evidence harnesses with the implementation.
  Do not weaken fixtures, goldens, CI gates, baselines, assertions, or budgets.

## Self-Checks

Run the cheapest relevant local .NET tests and structural scripts while working.
For Windows-only XAML/host work, prepare and, when the host is available, run the
focused Windows build/test/UIA path. Do not claim host proof from macOS builds.
Run suppression, secret, resilience, schema/golden, and documentation checks
when touched. Capture exact commands and exit codes.

## Handoff

Return, per target:

- implementation paths and main-app reachability;
- tests/checks with commands, exit codes, and artifact paths;
- Windows/staging/physical setup exercised or explicitly blocked;
- candidate commit and changed-path classification against `target-baseline.md`;
- remaining risks, missing evidence, and discovered gaps;
- no claim that validator-owned evidence already passes.

Commit the coherent assigned unit on the mission branch after focused checks.
Do not push/open a PR unless the task or orchestrator explicitly requests it;
the final mission integration/release task owns the repository PR loop.
