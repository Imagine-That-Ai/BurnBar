# Provider router scorecard production composition

Ledger row: `f2-model-proxy-router`

## What this proves

The Windows app's production `ModelProxyRouter` now selects routes through the
same five-factor policy used by macOS:

- capability 20%, cost 25%, latency 15%, trust 25%, and policy fit 15%;
- finite bounded score inputs, relative cost normalization, and the same
  50-200 ms latency normalization;
- ready, active/expired cooldown, exhausted, missing-secret, disabled, and
  legacy trust states;
- preferred credential slot and preferred provider policy-fit weights;
- strict quota-drain pools keyed by provider, resolved model, canonical model,
  wire-format family, and endpoint profile;
- soonest active reset, then highest remaining quota within a pool, without
  leaking quota priority across providers or models;
- deterministic composite, provider, slot-priority, least-recently-selected,
  slot-id, and route-id ties.

Exhausted, missing-secret, disabled, and statically unhealthy routes are
ineligible. Exact-model requests still fail closed unless the caller explicitly
opts into degradation. Every selected route carries a structured score
breakdown for audit and route telemetry consumers.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelProxyRouter.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelRouteScorecard.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayRouteConfiguration.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayCompositionFactory.cs`
- `windows/app/OpenBurnBar.App.Settings.ViewModels/GatewayRouteSettingsViewModel.cs`
- `windows/app/OpenBurnBar.App/App.xaml.cs`

Routing metadata is non-secret and serializable with the route catalog. Existing
records deserialize with legacy-neutral defaults. Ordinary settings edits
preserve advanced metadata, while provider/model/endpoint changes clear it so
stale canonical-model or quota state cannot influence a different upstream.
Bearer credentials remain resolved only from protected storage and never enter
the scorecard record.

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **147/147** locally. Focused coverage proves all five weights, clamping,
cost/latency/trust/provider preference, strict reset and remaining-quota order,
pool isolation, ineligible-route filtering, deterministic LRU ties, exact-model
fail-closed behavior, and the production decision score artifact.

`dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore`
passes **179/179** locally, including preservation of advanced routing metadata
across ordinary settings edits and invalidation when route identity changes.
Composition tests also reject non-finite,
negative, or oversized routing metadata before persistence or execution.

## Boundary

This closes WPD-0006 row 6's provider-router and quota-drain decision core. It
does not claim row 2 live model-health probing, row 4 durable route/streaming
usage telemetry, row 7 Codex/FactoryDroid/Ollama-native provider transports, or
live-provider staging acceptance. Those remain separately named gates.
