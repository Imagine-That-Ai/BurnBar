# Proactive local-provider model discovery

Ledger row: `f2-model-proxy-router`

## What this proves

The production Windows gateway now performs bounded, proactive discovery for
the same local catalog families as macOS:

- local Ollama routes refresh the canonical `/api/tags` endpoint and advertise
  installed local models while excluding `:cloud` entries from localhost;
- other loopback OpenAI-compatible routes refresh `/v1/models`, preserve the
  configured bearer credential only in the request header, and accept bounded
  `id`, `display_name`, and `name` metadata;
- protected Factory routes run the reviewed `droid exec --help` discovery
  contract, parse the `Available Models` and `Custom Models` sections, and remove
  the random working directory after every outcome;
- at most four sources refresh concurrently, 128 models are accepted per source,
  512 discovered routes are accepted globally, responses are capped at 2 MiB,
  requests time out after 12 seconds, and production refresh repeats every five
  minutes;
- provider-controlled display names are length/control-character bounded, and
  the production HTTP transport refuses redirects so a loopback catalog cannot
  turn discovery into a remote request;
- successful rows become real executable routes cloned from the configured
  source's endpoint, credential, routing metadata, and health policy; configured
  routes always win model/id collisions; and
- an authoritative failure immediately removes prior discovered rows instead of
  advertising stale or unroutable models. HTTP 401/403 also enters the existing
  authentication cooldown, while transient discovery failures do not falsely
  mark the completion transport healthy or leak provider output.

The authenticated `/v1/models` response and companion `models` operation expose
whether a row was discovered, its display name and source kind, and its source
route. `/v1/models` also includes the last bounded per-source refresh status and
error. Remote HTTPS routes are never probed by this local discovery service.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayLiveModelDiscovery.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelProxyRouter.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/LocalHttpGatewayHost.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/CompanionCliServer.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayCompositionFactory.cs`
- `windows/app/OpenBurnBar.App/Gateway/WindowsProviderCliProcessRunner.cs`
- `windows/app/OpenBurnBar.App/Settings/WindowsSettingsPersistence.cs`
- `windows/app/OpenBurnBar.App/App.xaml.cs`
- `windows/tests/managed-runtime/GatewayLiveModelDiscoveryTests.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **206/206** locally. Eleven focused tests cover Ollama native tags and cloud
filtering, loopback OpenAI authentication/deduplication, remote-route exclusion,
immediate stale-row removal, authentication cooldown and secret-safe errors,
the exact Factory discovery process contract and cleanup, HTTP and CLI response
bounds, configured-route precedence, redirect refusal, and authenticated
`/v1/models` provenance/status output.

The real `WindowsProviderCliProcessRunner.cs` also compiles in the isolated
portable host harness after adding its exact Factory discovery
argument/environment shape. The full WinUI XAML build remains an exact-head
hosted-Windows gate because `XamlCompiler.exe` cannot execute on macOS.

## Boundary

This closes the proactive local-provider/model discovery portion of WPD-0006
row 2 and F2 workstream 3. It does not claim that a local server or Factory
account exists on a particular installation, live-provider completion
acceptance, remote provider catalog discovery, or WPD-0006 row 8's long-lived
agent/tool execution loop.
