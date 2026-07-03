# `windows/pal/ipc-windows/` — Win32 IPC harness (W1 / R16)

The **Windows half** of the app↔daemon IPC seam: it wires the portable
signed-nonce handshake ([`../ipc/`](../ipc/)) into real Win32 primitives, plus the
ConPTY session harness. Targets `net10.0` with `[assembly: SupportedOSPlatform("windows")]`
so it **compiles on the macOS authoring host** (P/Invoke declarations + annotated
BCL types) yet only **runs** on Windows — the live proof is VAL-P0-CONPTY-019.

| File | R16 / ConPTY control |
|------|----------------------|
| `NamedPipePeerAuthListener.cs` | hardened server pipe (SDDL DACL + `FIRST_PIPE_INSTANCE`) + the SID→image→handshake gate; release-hardened dev bypass (`#if RELEASE_HARDENED`) |
| `NamedPipePeerAuthConnector.cs` | client connect + mirror mutual handshake |
| `PeerIdentity.cs` | `ImpersonateNamedPipeClient` → kernel-attested PID + SID |
| `PeerImageValidator.cs` | `WinVerifyTrust` on the image **and every loaded module** + trusted-dir allowlist |
| `CngNonceCredentials.cs` | CNG/TPM-backed `INonceSigner`/`INonceVerifier` + non-exportable key provisioning |
| `HandshakeWire.cs` | length-prefixed challenge/response framing over the pipe |
| `ConPtySession.cs` | `CreatePseudoConsole` spawn + `ResizePseudoConsole` + tree kill |
| `JobObjectProcessTree.cs` | `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` + `taskkill /T` fallback |
| `Interop/` | P/Invoke declarations, structs, constants (System32-pinned) |

Control → implementation map + per-item off-Windows testability:
[`docs/windows-port/design/0004-named-pipe-peer-auth.md`](../../../docs/windows-port/design/0004-named-pipe-peer-auth.md).
Dev-host proof steps:
[`docs/windows-port/runbooks/CONPTY-019-dev-host-runbook.md`](../../../docs/windows-port/runbooks/CONPTY-019-dev-host-runbook.md).
