# Policy engine production composition

Ledger row: `f2-policy-engine`

## What this proves

The Windows app now constructs the run/tool policy engine and exposes bounded,
side-effect-free `policy.evaluate` through the authenticated companion plane.
The implementation mirrors the macOS `OpenBurnBarPolicyEngine` behavior:

- read/search are low risk, patch is medium risk, and terminal/browser/system
  tools are high risk;
- explicit approval produces the effective-tool descriptor, with the final
  requested tool or patch as the deterministic fallback;
- trust-gated, missing-workspace, remote-unsupported, and patch failures are
  retryable; terminal and unknown failures are not;
- completed read/search calls require output to count as progress, while other
  completed tool calls count as progress;
- model-requested approval is honored for non-low-risk tools.

Approval messages use Windows wording for system-control tools. Custom title and
message input is bounded. The endpoint may describe a proposed action, error,
or tool-call snapshot, but has no process, provider, filesystem, journal, or
approval-resolution side effects.

## Production paths

- `windows/app/OpenBurnBar.App/App.xaml.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Planning/BurnBarPolicyEngine.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Planning/CompanionCliPolicyHandler.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/CompanionCliServer.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **225/225** locally. Coverage enumerates the full tool-risk matrix,
approval-disabled/default/custom behavior, empty requested-tool fallback, every
retry code, progress status/output rules, exact wire values, and authenticated
real-TCP evaluation.

## Boundary

This closes the WPD-0006 row 21 decision core. Durable approval
persistence/resolution and provider/tool execution are composed by the
separately evidenced headless run service. Physical Computer Use approval
safety remains an independent host gate and does not inherit this status.
