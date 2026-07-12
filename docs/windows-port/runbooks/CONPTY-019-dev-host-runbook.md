# CONPTY-019 — Windows dev-host runbook

**Turns the scaffold from VAL-P0-CONPTY-018 into live proof on Windows.**

Scope: the interactive ConPTY session and the live named-pipe peer-auth handshake
that *cannot* be exercised on the macOS authoring host (see
`docs/windows-port/design/0004-named-pipe-peer-auth.md` §3.1 for the per-item
list of what is already macOS-tested vs. deferred here).

Everything below runs on a **Windows 11 dev host** (a real or TPM-backed VM;
Windows Hello + a TPM are needed for the CNG parity items).

---

## 0. Prerequisites

```powershell
winget install Microsoft.DotNet.SDK.10      # dotnet 10.0.30x, matches the mac host
winget install Microsoft.VisualStudio.2022.BuildTools   # or full VS 2022
dotnet --version                            # expect 10.0.30x
```

- A TPM 2.0 (or a vTPM in the VM) for the Microsoft Platform Crypto Provider.
- Windows Hello configured, to prove Hello-gated key *release* (R15 link).
- Admin PowerShell for the pipe/SID/injection tests (they cross a trust boundary).

---

## 1. Build the harness + run the portable tests on Windows

The portable unit suite is the SAME assertions that pass on macOS; running them
here proves the state machine is byte-for-byte identical on the Windows runtime.

```powershell
cd windows
dotnet build OpenBurnBar.sln -c Debug
dotnet test  tests\ipc\OpenBurnBar.Pal.Ipc.Tests.csproj -c Debug
#   expect: Passed! Failed: 0, Passed: 20
```

Build the release-hardened flavor to confirm the dev bypass is gone:

```powershell
dotnet build pal\ipc-windows\OpenBurnBar.Pal.Ipc.Windows.csproj -c Release ^
  -p:DefineConstants="TRACE;RELEASE_HARDENED"
# Then confirm OPENBURNBAR_PIPE_AUTH_DISABLE=1 has NO effect in §3 below.
```

---

## 2. ConPTY session proof (spawn + resize + clean tree kill)

Drive `ConPtySession` from a scratch console app (or `dotnet script`):

```csharp
using OpenBurnBar.Pal.Ipc.Windows;

using var session = ConPtySession.Spawn("cmd.exe", columns: 120, rows: 30);
// (a) SPAWN: read session.Output — expect the cmd banner + prompt.
// (b) RESIZE: session.Resize(80, 24); write "mode con\r\n" to session.Input and
//     confirm the reported console size follows the resize.
// (c) spawn a grandchild that outlives its parent, e.g.:
//        session.Input.Write("start /b ping -n 60 127.0.0.1\r\n");
//     note the ping PID (Get-Process ping).
session.KillProcessTree();      // (d) TREE KILL
```

**Pass criteria**
- (a) child banner appears on `Output`.
- (b) the child observes the new dimensions after `Resize`.
- (c)/(d) after `KillProcessTree()`, `Get-Process ping,cmd` returns **nothing** —
  no orphaned grandchild survives (the Job Object killed the whole tree). Repeat
  with `Dispose()` instead of `KillProcessTree()` to prove KILL_ON_JOB_CLOSE.

Record `Get-Process` before/after as evidence.

---

## 3. Named-pipe peer-auth proof (R16)

Two processes: a **daemon** (server) and an **app** (client). Provision one CNG
key per side and cross-pin the public halves.

```csharp
// Daemon side
using var daemonKey = new CngNonceSigner(
    CngNonceKeyProvisioning.OpenOrCreatePersistedKey("OpenBurnBar.Daemon.PipeAuth"));
byte[] daemonPub = daemonKey.ExportPublicKey();     // hand to the app to pin

var policy = new PeerAuthPolicy(
    expectedClientSid: "<the interactive user SID>",         // whoami /user
    imageValidator: new PeerImageValidator(new[] {
        @"C:\Program Files\OpenBurnBar", @"C:\Windows\System32" }),
    selfSignerFactory: () => daemonKey,
    peerVerifierFactory: () => new CngNonceVerifier(appPub));

var listener = new NamedPipePeerAuthListener("OpenBurnBar.Daemon", policy);
using var pipe = listener.CreateHardenedServerPipe();       // SDDL DACL + FIRST_PIPE_INSTANCE
await pipe.WaitForConnectionAsync();
PeerAuthResult result = await listener.AuthenticateConnectedPeerAsync(pipe);
// result.Accepted == true for the genuine app.
```

Run each check and record the `PeerAuthResult.Outcome` / exception:

| # | Test | Expected outcome |
|---|------|------------------|
| 3.1 | Genuine app connects with the pinned key | `Accepted` |
| 3.2 | **Squatter** creates `\\.\pipe\OpenBurnBar.Daemon` first | daemon's `CreateHardenedServerPipe` throws (FIRST_PIPE_INSTANCE) |
| 3.3 | Different-user client connects | `RejectedBySid` |
| 3.4 | App with an **injected unsigned DLL** connects | `RejectedByImage`, DLL listed in `UntrustedModules` |
| 3.5 | App signs with the **wrong key** | `RejectedByHandshake` (portable verdict `RejectedBadSignature`) |
| 3.6 | **Replay** a captured response frame | `RejectedByHandshake` (verdict `RejectedReplay`) |
| 3.7 | Delay the response past the TTL | `RejectedByHandshake` (verdict `RejectedExpired`) |
| 3.8 | `OPENBURNBAR_PIPE_AUTH_DISABLE=1` on a **RELEASE_HARDENED** build, bad SID | still `RejectedBySid` (bypass compiled out) |
| 3.9 | Same env var on a **Debug** build, bad SID | `Accepted` with `detail="dev-bypass…"` (bypass present only in dev) |

3.4 needs a real injection (e.g. `CreateRemoteThread`+`LoadLibrary`, or a
manifest-planted DLL from a writable dir). 3.6/3.7 need a captured/parked wire
frame — reuse `HandshakeWire` to serialize/replay.

**CNG / R15 parity (3.10):** confirm `OpenOrCreatePersistedKey` returns a key
whose `ExportPolicy` forbids private-key export, and that signing prompts Windows
Hello when the key is release-gated. Attempt `key.Export(CngKeyBlobFormat.EccPrivateBlob)`
and confirm it throws.

---

## 4. Evidence to capture

Drop under `docs/windows-port/evidence/CONPTY-019/`:
- `dotnet test` transcript (20/20) on Windows.
- ConPTY before/after `Get-Process` for the tree-kill.
- The 3.1–3.10 outcome table with real `PeerAuthResult`/exception values.
- A screen capture of the Hello prompt on release-gated signing (3.10).

When all rows pass, VAL-P0-CONPTY-019 is satisfied; update its contract and this
runbook's status line.
