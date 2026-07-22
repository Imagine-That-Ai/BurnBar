# OpenBurnBar.App.CursorConnector (portable, net8.0)

Windows peer of the macOS **CursorConnector**
(`AgentLens/Services/CursorConnector/*.swift`). Portable-first: every seam is
provable via `dotnet test` on the macOS authoring host. Windows-native process,
socket, log-tail, and `state.vscdb` adapters remain separate from this portable
core. The connector/tooling plane itself is production-composed through the
authenticated companion server.

## What the connector does

The Mac connector lets Cursor use OpenBurnBar-routed providers (Z.ai / MiniMax /
Ollama Cloud): it runs a local OpenAI-compatible proxy, exposes it through a
Cloudflare quick-tunnel, rewrites Cursor's editor settings to point at that
tunnel, resolves per-route provider keys through a loopback **secret broker**
(so keys never touch the proxy's config file), and tails the proxy's usage log to
attribute token spend.

## Parity map (Swift oracle → this project)

| C# file | Swift source |
| --- | --- |
| `ConnectorModels.cs` | `CursorConnectorModels.swift` (all Codable/Hashable types) |
| `ConnectorProviderCatalog.cs` | `ConnectorProvider` metadata + `supportedModel`/`provider(forBaseURL)` fallback |
| `CursorConnectorLogStreamManager.cs` | `CursorConnectorLogStreamManager.swift` (delta tail + offsets) |
| `UsageEventNormalizer.cs` | `CursorConnectorManager.normalizeUsageEvent` (VAL-TOKEN buckets) |
| `UsageLogConsumer.cs` | `CursorConnectorManager.consumeUsageLogChunk` (JSONL → events, deterministic id) |
| `TryCloudflareUrlExtractor.cs` | `CursorConnectorManager.extractTryCloudflareURL` (canonical-host hardening) |
| `CursorConnectorSecretBroker.cs` | `CursorConnectorManager+SecretBroker.swift` (request→response contract) |
| `RoutedClientConfigSyncService.cs` | `RoutedClientConfigSyncService` (Factory / OpenCode config) |
| `CursorSettingsApplier.cs` | `backupAndApplyCursorSettings` / `restoreCursorSettings` |
| `CursorConnectorSession.cs` | `connect()` / `disconnect()` state machine + rollback |
| `ConnectorConfigurationValidator.cs` | Preflight provider/model validation before runtime side effects |
| `Seams.cs` | `KeychainStore` / `FileHandle` / `SecRandomCopyBytes` / `Date` seams |

## Seams (portable core ⇄ deferred `.Windows` bucket B)

- `IConnectorClock` — timing (`SystemConnectorClock`).
- `ISecretStore` — Keychain on Mac → **DPAPI/CNG** on Windows (bucket B).
- `ILogStreamSource` — real file tail (bucket B).
- `ICursorStateStore` — `state.vscdb` ItemTable read/write; the real half reuses
  the same `Microsoft.Data.Sqlite` open pattern as the landed
  `CursorStateDbReader` (bucket B).
- `IConnectorFileSystem` — external-client config files (bucket B).
- `IRandomTokenSource` — CSPRNG (`SystemRandomTokenSource`, portable).

`CursorConnectorSession` runs the portable provider/model preflight before
calling the injected runtime steps. This keeps an empty configuration from
starting the broker, proxy, tunnel, or Cursor-settings rewrite. API-key presence
is intentionally left to `IConnectorSessionSteps.ValidateConfiguration()`,
where the Windows implementation can use DPAPI/CNG without putting secrets in
the portable model.

## Composition, not duplication

`CursorSettingsApplier.ReadAccountIdentity` delegates to the landed
`OpenBurnBar.App.Quota.Acquisition.CursorStateDbReader` for the Cursor account
identity (auth JWT + email + membership) rather than opening a second
`state.vscdb` reader. This project references `OpenBurnBar.App.Quota.Acquisition`.

## Windows adapter boundary

The connector plane uses the app-wide DPAPI secret store and a DNS-pinned HTTPS
transport directly. Cursor-specific log tailing, `state.vscdb` writes, and
proxy/cloudflared process supervision stay in their Windows adapters; the
portable core owns their parsing, ordering, rollback, and HTTP contracts.

## Test

```
dotnet test windows/tests/cursor-connector/OpenBurnBar.App.CursorConnector.Tests.csproj
```
