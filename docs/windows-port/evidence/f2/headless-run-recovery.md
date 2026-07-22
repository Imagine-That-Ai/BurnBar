# F2 Headless Run and Recovery Evidence

Ledger row: `f2-headless-run-recovery`

## What this proves

The Windows app production-composes two distinct execution paths:

- the existing bounded local Mission DAG runner; and
- a durable, model-driven `HeadlessAgentRunService` that implements the macOS
  run/agent-loop/approval/tool-dispatch lifecycle through the authenticated
  companion plane.

`App+CompanionRuntime.cs` creates both services before the companion listener
starts. Agent requests checkpoint before returning, and model execution runs in
background tasks owned by the app runtime rather than by the requesting socket.
Closing a companion connection or the WinUI window therefore does not cancel a
run. Explicit app shutdown stops new work cleanly; the next app start reloads
non-terminal runs and resumes safe phases.

Agent checkpoints contain the prompt, bounded context, loop state, approval,
and tool-call state. The app stores them in a dedicated bounded binary payload
store encrypted with current-user DPAPI on Windows. Opaque checkpoints are not
registered as short log-redaction tokens. The separate append-only JSONL
journal records only run id, state, event kind, safe error code, and time;
tests prove that prompts, tool arguments, tool output, and canary secrets are
absent from it. Missing, malformed, oversized, or Windows-unsafe checkpoint
data fails closed.

The authenticated companion protocol exposes:

- `run.submit`, `run.get`, `run.poll`, `run.cancel`, `run.retry`, and
  `run.recover`;
- `approval.respond` for run-level and per-tool decisions; and
- `workspace.executeTool` plus `workspace.toolResult` for leased tool work.

The real agent loop accepts one strict JSON decision and one bounded repair
attempt, then fails closed. It caps iterations, prompt/context/tool bytes, and
poll results; detects no-progress churn; preserves an exact requested model;
and tries at most three healthy routes for that model. Every provider attempt
updates the shared route-health and metadata-only telemetry stores.

Read and search can dispatch without approval. Patch, terminal, browser, and
system-control actions require approval unless the controller's explicit
run-level approval is being consumed for that next risky action. Tool calls are
claimed with a two-minute lease by the owning authenticated client/session, and
results cannot be submitted before a claim. Duplicate results are idempotent.
Replacement rejects ambiguous source text and never truncates a file. Apply
failures retry once; trust, workspace, and remote-capability failures return to
approval; terminal and unknown failures stop the run.

## Production paths

- `windows/app/OpenBurnBar.App/App+CompanionRuntime.cs`
- `windows/app/OpenBurnBar.App/App+FusionAndShutdown.cs`
- `windows/app/OpenBurnBar.App/Run/ProtectedHeadlessAgentCheckpointStore.cs`
- `windows/app/OpenBurnBar.App.Configuration/ProtectedFilePayloadStore.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Run/HeadlessAgentRunService.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Run/HeadlessAgentRunService+Execution.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Run/HeadlessAgentLoopService.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Run/HeadlessAgentCheckpointStore.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Run/CompanionCliAgentRunHandler.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/CompanionCliServer.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore --verbosity minimal`
passes **225/225** locally. The new coverage includes:

- generic model loop, low-risk tool claim, and terminal completion;
- run-level and per-tool approval, ownership, and claim enforcement;
- exact-model provider failover plus health/telemetry receipts;
- strict JSON repair, braces inside strings, and iteration limits;
- restart recovery with a pending tool and idempotent duplicate results;
- one apply retry, ambiguous replacement rejection, and fail-closed errors;
- corrupt/oversized/unsafe checkpoint rejection and journal redaction;
- missing nested checkpoint state rejection without raw startup failures; and
- authenticated real-TCP submit, approve, claim, result, and completion.

`dotnet test windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj --no-restore --verbosity minimal`
passes **48/48**, including protected binary round-trip, tamper rejection, size
enforcement, and delete behavior.

Additional local gates passed:

- `bash scripts/debt/check-windows-tree-budget.sh`
- `bash scripts/ci/check-no-suppressions.sh`
- `git diff --check`

## Boundary

This is the live in-process run service evidence accepted by WPD-0009. It does
not claim a separate Windows Service, a standalone parity-complete CLI
executable, or physical host certification. The WinUI composition must still
compile in Windows CI, and sustained process restart/sleep, physical Computer
Use safety, accessibility, staging-cloud, and signed release lifecycle remain
independent certification gates.
