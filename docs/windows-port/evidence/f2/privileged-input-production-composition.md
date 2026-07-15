# F2 privileged-input production composition

Date: 2026-07-14

WPD-0006 rows: 24, 26, 27

Disposition: source implementation complete; signed-host and physical promotion pending

## Production path

An approved durable agent run can execute the seven Windows desktop-input tool
kinds through a concrete in-process bridge and an isolated native-input process:

1. `HeadlessAgentRunService` persists the exact approval identifier that
   authorizes the next risky tool and attaches it to the pending tool call.
2. `CompanionCliAgentRunHandler` claims supported input calls and executes them
   through `PrivilegedInputRunToolExecutor` instead of exporting raw input to an
   unauthenticated client.
3. The executor strictly parses bounded typed arguments, opens or validates the
   session audit archive, and appends a redacted tamper-evident reservation
   before requesting any native side effect.
4. `PrivilegedInputBrokerClient` mutually authenticates the separately packaged
   `OpenBurnBar.PrivilegedInput.exe` over the hardened per-user named pipe.
5. The broker verifies watchdog health, current UIA target policy, and the
   durable kill flag before reserving the action ID and calling `SendInput`.

The broker accepts only the exact `OpenBurnBar.App.exe` main image signed by the
expected `Imagine That AI LLC` publisher. The app accepts only the exact broker
image with that publisher. Both directions retain the existing SID, module,
trusted-directory, signed-nonce, first-pipe-instance, and remote-client checks.

## Replay and audit safety

Every dispatch carries the durable tool-call ID as its action ID. The broker
writes a receipt reservation before `SendInput`, then records the bounded result:

- a completed duplicate returns the cached response without a second input;
- an abandoned reservation returns `dispatch_indeterminate` and never retries;
- a missing, oversized, redirected, or corrupt receipt ledger fails closed.

Audit summaries never store typed text, selectors, entered values, or URLs. The
descriptor hash preserves evidence that the approved action was fixed without
revealing its payload. Restart recovery requires the manifest, complete JSONL
chain, and terminal `head.json` to agree; terminal-entry tampering is rejected.
The run output contains only action kind, dispatch status, and the audit head.

## Panic and lifecycle

The app registers Ctrl+Alt+Win+Period as the global panic chord and subscribes
to workstation-lock notifications before enabling the input executor. The
global chord, workstation lock, explicit settings halt, and app exit write the
durable local flag synchronously before contacting the independent watchdog,
closing the IPC scheduling window at the panic boundary. A settings session can
clear the flag only when the panic monitor is registered and the authenticated
broker becomes healthy; failed readiness re-arms the flag.

The broker independently checks watchdog health before every dispatch. The
execution leaf checks the durable flag before target inspection, again before
receipt reservation, and before each typed character. Built-in credential,
login, UAC, Windows Security, privacy, elevated-terminal, and guarded URL rules
are applied inside the broker, after live UIA inspection.

## Release layout

The release workflow publishes complete self-contained x64 and ARM64 helper
runtimes under `ComputerUseWatchdog/` and `PrivilegedInput/`. Recursive Azure
Artifact Signing covers their first-party executables and assemblies. The
signed x64 workflow executes each helper's exact-publisher self-check. Portable
and MSIX staging retain the nested runtimes, and MSIX packaging fails when
either executable is absent.

## Local verification

The authoring-host verification for this change records:

- Computer Use: 148 passed, 1 explicit live-Playwright platform skip;
- managed runtime: 293 passed;
- configuration: 58 passed;
- authenticated IPC: 22 passed;
- Computer Use Windows adapter: `net8.0` and `net10.0`, zero warnings/errors;
- privileged-input broker: Release build, zero warnings/errors;
- watchdog: Release build, zero warnings/errors;
- ops release hardening: pass.

The managed tests cover exact approval propagation, redacted audit persistence,
validated restart resume, invalid-input denial, panic entries, protected-target
denial, kill checks, completed replay, indeterminate replay, and durable-ledger
corruption. The WinUI XAML compiler remains Windows-only and is delegated to the
exact-head Windows build lanes.

## Honest boundary

This is production composition for the ordinary interactive desktop. It does
not claim secure-desktop, lock-screen, or cross-integrity injection. Such a path
would require a purpose-built signed keyboard/mouse HID driver and independent
certification. ViGEm emulates game controllers and is not used as a desktop
keyboard/mouse solution.

Source completion does not replace signed exact-head verification or the
physical x64 protocol. Release certification remains blocked until a signed
candidate proves real input delivery, protected-target denial, panic latency,
watchdog restart recovery, wrong-publisher rejection, and receipt/audit survival
on the physical Intel machine. Physical ARM64 remains an explicit beta coverage
limitation rather than simulated evidence.
