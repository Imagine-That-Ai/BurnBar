# OpenBurnBarCore

Swift package containing shared contracts between the macOS app, iOS companion, and the OpenBurnBar daemon. Everything that crosses the app↔daemon JSON-RPC boundary lives here.

**Location:** `OpenBurnBarCore/`  
**Package manifest:** `OpenBurnBarCore/Package.swift`

## Why it exists

The macOS app and daemon run in separate processes and exchange messages over a local JSON-RPC socket. Both sides must agree on every type name, `Codable` key, and enum `rawValue`. Keeping these types in a shared Swift package prevents drift and makes schema changes a compile error rather than a runtime surprise.

## Products

| Product | Purpose |
|---|---|
| `OpenBurnBarCore` | Shared wire types, provider contracts, token usage model, search contracts, mission control contracts |
| `OpenBurnBarIrohRelay` | Transport-agnostic relay protocol, pairing, and loopback transport. Links the iroh QUIC bridge when `Vendor/OpenBurnBarIroh.xcframework` is present |
| `OpenBurnBarMedia` | Mercury media substrate: frame codec, stream classes, bitrate controller, capability gate, budget envelope |
| `OpenBurnBarComputerUseCore` | Computer Use substrate: session metadata, scope rules, deny registry, audit chain, action descriptors, capability gate, budget envelope |
| `OpenBurnBarFirestoreModels` | Firestore document model types shared with the cloud sync layer |

## Source structure

```
OpenBurnBarCore/Sources/
  OpenBurnBarCore/          Main shared models and contracts
    SharedModels/           Domain types (AgentProvider, TokenUsage, HermesConnectionTypes, ...)
    Contracts/              JSON-RPC contract protocols
    Hermes/                 Hermes connection types
    AgentInsights/          Insight model types
    Views/                  Shared SwiftUI view helpers
    TextExpansion/          Text expansion types
  OpenBurnBarComputerUseCore/
  OpenBurnBarFirestoreModels/
  OpenBurnBarIroh/          UniFFI Swift shim (bridges to xcframework)
  OpenBurnBarIrohRelay/     Relay protocol and pairing
  OpenBurnBarMedia/         Mercury media types
```

## Key types

| Type | File | Description |
|---|---|---|
| `AgentProvider` | `SharedModels/AgentProvider.swift` | Canonical provider enum (also re-exported in `AgentLens/Models/AgentProvider.swift`) |
| `TokenUsage` | `SharedModels/TokenUsage.swift` | Core usage event model — input/output/cache tokens, cost, session metadata |
| `UsageProvenanceMethod` | `SharedModels/TokenUsage.swift` | How usage was obtained: `providerLog`, `billingAPI`, `connectorBridge`, etc. |
| `HermesConnectionTypes` | `SharedModels/HermesConnectionTypes.swift` | Hermes pairing and connection state types |
| `HermesRealtimeRelayTypes` | `SharedModels/HermesRealtimeRelayTypes.swift` | All relay frame variants (~99KB) |
| `ProviderAccountTypes` | `SharedModels/ProviderAccountTypes.swift` | Provider account and credential models (~50KB) |
| `OpenBurnBarAgentContracts` | `OpenBurnBarAgentContracts.swift` | Agent JSON-RPC contracts |
| `OpenBurnBarMissionControlContracts` | `OpenBurnBarMissionControlContracts.swift` | Mission control RPC contracts |

## Build commands

```bash
swift build --package-path OpenBurnBarCore
swift test --package-path OpenBurnBarCore
```

The `OpenBurnBarIrohRelay` product conditionally links `Vendor/OpenBurnBarIroh.xcframework` when present. The package builds without it — iroh QUIC features fall back to loopback transport.
