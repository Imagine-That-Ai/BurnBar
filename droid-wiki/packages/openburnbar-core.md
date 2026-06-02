# OpenBurnBarCore

Shared Swift package containing wire types, RPC contracts, and utilities used by the macOS app, iOS app, and daemon.

## Purpose

Prevent type drift between the macOS app UI, the iOS companion, and the local daemon. Every cross-boundary message uses a type defined in this package.

## Directory layout

```
OpenBurnBarCore/
  Package.swift
  Sources/OpenBurnBarCore/
    Models/
      AgentProvider.swift       # 17+ supported agents
      TokenUsage.swift          # Unified token + cost ledger
      UsageRollups.swift        # Aggregated window docs
    RPC/
      DaemonRPCContracts.swift  # JSON-RPC method signatures
      BurnBarComputerUseContracts.swift  # Computer Use wire types
    Utilities/
      Extensions.swift          # String, Date, Color helpers
```

## Key abstractions

| Type | File | Purpose |
|------|------|---------|
| `AgentProvider` | `Sources/OpenBurnBarCore/Models/AgentProvider.swift` | Enum of supported AI agents with metadata |
| `TokenUsage` | `Sources/OpenBurnBarCore/Models/TokenUsage.swift` | Per-session token and cost record |
| `BurnBarRPCMethod` | `Sources/OpenBurnBarCore/RPC/DaemonRPCContracts.swift` | JSON-RPC method constants |
| `ComputerUseIntent` | `Sources/OpenBurnBarCore/RPC/BurnBarComputerUseContracts.swift` | Signed intent for phone-as-controller |

## Integration points

- Imported by `AgentLens/`, `OpenBurnBarMobile/`, and `OpenBurnBarDaemon/`.
- Large migrations here can trigger stale Xcode cache issues — run `./scripts/clear-xcode-caches.sh` if you see ghost errors.

## Entry points for modification

- Add new shared models under `Sources/OpenBurnBarCore/Models/`.
- Add new RPC contracts under `Sources/OpenBurnBarCore/RPC/`.
- Update `Package.swift` platform targets if adding new dependencies.

## Related pages

- [macOS app](../apps/macos-app/index.md)
- [iOS app](../apps/ios-app/index.md)
- [Daemon](../systems/daemon/index.md)
- [Agent provider](../primitives/agent-provider.md)
- [Token usage](../primitives/token-usage.md)
