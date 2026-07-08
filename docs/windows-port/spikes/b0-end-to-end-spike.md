# WS-B0 end-to-end walking proof

**Branch:** `windows/b0-spike-end-to-end`  
**Gate:** Proves the ADR **WPD-0007** contract (in-process Swift Engine + `net8.0` forwarding facades) before production lanes B1–B6.

> **Note:** `docs/windows-port/decisions/0007-windows-app-backend.md` is not present on this branch; the spike follows the assignment contract: ConPTY → parse (Engine) → SQLCipher `token_usage` → live readback.

## Intended path (production shape)

```text
ConPtyCliStream (ICliStream)
    → stdout / stream-json bytes
    → ClaudeCodeParser (Swift Engine; UniFFI in B3)
    → TokenUsageWriteSeam.WriteTokenUsage (SQLCipher)
    → read row back (Dashboard tile / IConversationReadStore)
```

## What this spike proves

| Step | macOS authoring host | Windows dev host |
|------|----------------------|------------------|
| **Parse** | `swift run OpenBurnBarG2ParserParity` via `SwiftEngineParseBridge` — real lifted `ClaudeCodeParser` over committed `AgentLensTests/Fixtures/ParserContract/` | Same binary in Windows Engine CI (`openburnbar-engine-windows.yml`) |
| **Persist** | `dotnet test windows/tests/b0-spike` — opens Mac SQLCipher fixture, writes `token_usage`, reopens, asserts round-trip | Same managed assembly + `bundle_e_sqlcipher` win RID |
| **Live tile** | Console readback (`LiveTileReadback.FormatTile`) after `ReadTokenUsage` | WinUI Dashboard wiring deferred (B1–B6) |
| **ConPTY** | `ConPtyCliStream` **compiles**; runtime throws `PlatformNotSupportedException` off-Windows | `ConPtySession.Spawn` + stream events (VAL-P0-CONPTY-019) |

## macOS proof command

```bash
cd windows/tests/b0-spike
dotnet test OpenBurnBar.B0Spike.Tests.csproj -c Debug --nologo
```

Expected: all tests pass, including `SwiftEngine_ParseStep_G2ParserParityPasses` (first run may compile Swift; allow several minutes).

## Deferred (not this spike)

- UniFFI C# bindings for in-process Engine calls (B3).
- Wiring `ConPtyCliStream` into `OpenBurnBar.App` (replace `StubCliStream`).
- Live CLI spawn (`claude --output-format stream-json`) on Windows.
- WinUI Dashboard tile binding.

## Artifacts

- `windows/tests/b0-spike/` — xUnit spike project.
- `windows/tests/b0-spike/Support/ConPtyCliStream.cs` — ConPTY `ICliStream` implementation (spike-local seam mirror).