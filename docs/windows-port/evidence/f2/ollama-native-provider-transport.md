# Ollama-native provider transport

Ledger row: `f2-model-proxy-router`

## What this proves

Windows now production-composes the macOS Ollama-native provider behavior for a
configured `ollama` or `ollama-local` base URL:

- native routes resolve to `/api/chat`, while explicit `/v1` routes stay on the
  byte-preserving OpenAI-compatible transport;
- OpenAI messages, JSON response formats/schemas, token and sampling options,
  reasoning effort, and structured tool arguments convert to Ollama-native
  request fields;
- buffered native responses convert back to OpenAI chat completions with text,
  tool calls, finish reasons, and exact prompt/evaluation token counts;
- newline-delimited native streams convert to bounded OpenAI SSE and carry the
  final exact usage counters into gateway telemetry; and
- invalid JSON, malformed events, response-shape errors, and a stream without a
  terminal `done` event fail closed.

The executor retains the existing endpoint policy: remote providers require
HTTPS and cleartext HTTP is allowed only on loopback. It does not shell out,
log provider bodies, or place credentials in route metadata.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/OllamaNativeProviderAdapter.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelCompletionExecutor.cs`
- `windows/tests/managed-runtime/OllamaNativeProviderAdapterTests.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **178/178** locally. Six focused tests cover native detection and endpoint
resolution, request conversion, buffered response/tool conversion, streaming
and exact usage, truncation rejection, and the real HTTP executor boundary.

## Boundary

This advances WPD-0006 row 7 through all configured HTTP transports. The
separate `provider-cli-executors.md` evidence covers Codex and Factory, and
`proactive-local-model-discovery.md` covers local catalogs. This document does
not claim live local Ollama hardware/runtime acceptance.
