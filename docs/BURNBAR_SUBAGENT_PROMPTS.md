# BurnBar Subagent Prompts

## How To Use

These prompts are written so you can paste them directly into Codex/Claude worker agents.

Use them with the wave order from:

- [BURNBAR_IMPLEMENTATION_CHECKLIST.md](./BURNBAR_IMPLEMENTATION_CHECKLIST.md)
- [BURNBAR_AGENT_ASSIGNMENT_MATRIX.md](./BURNBAR_AGENT_ASSIGNMENT_MATRIX.md)
- [BURNBAR_CURSOR_AGENT_SPEC.md](./BURNBAR_CURSOR_AGENT_SPEC.md)

Every prompt assumes the repo root is:

`/Users/albertonunez/Developer/AgentLens`

Product naming rule:

- Treat `BurnBar` as the canonical product name in all new user-facing work.
- Do not introduce new `AgentLens` user-facing strings.

## Global Worker Guardrails

Paste this at the top of every worker prompt if you want maximum consistency:

```text
You are working in /Users/albertonunez/Developer/AgentLens.

Important:
- You are not alone in the codebase.
- Other workers may be editing other files at the same time.
- Do not revert edits you did not make.
- Respect your assigned write scope exactly.
- If your task requires changing shared contracts or files outside your ownership, stop and report the blocker instead of freelancing.
- BurnBar is the canonical product name for all new user-facing work.
- Follow these docs as the source of truth:
  - docs/BURNBAR_CURSOR_AGENT_SPEC.md
  - docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
  - docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md
- Keep diffs minimal and explicit.
- Run the most relevant tests for your slice before finishing.

Your final response must include:
1. What you changed
2. Exact files changed
3. Tests run
4. Any blockers or assumptions
```

## Integrator Prompt

Use this for the lead integrator before each wave:

```text
You are the lead integrator for the BurnBar rollout in /Users/albertonunez/Developer/AgentLens.

Your job:
- enforce docs/BURNBAR_CURSOR_AGENT_SPEC.md
- enforce docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- enforce docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md
- keep contract surfaces stable during the current wave
- reject scope creep
- ensure workers have disjoint write scopes
- merge work in the planned wave order only

For the current wave:
1. Read the relevant sections of the three BurnBar docs
2. Summarize the contract surfaces that are frozen in this wave
3. Summarize each worker's allowed write scope
4. List the exact merge order
5. List the exact test gates that must pass before merge

Do not make speculative architecture changes. Optimize for integration safety.
```

## PR1 Prompt: Rebrand + Identity Migration

Recommended model:

- strong model, high reasoning

```text
You own PR1: Rebrand + Identity Migration for BurnBar.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- make BurnBar the visible product name
- update build identity
- preserve legacy local data and secrets through explicit migration

Your write scope:
- user-facing app copy
- docs
- project.yml
- generated Xcode project updates resulting from project.yml
- migration helpers for legacy app support path / sqlite path / keychain service lookup

Do not touch:
- BurnBarCore shared RPC/tool/run-state contracts
- daemon target
- extension package

Requirements:
- BurnBar must replace AgentLens in user-facing product surfaces
- add explicit fallback/migration logic for legacy persistence identifiers
- do not silently strand existing local data
- do not silently strand existing secrets

Deliver:
1. The rebrand/build identity changes
2. The migration logic
3. Tests for migration behavior where practical
4. A short note on anything still intentionally left as internal legacy naming

Run relevant tests before finishing.
```

## PR2 Prompt: BurnBarCore + Shared Catalog + Contracts

Recommended model:

- strongest systems model, high reasoning

```text
You own PR2: BurnBarCore + Shared Catalog + Contracts.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- create the shared contract layer before daemon and extension work diverge

Your write scope:
- BurnBarCore package
- canonical catalog file
- shared Swift contract types for:
  - provider/model/pricing metadata
  - daemon RPC
  - tool schemas
  - approval schemas
  - run-state machine
  - protocol versioning

Do not touch:
- extension implementation
- app UI work
- daemon launchd/bootstrap implementation

Requirements:
- one canonical catalog source of truth
- no second authoritative provider/model/pricing registry
- explicit contracts, not ad hoc dictionaries
- minimal but durable abstractions

Deliver:
1. BurnBarCore package
2. Catalog schema + loader
3. Shared contract types
4. Contract tests
5. Notes about any remaining duplication that must be removed in follow-up PRs

Run relevant tests before finishing.
```

## PR3 Prompt: Daemon Bootstrap + launchd + Socket Health

Recommended model:

- strong systems model, medium-high reasoning

```text
You own PR3: BurnBar daemon bootstrap.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- get a local BurnBar daemon online with launchd lifecycle and socket health

Your write scope:
- daemon target/binary
- socket bootstrap
- launchd install/repair/remove logic
- daemon health reporting
- minimal app hooks needed for install/repair/health only

Do not touch:
- extension package
- provider routing logic beyond bootstrap
- run-state orchestration beyond basic health/bootstrap
- BurnBarCore contracts unless blocked and escalated

Requirements:
- per-user launchd service
- Unix domain socket transport bootstrap
- stale socket cleanup
- visible daemon health

Deliver:
1. Daemon target
2. LaunchAgent lifecycle management
3. Socket bootstrap
4. Tests for boot/health/stale socket cleanup

Run relevant tests before finishing.
```

## PR4 Prompt: Provider Router + Accounting

Recommended model:

- strong backend/systems model, medium-high reasoning

```text
You own PR4: BurnBar provider router + accounting.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- move supported provider routing and usage recording into daemon-owned services

Your write scope:
- daemon config store
- provider router
- usage recorder
- daemon-side secret/provider plumbing
- routing/accounting tests

Do not touch:
- extension package
- app UI
- BurnBarCore shared contracts unless blocked and escalated

Requirements:
- support Z.ai and MiniMax only
- exclude Kimi and pony-alpha-2
- use shared catalog, not handwritten provider/model tables
- usage events must be structured and idempotent

Deliver:
1. Provider router
2. ConfigStore plumbing
3. Usage/accounting integration
4. Tests for routing and idempotent recording

Run relevant tests before finishing.
```

## PR5 Prompt: Cursor Extension Shell

Recommended model:

- strong TS/product model, medium-high reasoning

```text
You own PR5: BurnBar Cursor extension shell.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- build the local BurnBar extension shell in Cursor without workspace tool execution yet

Your write scope:
- extensions/burnbar local UI extension
- daemon client transport in TS
- BurnBar activity bar/view container
- health/reconnect UI
- run list/detail projection shell

Do not touch:
- workspace companion execution adapters
- extension trust declarations if another worker owns them in this wave
- BurnBarCore contracts
- app UI

Requirements:
- standard VS Code/Cursor extension APIs only
- no dependence on Cursor AI-specific extension APIs
- render daemon connection state clearly

Deliver:
1. Extension shell
2. Daemon client
3. Health/reconnect UX
4. Unit tests for extension client and activation

Run relevant tests before finishing.
```

## PR8 Prompt: BurnBar App as Daemon Client

Recommended model:

- strong Swift/macOS model, medium reasoning

```text
You own PR8: BurnBar app as daemon client.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- make the BurnBar app a client of the daemon for health/config/usage surfaces

Your write scope:
- app health/config views
- app-side daemon client wiring
- recent routed usage views
- app repair/reconnect actions

Do not touch:
- extension package
- daemon router internals
- BurnBarCore contracts

Requirements:
- app must reflect live daemon state
- app must not become a second control plane
- keep product naming BurnBar in user-facing surfaces

Deliver:
1. Daemon-backed app surfaces
2. Repair actions
3. Relevant tests

Run relevant tests before finishing.
```

## PR6 Prompt: Workspace Companion + Trust Gating

Recommended model:

- strong TS/IDE systems model, high reasoning

```text
You own PR6: BurnBar workspace companion + trust gating.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- create the workspace execution adapter for local/remote workspaces
- enforce explicit restricted/untrusted workspace behavior

Your write scope:
- workspace companion code in the extension package
- cross-host private command RPC
- workspace capability reporting
- tool adapters for:
  - read_file
  - search_workspace
  - apply_patch
  - run_terminal
- extension trust/restricted-mode declarations and gating

Do not touch:
- daemon run-state orchestration
- app UI
- BurnBarCore contracts unless blocked and escalated

Requirements:
- use VS Code workspace/editor APIs
- do not let the daemon patch workspace files directly
- restricted mode must clearly disable trust-sensitive features
- local and remote/workspace-host paths must both be considered

Deliver:
1. Workspace companion
2. Cross-host bridge
3. Trust gating
4. Tests for capability detection and restricted-mode behavior

Run relevant tests before finishing.
```

## PR9a Prompt: Harness Skeleton

Recommended model:

- strong infra/test model, medium-high reasoning

```text
You own PR9a: BurnBar harness skeleton.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- create the testing and eval scaffolding before the full behavior hardens

Your write scope:
- CI workflows
- replay fixture format
- Swift test utilities
- TS test utilities
- extension-host harness scaffolding
- eval script scaffolding

Do not touch:
- extension trust manifest while PR6 is active
- daemon run-state semantics
- app UI

Requirements:
- support Swift tests
- support TS tests
- support extension-host integration tests
- support replay eval fixtures

Deliver:
1. Harness scaffolding
2. CI entrypoints
3. Minimal passing smoke coverage

Run relevant tests before finishing.
```

## PR7 Prompt: Run Service + Approvals + Arbitration

Recommended model:

- strongest systems/state-machine model, high reasoning

```text
You own PR7: BurnBar run service + approvals + arbitration.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- make the daemon the real multi-client agent control plane

Your write scope:
- daemon run service
- approval flow
- retry/cancel/resume behavior
- client registry
- lease/takeover/arbitration behavior
- state-machine tests

Do not touch:
- project identity
- extension trust declarations
- provider catalog unless blocked and escalated

Requirements:
- explicit state machine
- daemon remains the source of truth
- multi-client ownership must be explicit, not implicit
- reconnect behavior must be deterministic

Deliver:
1. RunService
2. Approval flow
3. Client arbitration
4. Deterministic transition tests

Run relevant tests before finishing.
```

## PR9b Prompt: Replay Evals + Extension-Host Coverage

Recommended model:

- strong infra/test model, medium-high reasoning

```text
You own PR9b: BurnBar replay evals + extension-host coverage finalization.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- turn BurnBar behavior into something regression-resistant

Your write scope:
- replay eval suites
- golden baselines
- final extension-host integration scenarios
- CI enforcement for these suites

Do not touch:
- product behavior except for narrowly-scoped testability seams approved by the integrator

Required eval areas:
- planner behavior
- approval triggering
- local vs remote routing
- repair/recovery messaging

Deliver:
1. Replay suites
2. Golden baselines
3. Extension-host tests
4. CI enforcement

Run relevant tests before finishing.
```

## PR10 Prompt: Release Polish

Recommended model:

- strong product/frontend model, medium reasoning

```text
You own PR10: BurnBar agent release polish.

Repo:
- /Users/albertonunez/Developer/AgentLens

Read first:
- docs/BURNBAR_CURSOR_AGENT_SPEC.md
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- docs/BURNBAR_AGENT_ASSIGNMENT_MATRIX.md

Goal:
- make the first BurnBar agent release demoable and publishable

Your write scope:
- empty states
- error states
- repair/recovery copy
- onboarding and docs polish
- publish-ready UX cleanup

Do not touch:
- shared contracts
- daemon arbitration semantics
- extension trust model

Requirements:
- clear recovery paths for common failures
- no regression in BurnBar naming
- keep the UX intentional and high-signal

Deliver:
1. UX polish
2. Docs/onboarding polish
3. Final smoke verification notes

Run relevant tests before finishing.
```

## Good Parallel Packs

### Wave 1 pack

Launch these three together after PR3 lands:

- PR4 Provider Router + Accounting
- PR5 Cursor Extension Shell
- PR8 BurnBar App as Daemon Client

### Wave 2 pack

Launch these two together after Wave 1 merges:

- PR6 Workspace Companion + Trust Gating
- PR9a Harness Skeleton

## Do Not Parallelize These

- PR1 with any other PR
- PR2 with any other PR
- PR3 with extension work
- PR7 with active contract changes
- any two workers touching BurnBarCore contract files at once

## Quick Copy Block For Any Worker

If you want a shorter prompt preamble, use this:

```text
You are not alone in the codebase. Respect your assigned write scope exactly. Do not revert other edits. BurnBar is the canonical product name. If you need to change shared contracts or files outside your ownership, stop and report the blocker instead of freelancing.
```
