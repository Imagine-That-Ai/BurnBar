# Cross-vendor degrade policy production composition

Ledger row: `f2-model-proxy-router`

## What this proves

Windows now matches the macOS cross-vendor degradation safety contract:

- degradation is off by default;
- the operator must explicitly enable it through
  `OPENBURNBAR_CROSS_VENDOR_DEGRADE`;
- each request must also explicitly set `openburnbar_allow_degrade`;
- the optional vendor environment setting narrows and orders a bounded
  allow-list; the macOS defaults remain DeepSeek, Z.AI, and Moonshot;
- a preferred model can constrain each vendor, and candidates are capped;
- only OpenAI-compatible routes can participate, never Anthropic-shape routes;
- candidates still pass static availability, failure-driven health, and the
  five-factor provider scorecard;
- the gateway rewrites the upstream `model` field to the selected fallback
  before transport.

An untrusted client boolean therefore cannot authorize a new paid provider, an
arbitrary configured route cannot become a fallback, and the substitute
provider does not receive a request naming a model it cannot serve. Exact-model
routing remains the default fail-closed path.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/CrossVendorDegradePolicy.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ModelProxyRouter.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/LocalHttpGatewayHost.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayCompositionFactory.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **165/165** locally. Focused coverage proves default-off behavior, every
accepted enable spelling, normalized/deduplicated/bounded allow-lists, preferred
model and wire-family enforcement, candidate caps, the two-party operator plus
request gate, fail-closed no-candidate behavior, and live upstream model
rewriting.

## Boundary

This closes WPD-0006 row 3 and reconciles row 1's already composed authenticated
gateway transport. It does not claim row 4 durable route logs/streaming usage,
row 7 provider transports or proactive local discovery, or live-provider
staging acceptance.
