# OpenBurnBar.App.ManagedAgentRuntime

Portable (`net8.0`, no WinUI) port of the macOS **Managed Agent Runtime**
(`AgentLens/Services/ManagedAgentRuntime/`). This is the platform-independent half
of the subsystem: the runtime-adapter contract + status model, the **Pi Agent**
runtime-controller state machine, the Pi CLI command profile, the Redis-backed
instance-discovery seam, the OpenAI-compatible gateway-probe seam, and the
process-run orchestration seam.

The same assembly is referenced by the WinUI app and proven on the macOS authoring
host today via `dotnet test` (`windows/tests/managed-agent-runtime`, 97 tests) —
the pattern already used by the storage seam, the Computer-Use core, and the
presentation view-models.

## Parity map (macOS oracle → C#)

| Swift (`AgentLens/Services/ManagedAgentRuntime/…`) | C# |
|---|---|
| `ManagedAgentRuntime.swift` (`ManagedAgentRuntimeKind`, `…Status`, `…Instance`, adapter protocol) | `ManagedAgentRuntimeKind.cs`, `ManagedAgentRuntimeStatus.cs`, `ManagedAgentInstance.cs`, `IManagedAgentRuntimeAdapter.cs` |
| `PiAgentCommandProfile.swift` | `PiAgentCommandProfile.cs` |
| `PiAgentRedisDiscovery.swift` | `Discovery/PiAgentRedisSnapshot.cs`, `Discovery/IPiAgentRedisDiscovery.cs`, `Discovery/PiAgentRedisInstanceDecoder.cs`, `Discovery/PiAgentRedisHttpDiscovery.cs` |
| `ManagedRuntimeProcessRunner.swift` | `Process/IManagedRuntimeProcessRunner.cs`, `Process/IManagedExecutableResolver.cs` |
| `PiAgentRuntimeAdapter.swift` | `PiAgentRuntimeAdapterDependencies.cs`, `PiAgentRuntimeAdapter.cs` |
| `OpenAICompatibleModelProbe` / `…ModelListParser` (CLIBridge) | `Gateway/IManagedRuntimeGatewayProbe.cs`, `Gateway/OpenAICompatibleGatewayProbe.cs`, `Http/*` |

## Seams and the deferred (Windows / bucket-B) remainder

Everything above runs on macOS because the network calls go through an injectable
`IManagedRuntimeHttpTransport` (the `URLSession` analog, backed by cross-platform
`HttpClient`). The **only** pieces that need a real Windows dev host are the two
process seams, kept behind interfaces so the state machine + tests are complete now:

- `IManagedRuntimeProcessRunner` — real `run` / `launch-detached`. The Windows
  adapter reuses the process/stream seam already landed in the tree
  (`windows/app/OpenBurnBar.App/Cli/ConPtyCliStream.cs` +
  `OpenBurnBar.Pal.Ipc.Windows.ConPtySession`) rather than inventing a new launcher,
  and applies the macOS runner's allowlisted-PATH environment hardening (M-040).
- `IManagedExecutableResolver` — real PATH / `PATHEXT` / shim-dir walk to resolve `pi`.

The composed companion plane exposes bounded `run.submit`, `run.resume`, and
`run.recover` operations. Startup inspects the journal for interrupted runs and
records only the recoverable-run count in diagnostics; it never logs step
payloads or provider credentials.

`GatewayAuthTokenPolicy` applies the same fail-closed local-gateway rule as the
Mac: an existing bearer token is preserved, an absent token is generated from
the OS CSPRNG, and only the explicit unauthenticated-loopback opt-out returns
no token. The desktop composition persists generated tokens through its
platform secret store.

Timing is injected too: the per-request HTTP timeout (2s, matching the Swift
`timeoutInterval`) is a constructor parameter on the discovery + probe. The runtime
controller itself reads no wall clock — neither does the Swift original.
