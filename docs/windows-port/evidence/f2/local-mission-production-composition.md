# Local Mission DAG production composition

Ledger row: `f2-local-mission-execution`

## What this proves

The Windows app now constructs `LocalMissionDagExecutor` in its production
runtime and exposes it through authenticated loopback companion operations:
`mission.submit` and `mission.resume`. This replaces the earlier evidence that
covered an unused presentation helper and a portable core only.

The command adapter accepts 1 to 128 nodes, bounds payloads, validates unique
ids and dependency references, rejects cycles before journaling, and executes a
deterministic topological plan. Production permits only `noop`, `health`, and a
0-to-30-second `delay`; arbitrary shell and provider work fails before the
journal is created. A shared 60-execution/minute limiter fails closed rather
than queueing unbounded work. The existing metadata-only JSONL journal records
state, node ids, and errors without payloads or secrets, and resume skips nodes
already durably completed.

## Production paths

- `windows/app/OpenBurnBar.App/App.xaml.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Mission/CompanionCliMissionHandler.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Mission/LocalMissionDagExecutor.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Run/HeadlessRunService.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/CompanionCliServer.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **85/85**. The suite includes:

- authenticated TCP `mission.submit` over the real multi-client server;
- safe dependency-ordered execution through the production command adapter;
- unsafe-kind rejection before journal creation;
- duplicate/missing dependency, cycle, payload, approval, cancellation,
  recovery, and shared rate-window behavior;
- bearer-token rejection and removal before command dispatch.

## Boundary

This closes the WPD-0009 local Mission DAG execution trigger. The broader
intent-normalization planner, policy/provider execution, and Telegram bridge
were subsequently promoted by their own evidence documents; physical/staging
release certification remains independently tracked and must not inherit this
row's status.
