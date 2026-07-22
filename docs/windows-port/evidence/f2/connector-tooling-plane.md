# F2 connector and tooling plane evidence

## Verdict

WPD-0006 row 33 is `SUB-DONE`. The authenticated Windows companion plane is
the concrete consumer for the connector plane, tooling proxy, workspace bridge,
and context selector. This is an in-process C# substitute for the daemon actors;
it does not introduce a second Windows service.

## Production composition

- `ConnectorPlaneComposition.CreateDefault()` persists non-secret configuration
  under current-user LocalAppData and stores credentials only in the existing
  DPAPI-backed `ProtectedFileSecretStore`.
- `ConnectorPlaneService` supplies the six macOS connector kinds, deterministic
  health states, update/test actions, and secret hints without placing a
  credential in configuration, status details, URLs, or logs.
- `PublicHttpsConnectorTransport` requires HTTPS, rejects URI credentials,
  private/reserved/literal targets, empty or mixed public/private DNS answers,
  redirects, oversized responses, and DNS rebinding by resolving again and
  pinning the socket at connect time.
- `ToolingProxyService` owns the connector plane, workspace broker, and context
  selector. `App.StartCompanionCli()` composes it once and exposes its operations
  only through the already authenticated, bounded loopback companion protocol.
- `WorkspaceBridgeBroker` enforces one active call per run, oldest-first claim,
  claimant ownership, stale-result rejection, terminal completion, cancellation,
  clearing, and recovery of pending/in-progress calls.
- `ContextSelector` preserves the macOS read-before-patch sequence, inspect/search
  selection, terminal argument shaping, candidate-path de-duplication, and
  fail-closed missing-context behavior.

Authenticated operations: `connector.get`, `connector.update`,
`connector.action`, `workspace.bridge.enqueue`, `workspace.bridge.claim`,
`workspace.bridge.result`, `workspace.bridge.clear`, `workspace.bridge.cancel`,
`context.next`, and `context.snapshot`.

## Validation

```text
dotnet test windows/tests/cursor-connector/OpenBurnBar.App.CursorConnector.Tests.csproj --no-restore
Passed: 115, Failed: 0, Skipped: 0

dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore
Passed: 287, Failed: 0, Skipped: 0
```

The full WinUI build compiled every C# dependency, including the new app
composition, before stopping at the expected non-Windows-host boundary where
macOS cannot execute `XamlCompiler.exe`. Native Windows CI is the authoritative
host compile.

## Remaining boundary

Live GitHub/Slack/Linear/PostHog/Sentry/Gmail credentials and requests remain a
staging certification activity. The implementation fails closed without a
saved DPAPI credential; no production or staging connector was contacted for
this evidence.
