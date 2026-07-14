# Gateway route telemetry production composition

Ledger row: `f2-model-proxy-router`

## What this proves

The production Windows gateway now records bounded, durable routing and usage
metadata without persisting provider request or response content:

- exact-model, failed-closed, and cross-vendor decisions share one route event
  schema;
- OpenAI and Anthropic normal JSON usage is normalized;
- for SSE responses, the last valid usage-bearing event is authoritative;
- uncached input, output, cache-creation, cache-read, and reasoning tokens remain
  separate counters;
- at most 5,000 records are retained, and authenticated diagnostics expose at
  most 50 recent records by default with a hard 200-record read cap;
- corrupt JSONL rows are skipped, invalid or negative records are refused, an
  oversized file fails open as empty, and compaction replaces the file
  atomically; and
- an unwritable telemetry target is advisory and cannot fail a provider request.

The schema has no fields for prompts, messages, attachments, tools, request or
response bodies, provider endpoints, bearer tokens, or other credentials. The
authenticated metrics endpoint exposes only aggregate counts and bounded recent
route metadata.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayRouteTelemetryStore.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelProxyRouter.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/LocalHttpGatewayHost.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayCompositionFactory.cs`
- `windows/app/OpenBurnBar.App/Settings/WindowsSettingsPersistence.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **178/178** locally. Focused tests cover OpenAI, Anthropic, and native
Ollama usage,
authoritative final SSE usage, cache/reasoning separation, persistence reload,
corrupt rows, 5,000-row retention, recent-read bounds, oversized files, invalid
records, and the live authenticated metrics projection.

## Boundary

This closes WPD-0006 row 4 for gateway route/stream usage telemetry. It does not
claim provider-specific cost calculation, row 7 provider transports or
proactive discovery, row 8 long-lived agent/tool execution, or live staging
provider acceptance.
