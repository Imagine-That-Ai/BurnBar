# Linux Daemon Target Map

This note records the Linux target boundary used to compile `OpenBurnBarDaemon`, `OpenBurnBarCLI`, and `OpenBurnBarDaemonExecutable` without inventing a parallel daemon RPC stack.

The preserved daemon transport remains the existing BurnBarRPC AF_UNIX path:

- `OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
- `OpenBurnBarDaemon/OpenBurnBarCLI.swift`
- `OpenBurnBarDaemon/BurnBarDaemonPeerAuthenticator.swift`

## Excluded And Stubbed Surfaces

| Surface | Linux handling in this lane | Resulting behavior |
| --- | --- | --- |
| `ElderWandFusionOrchestrator.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed. ElderWand orchestration does not compile or ship in the Linux daemon lane. |
| `ElderWandToolLoop.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed. No Linux tool-loop surface is exposed from this compile gate. |
| `ElderWandWebTools.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed. No Linux web-tool wrapper is exposed from this compile gate. |
| `OpenBurnBarHTTPGatewayElderWandIntegration.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed. No ElderWand-specific HTTP gateway integration compiles on Linux. |
| `OpenBurnBarHTTPGatewayError.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Narrowed surface. Linux keeps a daemon-facing gateway type, but the Apple gateway error and Network.framework path stay out of scope. |
| `OpenBurnBarHTTPGatewayRequests.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Narrowed surface. Linux parses only the minimal loopback HTTP requests needed by the compile gate. |
| `OpenBurnBarHTTPGatewayResponseTypes.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Narrowed surface. Linux serves minimal JSON responses from the replacement loopback server. |
| `OpenBurnBarHTTPGatewayServer.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Narrowed surface. Linux binds only via POSIX sockets and rejects non-loopback gateway configuration. |
| `OpenBurnBarHTTPGatewayServer+Connection.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Narrowed surface. Connection handling is reduced to the replacement server's minimal POSIX accept loop. |
| `OpenBurnBarHTTPGatewayServer+CrossVendorDegrade.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. Cross-vendor degrade behavior is not reimplemented for Linux here. |
| `OpenBurnBarHTTPGatewayServer+Endpoints.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Narrowed surface. Linux keeps only the replacement server's limited loopback endpoints. |
| `OpenBurnBarHTTPGatewayServer+HTTPTransport.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. The Apple transport split is not compiled on Linux. |
| `OpenBurnBarHTTPGatewayServer+ModelCatalog.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. Full model-catalog HTTP behavior remains out of scope. |
| `OpenBurnBarHTTPGatewayServer+RoutePipeline.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. The full HTTP route pipeline is not reopened on Linux. |
| `OpenBurnBarHTTPGatewayServer+UsageLogging.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. Full gateway usage logging remains out of scope. |
| `GatewayModelCatalogSource.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. No separate Linux catalog source was added. |
| `GatewayRouteLogging.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. The Linux compile gate does not reopen route-level gateway logging. |
| `GatewayStreamingUsageAccumulator.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux | Fail-closed in this lane. Streaming usage accumulation stays out of scope. |
| `OpenBurnBarSwitcherShell.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/OpenBurnBarSwitcherShellLinux.swift` | Fail-closed. Shell execution and shim installation throw explicit Linux-unavailable errors, and the Linux profile store is inert. |
| `PensieveKnowledgeWatcher.swift` | Excluded by `OpenBurnBarDaemon/Package.swift` on Linux; replaced by `Linux/PensieveKnowledgeWatcherLinux.swift` | Fail-closed. Filesystem watching becomes a no-op with `lastError` set to an explicit Linux-unavailable message. |
| `Linux/OpenBurnBarHTTPGatewayServerLinux.swift` | Linux-only replacement | Keeps a single daemon-facing gateway type compiled on Linux, but only for loopback POSIX sockets and a narrowed request/response surface. |
| `Linux/OpenBurnBarSwitcherShellLinux.swift` | Linux-only replacement | Keeps compile-time shell types available while refusing runtime shell execution and shim installation on Linux. |
| `Linux/PensieveKnowledgeWatcherLinux.swift` | Linux-only replacement | Keeps compile-time Pensieve watcher types available while refusing to perform live filesystem watching on Linux. |

## Scope Guard

This target map intentionally avoids:

- inventing `DaemonEnvelope`, `DaemonTransport`, `UnixSocketTransport`, or `NSXPC` daemon RPC layers;
- replacing BurnBarRPC AF_UNIX with any parallel daemon transport;
- reopening HTTP gateway, switcher shell, Pensieve watcher, or ElderWand behavior beyond the narrowed and fail-closed Linux boundary above.
