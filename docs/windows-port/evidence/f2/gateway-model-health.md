# Gateway model-health production composition

Ledger row: `f2-model-proxy-router`

## What this proves

The production Windows gateway now maintains failure-driven route health with
the same policy and key boundary as macOS `BurnBarGatewayModelHealthStore`:

- transient capacity failures block for one minute;
- ordinary rate limits block for five minutes, and Anthropic OAuth rate limits
  block for fifteen minutes;
- authentication failures block for one hour, except the current Claude Code
  login slot whose opaque 401/403 response cannot safely poison routing;
- HTTP 402 or bounded bodies indicating quota, insufficient balance, or
  exhaustion block for thirty minutes;
- unrelated client failures do not create health blocks;
- success clears the exact block, and elapsed cooldowns are pruned on read.

The key is provider, credential account, format family, and model. This prevents
one account or wire format from hiding unrelated routes. Active health blocks
participate in the actual `ModelProxyRouter` candidate filter, so failover uses
the next scored route rather than advertising an unhealthy winner.

## Privacy and durability

`ModelRouteHealthStore` persists only route/model/provider/account identifiers,
status, low-cardinality failure kind, and timestamps under the Windows settings
directory. Provider response bodies, prompts, tool data, endpoints, and bearer
credentials are never serialized. The file is size- and record-bounded, written
through atomic replacement, and corrupt/oversized/unwritable persistence fails
open as an empty routing hint without failing a user request.

The authenticated `/v1/models` response now projects effective health,
eligibility, failure kind, and expiry. `/v1/metrics` includes the same bounded
health records. The unauthenticated liveness endpoint remains aggregate-only.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelRouteHealthStore.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelProxyRouter.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/LocalHttpGatewayHost.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayCompositionFactory.cs`
- `windows/app/OpenBurnBar.App/Settings/WindowsSettingsPersistence.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **156/156** locally. Focused coverage proves every duration and exception,
expiry, success recovery, irrelevant-failure behavior, metadata-only persisted
reload, corrupt and oversized file handling, health-driven router failover, and
live model/metrics endpoint projection without provider-body disclosure.

## Boundary

This closes WPD-0006 row 2's production catalog and failure-driven health
contract. Proactive local discovery is covered separately by
`proactive-local-model-discovery.md`. This document does not claim row 4 durable
route logging/streaming usage, row 7 provider transports, or live-provider
staging acceptance.
