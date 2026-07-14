# Planner production composition

Ledger row: `f2-planner-service`

## What this proves

The Windows app now constructs a side-effect-free planner and exposes it as
`planner.plan` through the authenticated loopback companion plane. This is the
Windows composition of `OpenBurnBarPlannerService.swift`, not the unrelated DAG
topological ordering helper.

Raw requests use the same deterministic precedence as macOS:

1. explicit `agentIntent` metadata;
2. `workspaceWorkflow` / `workflow` metadata;
3. explicit `toolKind` + `toolArguments` metadata;
4. bounded prompt heuristics;
5. generic fallback.

The service supports the same replace-string workflow, every current tool-kind
wire value, requested-tool inference, replacement/terminal/search/read prompt
normalization, and exact three-step plan outlines. Typed planner input preserves
constraints, risk, and desired outputs; empty required arrays and unsupported
schema versions fail closed. Unsupported workflow metadata fails before a
lower-precedence tool or prompt can run.

The companion request is bounded by the 64 KiB authenticated JSONL transport,
with additional string and item-count limits. Planning has no filesystem,
process, provider, or journal side effects. Validation errors return structured
JSON without dropping the client or echoing the access token.

## Production paths

- `windows/app/OpenBurnBar.App/App.xaml.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Planning/BurnBarPlannerService.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Planning/BurnBarPlannerContracts.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Planning/BurnBarPlannerWire.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Planning/CompanionCliPlannerHandler.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/CompanionCliServer.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **100/100** locally. Coverage includes:

- macOS precedence and exact outline vectors;
- workflow, tool, replacement, selection, terminal, search, read, and generic
  normalization;
- inferred, explicit-empty, and explicit-null requested-tool behavior;
- typed constraint/risk/desired-output preservation and schema rejection;
- unsupported-workflow pre-execution failure;
- exact snake-case wire names;
- authenticated real-TCP `planner.plan`;
- structured validation errors that preserve the client connection.

## Boundary

This closes WPD-0006 row 20's intent-planning contract. It does not execute the
requested plan. Provider routing/execution, tool approval/dispatch, long-lived
headless execution, and live staging/physical certification remain separate
rows and do not inherit this status.
