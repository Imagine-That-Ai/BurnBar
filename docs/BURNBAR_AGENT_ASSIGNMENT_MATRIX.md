# BurnBar Agent Assignment Matrix

## Recommendation

Yes, multiple agents can work in parallel, but not by fanning out every PR at once and merging at the end.

For BurnBar, the early PRs define contracts. If multiple agents build against moving contracts, the result will be:

- RPC drift
- provider/catalog drift
- merge conflicts in shared files
- hidden incompatibilities between daemon, app, and extension

Use wave-based parallelism instead.

## Non-Negotiable Rules

### One integrator

One human or one lead agent owns:

- merge order
- integration branches
- conflict resolution
- final contract decisions

No other agent force-expands scope mid-wave.

### Single-owner files/surfaces

These surfaces must have exactly one owner at a time:

- `project.yml`
- generated Xcode project regeneration
- BurnBarCore catalog schema
- BurnBarCore RPC types
- BurnBarCore tool contracts
- BurnBarCore approval contracts
- BurnBarCore run-state machine
- daemon LaunchAgent install/uninstall logic
- extension `package.json` capability/trust declarations

If an agent needs one of these and does not own it in the current wave, it stops and hands the change back to the integrator.

### Disjoint write sets

Every agent gets a disjoint write scope.

Allowed overlap:

- docs-only references
- tests inside the files/directories explicitly assigned to that agent

Disallowed overlap:

- shared contracts
- extension manifest
- app build config
- daemon bootstrap/lifecycle files

### Merge by wave

Never let agents work for days and merge everything at the end.

Use:

1. contract wave
2. first product wave
3. second product wave
4. convergence wave
5. polish wave

## Roles

### Lead Integrator

Responsibilities:

- maintain the reviewed architecture
- cut integration branches
- review agent output against the spec
- run full test gates at the end of each wave
- decide when a blocked agent must be rebased or re-cut

### Foundation Agent

Strongest systems agent. Owns early shared-contract work.

### Daemon Agent

Owns daemon-only implementation details that do not mutate shared contracts mid-wave.

### Extension Shell Agent

Owns local extension UI shell and daemon client wiring.

### App Client Agent

Owns BurnBar app surfaces that become daemon-backed.

### Workspace Agent

Owns workspace companion and trust gating.

### Harness Agent

Owns test infrastructure, replay harnesses, and CI wiring.

### Run Service Agent

Owns run-state orchestration, approvals, retries, and multi-client arbitration.

## Wave 0: Sequential Foundation

These PRs should not be parallelized.

### PR1: Rebrand + Identity Migration

Owner:

- Foundation Agent

Write scope:

- app user-visible copy
- docs
- `project.yml`
- app identity/build names
- migration helpers for legacy app support/keychain paths

Do not touch:

- daemon target
- extension package
- BurnBarCore RPC contracts

Acceptance gate:

- BurnBar is visible everywhere user-facing
- legacy local data and secrets still resolve

### PR2: BurnBarCore + Shared Catalog + Contracts

Owner:

- Foundation Agent

Write scope:

- `BurnBarCore/`
- catalog file
- shared RPC/tool/approval/run-state types

Do not touch:

- extension implementation
- daemon lifecycle/install logic
- app UI polish

Acceptance gate:

- one catalog source of truth exists
- no duplicate provider/model/pricing registry remains authoritative

### PR3: Daemon Bootstrap + launchd + Socket Health

Owner:

- Foundation Agent or Daemon Agent

Write scope:

- `BurnBarDaemon/` bootstrap
- socket listener
- LaunchAgent install/repair/remove logic
- app hooks needed only for install/repair/health

Do not touch:

- extension UI
- workspace companion
- run-state orchestration beyond health/bootstrap

Acceptance gate:

- daemon installs
- daemon starts
- app can repair it

## Wave 1: First Parallel Product Wave

Start only after PR3 is merged.

Create:

- `integration/wave-1`

Branch each PR from that integration branch.

### Agent A: PR4 Provider Router + Accounting

Owner:

- Daemon Agent

Write scope:

- daemon config store
- provider router
- usage recorder
- daemon-side secret/provider plumbing
- daemon tests for routing/accounting

Do not touch:

- extension package
- app views
- BurnBarCore schema

Acceptance gate:

- supported models route correctly
- usage events record correctly

### Agent B: PR5 Cursor Extension Shell

Owner:

- Extension Shell Agent

Write scope:

- `extensions/burnbar/` local UI shell
- daemon client transport in TS
- activity bar or view container
- run list/detail projection shell

Do not touch:

- workspace companion execution adapters
- BurnBarCore contracts
- app UI

Acceptance gate:

- extension activates
- daemon health renders
- reconnect UI exists

### Agent C: PR8 BurnBar App as Daemon Client

Owner:

- App Client Agent

Write scope:

- BurnBar app health/config surfaces
- daemon-backed settings plumbing
- app-side recent usage views

Do not touch:

- extension package
- daemon router internals
- shared contracts

Acceptance gate:

- app reflects live daemon state
- app can repair daemon issues

### Wave 1 Merge Order

Recommended merge order into `integration/wave-1`:

1. PR4
2. PR5
3. PR8

Then run:

- Swift tests
- extension unit tests
- app + daemon smoke test

If green, merge `integration/wave-1` to `main`.

## Wave 2: Workspace + Harness Prep

Start only after Wave 1 is merged.

Create:

- `integration/wave-2`

### Agent D: PR6 Workspace Companion + Trust Gating

Owner:

- Workspace Agent

Write scope:

- workspace companion code
- cross-host private command RPC
- trust gating logic
- workspace capability reporting
- extension-side tool adapters

Do not touch:

- daemon run-state logic
- app UI
- BurnBarCore contracts unless explicitly handed back to integrator

Acceptance gate:

- local workspace tool path works
- restricted mode is explicit
- remote/workspace-host path is structurally correct

### Agent E: PR9a Harness Skeleton

Owner:

- Harness Agent

Write scope:

- CI workflows
- replay fixture format
- Swift test utilities
- TS test utilities
- extension-host test harness scaffolding
- eval scripts

Do not touch:

- extension manifest/capabilities while PR6 is active
- daemon run-state logic
- app UI

Acceptance gate:

- test harness exists
- replay fixtures can run in at least stub form
- extension-host harness can boot

### Wave 2 Merge Order

Recommended merge order into `integration/wave-2`:

1. PR6
2. PR9a

Then run:

- Swift tests
- extension unit tests
- trust-gating tests
- extension-host harness smoke test

If green, merge `integration/wave-2` to `main`.

## Wave 3: Convergence

These should not be parallelized with other contract-heavy work.

### Agent F: PR7 Run Service + Approvals + Arbitration

Owner:

- Run Service Agent

Write scope:

- daemon run service
- approval flow
- retry/cancel/resume behavior
- client registry
- lease/takeover/arbitration behavior
- related BurnBarCore state-machine refinements only if absolutely necessary

Do not touch:

- project identity
- extension manifest
- provider catalog unless blocked

Acceptance gate:

- approvals work
- cancel works
- retry works
- reconnect works
- multi-client conflicts are explicit, not implicit

### Merge Order

PR7 merges directly after Wave 2 is green.

Run:

- state-machine tests
- arbitration tests
- app/daemon/extension reconnect smoke tests

## Wave 4: Final Test/Eval Completion

### Agent E: PR9b Replay Evals + Extension-Host Coverage Finalization

Owner:

- Harness Agent

Write scope:

- replay eval suites
- golden baselines
- final extension-host integration scenarios
- CI enforcement

Do not touch:

- core product behavior unless fixing a test-only seam approved by the integrator

Acceptance gate:

- planner replays pass
- approval replays pass
- repair/recovery replays pass
- extension-host tests pass

## Wave 5: Release Polish

### Agent G: PR10 Public BurnBar Agent Release Polish

Owner:

- App Client Agent or Extension Shell Agent, with integrator review

Write scope:

- empty states
- repair copy
- docs
- onboarding
- publish-ready polish

Do not touch:

- shared contracts
- daemon arbitration semantics
- extension trust model

Acceptance gate:

- new user can complete the first BurnBar-in-Cursor flow
- common failure paths show recovery

## Merge Train

Use this order:

1. PR1
2. PR2
3. PR3
4. Wave 1 integration: PR4 + PR5 + PR8
5. Wave 2 integration: PR6 + PR9a
6. PR7
7. PR9b
8. PR10

This is the safest way to get parallelism without letting contracts drift.

## Fast Reference: Who Owns What

### Foundation Agent

Owns:

- rebrand
- migration
- BurnBarCore
- catalog
- shared contracts
- early daemon bootstrap

### Daemon Agent

Owns:

- provider router
- config store
- usage recorder

### Extension Shell Agent

Owns:

- local extension UI shell
- daemon client in TS

### App Client Agent

Owns:

- BurnBar app daemon-backed surfaces

### Workspace Agent

Owns:

- workspace companion
- cross-host bridge
- trust gating

### Harness Agent

Owns:

- CI
- extension-host harness
- replay evals

### Run Service Agent

Owns:

- approvals
- run-state orchestration
- arbitration

## Stop Conditions

An agent should stop and escalate to the integrator if:

- it needs to change BurnBarCore contracts outside its assigned wave
- it needs to edit `project.yml` outside PR1
- it needs to modify extension trust declarations while another agent owns them
- it discovers a required protocol change that would invalidate another active PR
- it needs to touch both app and extension and daemon in a way that breaks disjoint ownership

## Bottom Line

Parallelize after the foundation is merged.

Good parallelization:

- PR4 + PR5 + PR8 together
- PR6 + PR9a together

Bad parallelization:

- PR1 through PR10 all at once
- two agents editing BurnBarCore contracts at the same time
- two agents editing the extension manifest at the same time
- merging everything only at the very end

Copy-paste subagent prompts:

- [BURNBAR_SUBAGENT_PROMPTS.md](./BURNBAR_SUBAGENT_PROMPTS.md)
