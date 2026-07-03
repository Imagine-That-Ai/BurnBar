# 0004 — Named-pipe peer-auth design (R16) + ConPTY harness

**Status:** scaffold landed (VAL-P0-CONPTY-018). Live Windows proof is
VAL-P0-CONPTY-019.
**Owner tree:** `windows/pal/ipc/` (portable) + `windows/pal/ipc-windows/` (Win32).
**Risk:** R16 (`docs/WINDOWS_PORT_MASTER_PLAN.md` §13), plus R15/R19 touch-points.

---

## 1. Why this exists

macOS authenticates the app↔daemon Unix-domain socket with a
codesign/audit-token/`getpeereid` peer gate (~85 sites, bidirectional, release-
hardened). Windows has no Unix socket and no audit token. The parity substitute
is a **hardened named pipe** whose peer gate must be *at least as strong* as the
codesign gate. R16 is the risk that a naive named-pipe gate is **weaker**:

| R16 threat | Why a naive pipe gate fails | Control that closes it |
|---|---|---|
| PID reuse / TOCTOU | A PID read from the pipe can be recycled to another process between check and use | Kernel-attested **SID** via `ImpersonateNamedPipeClient`, not PID trust; the signed-nonce handshake re-binds identity to key possession |
| DLL injection into a signed process | Authenticode on the main image still passes when a malicious DLL is injected | **Loaded-module validation**: WinVerifyTrust *every* module + trusted-directory allowlist |
| Pipe squatting | An attacker creates the pipe name first and impersonates the daemon | **`FIRST_PIPE_INSTANCE`** + owner-only **SDDL DACL**; mutual handshake so a squatter without the pinned key cannot answer |
| Release env compile-out | A dev "disable auth" env var ships to production | Bypass wrapped in `#if !RELEASE_HARDENED`, folded to constant `false` in the shipping build |

---

## 2. Control → implementation-point map

Every R16 control named in the master plan maps to a concrete symbol below.

| R16 control | Implementation point | File |
|---|---|---|
| **Owner DACL (SDDL)** | `NamedPipePeerAuthListener.CreateHardenedServerPipe(sddl)` → `ConvertStringSecurityDescriptorToSecurityDescriptorW`; default `D:P(A;;GA;;;SY)(A;;GA;;;OW)` (protected DACL, SYSTEM + owner only) | `windows/pal/ipc-windows/NamedPipePeerAuthListener.cs` |
| **`FIRST_PIPE_INSTANCE`** | `CreateHardenedServerPipe` sets `FILE_FLAG_FIRST_PIPE_INSTANCE` in `dwOpenMode`; a non-first error is treated as "a squatter owns the name" | `NamedPipePeerAuthListener.cs` + `Interop/NativeConstants.cs` |
| **Handle-validate peer / `ImpersonateNamedPipeClient` + SID** | `PeerIdentityResolver.Resolve` → `GetNamedPipeClientProcessId` (PID) + `ImpersonateNamedPipeClient` → `OpenThreadToken` → `GetTokenInformation(TokenUser)` → `ConvertSidToStringSid`; listener compares against `PeerAuthPolicy.ExpectedClientSid` | `windows/pal/ipc-windows/PeerIdentity.cs`, `NamedPipePeerAuthListener.AuthenticateConnectedPeerAsync` |
| **Verify image (Authenticode)** | `PeerImageValidator.IsAuthenticodeTrusted` → `WinVerifyTrust(WINTRUST_ACTION_GENERIC_VERIFY_V2)` | `windows/pal/ipc-windows/PeerImageValidator.cs` |
| **Verify loaded modules** | `PeerImageValidator.Validate` enumerates `Process.Modules` and runs Authenticode **+ trusted-directory allowlist** on every module (not just the main image) | `PeerImageValidator.cs` |
| **Signed-nonce mutual handshake** | Portable state machine `SignedNonceHandshakeVerifier` (issue/verify) + `SignedNonceResponder` (sign) + `MutualHandshakeEndpoint`; driven both directions in `RunMutualHandshakeAsync`; transcript `HandshakeTranscript` (domain-separated + role-bound) | `windows/pal/ipc/*.cs`, `NamedPipePeerAuthListener.cs`, `NamedPipePeerAuthConnector.cs` |
| **CNG/TPM-backed keys (R15 link)** | `CngNonceSigner`/`CngNonceVerifier` over `ECDsaCng`; `CngNonceKeyProvisioning.OpenOrCreatePersistedKey` creates a non-exportable key in the Microsoft Platform Crypto Provider | `windows/pal/ipc-windows/CngNonceCredentials.cs` |
| **Compile out disable-env in release** | `NamedPipePeerAuthListener.DeveloperBypassEngaged` → `#if RELEASE_HARDENED return false;` (JIT-folded) | `NamedPipePeerAuthListener.cs` |
| **DLL side-load hardening (R19 link)** | `[assembly: DefaultDllImportSearchPaths(System32)]` pins every P/Invoke to System32 | `windows/pal/ipc-windows/Interop/NativeMethods.cs` |

**Gate order** (fail-fast; first failure wins), in `AuthenticateConnectedPeerAsync`:
`SID → image+modules → signed-nonce mutual handshake`. A connection is accepted
only if all three pass. The wire framing lives in `HandshakeWire` (length-prefixed
challenge/response frames); the *signed* bytes are always the portable transcript,
never the raw nonce.

---

## 3. Portable vs. Windows split (why the handshake is testable off-Windows)

The handshake is deliberately cut so its **decision logic** is platform-free:

- **Portable** (`OpenBurnBar.Pal.Ipc`, `net10.0`): the nonce state machine, the
  domain-separated/role-bound transcript, and the `INonceSigner`/`INonceVerifier`/
  `IHandshakeClock`/`INonceSource` seams. No OS calls. This is what the macOS unit
  tests exercise (real ECDSA-P256 + a manual clock).
- **Windows** (`OpenBurnBar.Pal.Ipc.Windows`, `net10.0` compiled with
  `[assembly: SupportedOSPlatform("windows")]`): the Win32 primitives — pipe
  creation, SID/image/module checks, CNG keys, ConPTY, Job Objects. Compiles on
  macOS (P/Invoke declarations + annotated BCL types) but only *runs* on Windows.

The same transcript and ECDSA signature scheme are shared between the macOS test
credentials and the Windows CNG credentials, so CONPTY-019 re-runs the identical
handshake assertions against CNG without editing the state machine or the tests.

### 3.1 Per-item off-Windows testability (no blanket "where feasible")

| Handshake step | macOS-tested now? | Justification |
|---|---|---|
| Nonce issue (fresh, sized, stamped) | ✅ | Pure logic — `IssueChallenge` |
| Accept valid, fresh, in-TTL signed nonce | ✅ | `Verify_ValidFreshResponse_IsAccepted` |
| Reject **replay** of an accepted nonce | ✅ | `Verify_Replayed…` (+ across re-issue, + bounded history) |
| Reject **expired** challenge (at/after TTL) | ✅ | `Verify_ResponseAfterTtl…` + just-before-TTL accept, via a manual clock |
| Reject **wrong signature** (wrong key / tampered sig) | ✅ | `Verify_ResponseSignedByWrongKey…`, `…TamperedSignatureBytes…` — real ECDSA verify |
| Reject unknown / tampered nonce / malformed | ✅ | dedicated cases |
| Role binding (no reflection) | ✅ | transcript differs by role; mutual reflection rejected |
| Full mutual handshake (both directions) | ✅ | `MutualHandshake_BetweenTwoEndpoints…` |
| Wire framing round-trip over a **real named pipe** | ❌ → CONPTY-019 | Requires a live Windows named pipe; the framing logic is deterministic but the transport is OS-only |
| Kernel **SID** of a connecting process | ❌ → CONPTY-019 | `ImpersonateNamedPipeClient`/token APIs need a real Windows connection and a second process |
| **Image + loaded-module** verdict | ❌ → CONPTY-019 | `WinVerifyTrust` + `Process.Modules` require Windows PE images; the injected-DLL rejection must be proven with a real injected module |
| **CNG/TPM** non-exportable key + Hello-gated release | ❌ → CONPTY-019 | `ECDsaCng`/`CngKey` throw off-Windows; TPM binding needs real hardware |
| `RELEASE_HARDENED` bypass compiled out | ⚠️ partial | Both branches **compile** on macOS (Debug and `-p:DefineConstants=…RELEASE_HARDENED`); the *behavioral* proof that the env var is dead in a shipped binary is CONPTY-019 |

Every `❌` is a step whose behavior is defined by the Windows kernel/TPM/PE
loader and cannot be honestly exercised on macOS; each is deferred to
VAL-P0-CONPTY-019, not waved away.

---

## 4. ConPTY session harness (spawn + resize + clean tree kill)

Separate from R16 peer-auth but part of the same PAL IPC seam and the same
contract. The macOS `openpty` interactive-session equivalent:

| Capability | Implementation point | File |
|---|---|---|
| Spawn attached to a pseudoconsole | `ConPtySession.Spawn` → `CreatePseudoConsole` + `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` on `CreateProcessW` | `windows/pal/ipc-windows/ConPtySession.cs` |
| Live resize | `ConPtySession.Resize` → `ResizePseudoConsole` | `ConPtySession.cs` |
| Clean process-**tree** kill | `JobObjectProcessTree` — `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` + `TerminateJobObject`, with a `taskkill /T /F` fallback | `windows/pal/ipc-windows/JobObjectProcessTree.cs` |

Windows has no `SIGTERM` and no POSIX process group, so the macOS
"SIGTERM-the-group / exit-15-clean" logic is rewritten as a Job Object: the
child and every descendant die with the job. Interactive spawn/resize/kill
against a real console program is VAL-P0-CONPTY-019.

---

## 5. What the deployment must supply

`PeerAuthPolicy` is the seam a deployment fills:
- `ExpectedClientSid` — the interactive user's SID the daemon will accept.
- `PeerImageValidator(trustedDirectories)` — the install dir + `System32`.
- `SelfSignerFactory` / `PeerVerifierFactory` — CNG signer for this side, pinned
  peer public key for the other. Key provisioning + pinning is CONPTY-019 work.
