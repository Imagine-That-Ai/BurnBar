# F2 Model Proxy Settings and Live Catalog Evidence

**Date:** 2026-07-13
**Lane:** F2 local gateway, Model Proxy, and Elder Wand production composition

## What this proves

- App startup loads the persisted Model Proxy `Enabled`, `Host`, `Port`, secret
  token, and unauthenticated-loopback preference instead of always opening a
  hard-coded `127.0.0.1:8642` listener.
- Explicit `OPENBURNBAR_GATEWAY_ENABLED`, `OPENBURNBAR_GATEWAY_HOST`, and
  `OPENBURNBAR_GATEWAY_PORT` values remain supported for automation. Legacy
  host/port overrides enable the listener unless an explicit enabled override
  disables it.
- Host and port values are normalized before `HttpListener` is created. Invalid
  URI-like hosts, path-bearing hosts, malformed enable flags, and ports outside
  `1...65535` fail closed. The settings view-model uses that same resolver, so
  host validity, loopback/auth warnings, copied endpoints, and IPv6 bracket
  formatting cannot disagree with startup behavior.
- Unauthenticated mode is honored only when the resolved bind is an actual
  loopback address. A persisted or environment opt-out cannot remove bearer
  authentication from a LAN, wildcard, or other non-loopback bind.
- The router composition stays alive when the external listener is disabled or
  cannot bind, so internal fusion and companion operations do not disappear as
  a side effect of an HTTP endpoint preference.
- Provider routes now have a durable, typed metadata catalog in Windows
  settings. The production app no longer depends on
  `OPENBURNBAR_GATEWAY_ROUTES_JSON`; startup, Elder Wand, fusion, and the HTTP
  gateway consume the same persisted route list.
- Each bearer credential is stored separately through the Windows protected
  secret store under a SHA-256-derived route account name. Route metadata,
  observable settings rows, diagnostics, and support artifacts never contain
  the credential. Add/update/delete operations attempt to restore the prior
  protected value when metadata persistence fails and surface the original
  protected-storage failure.
- Route validation is shared by settings and the executor. Remote endpoints
  require HTTPS; loopback providers may use HTTP. URI credentials, fragments,
  duplicate route IDs, invalid bounds, and enabled bearer routes without a
  protected credential fail closed.
- The Model Proxy settings leaf now renders the live provider catalog with
  ready/disabled/credential-required states and add, edit, enable/disable, and
  delete controls. Successful mutations restart the shared local runtime so
  gateway, companion, fusion, and Elder Wand see the new graph together.
- The Model Proxy settings leaf exposes an explicit local-runtime restart
  action. Applying endpoint or credential changes rotates the HTTP listener,
  companion CLI, shared token, fusion composition, and project-memory service
  together; success and fail-closed bind outcomes are surfaced in the page.
- `/v1/models` now exposes `route_eligible`, `provider_id`, and
  `provider_name` alongside the existing model and health fields.
- Production Elder Wand configuration projects the same route graph used by the
  gateway. It suppresses the synthetic no-endpoint placeholder, de-duplicates
  model IDs, prefers an executable duplicate route, preserves priority-based
  provider order, and leaves advertised but unroutable models visibly disabled.

## Automated evidence

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore --nologo
Passed: 80, Failed: 0, Skipped: 0

dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --nologo -v:minimal -m:1
Passed: 774, Failed: 0, Skipped: 0

dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore --nologo
Passed: 160, Failed: 0, Skipped: 0

dotnet test windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj --no-restore --nologo --filter 'FullyQualifiedName~Gateway_route_secret_names|FullyQualifiedName~Release_guard_rejects_plaintext_gateway'
Passed: 2, Failed: 0, Skipped: 0

dotnet format windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj --no-restore --verify-no-changes --verbosity minimal --include <changed gateway, settings, configuration, and app C# files>
Exit: 0 (workspace-load warnings only)

dotnet build windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj --nologo -v:minimal -m:1
All 26 referenced managed projects compiled. The macOS authoring host then
stopped at the expected Windows-only XamlCompiler.exe execution boundary.
No C# or project-reference error preceded that boundary.
```

Focused coverage lives in:

- `windows/tests/managed-runtime/GatewayListenerOptionsTests.cs`
- `windows/tests/managed-runtime/GatewayCompositionFactoryTests.cs`
- `windows/tests/managed-runtime/LocalHttpGatewayHostTests.cs`
- `windows/tests/presentation/ElderWandGatewayCatalogProjectionTests.cs`
- `windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/GatewayRouteSettingsViewModelTests.cs`
- `windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/ModelProxySettingsViewModelTests.cs`

## Evidence boundary

This is source, portable-runtime, and managed app-boundary evidence. It does not
claim that a non-loopback `HttpListener` URL ACL is available on a particular
Windows installation, that the restart interaction has been exercised through
WinUI Automation on physical Windows, or that provider credentials/routes pass
live staging traffic. Full macOS provider-plan/quota/account semantics and live
provider health probes remain broader F2 work; the new editor closes the prior
environment-only production composition gap, not those host and staging gates.
